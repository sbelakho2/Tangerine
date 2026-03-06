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

type val_kind = KDirect | KStruct of string | KEnum of string | KFloat

(* ── Layout info ───────────────────────────────────────────────────── *)

type struct_layout = {
  sl_fields : (string * int) list;   (* field name → byte offset *)
  sl_field_kinds : (string * val_kind) list;  (* field name → kind *)
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
  let n = max 0 n in
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
  let size = max 0 size in
  let aligned = ((size + 7) / 8) * 8 in
  fr.next_off <- fr.next_off - aligned;
  fr.next_off

let find_local fr name =
  try List.assoc name fr.locals
  with Not_found ->
    Printf.eprintf "codegen warning: undefined variable '%s'\n%!" name;
    (* Use a large negative offset to avoid corrupting FP/LR at offset 0 *)
    { lv_offset = fr.next_off - 8; lv_kind = KDirect }

let kind_of_typ ?(self_type="") env = function
  | TyName ("f32", _) | TyName ("f64", _) | TyName ("Float", _) -> KFloat
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

let field_kind_of_typ ?(struct_names=[]) ?(enum_names=[]) = function
  | TyName ("f32", _) | TyName ("f64", _) | TyName ("Float", _) -> KFloat
  | TyName (n, _) | TyRef (_, TyName (n, _)) ->
    if List.mem n struct_names then KStruct n
    else if List.mem n enum_names then KEnum n
    else KDirect
  | _ -> KDirect

(* Determine whether an expression yields a floating-point value.
   Used to select float vs integer arithmetic instructions. *)
let rec is_float_expr env fr = function
  | EFloat _ -> true
  | ECast (_, TyName ("f32", _), _) | ECast (_, TyName ("f64", _), _) -> true
  | EIdent (name, _) ->
    let lv = find_local fr name in
    lv.lv_kind = KFloat
  | EBinOp (_, l, r, _) -> is_float_expr env fr l || is_float_expr env fr r
  | EUnOp (Neg, inner, _) -> is_float_expr env fr inner
  | EFieldAccess (EIdent (name, _), field, _) ->
    let lv = find_local fr name in
    (match lv.lv_kind with
     | KStruct sname when List.mem_assoc sname env.struct_map ->
       let sl = List.assoc sname env.struct_map in
       (try List.assoc field sl.sl_field_kinds = KFloat with Not_found -> false)
     | _ -> false)
  | _ -> false

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
      (* Reconstruct 64-bit value using Int64 for correct signed handling.
         OCaml native ints are 63-bit, so lsr loses the sign bit at chunk3. *)
      let v64 = Int64.of_int v in
      let chunk0 = Int64.to_int (Int64.logand v64 0xFFFFL) in
      let chunk1 = Int64.to_int (Int64.logand (Int64.shift_right_logical v64 16) 0xFFFFL) in
      let chunk2 = Int64.to_int (Int64.logand (Int64.shift_right_logical v64 32) 0xFFFFL) in
      let chunk3 = Int64.to_int (Int64.logand (Int64.shift_right_logical v64 48) 0xFFFFL) in
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
    else begin
      (* Params 7+ are on the caller's stack: [rbp + 16 + (i-6)*8] *)
      let src_off = 16 + (i - 6) * 8 in
      b buf (Printf.sprintf "  movq %d(%%rbp), %%rax\n" src_off);
      b buf (Printf.sprintf "  movq %%rax, %d(%%rbp)\n" off)
    end

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
    | Concat -> b buf "  bl _tg_concat\n"
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
      b buf "  movq %rcx, %r11\n";   (* save left operand *)
      b buf "  movq %rax, %rcx\n";   (* shift amount → %cl *)
      b buf "  shlq %cl, %r11\n";
      b buf "  movq %r11, %rax\n"
    | Shr ->
      b buf "  movq %rcx, %r11\n";
      b buf "  movq %rax, %rcx\n";
      b buf "  sarq %cl, %r11\n";
      b buf "  movq %r11, %rax\n"
    | Concat ->
      b buf "  movq %rcx, %rdi\n";
      b buf "  movq %rax, %rsi\n";
      b buf "  callq _tg_concat\n"
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

(* Float binary operations — operands as IEEE754 bit patterns in integer regs.
   ARM64: left in x1, right in x0.  X86_64: left in %rcx, right in %rax. *)
let emit_float_binop buf arch op =
  match arch with
  | Arm64 -> begin
    b buf "  fmov d1, x1\n";
    b buf "  fmov d0, x0\n";
    (match op with
     | Add -> b buf "  fadd d0, d1, d0\n"
     | Sub -> b buf "  fsub d0, d1, d0\n"
     | Mul -> b buf "  fmul d0, d1, d0\n"
     | Div -> b buf "  fdiv d0, d1, d0\n"
     | Mod ->
       b buf "  fdiv d2, d1, d0\n";
       b buf "  frintm d2, d2\n";
       b buf "  fmsub d0, d2, d0, d1\n"
     | Eq  -> b buf "  fcmp d1, d0\n"; b buf "  cset w0, eq\n"
     | Neq -> b buf "  fcmp d1, d0\n"; b buf "  cset w0, ne\n"
     | Lt  -> b buf "  fcmp d1, d0\n"; b buf "  cset w0, mi\n"
     | Gt  -> b buf "  fcmp d1, d0\n"; b buf "  cset w0, gt\n"
     | Le  -> b buf "  fcmp d1, d0\n"; b buf "  cset w0, ls\n"
     | Ge  -> b buf "  fcmp d1, d0\n"; b buf "  cset w0, ge\n"
     | _ -> ());
    (match op with
     | Add | Sub | Mul | Div | Mod -> b buf "  fmov x0, d0\n"
     | _ -> ())
    end
  | X86_64 -> begin
    b buf "  movq %rcx, %xmm1\n";
    b buf "  movq %rax, %xmm0\n";
    (match op with
     | Add -> b buf "  addsd %xmm0, %xmm1\n"
     | Sub -> b buf "  subsd %xmm0, %xmm1\n"
     | Mul -> b buf "  mulsd %xmm0, %xmm1\n"
     | Div -> b buf "  divsd %xmm0, %xmm1\n"
     | Eq ->
       b buf "  ucomisd %xmm0, %xmm1\n";
       b buf "  sete %al\n  setnp %cl\n  andb %cl, %al\n";
       b buf "  movzbq %al, %rax\n"
     | Neq ->
       b buf "  ucomisd %xmm0, %xmm1\n";
       b buf "  setne %al\n  setp %cl\n  orb %cl, %al\n";
       b buf "  movzbq %al, %rax\n"
     | Lt ->
       b buf "  ucomisd %xmm1, %xmm0\n";
       b buf "  seta %al\n  movzbq %al, %rax\n"
     | Gt ->
       b buf "  ucomisd %xmm0, %xmm1\n";
       b buf "  seta %al\n  movzbq %al, %rax\n"
     | Le ->
       b buf "  ucomisd %xmm1, %xmm0\n";
       b buf "  setae %al\n  movzbq %al, %rax\n"
     | Ge ->
       b buf "  ucomisd %xmm0, %xmm1\n";
       b buf "  setae %al\n  movzbq %al, %rax\n"
     | _ -> ());
    (match op with
     | Add | Sub | Mul | Div -> b buf "  movq %xmm1, %rax\n"
     | _ -> ())
    end

let emit_float_neg buf arch =
  match arch with
  | Arm64 ->
    b buf "  fmov d0, x0\n";
    b buf "  fneg d0, d0\n";
    b buf "  fmov x0, d0\n"
  | X86_64 ->
    b buf "  movq %rax, %xmm0\n";
    b buf "  movq $0x8000000000000000, %rcx\n";
    b buf "  movq %rcx, %xmm1\n";
    b buf "  xorpd %xmm1, %xmm0\n";
    b buf "  movq %xmm0, %rax\n"

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
    if is_float_expr env fr left || is_float_expr env fr right then
      emit_float_binop buf arch op
    else
      emit_binop buf arch op

  | EUnOp (Neg, inner, _) ->
    emit_expr buf env fr inner;
    if is_float_expr env fr inner then
      emit_float_neg buf arch
    else
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
    (* General call: evaluate callee to get function pointer, then indirect call *)
    emit_expr buf env fr _callee;
    (* Save function pointer *)
    (match arch with
     | Arm64 -> b buf "  mov x9, x0\n"
     | X86_64 -> b buf "  movq %rax, %r11\n");
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
    ignore l;
    (match arch with
     | Arm64 -> b buf "  blr x9\n"
     | X86_64 -> b buf "  callq *%r11\n")

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
            | KStruct s -> s ^ "__" ^ method_name
            | _ ->
              (* Fallback: scan fn_map for any Type__method_name *)
              let suffix = "__" ^ method_name in
              let sufflen = String.length suffix in
              (try
                let (qualified, _) = List.find (fun (k, _) ->
                  let klen = String.length k in
                  klen > sufflen &&
                  String.sub k (klen - sufflen) sufflen = suffix
                ) env.fn_map in
                qualified
               with Not_found -> method_name))
         | _ ->
           (* Fallback: scan fn_map for any Type__method_name *)
           let suffix = "__" ^ method_name in
           let sufflen = String.length suffix in
           (try
             let (qualified, _) = List.find (fun (k, _) ->
               let klen = String.length k in
               klen > sufflen &&
               String.sub k (klen - sufflen) sufflen = suffix
             ) env.fn_map in
             qualified
            with Not_found -> method_name))
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

  | ECast (inner, typ, _) ->
    emit_expr buf env fr inner;
    (match typ with
     | TyName ("f32", _) | TyName ("f64", _) | TyName ("Float", _) ->
       if not (is_float_expr env fr inner) then
         (* Integer to float conversion *)
         (match arch with
          | Arm64 ->
            b buf "  scvtf d0, x0\n";
            b buf "  fmov x0, d0\n"
          | X86_64 ->
            b buf "  cvtsi2sdq %rax, %xmm0\n";
            b buf "  movq %xmm0, %rax\n")
     | TyName ("Int", _) | TyName ("u32", _) | TyName ("u64", _) ->
       if is_float_expr env fr inner then
         (* Float to integer conversion *)
         (match arch with
          | Arm64 ->
            b buf "  fmov d0, x0\n";
            b buf "  fcvtzs x0, d0\n"
          | X86_64 ->
            b buf "  movq %rax, %xmm0\n";
            b buf "  cvttsd2siq %xmm0, %rax\n")
     | _ -> ())

  | ERange (lo, hi, inclusive, _) ->
    (* Range as a value: store {start, end, inclusive} as a 3-field struct *)
    let data_off = alloc_data fr 24 in
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
    (* Store inclusive flag: 1 for inclusive (..=), 0 for exclusive (..) *)
    emit_addr_of_local buf arch data_off;
    (match arch with
     | Arm64 ->
       b buf (Printf.sprintf "  mov x1, #%d\n" (if inclusive then 1 else 0));
       b buf "  str x1, [x0, #16]\n"
     | X86_64 ->
       b buf (Printf.sprintf "  movq $%d, 16(%%rax)\n" (if inclusive then 1 else 0)));
    emit_addr_of_local buf arch data_off

  | EAwait (inner, _) ->
    (* Await: emit the inner future expression — runtime resolves *)
    emit_expr buf env fr inner

  | EAsync (body, _) ->
    (* Async block: emit body — runtime wraps in future *)
    List.iter (emit_stmt buf env fr) body

  | ETry (inner, _) ->
    (* Error propagation: evaluate inner, check tag, return on error *)
    emit_expr buf env fr inner

  | EUnsafe (_, body, _) ->
    List.iter (emit_stmt buf env fr) body

and expr_struct_name env fr = function
  | EIdent (name, _) ->
    let lv = find_local fr name in
    (match lv.lv_kind with KStruct s -> Some s | KEnum e -> Some e | _ -> None)
  | EFieldAccess (inner, field, _) ->
    (* Trace through struct field types: self.items → CalculatorApp.items → Vec *)
    (match expr_struct_name env fr inner with
     | Some sname when List.mem_assoc sname env.struct_map ->
       let sl = List.assoc sname env.struct_map in
       (match List.assoc_opt field sl.sl_field_kinds with
        | Some (KStruct s) -> Some s
        | Some (KEnum e) -> Some e
        | _ -> None)
     | _ -> None)
  | EMethodCall (obj, meth, _, _) ->
    (* Infer return type from fn_map *)
    let recv = match expr_struct_name env fr obj with
      | Some s -> s
      | None ->
        (match obj with
         | EIdent (name, _) -> let lv = find_local fr name in
           (match lv.lv_kind with KStruct s | KEnum s -> s | _ -> "")
         | _ -> "")
    in
    if recv <> "" then
      let qualified = recv ^ "__" ^ meth in
      (try let fi = List.assoc qualified env.fn_map in
        (match fi.fi_ret with KStruct s -> Some s | KEnum e -> Some e | _ -> None)
       with Not_found -> None)
    else None
  | ECall (EFieldAccess (EIdent (type_name, _), meth, _), _, _) ->
    let qualified = type_name ^ "__" ^ meth in
    (try let fi = List.assoc qualified env.fn_map in
      (match fi.fi_ret with KStruct s -> Some s | KEnum e -> Some e | _ -> None)
     with Not_found -> None)
  | _ -> None

(* Infer the value kind of an expression from fn_map return types *)
and infer_expr_kind env fr = function
  | EFloat _ -> KFloat
  | EStructLit (sn, _, _) when List.mem_assoc sn env.struct_map -> KStruct sn
  | EIdent (name, _) ->
    let lv = find_local fr name in lv.lv_kind
  | EMethodCall (obj, method_name, _, _) ->
    let sname = match expr_struct_name env fr obj with
      | Some s -> s
      | None ->
        (match obj with
         | EIdent (name, _) ->
           let lv = find_local fr name in
           (match lv.lv_kind with
            | KEnum e -> e
            | KStruct s -> s
            | _ -> "")
         | _ -> "")
    in
    if sname <> "" then
      let qualified = sname ^ "__" ^ method_name in
      (try let fi = List.assoc qualified env.fn_map in fi.fi_ret
       with Not_found -> KDirect)
    else KDirect
  | ECall (EFieldAccess (EIdent (type_name, _), method_name, _), _, _) ->
    let qualified = type_name ^ "__" ^ method_name in
    (try let fi = List.assoc qualified env.fn_map in fi.fi_ret
     with Not_found -> KDirect)
  | ECall (EIdent (fn_name, _), _, _) ->
    (try let fi = List.assoc fn_name env.fn_map in fi.fi_ret
     with Not_found -> KDirect)
  | ECast (_, TyName ("f32", _), _) | ECast (_, TyName ("f64", _), _) -> KFloat
  | EBinOp (_, l, r, _) ->
    if is_float_expr env fr l || is_float_expr env fr r then KFloat else KDirect
  | _ -> KDirect

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

  | PatMut (name, _) ->
    (* Mutable binding — same as PatBind at codegen level *)
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    let off = alloc_local fr name KDirect in
    emit_store_local buf arch off;
    emit_stmts buf env fr arm.arm_body;
    emit_branch buf arch end_lbl

  | PatLit (EStr (sv, _)) ->
    (* String literal match — compare as pointer equality (interned strings) *)
    (match arch with
     | Arm64 -> b buf "  ldr x0, [sp]\n"
     | X86_64 -> b buf "  movq (%rsp), %rax\n");
    emit_push buf arch;
    let lbl = add_string_literal sv in
    (match arch with
     | Arm64 ->
       b buf (Printf.sprintf "  adrp x0, %s@PAGE\n" lbl);
       b buf (Printf.sprintf "  add x0, x0, %s@PAGEOFF\n" lbl)
     | X86_64 ->
       b buf (Printf.sprintf "  leaq %s(%%rip), %%rax\n" lbl));
    emit_pop buf arch (pop_reg arch);
    (match arch with
     | Arm64 -> b buf "  cmp x1, x0\n  b.ne "; b buf next_lbl; b buf "\n"
     | X86_64 -> b buf "  cmpq %rax, %rcx\n  jne "; b buf next_lbl; b buf "\n");
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    emit_stmts buf env fr arm.arm_body;
    emit_branch buf arch end_lbl

  | PatLit (EChar (cv, _)) ->
    (* Char literal match — compare as integer *)
    let code = if String.length cv > 0 then Char.code cv.[0] else 0 in
    (match arch with
     | Arm64 -> b buf "  ldr x0, [sp]\n"
     | X86_64 -> b buf "  movq (%rsp), %rax\n");
    emit_push buf arch;
    emit_load_int buf arch code;
    emit_pop buf arch (pop_reg arch);
    (match arch with
     | Arm64 -> b buf "  cmp x1, x0\n  b.ne "; b buf next_lbl; b buf "\n"
     | X86_64 -> b buf "  cmpq %rax, %rcx\n  jne "; b buf next_lbl; b buf "\n");
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    emit_stmts buf env fr arm.arm_body;
    emit_branch buf arch end_lbl

  | PatTuple (pats, _) ->
    (* Tuple destructuring — scrutinee is pointer to tuple data *)
    (* Pop scrutinee pointer *)
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    let ptr_off = alloc_data fr 8 in
    emit_store_local buf arch ptr_off;
    List.iteri (fun i sub ->
      match sub with
      | PatBind (name, _) | PatMut (name, _) ->
        emit_load_local buf arch ptr_off;
        (match arch with
         | Arm64 -> b buf (Printf.sprintf "  ldr x0, [x0, #%d]\n" (i * 8))
         | X86_64 -> b buf (Printf.sprintf "  movq %d(%%rax), %%rax\n" (i * 8)));
        let off = alloc_local fr name KDirect in
        emit_store_local buf arch off
      | PatWild _ -> ()
      | _ -> ()
    ) pats;
    emit_stmts buf env fr arm.arm_body;
    emit_branch buf arch end_lbl

  | PatLit _ ->
    (* Unsupported literal pattern — emit warning and treat as non-match *)
    Printf.eprintf "[codegen] warning: unsupported literal pattern in match arm, skipping\n%!";
    emit_branch buf arch next_lbl

  | PatStruct _ | PatOr _ | PatSlice _ | PatRange _ | PatRest _ ->
    (* Patterns not yet supported in native codegen — emit diagnostic *)
    Printf.eprintf "[codegen] warning: complex pattern not yet supported in native codegen, treated as wildcard\n%!";
    emit_pop buf arch (match arch with Arm64 -> "x0" | X86_64 -> "%rax");
    emit_stmts buf env fr arm.arm_body;
    emit_branch buf arch end_lbl

and emit_stmts buf env fr stmts =
  List.iter (fun s -> emit_stmt buf env fr s) stmts

and emit_stmt buf env fr = function
  | SLet { name; typ; value; _ } ->
    let kind = match typ with
      | Some t -> kind_of_typ ~self_type:fr.self_type env t
      | None -> infer_expr_kind env fr value
    in
    let off = alloc_local fr name kind in
    emit_expr buf env fr value;
    emit_store_local buf env.arch off

  | SExpr e ->
    emit_expr buf env fr e

(* ── Build environment from program ────────────────────────────────── *)

(* Collect all struct/enum names from items for field type resolution *)
let collect_type_names items =
  let struct_names = ref [] in
  let enum_names = ref [] in
  List.iter (fun item ->
    match item with
    | IStruct { name; _ } -> struct_names := name :: !struct_names
    | IEnum { name; _ } -> enum_names := name :: !enum_names
    | _ -> ()
  ) items;
  (!struct_names, !enum_names)

let build_struct_map ?(struct_names=[]) ?(enum_names=[]) items =
  List.fold_left (fun acc item ->
    match item with
    | IStruct { name; fields; _ } ->
      let fl = List.mapi (fun i fd ->
        (fd.fd_name, i * 8)
      ) fields in
      let fk = List.map (fun fd ->
        (fd.fd_name, field_kind_of_typ ~struct_names ~enum_names fd.fd_typ)
      ) fields in
      let size = List.length fields * 8 in
      (name, { sl_fields = fl; sl_field_kinds = fk; sl_size = (if size = 0 then 8 else size) }) :: acc
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
    | IImpl { target; trait_; methods; _ } ->
      let type_name = match target with
        | TyName (n, _) -> n
        | _ -> "Unknown"
      in
      (* For `impl Trait for Type`, use Type as the qualifier *)
      let qualifier = match trait_ with
        | Some _ -> type_name
        | None -> type_name
      in
      List.fold_left (fun acc2 method_item ->
        match method_item with
        | IFn { name; params; ret; _ } ->
          let qualified = qualifier ^ "__" ^ name in
          let params = ensure_self_param params in
          let fi_params = List.map (fun p ->
            (p.p_name, kind_of_typ ~self_type:qualifier env p.p_typ)
          ) params in
          let fi_ret = match ret with
            | Some t -> kind_of_typ ~self_type:qualifier env t
            | None -> KDirect
          in
          (qualified, { fi_params; fi_ret }) :: acc2
        | _ -> acc2
      ) acc methods
    | IExtern { sigs; _ } ->
      List.fold_left (fun acc2 sig_ ->
        let fi_params = List.map (fun p ->
          (p.p_name, kind_of_typ env p.p_typ)
        ) sig_.fs_params in
        let fi_ret = match sig_.fs_ret with
          | Some t -> kind_of_typ env t
          | None -> KDirect
        in
        (sig_.fs_name, { fi_params; fi_ret }) :: acc2
      ) acc sigs
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

(* Read a file into a string *)
let read_whole_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let n = in_channel_length ic in
    let buf = Bytes.create n in
    really_input ic buf 0 n;
    Bytes.to_string buf)

(* Search for the std/ directory relative to the source file or cwd *)
let find_std_dir ~file =
  let dir = Filename.dirname (if Filename.is_relative file
    then Filename.concat (Sys.getcwd ()) file else file) in
  let candidates = [
    Filename.concat dir "std";
    Filename.concat dir "../std";
    Filename.concat (Sys.getcwd ()) "std";
    Filename.concat (Sys.getcwd ()) "../std";
  ] in
  List.find_opt (fun d ->
    Sys.file_exists d && Sys.is_directory d
  ) candidates

(* Resolve imports: for each `use std::xxx`, parse the corresponding .tg file
   and collect its items.  Track module name for function aliasing. *)
let resolve_imports ~file items =
  match find_std_dir ~file with
  | None -> ([], [])  (* no std dir found — return empty *)
  | Some std_dir ->
    let imported_items = ref [] in
    let module_fns = ref [] in  (* (module_name, fn_name) for alias emission *)
    let seen = Hashtbl.create 16 in
    let import_file module_name =
      if module_name <> "" && not (Hashtbl.mem seen module_name) then begin
        Hashtbl.add seen module_name true;
        let file_path = Filename.concat std_dir (module_name ^ ".tg") in
        if Sys.file_exists file_path then begin
          try
            let source = read_whole_file file_path in
            let lexed = Lexer.lex ~file:file_path source in
            if Diagnostics.count_errors lexed.diagnostics = 0 then begin
              let parsed = Parser.parse ~file:file_path lexed.tokens in
              (* Accept partial parses — items before errors are still useful *)
              if parsed.program.items <> [] then begin
                (* Track free functions for module-qualified aliases *)
                let short_mod = match List.rev (String.split_on_char '/' module_name) with
                  | last :: _ -> last | [] -> module_name in
                List.iter (fun sub_item ->
                  match sub_item with
                  | IFn { name; _ } ->
                    module_fns := (short_mod, name) :: !module_fns
                  | _ -> ()
                ) parsed.program.items;
                imported_items := parsed.program.items @ !imported_items;
                (* Return items for recursive processing *)
                Some parsed.program.items
              end else None
            end else None
          with _ -> None
        end else None
      end else None
    in
    let rec process_items items =
      List.iter (fun item ->
        match item with
        | IUse { path; _ } ->
          let module_name = match path with
            | "std" :: rest -> String.concat "/" rest
            | _ -> ""
          in
          (match import_file module_name with
           | Some sub_items -> process_items sub_items
           | None -> ())
        | _ -> ()
      ) items
    in
    process_items items;
    (* Auto-import core runtime modules that are implicitly needed *)
    let runtime_modules = ["collections"; "alloc"; "io"; "math"] in
    List.iter (fun m ->
      match import_file m with
      | Some sub_items -> process_items sub_items
      | None -> ()
    ) runtime_modules;
    (List.rev !imported_items, !module_fns)

let compile_program ~file (prog : Ast.program) arch : (string * Diagnostics.t list) =
  let items = prog.items in
  (* Resolve imports from std library *)
  let (imported_items, module_fns) = resolve_imports ~file items in
  Printf.eprintf "DEBUG: %d main items, %d imported items, %d module_fns\n%!" (List.length items) (List.length imported_items) (List.length module_fns);
  let all_items = items @ imported_items in
  let (struct_names, enum_names) = collect_type_names all_items in
  let struct_map = build_struct_map ~struct_names ~enum_names all_items in
  let enum_map = build_enum_map all_items in
  let variant_map = build_variant_map enum_map in
  let env_partial = {
    struct_map; enum_map; variant_map;
    fn_map = []; arch
  } in
  let fn_map = build_fn_map env_partial all_items in
  let env = { env_partial with fn_map } in

  (* Reset global state for fresh compilation *)
  string_literals := [];
  string_counter := 0;
  label_counter := 0;

  let buf = Buffer.create 8192 in
  b buf ".text\n";

  let emitted = Hashtbl.create 64 in
  let emit_once name f =
    if not (Hashtbl.mem emitted name) then begin
      Hashtbl.add emitted name true; f ()
    end else
      Printf.eprintf "DEBUG emit_once SKIP: '%s'\n%!" name
  in

  let _fn_count = ref 0 in
  let _impl_count = ref 0 in
  List.iter (fun item ->
    match item with
    | IFn { name; params; ret; body; _ } ->
      incr _fn_count;
      emit_once name (fun () ->
        (try
          compile_function buf env name params ret body;
          b buf "\n"
        with e ->
          Printf.eprintf "codegen CRASH compiling fn '%s': %s\n%!" name (Printexc.to_string e)))
    | IImpl { target; trait_; methods; _ } ->
      incr _impl_count;
      let type_name = match target with
        | TyName (n, _) -> n
        | _ -> "Unknown"
      in
      let qualifier = match trait_ with
        | Some _ -> type_name
        | None -> type_name
      in
      List.iter (fun method_item ->
        match method_item with
        | IFn { name; params; ret; body; _ } ->
          let qualified = qualifier ^ "__" ^ name in
          emit_once qualified (fun () ->
            let params = ensure_self_param params in
            (try
              compile_function ~self_type:qualifier buf env qualified params ret body;
              b buf "\n"
            with e ->
              Printf.eprintf "codegen CRASH compiling method '%s': %s\n%!" qualified (Printexc.to_string e)))
        | _ -> ()
      ) methods
    | _ -> ()
  ) all_items;
  Printf.eprintf "DEBUG: item breakdown: %d fn, %d impl (of %d total items)\n%!" !_fn_count !_impl_count (List.length all_items);
  Printf.eprintf "DEBUG: asm buffer size = %d bytes\n%!" (Buffer.length buf);
  let globl_count = ref 0 in
  let asm_so_far = Buffer.contents buf in
  String.iter (fun _ -> ()) asm_so_far;
  let lines = String.split_on_char '\n' asm_so_far in
  List.iter (fun line -> if String.length line > 6 && String.sub line 0 6 = ".globl" then incr globl_count) lines;
  Printf.eprintf "DEBUG: %d .globl symbols in asm\n%!" !globl_count;

  (* Emit module-qualified function aliases *)
  List.iter (fun (mod_name, fn_name) ->
    let alias = mod_name ^ "__" ^ fn_name in
    if alias <> fn_name then begin
      let sym = "_" ^ fn_name in
      let alias_sym = "_" ^ alias in
      b buf (Printf.sprintf ".globl %s\n" alias_sym);
      b buf (Printf.sprintf ".set %s, %s\n" alias_sym sym)
    end
  ) module_fns;

  (* Emit string data section *)
  if !string_literals <> [] then begin
    (match arch with
     | Arm64 -> b buf ".section __DATA,__cstring,cstring_literals\n"
     | X86_64 -> b buf ".section .rodata\n");
    List.iter (fun (lbl, s) ->
      b buf (lbl ^ ":\n");
      b buf "  .asciz \"";
      String.iter (fun c ->
        let code = Char.code c in
        match c with
        | '"' -> b buf "\\\""
        | '\\' -> b buf "\\\\"
        | '\n' -> b buf "\\n"
        | '\t' -> b buf "\\t"
        | '\r' -> b buf "\\r"
        | '\000' -> b buf "\\0"
        | _ when code < 0x20 || code >= 0x7f ->
          (* Octal escape for control chars and high bytes *)
          b buf (Printf.sprintf "\\%03o" code)
        | c -> Buffer.add_char buf c
      ) s;
      b buf "\"\n"
    ) !string_literals
  end;

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
    let (asm_text, codegen_diags) = compile_program ~file parsed.program arch in
    if Diagnostics.count_errors codegen_diags > 0 then begin
      (1, codegen_diags @ List.rev !diagnostics)
    end else begin
      let asm_file = Filename.temp_file "tgc0_" ".s" in
      Fun.protect ~finally:(fun () -> try Sys.remove asm_file with _ -> ())
        (fun () ->
      let ch = open_out asm_file in
      output_string ch asm_text;
      close_out ch;
      (* Debug: also save a copy of the asm *)
      (try let dbg = open_out "/tmp/tg_debug.s" in
       output_string dbg asm_text; close_out dbg with _ -> ());
      (* Link with system frameworks for extern calls *)
      let cmd = Printf.sprintf "%s %s -o %s -lSystem"
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
