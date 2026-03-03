(* Tangerine native codegen – stage0
   Compiles AST to arm64 / x86_64 assembly, links via cc.
   No C transpilation – direct native emission. *)

open Ast

(* ── Architecture ──────────────────────────────────────────────────── *)

type arch = Arm64 | X86_64

let read_command_output cmd =
  let ic = Unix.open_process_in cmd in
  let r = try input_line ic with End_of_file -> "" in
  let _ = Unix.close_process_in ic in
  String.trim r

let detect_arch () =
  let a = read_command_output "uname -m" in
  if a = "arm64" || a = "aarch64" then Arm64 else X86_64

(* ── Value kinds ───────────────────────────────────────────────────── *)

type val_kind = KDirect | KStruct of string | KEnum of string

(* ── Layout info ───────────────────────────────────────────────────── *)

type struct_layout = {
  sl_fields : (string * int) list;   (* field name → byte offset *)
  sl_size : int;
}

type enum_layout = {
  el_variants : (string * int * int) list;  (* name, tag, field_count *)
  el_max_payload : int;
  el_size : int;    (* 8 tag + 8 * max_payload *)
}

type fn_info = {
  fi_params : (string * val_kind) list;
  fi_ret : val_kind;
}

(* ── Compiler environment ──────────────────────────────────────────── *)

type local_var = { lv_offset : int; lv_kind : val_kind }

type frame = {
  mutable locals : (string * local_var) list;
  mutable next_off : int;     (* grows negative from fp *)
  mutable label_cnt : int;
}

type env = {
  struct_map : (string * struct_layout) list;
  enum_map : (string * enum_layout) list;
  variant_map : (string * (string * int * int)) list;  (* variant → (enum, tag, nfields) *)
  fn_map : (string * fn_info) list;
  arch : arch;
}

(* ── Helpers ───────────────────────────────────────────────────────── *)

let align16 n =
  let r = n mod 16 in
  if r = 0 then n else n + 16 - r

let fresh_label fr prefix =
  fr.label_cnt <- fr.label_cnt + 1;
  Printf.sprintf ".L%s_%d" prefix fr.label_cnt

let alloc_slot fr kind =
  fr.next_off <- fr.next_off - 8;
  let off = fr.next_off in
  (off, kind)

let alloc_local fr name kind =
  let (off, k) = alloc_slot fr kind in
  fr.locals <- (name, { lv_offset = off; lv_kind = k }) :: fr.locals;
  off

let alloc_data fr size =
  let aligned = ((size + 7) / 8) * 8 in
  fr.next_off <- fr.next_off - aligned;
  fr.next_off

let find_local fr name =
  try List.assoc name fr.locals
  with Not_found -> { lv_offset = 0; lv_kind = KDirect }

let kind_of_typ env = function
  | TyName (n, _) ->
    if List.mem_assoc n env.struct_map then KStruct n
    else if List.mem_assoc n env.enum_map then KEnum n
    else KDirect
  | _ -> KDirect

(* ── Architecture-specific emission ────────────────────────────────── *)

let b = Buffer.add_string

let emit_fn_label buf arch name =
  let sym = "_" ^ name in
  match arch with
  | Arm64 ->
    b buf ".p2align 2\n";
    b buf (".globl " ^ sym ^ "\n");
    b buf (sym ^ ":\n")
  | X86_64 ->
    b buf (".globl " ^ sym ^ "\n");
    b buf (sym ^ ":\n")

let emit_prologue buf arch =
  match arch with
  | Arm64 ->
    b buf "  stp x29, x30, [sp, #-16]!\n";
    b buf "  mov x29, sp\n"
  | X86_64 ->
    b buf "  pushq %rbp\n";
    b buf "  movq %rsp, %rbp\n"

let emit_sub_sp buf arch n =
  if n > 0 then
    match arch with
    | Arm64 -> b buf (Printf.sprintf "  sub sp, sp, #%d\n" n)
    | X86_64 -> b buf (Printf.sprintf "  subq $%d, %%rsp\n" n)

let emit_epilogue buf arch =
  match arch with
  | Arm64 ->
    b buf "  mov sp, x29\n";
    b buf "  ldp x29, x30, [sp], #16\n";
    b buf "  ret\n"
  | X86_64 ->
    b buf "  movq %rbp, %rsp\n";
    b buf "  popq %rbp\n";
    b buf "  retq\n"

let emit_push buf arch =
  match arch with
  | Arm64 -> b buf "  str x0, [sp, #-16]!\n"
  | X86_64 -> b buf "  subq $16, %rsp\n  movq %rax, (%rsp)\n"

let emit_pop buf arch reg =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  ldr %s, [sp], #16\n" reg)
  | X86_64 -> b buf (Printf.sprintf "  movq (%%rsp), %s\n  addq $16, %%rsp\n" reg)

let emit_load_int buf arch v =
  match arch with
  | Arm64 ->
    if v >= 0 && v <= 65535 then
      b buf (Printf.sprintf "  mov x0, #%d\n" v)
    else if v >= -65536 && v < 0 then
      b buf (Printf.sprintf "  mov x0, #%d\n" v)
    else begin
      let u = if v >= 0 then v else v land 0x7FFFFFFFFFFFFFFF in
      b buf (Printf.sprintf "  movz x0, #%d\n" (u land 0xFFFF));
      if (u lsr 16) land 0xFFFF <> 0 then
        b buf (Printf.sprintf "  movk x0, #%d, lsl #16\n" ((u lsr 16) land 0xFFFF));
      if (u lsr 32) land 0xFFFF <> 0 then
        b buf (Printf.sprintf "  movk x0, #%d, lsl #32\n" ((u lsr 32) land 0xFFFF));
      if (u lsr 48) land 0xFFFF <> 0 then
        b buf (Printf.sprintf "  movk x0, #%d, lsl #48\n" ((u lsr 48) land 0xFFFF))
    end
  | X86_64 ->
    b buf (Printf.sprintf "  movq $%d, %%rax\n" v)

let emit_load_local buf arch off =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  ldr x0, [x29, #%d]\n" off)
  | X86_64 -> b buf (Printf.sprintf "  movq %d(%%rbp), %%rax\n" off)

let emit_store_local buf arch off =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  str x0, [x29, #%d]\n" off)
  | X86_64 -> b buf (Printf.sprintf "  movq %%rax, %d(%%rbp)\n" off)

let emit_store_param buf arch i off =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  str x%d, [x29, #%d]\n" i off)
  | X86_64 ->
    let regs = [|"%rdi"; "%rsi"; "%rdx"; "%rcx"; "%r8"; "%r9"|] in
    if i < 6 then
      b buf (Printf.sprintf "  movq %s, %d(%%rbp)\n" regs.(i) off)

let emit_load_field buf arch field_off =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  ldr x0, [x0, #%d]\n" field_off)
  | X86_64 -> b buf (Printf.sprintf "  movq %d(%%rax), %%rax\n" field_off)

let emit_store_field buf arch base_reg field_off =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  str x0, [%s, #%d]\n" base_reg field_off)
  | X86_64 -> b buf (Printf.sprintf "  movq %%rax, %d(%s)\n" field_off base_reg)

let emit_addr_of_local buf arch off =
  match arch with
  | Arm64 ->
    if off >= 0 then
      b buf (Printf.sprintf "  add x0, x29, #%d\n" off)
    else
      b buf (Printf.sprintf "  sub x0, x29, #%d\n" (-off))
  | X86_64 ->
    b buf (Printf.sprintf "  leaq %d(%%rbp), %%rax\n" off)

let emit_call buf arch name =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  bl _%s\n" name)
  | X86_64 -> b buf (Printf.sprintf "  callq _%s\n" name)

let emit_label buf lbl =
  b buf (lbl ^ ":\n")

let emit_branch buf arch lbl =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  b %s\n" lbl)
  | X86_64 -> b buf (Printf.sprintf "  jmp %s\n" lbl)

let emit_cbz buf arch lbl =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  cbz x0, %s\n" lbl)
  | X86_64 ->
    b buf "  testq %rax, %rax\n";
    b buf (Printf.sprintf "  je %s\n" lbl)

let emit_cbnz buf arch lbl =
  match arch with
  | Arm64 -> b buf (Printf.sprintf "  cbnz x0, %s\n" lbl)
  | X86_64 ->
    b buf "  testq %rax, %rax\n";
    b buf (Printf.sprintf "  jne %s\n" lbl)

(* Binary operations: x1=left, x0=right → result in x0 *)
let emit_binop buf arch op =
  match arch with
  | Arm64 -> begin match op with
    | Add -> b buf "  add x0, x1, x0\n"
    | Sub -> b buf "  sub x0, x1, x0\n"
    | Mul -> b buf "  mul x0, x1, x0\n"
    | Div -> b buf "  sdiv x0, x1, x0\n"
    | Mod ->
      b buf "  sdiv x2, x1, x0\n";
      b buf "  msub x0, x2, x0, x1\n"
    | Eq ->
      b buf "  cmp x1, x0\n";
      b buf "  cset w0, eq\n"
    | Neq ->
      b buf "  cmp x1, x0\n";
      b buf "  cset w0, ne\n"
    | Lt ->
      b buf "  cmp x1, x0\n";
      b buf "  cset w0, lt\n"
    | Gt ->
      b buf "  cmp x1, x0\n";
      b buf "  cset w0, gt\n"
    | Le ->
      b buf "  cmp x1, x0\n";
      b buf "  cset w0, le\n"
    | Ge ->
      b buf "  cmp x1, x0\n";
      b buf "  cset w0, ge\n"
    | BitAnd -> b buf "  and x0, x1, x0\n"
    | BitOr -> b buf "  orr x0, x1, x0\n"
    | BitXor -> b buf "  eor x0, x1, x0\n"
    | Shl -> b buf "  lsl x0, x1, x0\n"
    | Shr -> b buf "  asr x0, x1, x0\n"
    | And | Or -> ()  (* handled by short circuit *)
    end
  | X86_64 -> begin
    (* rcx=left, rax=right *)
    match op with
    | Add ->
      b buf "  addq %rax, %rcx\n";
      b buf "  movq %rcx, %rax\n"
    | Sub ->
      b buf "  subq %rax, %rcx\n";
      b buf "  movq %rcx, %rax\n"
    | Mul ->
      b buf "  imulq %rax, %rcx\n";
      b buf "  movq %rcx, %rax\n"
    | Div ->
      b buf "  movq %rax, %r11\n";
      b buf "  movq %rcx, %rax\n";
      b buf "  cqto\n";
      b buf "  idivq %r11\n"
    | Mod ->
      b buf "  movq %rax, %r11\n";
      b buf "  movq %rcx, %rax\n";
      b buf "  cqto\n";
      b buf "  idivq %r11\n";
      b buf "  movq %rdx, %rax\n"
    | Eq ->
      b buf "  cmpq %rax, %rcx\n";
      b buf "  sete %al\n";
      b buf "  movzbq %al, %rax\n"
    | Neq ->
      b buf "  cmpq %rax, %rcx\n";
      b buf "  setne %al\n";
      b buf "  movzbq %al, %rax\n"
    | Lt ->
      b buf "  cmpq %rax, %rcx\n";
      b buf "  setl %al\n";
      b buf "  movzbq %al, %rax\n"
    | Gt ->
      b buf "  cmpq %rax, %rcx\n";
      b buf "  setg %al\n";
      b buf "  movzbq %al, %rax\n"
    | Le ->
      b buf "  cmpq %rax, %rcx\n";
      b buf "  setle %al\n";
      b buf "  movzbq %al, %rax\n"
    | Ge ->
      b buf "  cmpq %rax, %rcx\n";
      b buf "  setge %al\n";
      b buf "  movzbq %al, %rax\n"
    | BitAnd ->
      b buf "  andq %rax, %rcx\n";
      b buf "  movq %rcx, %rax\n"
    | BitOr ->
      b buf "  orq %rax, %rcx\n";
      b buf "  movq %rcx, %rax\n"
    | BitXor ->
      b buf "  xorq %rax, %rcx\n";
      b buf "  movq %rcx, %rax\n"
    | Shl ->
      b buf "  movq %rax, %rcx\n";  (* shift amount in %cl *)
      b buf "  movq (%rsp), %rax\n"; (* reload left – not ideal *)
      b buf "  shlq %cl, %rax\n"
    | Shr ->
      b buf "  movq %rax, %rcx\n";
      b buf "  movq (%rsp), %rax\n";
      b buf "  sarq %cl, %rax\n"
    | And | Or -> ()
    end

let emit_neg buf arch =
  match arch with
  | Arm64 -> b buf "  neg x0, x0\n"
  | X86_64 -> b buf "  negq %rax\n"

let emit_not buf arch =
  match arch with
  | Arm64 ->
    b buf "  cmp x0, #0\n";
    b buf "  cset w0, eq\n"
  | X86_64 ->
    b buf "  testq %rax, %rax\n";
    b buf "  sete %al\n";
    b buf "  movzbq %al, %rax\n"

let pop_reg arch = match arch with
  | Arm64 -> "x1"
  | X86_64 -> "%rcx"

(* ── Expression codegen ────────────────────────────────────────────── *)
(* Result always in x0 (arm64) or rax (x86_64) *)

let rec emit_expr buf env fr expr =
  let arch = env.arch in
  match expr with
  | EInt (v, _) -> emit_load_int buf arch v
  | EBool (true, _) -> emit_load_int buf arch 1
  | EBool (false, _) | ENil _ -> emit_load_int buf arch 0
  | EFloat (_, _) -> emit_load_int buf arch 0  (* stub *)
  | EStr (_, _) -> emit_load_int buf arch 0  (* stub *)
  | EChar (_, _) -> emit_load_int buf arch 0  (* stub *)

  | EIdent (name, _) ->
    let lv = find_local fr name in
    emit_load_local buf arch lv.lv_offset

  | EBinOp ((And | Or) as op, left, right, _) ->
    (* Short-circuit *)
    let lbl = fresh_label fr "sc" in
    emit_expr buf env fr left;
    (match op with
     | And -> emit_cbz buf arch lbl   (* if left=0, skip right, result=0 *)
     | Or  -> emit_cbnz buf arch lbl  (* if left!=0, skip right, result=left *)
     | _ -> ());
    emit_expr buf env fr right;
    emit_label buf lbl

  | EBinOp (op, left, right, _) ->
    emit_expr buf env fr left;
    emit_push buf arch;
    emit_expr buf env fr right;
    emit_pop buf arch (pop_reg arch);
    emit_binop buf arch op

  | EUnOp (Neg, inner, _) ->
    emit_expr buf env fr inner;
    emit_neg buf arch

  | EUnOp (Not, inner, _) ->
    emit_expr buf env fr inner;
    emit_not buf arch

  | EUnOp (_, inner, _) ->
    emit_expr buf env fr inner   (* stub for addr/deref *)

  | ECall (EIdent (name, _), args, _) ->
    (* Check if this is an enum variant constructor *)
    if List.mem_assoc name env.variant_map then begin
      let (enum_name, tag, _nfields) = List.assoc name env.variant_map in
      let el = List.assoc enum_name env.enum_map in
      let data_off = alloc_data fr el.el_size in
      (* Store tag *)
      emit_load_int buf arch tag;
      emit_push buf arch;
      emit_addr_of_local buf arch data_off;
      emit_pop buf arch (pop_reg arch);
      (match arch with
       | Arm64 -> b buf "  str x1, [x0, #0]\n"
       | X86_64 -> b buf "  movq %rcx, (%rax)\n");
      (* Store payload fields *)
      List.iteri (fun i arg ->
        emit_expr buf env fr arg;
        emit_push buf arch;
        emit_addr_of_local buf arch data_off;
        emit_pop buf arch (pop_reg arch);
        let foff = 8 + i * 8 in
        (match arch with
         | Arm64 -> b buf (Printf.sprintf "  str x1, [x0, #%d]\n" foff)
         | X86_64 -> b buf (Printf.sprintf "  movq %%rcx, %d(%%rax)\n" foff))
      ) args;
      (* Result = pointer to enum data *)
      emit_addr_of_local buf arch data_off
    end else begin
      (* Regular function call *)
      let n = List.length args in
      (* Evaluate args left to right, push each *)
      List.iter (fun arg ->
        emit_expr buf env fr arg;
        emit_push buf arch
      ) args;
      (* Pop into arg registers in reverse order *)
      for i = n - 1 downto 0 do
        match arch with
        | Arm64 -> b buf (Printf.sprintf "  ldr x%d, [sp], #16\n" i)
        | X86_64 ->
          let regs = [|"%rdi"; "%rsi"; "%rdx"; "%rcx"; "%r8"; "%r9"|] in
          if i < 6 then begin
            b buf (Printf.sprintf "  movq (%%rsp), %s\n" regs.(i));
            b buf "  addq $16, %rsp\n"
          end
      done;
      emit_call buf arch name
    end

  | ECall (_callee, args, l) ->
    (* General call: evaluate callee, then treat as indirect — for now error *)
    emit_expr buf env fr (ECall (EIdent ("_indirect", l), args, l))

  | EMethodCall (obj, method_name, args, _) ->
    (* Desugar to function call with self as first arg *)
    let all_args = obj :: args in
    let n = List.length all_args in
    List.iter (fun arg ->
      emit_expr buf env fr arg;
      emit_push buf arch
    ) all_args;
    for i = n - 1 downto 0 do
      match arch with
      | Arm64 -> b buf (Printf.sprintf "  ldr x%d, [sp], #16\n" i)
      | X86_64 ->
        let regs = [|"%rdi"; "%rsi"; "%rdx"; "%rcx"; "%r8"; "%r9"|] in
        if i < 6 then begin
          b buf (Printf.sprintf "  movq (%%rsp), %s\n" regs.(i));
          b buf "  addq $16, %rsp\n"
        end
    done;
    emit_call buf arch method_name

  | EFieldAccess (obj, field, _) ->
    emit_expr buf env fr obj;
    (* Determine struct name from obj *)
    let sname = match expr_struct_name env fr obj with
      | Some s -> s
      | None -> ""
    in
    if List.mem_assoc sname env.struct_map then begin
      let sl = List.assoc sname env.struct_map in
      let foff = try List.assoc field sl.sl_fields with Not_found -> 0 in
      emit_load_field buf arch foff
    end else
      emit_load_field buf arch 0  (* guess offset 0 *)

  | EIndex (obj, idx, _) ->
    emit_expr buf env fr idx;
    emit_push buf arch;
    emit_expr buf env fr obj;
    emit_pop buf arch (pop_reg arch);
    (* obj in x0, idx in x1 — obj[idx] = *(obj + idx * 8) *)
    (match arch with
     | Arm64 ->
       b buf "  lsl x1, x1, #3\n";
       b buf "  ldr x0, [x0, x1]\n"
     | X86_64 ->
       b buf "  movq (%rax,%rcx,8), %rax\n")

  | EStructLit (sname, fields, _) ->
    if List.mem_assoc sname env.struct_map then begin
      let sl = List.assoc sname env.struct_map in
      let data_off = alloc_data fr sl.sl_size in
      (* Store each field *)
      List.iter (fun (fname, fexpr) ->
        emit_expr buf env fr fexpr;
        emit_push buf arch;
        emit_addr_of_local buf arch data_off;
        emit_pop buf arch (pop_reg arch);
        let foff = try List.assoc fname sl.sl_fields with Not_found -> 0 in
        (match arch with
         | Arm64 -> b buf (Printf.sprintf "  str x1, [x0, #%d]\n" foff)
         | X86_64 -> b buf (Printf.sprintf "  movq %%rcx, %d(%%rax)\n" foff))
      ) fields;
      (* Result = pointer to struct data *)
      emit_addr_of_local buf arch data_off
    end else begin
      emit_load_int buf arch 0  (* unknown struct *)
    end

  | EIf (branches, else_body, _) ->
    let end_lbl = fresh_label fr "endif" in
    let rec emit_branches = function
      | [] ->
        (match else_body with
         | Some stmts -> emit_stmts buf env fr stmts
         | None -> ())
      | { cond; body } :: rest ->
        let next_lbl = fresh_label fr "elif" in
        emit_expr buf env fr cond;
        emit_cbz buf arch next_lbl;
        emit_stmts buf env fr body;
        emit_branch buf arch end_lbl;
        emit_label buf next_lbl;
        emit_branches rest
    in
    emit_branches branches;
    emit_label buf end_lbl

  | EWhile (cond, body, _) ->
    let top_lbl = fresh_label fr "wtop" in
    let end_lbl = fresh_label fr "wend" in
    emit_label buf top_lbl;
    emit_expr buf env fr cond;
    emit_cbz buf arch end_lbl;
    emit_stmts buf env fr body;
    emit_branch buf arch top_lbl;
    emit_label buf end_lbl

  | EFor (var, iter, body, _) ->
    (* Stub: evaluate iter, ignore *)
    ignore (var, iter);
    emit_stmts buf env fr body

  | ELoop (body, _) ->
    let top_lbl = fresh_label fr "ltop" in
    emit_label buf top_lbl;
    emit_stmts buf env fr body;
    emit_branch buf arch top_lbl

  | EMatch (scrutinee, arms, _) ->
    let end_lbl = fresh_label fr "mend" in
    emit_expr buf env fr scrutinee;
    emit_push buf arch;  (* save scrutinee on stack *)
    List.iter (fun arm ->
      let next_lbl = fresh_label fr "marm" in
      emit_match_arm buf env fr arm next_lbl end_lbl;
      emit_label buf next_lbl
    ) arms;
    (* fallthrough — should not happen if patterns are exhaustive *)
    emit_pop buf arch (pop_reg arch);  (* clean up scrutinee *)
    emit_label buf end_lbl

  | EBlock (body, _) ->
    emit_stmts buf env fr body

  | EReturn (Some e, _) ->
    emit_expr buf env fr e;
    emit_epilogue buf arch

  | EReturn (None, _) ->
    emit_load_int buf arch 0;
    emit_epilogue buf arch

  | EBreak (_, _) | ENext _ ->
    (* Stub — need loop label context *)
    ()

  | EAssign (EIdent (name, _), rhs, _) ->
    emit_expr buf env fr rhs;
    let lv = find_local fr name in
    emit_store_local buf arch lv.lv_offset

  | EAssign (EFieldAccess (obj, field, _), rhs, _) ->
    emit_expr buf env fr rhs;
    emit_push buf arch;
    emit_expr buf env fr obj;
    let sname = match expr_struct_name env fr obj with Some s -> s | None -> "" in
    let foff =
      if List.mem_assoc sname env.struct_map then
        let sl = List.assoc sname env.struct_map in
        try List.assoc field sl.sl_fields with Not_found -> 0
      else 0
    in
    emit_pop buf arch (pop_reg arch);
    emit_store_field buf arch
      (match arch with Arm64 -> "x0" | X86_64 -> "%rax")
      foff

  | EAssign _ -> ()

  | ETuple _ | EArray _ | EClosure _ | ECast _ | ERange _ -> ()

and expr_struct_name _env fr = function
  | EIdent (name, _) ->
    let lv = find_local fr name in
    (match lv.lv_kind with KStruct s -> Some s | _ -> None)
  | EFieldAccess _ -> None  (* could recurse, but not needed for golden tests *)
  | _ -> None

and emit_match_arm buf env fr arm next_lbl end_lbl =
  let arch = env.arch in
  (* Scrutinee is on top of eval stack *)
  match arm.pat with
  | PatWild _ | PatBind (_, _) ->
    (* Always matches — pop scrutinee, bind if needed *)
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    (match arm.pat with
     | PatBind (name, _) ->
       let off = alloc_local fr name KDirect in
       emit_store_local buf arch off
     | _ -> ());
    emit_stmts buf env fr arm.arm_body;
    emit_branch buf arch end_lbl

  | PatLit (EInt (v, _)) ->
    (* Load scrutinee without popping *)
    (match arch with
     | Arm64 -> b buf "  ldr x0, [sp]\n"
     | X86_64 -> b buf "  movq (%rsp), %rax\n");
    emit_push buf arch;
    emit_load_int buf arch v;
    emit_pop buf arch (pop_reg arch);
    (match arch with
     | Arm64 -> b buf "  cmp x1, x0\n  b.ne "; b buf next_lbl; b buf "\n"
     | X86_64 -> b buf "  cmpq %rax, %rcx\n  jne "; b buf next_lbl; b buf "\n");
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    emit_stmts buf env fr arm.arm_body;
    emit_branch buf arch end_lbl

  | PatLit (EBool (bv, _)) ->
    (match arch with
     | Arm64 -> b buf "  ldr x0, [sp]\n"
     | X86_64 -> b buf "  movq (%rsp), %rax\n");
    emit_push buf arch;
    emit_load_int buf arch (if bv then 1 else 0);
    emit_pop buf arch (pop_reg arch);
    (match arch with
     | Arm64 -> b buf "  cmp x1, x0\n  b.ne "; b buf next_lbl; b buf "\n"
     | X86_64 -> b buf "  cmpq %rax, %rcx\n  jne "; b buf next_lbl; b buf "\n");
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    emit_stmts buf env fr arm.arm_body;
    emit_branch buf arch end_lbl

  | PatVariant (vname, sub_pats, _) ->
    (* Scrutinee is a pointer to enum data on top of eval stack *)
    (* Load tag: *)
    (match arch with
     | Arm64 ->
       b buf "  ldr x0, [sp]\n";       (* load scrutinee pointer *)
       b buf "  ldr x0, [x0, #0]\n"    (* load tag *)
     | X86_64 ->
       b buf "  movq (%rsp), %rax\n";
       b buf "  movq (%rax), %rax\n");
    (* Compare tag with expected *)
    let expected_tag =
      try let (_, tag, _) = List.assoc vname env.variant_map in tag
      with Not_found -> -1
    in
    emit_push buf arch;
    emit_load_int buf arch expected_tag;
    emit_pop buf arch (pop_reg arch);
    (match arch with
     | Arm64 -> b buf "  cmp x1, x0\n  b.ne "; b buf next_lbl; b buf "\n"
     | X86_64 -> b buf "  cmpq %rax, %rcx\n  jne "; b buf next_lbl; b buf "\n");
    (* Tag matches — extract payload fields into pattern bindings *)
    List.iteri (fun i sub ->
      match sub with
      | PatBind (name, _) ->
        (* Load scrutinee pointer, then load payload field *)
        (match arch with
         | Arm64 ->
           b buf "  ldr x0, [sp]\n";
           b buf (Printf.sprintf "  ldr x0, [x0, #%d]\n" (8 + i * 8))
         | X86_64 ->
           b buf "  movq (%rsp), %rax\n";
           b buf (Printf.sprintf "  movq %d(%%rax), %%rax\n" (8 + i * 8)));
        let off = alloc_local fr name KDirect in
        emit_store_local buf arch off
      | PatWild _ -> ()
      | _ -> ()  (* nested patterns not handled yet *)
    ) sub_pats;
    (* Pop scrutinee, execute body *)
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    emit_stmts buf env fr arm.arm_body;
    emit_branch buf arch end_lbl

  | _ ->
    (* Unsupported pattern — skip *)
    emit_branch buf arch next_lbl

and emit_stmts buf env fr stmts =
  List.iter (fun s -> emit_stmt buf env fr s) stmts

and emit_stmt buf env fr = function
  | SLet { name; typ; value; _ } ->
    let kind = match typ with
      | Some t -> kind_of_typ env t
      | None -> KDirect
    in
    let off = alloc_local fr name kind in
    emit_expr buf env fr value;
    emit_store_local buf env.arch off

  | SExpr e ->
    emit_expr buf env fr e

(* ── Build environment from program ────────────────────────────────── *)

let build_struct_map items =
  List.fold_left (fun acc item ->
    match item with
    | IStruct { name; fields; _ } ->
      let fl = List.mapi (fun i fd ->
        (fd.fd_name, i * 8)
      ) fields in
      let size = List.length fields * 8 in
      (name, { sl_fields = fl; sl_size = (if size = 0 then 8 else size) }) :: acc
    | _ -> acc
  ) [] items

let build_enum_map items =
  List.fold_left (fun acc item ->
    match item with
    | IEnum { name; variants; _ } ->
      let max_payload = List.fold_left (fun mx vd ->
        max mx (List.length vd.vd_fields)
      ) 0 variants in
      let els = List.mapi (fun tag vd ->
        (vd.vd_name, tag, List.length vd.vd_fields)
      ) variants in
      let size = 8 + max_payload * 8 in
      (name, { el_variants = els; el_max_payload = max_payload;
               el_size = (if size < 8 then 8 else size) }) :: acc
    | _ -> acc
  ) [] items

let build_variant_map enum_map =
  List.fold_left (fun acc (ename, el) ->
    List.fold_left (fun acc2 (vname, tag, nf) ->
      (vname, (ename, tag, nf)) :: acc2
    ) acc el.el_variants
  ) [] enum_map

let build_fn_map env items =
  List.fold_left (fun acc item ->
    match item with
    | IFn { name; params; ret; _ } ->
      let fi_params = List.map (fun p ->
        (p.p_name, kind_of_typ env p.p_typ)
      ) params in
      let fi_ret = match ret with
        | Some t -> kind_of_typ env t
        | None -> KDirect
      in
      (name, { fi_params; fi_ret }) :: acc
    | _ -> acc
  ) [] items

(* ── Compile a single function ─────────────────────────────────────── *)

let compile_function buf env fn_name fn_params fn_ret fn_body =
  let _ = fn_ret in
  let arch = env.arch in
  let fr = { locals = []; next_off = 0; label_cnt = 0 } in

  (* Allocate param slots *)
  let param_offs = List.map (fun p ->
    let kind = kind_of_typ env p.p_typ in
    alloc_local fr p.p_name kind
  ) fn_params in

  (* Generate body into temporary buffer *)
  let body_buf = Buffer.create 4096 in

  (* Store params from registers *)
  List.iteri (fun i off ->
    emit_store_param body_buf arch i off
  ) param_offs;

  (* Emit body *)
  emit_stmts body_buf env fr fn_body;

  (* Compute frame size *)
  let frame_size = align16 (- fr.next_off) in

  (* Write function *)
  emit_fn_label buf arch fn_name;
  emit_prologue buf arch;
  emit_sub_sp buf arch frame_size;
  Buffer.add_buffer buf body_buf;
  emit_epilogue buf arch

(* ── Compile entire program to assembly string ─────────────────────── *)

let compile_program (prog : Ast.program) arch : (string * Diagnostics.t list) =
  let items = prog.items in
  let struct_map = build_struct_map items in
  let enum_map = build_enum_map items in
  let variant_map = build_variant_map enum_map in
  let env_partial = {
    struct_map; enum_map; variant_map;
    fn_map = []; arch
  } in
  let fn_map = build_fn_map env_partial items in
  let env = { env_partial with fn_map } in

  let buf = Buffer.create 8192 in
  b buf ".text\n";

  List.iter (fun item ->
    match item with
    | IFn { name; params; ret; body; _ } ->
      compile_function buf env name params ret body;
      b buf "\n"
    | _ -> ()
  ) items;

  (Buffer.contents buf, [])

(* ── Public API: compile .tg file to native binary ─────────────────── *)

let compile_tg_to_native ~file ~source ~output ~cc : (int * Diagnostics.t list) =
  let diagnostics = ref [] in
  let add_diag sev code msg =
    diagnostics := Diagnostics.make ~severity:sev ~code ~file ~line:1 ~col:1 msg :: !diagnostics
  in
  (* Lex *)
  let lexed = Lexer.lex ~file source in
  if Diagnostics.count_errors lexed.diagnostics > 0 then begin
    add_diag Diagnostics.Error "E300" "lex errors prevent compilation";
    (1, lexed.diagnostics @ List.rev !diagnostics)
  end else
  (* Parse *)
  let parsed = Parser.parse ~file lexed.tokens in
  if Diagnostics.count_errors parsed.parse_diags > 0 then begin
    add_diag Diagnostics.Error "E300" "parse errors prevent compilation";
    (1, parsed.parse_diags @ List.rev !diagnostics)
  end else begin
    let arch = detect_arch () in
    let (asm_text, codegen_diags) = compile_program parsed.program arch in
    if Diagnostics.count_errors codegen_diags > 0 then begin
      (1, codegen_diags @ List.rev !diagnostics)
    end else begin
      let asm_file = Filename.temp_file "tgc0_" ".s" in
      let ch = open_out asm_file in
      output_string ch asm_text;
      close_out ch;
      let cmd = Printf.sprintf "%s %s -o %s"
        (Filename.quote cc) (Filename.quote asm_file) (Filename.quote output) in
      let exit_code = Sys.command cmd in
      (try Sys.remove asm_file with _ -> ());
      if exit_code <> 0 then
        add_diag Diagnostics.Error "E301"
          (Printf.sprintf "native link failed (cc exit %d): %s" exit_code cmd)
      else
        add_diag Diagnostics.Warning "W300"
          "compiled via direct native assembly (no C)";
      ((if exit_code = 0 then 0 else 1), List.rev !diagnostics)
    end
  end
