(* tg_intvalue.ml — Int_value arithmetic self-check.

   Reads oracle lines

       op width signed a_lo a_hi b_lo b_hi result_lo result_hi

   (each 64-bit word as a signed int64 decimal, produced by the
   arbitrary-precision oracle /tmp/int_oracle.py) from a file argument
   or stdin, asserts that every Int_value operation reproduces the
   oracle's masked result, then runs a battery of fixed edge-case
   vectors and the integer-literal lowering checks. *)

open Int_value

let mask_for w = if w = 64 then -1L else Int64.pred (Int64.shift_left 1L w)

let words_match (width : int) (lo : int64) (hi : int64) (r_lo : int64) (r_hi : int64) : bool =
  if width = 128 then Int64.equal lo r_lo && Int64.equal hi r_hi
  else Int64.equal (Int64.logand lo (mask_for width)) r_lo && Int64.equal r_hi 0L

let run_op (op : string) (a : t) (b : t) : int64 * int64 =
  match op with
  | "add" ->
      let r = add a b in
      (r.bits_lo, r.bits_hi)
  | "sub" ->
      let r = sub a b in
      (r.bits_lo, r.bits_hi)
  | "neg" ->
      let r = neg a in
      (r.bits_lo, r.bits_hi)
  | "mul" ->
      let r = mul a b in
      (r.bits_lo, r.bits_hi)
  | "div" ->
      let r = div a b in
      (r.bits_lo, r.bits_hi)
  | "rem" ->
      let r = rem a b in
      (r.bits_lo, r.bits_hi)
  | "and" ->
      let r = logand a b in
      (r.bits_lo, r.bits_hi)
  | "or" ->
      let r = logor a b in
      (r.bits_lo, r.bits_hi)
  | "xor" ->
      let r = logxor a b in
      (r.bits_lo, r.bits_hi)
  | "shl" ->
      let r = shift_left a b in
      (r.bits_lo, r.bits_hi)
  | "lshr" | "ashr" ->
      let r = shift_right a b in
      (r.bits_lo, r.bits_hi)
  | "slt" -> if signed_less a b then (1L, 0L) else (0L, 0L)
  | "sgt" -> if signed_less b a then (1L, 0L) else (0L, 0L)
  | "seq" -> if not (signed_less a b || signed_less b a) then (1L, 0L) else (0L, 0L)
  | "ult" -> if unsigned_less a b then (1L, 0L) else (0L, 0L)
  | "ugt" -> if unsigned_less b a then (1L, 0L) else (0L, 0L)
  | "ueq" -> if not (unsigned_less a b || unsigned_less b a) then (1L, 0L) else (0L, 0L)
  | "cast" -> (a.bits_lo, a.bits_hi)
  | _ -> failwith ("tg_intvalue: unknown op " ^ op)

let check_line (ln : string) : bool =
  match String.split_on_char ' ' ln with
  | [ op; w; s; al; ah; bl; bh; rl; rh ] ->
      let width = int_of_string w in
      let signed = s = "1" in
      let a =
        of_words ~width ~signed ~bits_lo:(Int64.of_string al) ~bits_hi:(Int64.of_string ah)
      in
      let b =
        of_words ~width ~signed ~bits_lo:(Int64.of_string bl) ~bits_hi:(Int64.of_string bh)
      in
      let lo, hi = run_op op a b in
      words_match width lo hi (Int64.of_string rl) (Int64.of_string rh)
  | _ -> failwith ("tg_intvalue: bad oracle line: " ^ ln)

let run_fixed_vectors () =
  let vectors =
    [
      (* 0xFFFFFFFFFFFFFFFF + 1 at u64 wraps to 0 *)
      ("u64_max_plus_1", "add", 64, 0, -1L, 0L, 1L, 0L, 0L, 0L);
      (* neg of u8 128 wraps to 128 (i.e. -128 at 8 bits) *)
      ("u8_neg_128_wraps", "neg", 8, 0, 128L, 0L, 0L, 0L, 128L, 0L);
      (* 2^127 / -1 at i128 wraps to min_i128 (two's complement) *)
      ("i128_2p127_div_minus1", "div", 128, 1, 0L, -9223372036854775808L, -1L, -1L, 0L, -9223372036854775808L);
      (* shift by 130 (>= 128) yields zero *)
      ("u64_shl_1_by_130", "shl", 64, 0, 1L, 0L, 130L, 0L, 0L, 0L);
      (* arithmetic shift by 130 of a negative value sign-fills to -1 *)
      ("i64_ashr_minus5_by_130", "ashr", 64, 1, -5L, 0L, 130L, 0L, -1L, 0L);
      (* neg of min_i128 wraps to min_i128 *)
      ("i128_neg_min_wraps", "neg", 128, 1, 0L, -9223372036854775808L, 0L, 0L, 0L, -9223372036854775808L);
      (* 2^63 * 2^63 mod 2^64 = 0 *)
      ("u64_half_mul_self", "mul", 64, 0, -9223372036854775808L, 0L, -9223372036854775808L, 0L, 0L, 0L);
      (* (2^64-1)^2 mod 2^128 = 2^128 - 2^65 + 1: hi = 2^64-2, lo = 1 *)
      ("u128_m64m1_sq", "mul", 128, 0, -1L, 0L, -1L, 0L, 1L, -2L);
      (* (2^128-1)^2 mod 2^128 = 1 *)
      ("u128_max_mul_max", "mul", 128, 0, -1L, -1L, -1L, -1L, 1L, 0L);
      (* i64 min / -1 wraps to min *)
      ("i64_min_div_minus1", "div", 64, 1, -9223372036854775808L, 0L, -1L, 0L, -9223372036854775808L, 0L);
      (* -7 rem 3 at i128 = -1 (dividend's sign) *)
      ("i128_neg7_rem_3", "rem", 128, 1, -7L, -1L, 3L, 0L, -1L, -1L);
      (* u128 max / 2 *)
      ("u128_max_div_2", "div", 128, 0, -1L, -1L, 2L, 0L, -1L, 9223372036854775807L);
      (* 1 << 127 at i128 = min_i128 *)
      ("i128_shl_1_by_127", "shl", 128, 1, 1L, 0L, 127L, 0L, 0L, -9223372036854775808L);
      (* 7 rem -3 at i128 = 1 *)
      ("i128_7_rem_neg3", "rem", 128, 1, 7L, 0L, -3L, -1L, 1L, 0L);
      (* (2^64) >> 1 logical at u128 *)
      ("u128_shr_hi_by_1", "lshr", 128, 0, 0L, 1L, 1L, 0L, -9223372036854775808L, 0L);
      (* neg of i8 0x80 wraps to 0x80 *)
      ("i8_neg_128", "neg", 8, 1, 128L, 0L, 0L, 0L, 128L, 0L);
      (* u16 max + 1 wraps to 0 *)
      ("u16_add_65535_1", "add", 16, 0, 65535L, 0L, 1L, 0L, 0L, 0L);
      (* i32 min / -1 wraps to min *)
      ("i32_min_div_minus1", "div", 32, 1, 2147483648L, 0L, 4294967295L, 0L, 2147483648L, 0L);
      (* truncating cast: u8 300 wraps to 44 *)
      ("u8_cast_300", "cast", 8, 0, 44L, 0L, 0L, 0L, 44L, 0L);
      (* truncating cast: 0xFF to u16 is 0x00FF = 255 *)
      ("i8_cast_minus1_to_u16", "cast", 16, 0, 255L, 0L, 0L, 0L, 255L, 0L);
      (* min_i128 rem -1 = 0 *)
      ("i128_min_rem_minus1", "rem", 128, 1, 0L, -9223372036854775808L, -1L, -1L, 0L, 0L);
      (* min_i128 * 1 = min_i128 *)
      ("i128_min_div_minus1_mulback", "mul", 128, 1, 0L, -9223372036854775808L, 1L, 0L, 0L, -9223372036854775808L);
      (* shift by exactly the width yields zero *)
      ("u64_shl_3_by_64", "shl", 64, 0, 3L, 0L, 64L, 0L, 0L, 0L);
      (* i64 min ashr 127 = -1 *)
      ("i64_ashr_min_by_127", "ashr", 64, 1, -9223372036854775808L, 0L, 127L, 0L, -1L, 0L);
      (* i128 -1 ashr 129 = -1 (sign fill), 1 ashr 129 = 0 *)
      ("u128_ashr_neg1_by_129", "ashr", 128, 1, -1L, -1L, 129L, 0L, -1L, -1L);
      ("u128_ashr_pos_by_129", "ashr", 128, 1, 1L, 0L, 129L, 0L, 0L, 0L);
      (* division by zero raises *)
      ("div_by_zero", "div", 64, 0, 5L, 0L, 0L, 0L, 0L, 0L);
    ]
  in
  List.iter
    (fun (name, op, width, signed, al, ah, bl, bh, rl, rh) ->
      let signed = signed = 1 in
      let a = of_words ~width ~signed ~bits_lo:al ~bits_hi:ah in
      let b = of_words ~width ~signed ~bits_lo:bl ~bits_hi:bh in
      if name = "div_by_zero" then begin
        (match div a b with
        | _ -> failwith ("fixed vector " ^ name ^ ": division by zero did not raise")
        | exception Division_by_zero -> ())
      end
      else begin
        let lo, hi = run_op op a b in
        if not (words_match width lo hi rl rh) then
          failwith
            (Printf.sprintf "fixed vector %s: got (%Ld, %Ld), expected (%Ld, %Ld)" name lo hi rl rh)
      end)
    vectors;
  Printf.printf "fixed vectors: PASS (%d)\n" (List.length vectors)

(* ── integer-literal lowering checks (parse + lower, no typecheck) ── *)

let parse_program (src_text : string) : Ast.program =
  let file = "<intvalue-self-check>" in
  match Source_loader.load_string file src_text with
  | Error _ -> failwith "tg_intvalue: source load failed"
  | Ok src ->
      let sm = Span.create () in
      let file_id = Span.add_file sm src.Source.name src in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      let program = Parser.parse tokens src.Source.bytes file_id diags [ "intvalue" ] in
      if Diagnostic.has_errors diags then
        failwith ("tg_intvalue: parse errors:\n" ^ Diagnostic.render sm diags)
      else program

let lower_env () : Mir_lower.func_env =
  let int t = Type_repr.Int t in
  {
    Mir_lower.types =
      [
        ("Int", int Type_repr.Int);
        ("UInt", int Type_repr.UInt);
        ("i8", int Type_repr.I8);
        ("i16", int Type_repr.I16);
        ("i32", int Type_repr.I32);
        ("i64", int Type_repr.I64);
        ("i128", int Type_repr.I128);
        ("u8", int Type_repr.U8);
        ("u16", int Type_repr.U16);
        ("u32", int Type_repr.U32);
        ("u64", int Type_repr.U64);
        ("u128", int Type_repr.U128);
        ("Unit", Type_repr.Unit);
        ("Bool", Type_repr.Bool);
        ("String", Type_repr.String);
        ("Char", Type_repr.Char);
      ];
    values = [];
    callables = [];
    methods = [];
    fn_ret = Type_repr.Unit;
    struct_fields = [];
  }

let collect_int_constants (fn : Seed_mir.function_) : Int_value.t list =
  let acc = ref [] in
  let operand op =
    match op with
    | Seed_mir.Constant (Seed_mir.Integer v) -> acc := v :: !acc
    | _ -> ()
  in
  Array.iter
    (fun b ->
      List.iter
        (fun s ->
          match s with
          | Seed_mir.Assign (_, rv) -> (
              match rv with
              | Seed_mir.Use op -> operand op
              | Seed_mir.Ref p | Seed_mir.RefMut p -> ignore p
              | Seed_mir.Aggregate (_, ops) -> List.iter operand ops
              | Seed_mir.BinaryOp (_, l, r) ->
                  operand l;
                  operand r
              | Seed_mir.UnaryOp (_, op) -> operand op
              | Seed_mir.Cast (op, _) -> operand op
              | _ -> ())
          | _ -> ())
        b.Seed_mir.statements;
      (match b.Seed_mir.terminator with
       | Seed_mir.SwitchInt (op, _, _) -> operand op
       | Seed_mir.Call (_, _, args, _, _) -> Array.iter (fun a -> operand a.Seed_mir.value) args
       | _ -> ()))
    fn.Seed_mir.blocks;
  List.rev !acc

let lower_int_literal (src : string) : Int_value.t =
  let program = parse_program src in
  let funcs =
    List.filter_map
      (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
      program.Ast.items
  in
  let env = lower_env () in
  let fn = Mir_lower.lower_function env "main" 0 (List.hd funcs) in
  match collect_int_constants fn with
  | [ v ] -> v
  | vs ->
      failwith
        (Printf.sprintf "expected exactly one integer constant, got %d"
           (List.length vs))

let expect_literal (name : string) (src : string) (width : int) (signed : bool)
    (bits_lo : int64) (bits_hi : int64) (printed : string) : unit =
  let v = lower_int_literal src in
  let printed_ok = Seed_mir.print_constant (Seed_mir.Integer v) = printed in
  if
    v.width <> width || v.signed <> signed || not (Int64.equal v.bits_lo bits_lo)
    || not (Int64.equal v.bits_hi bits_hi) || not printed_ok
  then
    failwith
      (Printf.sprintf
         "literal check %s: got (w=%d signed=%b lo=%Ld hi=%Ld printed=%s), \
          expected (w=%d signed=%b lo=%Ld hi=%Ld printed=%s)"
         name v.width v.signed v.bits_lo v.bits_hi
         (Seed_mir.print_constant (Seed_mir.Integer v))
         width signed bits_lo bits_hi printed)
  else Printf.printf "literal check %s: PASS (prints %s)\n" name printed

let contains_substring (haystack : string) (needle : string) : bool =
  let n = String.length needle in
  let hn = String.length haystack in
  let rec go i = i + n <= hn && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

let expect_seed_bug (name : string) (src : string) (needle : string) : unit =
  match (try Ok (lower_int_literal src) with Mir_lower.Seed_bug m -> Error m) with
  | Error m when not (contains_substring m needle) ->
      failwith (Printf.sprintf "Seed_bug check %s: message %S missing %S" name m needle)
  | Error _ -> Printf.printf "Seed_bug check %s: PASS\n" name
  | Ok _ -> failwith (Printf.sprintf "Seed_bug check %s: expected Seed_bug, got a value" name)

let run_literal_checks () =
  (* 2^64 - 1: fits no OCaml native int; must lower to the exact value,
     never silently to zero *)
  expect_literal "u64_max"
    "def main() -> u64\n  18446744073709551615u64\nend"
    64 false (-1L) 0L "18446744073709551615";
  (* 2^128 - 1 *)
  expect_literal "u128_max"
    "def main() -> u128\n  340282366920938463463374607431768211455u128\nend"
    128 false (-1L) (-1L) "0xffffffffffffffff_ffffffffffffffff";
  (* u8 300 wraps deterministically to 44 *)
  expect_literal "u8_300_wrap"
    "def main() -> u8\n  300u8\nend"
    8 false 44L 0L "44";
  (* 2^129 exceeds 128 bits: Seed_bug, not a silent zero *)
  expect_seed_bug "u128_2p129"
    "def main() -> u128\n  680564733841876926926749214863536422912u128\nend"
    "integer literal exceeds 128 bits in lowering"

(* ── main ──────────────────────────────────────────────────────── *)

let read_input () =
  match Array.to_list Sys.argv with
  | _ :: f :: _ ->
      let ic = open_in f in
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      (f, s)
  | _ ->
      let buf = Buffer.create 65536 in
      (try
         while true do
           Buffer.add_channel buf stdin 4096
         done
       with End_of_file -> ());
      ("<stdin>", Buffer.contents buf)

let () =
  let name, contents = read_input () in
  let lines =
    List.filter (fun l -> String.trim l <> "") (String.split_on_char '\n' contents)
  in
  let failed = ref 0 in
  List.iter
    (fun ln ->
      if not (check_line ln) then begin
        incr failed;
        if !failed <= 5 then Printf.printf "MISMATCH: %s\n" ln
      end)
    lines;
  if !failed > 0 then begin
    Printf.printf "FAIL: %d/%d oracle lines mismatched (from %s)\n" !failed
      (List.length lines) name;
    exit 1
  end;
  Printf.printf "oracle: PASS (%d lines, from %s)\n" (List.length lines) name;
  run_fixed_vectors ();
  run_literal_checks ();
  Printf.printf "all Int_value self-checks: PASS\n"
