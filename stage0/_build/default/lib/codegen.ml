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
  mutable loop_labels : (string * string) list;  (* (break_lbl, continue_lbl) stack *)
  self_type : string;  (* impl target type name, "" for free functions *)
}

(* Global string literals accumulated during codegen *)
let string_literals : (string * string) list ref = ref []  (* (label, value) *)
let string_counter = ref 0
let label_counter = ref 0

let add_string_literal s =
  (* Check if this string already has a label *)
  match List.find_opt (fun (_, v) -> v = s) !string_literals with
  | Some (lbl, _) -> lbl
  | None ->
    incr string_counter;
    let lbl = Printf.sprintf ".Lstr_%d" !string_counter in
    string_literals := (lbl, s) :: !string_literals;
    lbl

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

let fresh_label prefix =
  incr label_counter;
  Printf.sprintf ".L%s_%d" prefix !label_counter

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

let kind_of_typ ?(self_type="") env = function
  | TyName (n, _) ->
    if List.mem_assoc n env.struct_map then KStruct n
    else if List.mem_assoc n env.enum_map then KEnum n
    else KDirect
  | TySelf ->
    if self_type <> "" then
      if List.mem_assoc self_type env.struct_map then KStruct self_type
      else if List.mem_assoc self_type env.enum_map then KEnum self_type
      else KDirect
    else KDirect
  | TyRef (_, inner) ->
    (* References carry the inner type's kind, bool indicates mutability *)
    (match inner with
     | TyName (n, _) ->
       if List.mem_assoc n env.struct_map then KStruct n
       else if List.mem_assoc n env.enum_map then KEnum n
       else KDirect
     | TySelf when self_type <> "" ->
       if List.mem_assoc self_type env.struct_map then KStruct self_type
       else if List.mem_assoc self_type env.enum_map then KEnum self_type
       else KDirect
     | _ -> KDirect)
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
    | Arm64 ->
      if n <= 4095 then
        b buf (Printf.sprintf "  sub sp, sp, #%d\n" n)
      else begin
        b buf (Printf.sprintf "  mov x16, #%d\n" n);
        b buf "  sub sp, sp, x16\n"
      end
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
      (* For negative values, reconstruct all 64-bit unsigned chunks.
         OCaml integers are 63–bit on 64-bit platforms, so we must handle
         the sign extension carefully. *)
      let chunk0 = v land 0xFFFF in
      let chunk1 = (v lsr 16) land 0xFFFF in
      let chunk2 = (v lsr 32) land 0xFFFF in
      let chunk3 = (v lsr 48) land 0xFFFF in
      b buf (Printf.sprintf "  movz x0, #%d\n" chunk0);
      if chunk1 <> 0 then
        b buf (Printf.sprintf "  movk x0, #%d, lsl #16\n" chunk1);
      if chunk2 <> 0 then
        b buf (Printf.sprintf "  movk x0, #%d, lsl #32\n" chunk2);
      if chunk3 <> 0 then
        b buf (Printf.sprintf "  movk x0, #%d, lsl #48\n" chunk3)
    end
  | X86_64 ->
    b buf (Printf.sprintf "  movq $%d, %%rax\n" v)

(* ARM64 fp-relative addressing helpers.
   ldur/stur: signed 9-bit immediate [-256, 255].
   ldr/str unsigned offset: [0, 32760] in multiples of 8.
   For offsets outside these ranges, compute address in x16 (IP0). *)

let arm64_fp_load buf reg off =
  if off >= -256 && off <= 255 then
    b buf (Printf.sprintf "  ldur %s, [x29, #%d]\n" reg off)
  else if off >= 0 && off mod 8 = 0 && off <= 32760 then
    b buf (Printf.sprintf "  ldr %s, [x29, #%d]\n" reg off)
  else begin
    if off < 0 && (-off) <= 4095 then
      b buf (Printf.sprintf "  sub x16, x29, #%d\n" (-off))
    else if off > 0 && off <= 4095 then
      b buf (Printf.sprintf "  add x16, x29, #%d\n" off)
    else begin
      b buf (Printf.sprintf "  mov x16, #%d\n" off);
      b buf "  add x16, x29, x16\n"
    end;
    b buf (Printf.sprintf "  ldr %s, [x16]\n" reg)
  end

let arm64_fp_store buf reg off =
  if off >= -256 && off <= 255 then
    b buf (Printf.sprintf "  stur %s, [x29, #%d]\n" reg off)
  else if off >= 0 && off mod 8 = 0 && off <= 32760 then
    b buf (Printf.sprintf "  str %s, [x29, #%d]\n" reg off)
  else begin
    if off < 0 && (-off) <= 4095 then
      b buf (Printf.sprintf "  sub x16, x29, #%d\n" (-off))
    else if off > 0 && off <= 4095 then
      b buf (Printf.sprintf "  add x16, x29, #%d\n" off)
    else begin
      b buf (Printf.sprintf "  mov x16, #%d\n" off);
      b buf "  add x16, x29, x16\n"
    end;
    b buf (Printf.sprintf "  str %s, [x16]\n" reg)
  end

let arm64_fp_addr buf dst off =
  if off = 0 then
    b buf (Printf.sprintf "  mov %s, x29\n" dst)
  else if off > 0 && off <= 4095 then
    b buf (Printf.sprintf "  add %s, x29, #%d\n" dst off)
  else if off < 0 && (-off) <= 4095 then
    b buf (Printf.sprintf "  sub %s, x29, #%d\n" dst (-off))
  else begin
    b buf (Printf.sprintf "  mov %s, #%d\n" dst off);
    b buf (Printf.sprintf "  add %s, x29, %s\n" dst dst)
  end

let emit_load_local buf arch off =
  match arch with
  | Arm64 -> arm64_fp_load buf "x0" off
  | X86_64 -> b buf (Printf.sprintf "  movq %d(%%rbp), %%rax\n" off)

let emit_store_local buf arch off =
  match arch with
  | Arm64 -> arm64_fp_store buf "x0" off
  | X86_64 -> b buf (Printf.sprintf "  movq %%rax, %d(%%rbp)\n" off)

let emit_store_param buf arch i off =
  match arch with
  | Arm64 -> arm64_fp_store buf (Printf.sprintf "x%d" i) off
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
  | Arm64 -> arm64_fp_addr buf "x0" off
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
  | EFloat (f, _) ->
    (* Encode float bits as integer — caller should interpret *)
    let bits = Int64.to_int (Int64.bits_of_float f) in
    emit_load_int buf arch bits
  | EStr (s, _) ->
    let lbl = add_string_literal s in
    (match arch with
     | Arm64 ->
       b buf (Printf.sprintf "  adrp x0, %s@PAGE\n" lbl);
       b buf (Printf.sprintf "  add x0, x0, %s@PAGEOFF\n" lbl)
     | X86_64 ->
       b buf (Printf.sprintf "  leaq %s(%%rip), %%rax\n" lbl))
  | EChar (s, _) ->
    (* EChar is stored as a string — take first character *)
    let code = if String.length s > 0 then Char.code s.[0] else 0 in
    emit_load_int buf arch code

  | EIdent (name, _) ->
    let lv = find_local fr name in
    emit_load_local buf arch lv.lv_offset

  | EBinOp ((And | Or) as op, left, right, _) ->
    (* Short-circuit *)
    let lbl = fresh_label "sc" in
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

  | EUnOp (AddrOf, EIdent (name, _), _) | EUnOp (AddrMut, EIdent (name, _), _) ->
    (* &x / &mut x — load the stack address of the named variable *)
    let lv = find_local fr name in
    emit_addr_of_local buf arch lv.lv_offset

  | EUnOp ((AddrOf | AddrMut), inner, _) ->
    (* &expr — evaluate into a temporary, then take its address *)
    let tmp_off = alloc_data fr 8 in
    emit_expr buf env fr inner;
    emit_store_local buf arch tmp_off;
    emit_addr_of_local buf arch tmp_off

  | EUnOp (Deref, inner, _) ->
    (* *ptr — evaluate pointer, then load the value it points to *)
    emit_expr buf env fr inner;
    (match arch with
     | Arm64 -> b buf "  ldr x0, [x0, #0]\n"
     | X86_64 -> b buf "  movq (%rax), %rax\n")

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

  | ECall (EFieldAccess (EIdent (type_name, _), variant_name, _), args, _)
    when List.mem_assoc type_name env.enum_map ->
    (* Enum variant constructor: EnumType::Variant(arg0, ...) — inline *)
    let el = List.assoc type_name env.enum_map in
    let tag = try
      let (_, t, _) = List.find (fun (n, _, _) -> n = variant_name) el.el_variants in t
    with Not_found -> 0 in
    let data_off = alloc_data fr el.el_size in
    (* Set tag *)
    emit_load_int buf arch tag;
    emit_push buf arch;
    emit_addr_of_local buf arch data_off;
    emit_pop buf arch (pop_reg arch);
    (match arch with
     | Arm64 -> b buf "  str x1, [x0, #0]\n"
     | X86_64 -> b buf "  movq %rcx, (%rax)\n");
    (* Set payload fields *)
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
    emit_addr_of_local buf arch data_off

  | ECall (EFieldAccess (EIdent (type_name, _), method_name, _), args, _) ->
    (* Static method call: Type.method(args) → Type__method(args) *)
    let qualified = type_name ^ "__" ^ method_name in
    let n = List.length args in
    List.iter (fun arg ->
      emit_expr buf env fr arg;
      emit_push buf arch
    ) args;
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
    emit_call buf arch qualified

  | ECall (_callee, args, l) ->
    (* General call: evaluate callee, then treat as indirect — for now error *)
    emit_expr buf env fr (ECall (EIdent ("_indirect", l), args, l))

  | EMethodCall (obj, method_name, args, _) ->
    (* Desugar to function call with self as first arg *)
    (* Qualify method name with receiver type when possible *)
    let qualified_name =
      match expr_struct_name env fr obj with
      | Some sname -> sname ^ "__" ^ method_name
      | None ->
        (match obj with
         | EIdent (name, _) ->
           let lv = find_local fr name in
           (match lv.lv_kind with
            | KEnum e -> e ^ "__" ^ method_name
            | _ -> method_name)
         | _ -> method_name)
    in
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
    emit_call buf arch qualified_name

  | EFieldAccess (EIdent (type_name, _), variant_name, _)
    when List.mem_assoc type_name env.enum_map ->
    (* Enum variant reference: EnumType::Variant — allocate and set tag *)
    let el = List.assoc type_name env.enum_map in
    let tag = try
      let (_, t, _) = List.find (fun (n, _, _) -> n = variant_name) el.el_variants in t
    with Not_found -> 0 in
    let data_off = alloc_data fr el.el_size in
    emit_load_int buf arch tag;
    emit_push buf arch;
    emit_addr_of_local buf arch data_off;
    emit_pop buf arch (pop_reg arch);
    (match arch with
     | Arm64 -> b buf "  str x1, [x0, #0]\n"
     | X86_64 -> b buf "  movq %rcx, (%rax)\n");
    emit_addr_of_local buf arch data_off

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
    let end_lbl = fresh_label "endif" in
    let rec emit_branches = function
      | [] ->
        (match else_body with
         | Some stmts -> emit_stmts buf env fr stmts
         | None -> ())
      | { cond; body } :: rest ->
        let next_lbl = fresh_label "elif" in
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
    let top_lbl = fresh_label "wtop" in
    let end_lbl = fresh_label "wend" in
    fr.loop_labels <- (end_lbl, top_lbl) :: fr.loop_labels;
    emit_label buf top_lbl;
    emit_expr buf env fr cond;
    emit_cbz buf arch end_lbl;
    emit_stmts buf env fr body;
    emit_branch buf arch top_lbl;
    emit_label buf end_lbl;
    fr.loop_labels <- (match fr.loop_labels with _ :: tl -> tl | [] -> [])

  | EFor (var, iter, body, _) ->
    (* For loop: for var in start..end do ... end *)
    let top_lbl = fresh_label "ftop" in
    let end_lbl = fresh_label "fend" in
    let step_lbl = fresh_label "fstep" in
    fr.loop_labels <- (end_lbl, step_lbl) :: fr.loop_labels;
    (match iter with
     | ERange (lo, hi, inclusive, _) ->
       (* Allocate loop variable and upper bound *)
       let var_off = alloc_local fr var KDirect in
       let hi_off = fst (alloc_slot fr KDirect) in
       fr.locals <- ("__for_hi", { lv_offset = hi_off; lv_kind = KDirect }) :: fr.locals;
       (* Initialize: var = lo, hi = hi_expr *)
       emit_expr buf env fr lo;
       emit_store_local buf arch var_off;
       emit_expr buf env fr hi;
       emit_store_local buf arch hi_off;
       (* Loop: while var < hi (exclusive) or var <= hi (inclusive) *)
       emit_label buf top_lbl;
       emit_load_local buf arch var_off;
       emit_push buf arch;
       emit_load_local buf arch hi_off;
       emit_pop buf arch (pop_reg arch);
       (* x1=var, x0=hi → check var < hi or var <= hi *)
       if inclusive then
         (match arch with
          | Arm64 ->
            b buf "  cmp x1, x0\n";
            b buf (Printf.sprintf "  b.gt %s\n" end_lbl)
          | X86_64 ->
            b buf "  cmpq %rax, %rcx\n";
            b buf (Printf.sprintf "  jg %s\n" end_lbl))
       else
         (match arch with
          | Arm64 ->
            b buf "  cmp x1, x0\n";
            b buf (Printf.sprintf "  b.ge %s\n" end_lbl)
          | X86_64 ->
            b buf "  cmpq %rax, %rcx\n";
            b buf (Printf.sprintf "  jge %s\n" end_lbl));
       emit_stmts buf env fr body;
       (* Step: var = var + 1 *)
       emit_label buf step_lbl;
       emit_load_local buf arch var_off;
       (match arch with
        | Arm64 -> b buf "  add x0, x0, #1\n"
        | X86_64 -> b buf "  incq %rax\n");
       emit_store_local buf arch var_off;
       emit_branch buf arch top_lbl;
       emit_label buf end_lbl
     | _ ->
       (* Non-range iterator: just evaluate body once with iter as value *)
       let var_off = alloc_local fr var KDirect in
       emit_expr buf env fr iter;
       emit_store_local buf arch var_off;
       emit_stmts buf env fr body;
       emit_label buf top_lbl;
       emit_label buf step_lbl;
       emit_label buf end_lbl);
    fr.loop_labels <- (match fr.loop_labels with _ :: tl -> tl | [] -> [])

  | ELoop (body, _) ->
    let top_lbl = fresh_label "ltop" in
    let end_lbl = fresh_label "lend" in
    fr.loop_labels <- (end_lbl, top_lbl) :: fr.loop_labels;
    emit_label buf top_lbl;
    emit_stmts buf env fr body;
    emit_branch buf arch top_lbl;
    emit_label buf end_lbl;
    fr.loop_labels <- (match fr.loop_labels with _ :: tl -> tl | [] -> [])

  | EMatch (scrutinee, arms, _) ->
    let end_lbl = fresh_label "mend" in
    emit_expr buf env fr scrutinee;
    emit_push buf arch;  (* save scrutinee on stack *)
    List.iter (fun arm ->
      let next_lbl = fresh_label "marm" in
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

  | EBreak (value, _) ->
    (match value with
     | Some e -> emit_expr buf env fr e
     | None -> ());
    (match fr.loop_labels with
     | (break_lbl, _) :: _ -> emit_branch buf arch break_lbl
     | [] -> ())

  | ENext _ ->
    (match fr.loop_labels with
     | (_, continue_lbl) :: _ -> emit_branch buf arch continue_lbl
     | [] -> ())

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

  | EAssign (EIndex (obj, idx, _), rhs, _) ->
    (* Array/tuple index assignment: obj[idx] = rhs *)
    emit_expr buf env fr rhs;
    emit_push buf arch;
    emit_expr buf env fr idx;
    emit_push buf arch;
    emit_expr buf env fr obj;
    emit_pop buf arch (pop_reg arch);
    (* x0=obj ptr, x1=idx *)
    (match arch with
     | Arm64 ->
       b buf "  lsl x1, x1, #3\n";
       b buf "  add x0, x0, x1\n"
     | X86_64 ->
       b buf "  leaq (%rax,%rcx,8), %rax\n");
    emit_push buf arch;
    emit_pop buf arch (pop_reg arch);
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    (* now x1=dest addr, x0=rhs value *)
    (match arch with
     | Arm64 -> b buf "  str x0, [x1, #0]\n"
     | X86_64 -> b buf "  movq %rax, (%rcx)\n")

  | EAssign _ -> ()

  | ETuple (elems, _) ->
    let n = List.length elems in
    let data_off = alloc_data fr (n * 8) in
    List.iteri (fun i elem ->
      emit_expr buf env fr elem;
      emit_push buf arch;
      emit_addr_of_local buf arch data_off;
      emit_pop buf arch (pop_reg arch);
      let foff = i * 8 in
      (match arch with
       | Arm64 -> b buf (Printf.sprintf "  str x1, [x0, #%d]\n" foff)
       | X86_64 -> b buf (Printf.sprintf "  movq %%rcx, %d(%%rax)\n" foff))
    ) elems;
    emit_addr_of_local buf arch data_off

  | EArray (elems, _) ->
    let n = List.length elems in
    let data_off = alloc_data fr (n * 8) in
    List.iteri (fun i elem ->
      emit_expr buf env fr elem;
      emit_push buf arch;
      emit_addr_of_local buf arch data_off;
      emit_pop buf arch (pop_reg arch);
      let foff = i * 8 in
      (match arch with
       | Arm64 -> b buf (Printf.sprintf "  str x1, [x0, #%d]\n" foff)
       | X86_64 -> b buf (Printf.sprintf "  movq %%rcx, %d(%%rax)\n" foff))
    ) elems;
    emit_addr_of_local buf arch data_off

  | EClosure _ ->
    (* Closures: currently emit as 0 — function pointer support pending *)
    emit_load_int buf arch 0

  | ECast (inner, _typ, _) ->
    (* Type casts: emit the inner expression — integer identity cast *)
    emit_expr buf env fr inner

  | ERange (lo, hi, _inclusive, _) ->
    (* Range as a value: store (lo, hi) as a tuple of 2 *)
    let data_off = alloc_data fr 16 in
    emit_expr buf env fr lo;
    emit_push buf arch;
    emit_addr_of_local buf arch data_off;
    emit_pop buf arch (pop_reg arch);
    (match arch with
     | Arm64 -> b buf "  str x1, [x0, #0]\n"
     | X86_64 -> b buf "  movq %rcx, (%rax)\n");
    emit_expr buf env fr hi;
    emit_push buf arch;
    emit_addr_of_local buf arch data_off;
    emit_pop buf arch (pop_reg arch);
    (match arch with
     | Arm64 -> b buf "  str x1, [x0, #8]\n"
     | X86_64 -> b buf "  movq %rcx, 8(%rax)\n");
    emit_addr_of_local buf arch data_off

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
  | PatBind (name, _) when String.contains name ':' ->
    (* Qualified enum variant: Operator::None — extract variant name, look up tag *)
    let parts = String.split_on_char ':' name in
    let parts = List.filter (fun s -> s <> "") parts in
    let vname = if List.length parts >= 2 then
      List.nth parts (List.length parts - 1)
    else name in
    if List.mem_assoc vname env.variant_map then begin
      let (_, tag, _) = List.assoc vname env.variant_map in
      (* Load scrutinee pointer, dereference tag *)
      (match arch with
       | Arm64 ->
         b buf "  ldr x0, [sp]\n";
         b buf "  ldr x0, [x0, #0]\n"
       | X86_64 ->
         b buf "  movq (%rsp), %rax\n";
         b buf "  movq (%rax), %rax\n");
      emit_push buf arch;
      emit_load_int buf arch tag;
      emit_pop buf arch (pop_reg arch);
      (match arch with
       | Arm64 -> b buf "  cmp x1, x0\n  b.ne "; b buf next_lbl; b buf "\n"
       | X86_64 -> b buf "  cmpq %rax, %rcx\n  jne "; b buf next_lbl; b buf "\n");
      emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
      emit_stmts buf env fr arm.arm_body;
      emit_branch buf arch end_lbl
    end else begin
      (* Not a known variant — treat as binding *)
      emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
      let off = alloc_local fr name KDirect in
      emit_store_local buf arch off;
      emit_stmts buf env fr arm.arm_body;
      emit_branch buf arch end_lbl
    end
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
    let lookup_name =
      if String.contains vname ':' then
        let parts = String.split_on_char ':' vname in
        let parts = List.filter (fun s -> s <> "") parts in
        List.nth parts (List.length parts - 1)
      else vname in
    let expected_tag =
      try let (_, tag, _) = List.assoc lookup_name env.variant_map in tag
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
      | Some t -> kind_of_typ ~self_type:fr.self_type env t
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

(* Ensure impl methods have an explicit self parameter.
   If the first param is not named "self", prepend one as &mut Self. *)
let ensure_self_param params =
  match params with
  | p :: _ when p.p_name = "self" -> params
  | _ ->
    { p_name = "self"; p_typ = TyRef (true, TySelf); p_mut = false; p_default = None }
    :: params

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
    | IImpl { target; methods; _ } ->
      let type_name = match target with
        | TyName (n, _) -> n
        | _ -> "Unknown"
      in
      List.fold_left (fun acc2 method_item ->
        match method_item with
        | IFn { name; params; ret; _ } ->
          let qualified = type_name ^ "__" ^ name in
          let params = ensure_self_param params in
          let fi_params = List.map (fun p ->
            (p.p_name, kind_of_typ ~self_type:type_name env p.p_typ)
          ) params in
          let fi_ret = match ret with
            | Some t -> kind_of_typ ~self_type:type_name env t
            | None -> KDirect
          in
          (qualified, { fi_params; fi_ret }) :: acc2
        | _ -> acc2
      ) acc methods
    | _ -> acc
  ) [] items

(* ── Compile a single function ─────────────────────────────────────── *)

let compile_function ?(self_type="") buf env fn_name fn_params fn_ret fn_body =
  let _ = fn_ret in
  let arch = env.arch in
  let fr = { locals = []; next_off = 0; loop_labels = []; self_type } in

  (* Allocate param slots *)
  let param_offs = List.map (fun p ->
    let kind = kind_of_typ ~self_type env p.p_typ in
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

  (* Reset string literals *)
  string_literals := [];
  string_counter := 0;

  let buf = Buffer.create 8192 in
  b buf ".text\n";

  List.iter (fun item ->
    match item with
    | IFn { name; params; ret; body; _ } ->
      compile_function buf env name params ret body;
      b buf "\n"
    | IImpl { target; methods; _ } ->
      (* Extract type name for method qualification *)
      let type_name = match target with
        | TyName (n, _) -> n
        | _ -> "Unknown"
      in
      List.iter (fun method_item ->
        match method_item with
        | IFn { name; params; ret; body; _ } ->
          let qualified = type_name ^ "__" ^ name in
          let params = ensure_self_param params in
          compile_function ~self_type:type_name buf env qualified params ret body;
          b buf "\n"
        | _ -> ()
      ) methods
    | _ -> ()
  ) items;

  (* Emit string data section *)
  if !string_literals <> [] then begin
    (match arch with
     | Arm64 -> b buf ".section __DATA,__cstring,cstring_literals\n"
     | X86_64 -> b buf ".section .rodata\n");
    List.iter (fun (lbl, s) ->
      b buf (lbl ^ ":\n");
      (* Emit .asciz with proper escaping *)
      b buf "  .asciz \"";
      String.iter (fun c ->
        match c with
        | '"' -> b buf "\\\""
        | '\\' -> b buf "\\\\"
        | '\n' -> b buf "\\n"
        | '\t' -> b buf "\\t"
        | '\r' -> b buf "\\r"
        | '\000' -> b buf "\\0"
        | c -> Buffer.add_char buf c
      ) s;
      b buf "\"\n"
    ) !string_literals
  end;

  (* Check if a main function was defined *)
  let has_main = List.exists (fun item ->
    match item with IFn { name = "main"; _ } -> true | _ -> false
  ) items in
  let diags = if has_main then []
    else [Diagnostics.make ~severity:Diagnostics.Warning ~code:"W301"
            ~file:"" ~line:1 ~col:1 "no 'main' function defined"] in
  (Buffer.contents buf, diags)

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
      Fun.protect ~finally:(fun () -> try Sys.remove asm_file with _ -> ())
        (fun () ->
      let ch = open_out asm_file in
      output_string ch asm_text;
      close_out ch;
      let cmd = Printf.sprintf "%s %s -o %s"
        (Filename.quote cc) (Filename.quote asm_file) (Filename.quote output) in
      let exit_code = Sys.command cmd in
      if exit_code <> 0 then
        add_diag Diagnostics.Error "E301"
          (Printf.sprintf "native link failed (cc exit %d): %s" exit_code cmd)
      else
        add_diag Diagnostics.Warning "W300"
          "compiled via direct native assembly (no C)";
      ((if exit_code = 0 then 0 else 1), List.rev !diagnostics))
    end
  end
