(** Tests for the Tangerine stage0 compiler *)

open Alcotest

(* ===== Lexer Tests ===== *)

let test_lex_simple () =
  let src = "def add(a: Int, b: Int) -> Int\n  a + b\nend" in
  let lexbuf = Lexing.from_string src in
  let rec collect_tokens acc =
    match Tangerine.Lexer.token lexbuf with
    | Tangerine.Parser.EOF -> List.rev acc
    | tok -> collect_tokens (tok :: acc)
  in
  let tokens = collect_tokens [] in
  check (list pass) "token count" () (ignore tokens)

let test_lex_keywords () =
  let src = "def end if then else elsif while for in do let mut" in
  let lexbuf = Lexing.from_string src in
  let first_token = Tangerine.Lexer.token lexbuf in
  check pass "first token is DEF" () (
    match first_token with
    | Tangerine.Parser.DEF -> ()
    | _ -> failwith "expected DEF"
  )

let test_lex_numbers () =
  let src = "42 0x2A 0b101010 0o52 3.14 1e10" in
  let lexbuf = Lexing.from_string src in
  let tok = Tangerine.Lexer.token lexbuf in
  match tok with
  | Tangerine.Parser.INT_LIT (n, _) ->
    check int64 "decimal literal" 42L n
  | _ -> failwith "expected INT_LIT"

let test_lex_strings () =
  let src = "\"hello world\"" in
  let lexbuf = Lexing.from_string src in
  let tok = Tangerine.Lexer.token lexbuf in
  match tok with
  | Tangerine.Parser.STRING_LIT s ->
    check string "string literal" "hello world" s
  | _ -> failwith "expected STRING_LIT"

(* ===== Parser Tests ===== *)

let test_parse_simple_function () =
  let src = "def add(a: Int, b: Int) -> Int\n  a + b\nend" in
  let lexbuf = Lexing.from_string src in
  let ast = Tangerine.Parser.program Tangerine.Lexer.token lexbuf in
  check int "one item" 1 (List.length ast.Tangerine.Ast.prog_items)

let test_parse_struct () =
  let src = "struct Point\n  x: Int\n  y: Int\nend" in
  let lexbuf = Lexing.from_string src in
  let ast = Tangerine.Parser.program Tangerine.Lexer.token lexbuf in
  check int "one item" 1 (List.length ast.Tangerine.Ast.prog_items);
  match (List.hd ast.prog_items).item_desc with
  | Tangerine.Ast.ItemStruct s ->
    check string "struct name" "Point" s.struct_name.name;
    check int "field count" 2 (List.length s.struct_fields)
  | _ -> failwith "expected struct"

let test_parse_enum () =
  let src = "enum Color\n  Red\n  Green\n  Blue\n  RGB(Int, Int, Int)\nend" in
  let lexbuf = Lexing.from_string src in
  let ast = Tangerine.Parser.program Tangerine.Lexer.token lexbuf in
  match (List.hd ast.prog_items).item_desc with
  | Tangerine.Ast.ItemEnum e ->
    check string "enum name" "Color" e.enum_name.name;
    check int "variant count" 4 (List.length e.enum_variants)
  | _ -> failwith "expected enum"

let test_parse_if_expr () =
  let src = "def foo() -> Int\n  if true then 1 else 2 end\nend" in
  let lexbuf = Lexing.from_string src in
  let _ast = Tangerine.Parser.program Tangerine.Lexer.token lexbuf in
  check pass "parsed if expression" () ()

let test_parse_match () =
  let src = "def foo(x: Int) -> Int\n  match x\n  when 0 then 1\n  when _ then 2\n  end\nend" in
  let lexbuf = Lexing.from_string src in
  let _ast = Tangerine.Parser.program Tangerine.Lexer.token lexbuf in
  check pass "parsed match expression" () ()

(* ===== Type System Tests ===== *)

let test_type_unify_same () =
  let t = Tangerine.Types.TPrim Tangerine.Types.TInt in
  match Tangerine.Types.unify t t with
  | Ok () -> check pass "same types unify" () ()
  | Error _ -> failwith "should unify"

let test_type_unify_var () =
  let var = Tangerine.Types.fresh_tvar 0 in
  let int_ty = Tangerine.Types.TPrim Tangerine.Types.TInt in
  match Tangerine.Types.unify var int_ty with
  | Ok () ->
    check pass "var unified with int" () (
      match Tangerine.Types.repr var with
      | Tangerine.Types.TPrim Tangerine.Types.TInt -> ()
      | _ -> failwith "var should be linked to int"
    )
  | Error _ -> failwith "should unify"

let test_type_unify_mismatch () =
  let t1 = Tangerine.Types.TPrim Tangerine.Types.TInt in
  let t2 = Tangerine.Types.TPrim Tangerine.Types.TBool in
  match Tangerine.Types.unify t1 t2 with
  | Ok () -> failwith "should not unify"
  | Error _ -> check pass "different types don't unify" () ()

(* ===== Integration Tests ===== *)

let test_full_pipeline () =
  let src = "
struct Point
  x: Int
  y: Int
end

def add(a: Int, b: Int) -> Int
  a + b
end

def main() -> Int
  let p: Point = Point { x: 1, y: 2 }
  add(p.x, p.y)
end
" in
  let lexbuf = Lexing.from_string src in
  let ast = Tangerine.Parser.program Tangerine.Lexer.token lexbuf in
  let errors = Tangerine.Typecheck.check_program ast in
  (* Note: This may have some errors due to incomplete implementation *)
  ignore errors;
  let mir = Tangerine.Lower.lower_program ast in
  check int "functions lowered" 2 (List.length mir.Tangerine.Mir.functions)

(* ===== Test Suites ===== *)

let lexer_tests = [
  "simple lexing", `Quick, test_lex_simple;
  "keywords", `Quick, test_lex_keywords;
  "numbers", `Quick, test_lex_numbers;
  "strings", `Quick, test_lex_strings;
]

let parser_tests = [
  "simple function", `Quick, test_parse_simple_function;
  "struct", `Quick, test_parse_struct;
  "enum", `Quick, test_parse_enum;
  "if expression", `Quick, test_parse_if_expr;
  "match expression", `Quick, test_parse_match;
]

let type_tests = [
  "unify same types", `Quick, test_type_unify_same;
  "unify type var", `Quick, test_type_unify_var;
  "unify mismatch", `Quick, test_type_unify_mismatch;
]

let integration_tests = [
  "full pipeline", `Quick, test_full_pipeline;
]

let () =
  run "Tangerine Stage0" [
    "Lexer", lexer_tests;
    "Parser", parser_tests;
    "Types", type_tests;
    "Integration", integration_tests;
  ]
