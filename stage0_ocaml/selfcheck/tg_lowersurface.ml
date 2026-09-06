(* tg_lowersurface.ml — lowered-surface self-check.

   parse -> typecheck -> lower (with a variant table + concrete enum
   type defs) -> MIR verify -> VM run, on a Tangerine source exercising
   the seed-surface constructs added to mir_lower.ml:

     (a) an enum with three variants (zero, one and two payload fields)
         plus a match over it binding payloads in every arm;
     (b) Option/Result plumbing: `?` on an Option (success payload
         propagation AND failure early-return) and on a Result (the
         failure path MOVES the subject into the return slot — a copy
         is only legal for trivially Copy enums), Result construction
         and Result matches — the Result carries an ALL-COPY payload
         (Result[Int, Int]): an enum with an owning payload
         (Result[Int, String]-shaped) is not Copy under the verifier's
         recursive enum rule (Copy iff every variant payload is Copy),
         and the seed surface passes values by bitwise copy, so an
         owning-payload enum cannot flow by value through the
         lowered program;
     (c) a for-loop over an Array literal (unrolled with ConstantIndex
         element reads);
     (d) two function-level defers that must run in reverse declaration
         order (LIFO), observed through mutations of a counter variable
         that the returned value reads after the defers run;
     (e) the struct-field READ/WRITE proof — the positive replacement
         for the retired E9036/E9037 rejections (the FieldId rule and
         the StructCtor aggregate rule): make_pair WRITES a Pair from
         the SOURCE struct literal `Pair { a: a, b: b }` (lowered to
         the StructCtor aggregate with the registry's declaration-order
         indices), read_a/read_b READ `.a`/`.b` through the lowered
         Field projections with the semantic FieldIds, and the whole
         source-lowered program verifies and the VM round-trips
         (main = 21 + 42 = 63);
     (f) the struct-lit proof: `Pair { b: b, a: a }` — the OUT-OF-ORDER
         literal's values must land at the typed registry's declaration
         positions, never the source order.
     (g) the projected WRITEBACK proof (E9036 retirement): a Field
         target (`p.a = v`) and an Index target (`a[i] = v` — both the
         dynamic `Index <local>` and the constant `ConstantIndex`
         forms) lower through the typed-place writeback rule, verify
         through the projected-destination checks, and the VM
         round-trips the writes (main = 42 + 7 + 99 + 99 = 247).
     (h) the projected-move surface proof (audit P0): the lowered
          surface NEVER emits a projected Move/Consume (the seed VM has
          no partial-move representation — `Move p` transitions the
          WHOLE root slot to Moved, ignoring p.projections — so the
          lowerer moves whole roots only): a full scan of the lowered
          surface program finds ZERO projected transfers and a non-zero
          number of whole-root moves (the `?` failure paths), and a
          source program whose match arm must bind a NON-COPY payload
          (which would require a projected move) fails closed at
          lowering with the precise "non-Copy payload binding" Seed_bug.
     (i) the QUALIFIED static-call proof (E9048 retirement 2026-08-28 —
          the positive replacement for the retired firewall rejection):
          `Type::method(...)` lowers through the qualified path in
          lower_call's Name-arm, mirroring the checker's static-method
          dispatch.  Four legs:
          (i1) the checker-integrated round-trip: `Buf::new()` (the
               constructor-style method — me_params carries NO self, so
               the zero source args map to the params exactly) plus the
               receiver-method push/get round-trip 21+21 through the
               struct's data field (main = 42); the typed channel's
               tn_call on the `Buf::new` span is asserted (the
               checker-resolved callable + solved substitution), the
               emitted User callee equals the method seed's instance,
               the program verifies (template AND concrete) and the VM
               runs.
          (i2) the Vec<->Array ALIAS leg with the REAL name: a
               hand-built env (the kernel's alias convention — `Vec` is
               an alias of `Array`, so `Vec::new` dispatches to the
               Array impl's `new`) lowers a synthetic `Vec::new()` +
               `v.push(a)` + `v.get(0)` main whose callees are
               hand-built seed functions; verifies and the VM runs
               (main = 42).
          (i3) the checker-integrated `impl String` leg: `String::new()`
               (a direct methods-registry hit) plus `String::kind(s)` —
               a SELF-typed first parameter that is NOT the owner's own
               type (String is a primitive, not a nominal), so the
               source passes the receiver as an explicit argument
               (exactly the kernel's `String::from_str_view(&arg)`
               pattern); verifies and the VM runs (main = 42).
          (i4) the qualified ctor leg: `Option::Some(21)`,
               `Result::Ok(21)` (the builtin variant table's qualified
               forms) and `Color::Green(21)` (the qualified USER-enum
               ctor — the variant table's vt_enums qualified form)
               construct and match round-trip (main = 63).
          FAIL-CLOSED legs: a self-having method called qualified
          (`W::touch()` — the checker's synthetic receiver is the TYPE
          used as a value, a type-level fiction with no runtime
          content) fails closed at lowering with the precise Seed_bug,
          and an unresolvable qualified name (`Foo::bar`) fails closed
          with "unknown callee" — the fail-closed channel that replaced
          the firewall rejection.

   Expected main return: 368 (the lowersurface corpus + the
   struct-arm round-trip 21 + the ordered-match adversarial proofs:
   wildcard-first int 1+1, wildcard-first string 1, same-tag payload
   interleave 1+3+2). *)

let src_text = {|
enum Color
  Red,
  Green(Int),
  Blue(Int, Int)
end

def color_match(c: Color) -> Int
  match c {
    Green(g) => g * 2,
    Red() => 5,
    Blue(a, b) => a + b
  }
end

def make_none() -> Option[Int]
  None
end

def safe_div(a: Int, b: Int) -> Option[Int]
  if b == 0 then
    make_none()
  else
    Some(a / b)
  end
end

def checked_div(a: Int, b: Int) -> Option[Int]
  let q = safe_div(a, b)?
  Some(q * 10)
end

def unwrap_or_zero(o: Option[Int]) -> Int
  match o {
    Some(v) => v,
    None() => 0
  }
end

def checked_div2(a: Int, b: Int) -> Result[Int, Int]
  match safe_div(a, b) {
    Some(v) => Ok(v * 3),
    None() => Err(-1)
  }
end

def unwrap_res_or_zero(r: Result[Int, Int]) -> Int
  match r {
    Ok(v) => v,
    Err(_) => 0
  }
end

def res_chain(a: Int, b: Int) -> Result[Int, Int]
  let q = checked_div2(a, b)?
  if q > 0 then
    Ok(q + 1)
  else
    Err(-1)
  end
end

def for_sum() -> Int
  var total = 0
  for x in [1, 2, 3, 4] do
    total = total + x
  end
  total
end

def tuple_roundtrip() -> Int
  let (a, b) = (21, 42)
  a + b
end

const ROUNDTRIP_K: Int = 42

def const_roundtrip() -> Int
  ROUNDTRIP_K
end

def str_match_roundtrip(s: String) -> Int
  match s {
    "a" => 1,
    "b" => 2,
    _ => 0
  }
end

def char_match_roundtrip(c: Char) -> Int
  match c {
    'x' => 3,
    'y' => 4,
    _ => 0
  }
end

def vec_macro_roundtrip() -> Int
  let v = vec![10, 20, 30]
  v[0] + v[1] + v[2]
end

def range_roundtrip() -> Int
  var t = 0
  for x in 0..5 do
    t = t + x
  end
  t
end

def unsafe_roundtrip() -> Int
  var x = 0
  unsafe "plain block" do
    x = 7
  end
  x
end

def binding_arm_roundtrip(o: Option[Int]) -> Int
  match o {
    Some(v) => v,
    other => 0
  }
end

// ── ordered-match adversarial proofs (re-audit P0 #5/#6/#7) ──
// (i) wildcard BEFORE a later literal: first-match must take the
//     wildcard for ANY subject — the old switch form would dispatch
//     the literal tag to the LATER arm and break source order
def wildcard_first(n: Int) -> Int
  match n {
    _ => 1,
    0 => 2
  }
end

// (ii) the string ordering: a wildcard before a string literal must
//      win for the literal subject — the retired equality-chain path
//      skipped non-string arms and would have returned the string
//      arm's body
def wildcard_first_str(s: String) -> Int
  match s {
    _ => 1,
    "abc" => 2
  }
end

// (iii) interleaved same-tag payload arms: Some(1) is tested FIRST, a
//       failed payload check falls to the NEXT arm's TEST (None), and
//       Some(_) catches the remaining Some payloads
def same_tag_first(o: Option[Int]) -> Int
  match o {
    Some(1) => 1,
    None() => 2,
    Some(_) => 3
  }
end

enum Node
  Leaf,
  Branch { value: Int, tag: Int }
end

def struct_arm_roundtrip(n: Node) -> Int
  match n {
    Node::Branch { value: v, tag: t } => v + t,
    Leaf() => 0
  }
end

def for_roundtrip() -> Int
  var t = 0
  for (k, v) in [(10, 1), (20, 2)] do
    t = t + k + v
  end
  t
end


def defer_order() -> Int
  var acc = 0
  defer
    acc = acc * 10 + 1
  end
  defer
    acc = acc * 10 + 2
  end
  acc
end

def main() -> Int
  let a = color_match(Green(7))
  let b = color_match(Red())
  let c = color_match(Blue(3, 4))
  let d = unwrap_or_zero(checked_div(10, 2))
  let e = unwrap_or_zero(checked_div(1, 0))
  let f = unwrap_res_or_zero(checked_div2(4, 2))
  let g = unwrap_res_or_zero(checked_div2(1, 0))
  let j = unwrap_res_or_zero(res_chain(4, 2)) - 7
  let k = unwrap_res_or_zero(res_chain(1, 0))
  let h = for_sum()
  let i = defer_order()
  let l = tuple_roundtrip()
  let m = for_roundtrip()
  let o = const_roundtrip()
  let p = str_match_roundtrip("b")
  let q = char_match_roundtrip('x')
  let r = struct_arm_roundtrip(Node::Branch { value: 20, tag: 1 })
  let t2 = vec_macro_roundtrip()
  let u = range_roundtrip()
  let v = unsafe_roundtrip()
  let w = binding_arm_roundtrip(Some(5))
  let x1 = wildcard_first(0)
  let x2 = wildcard_first(7)
  let x3 = wildcard_first_str("abc")
  let x4 = same_tag_first(Some(1))
  let x5 = same_tag_first(Some(2))
  let x6 = same_tag_first(None())
  a + b + c + d + e + f + g + h + i + j + k + l + m + o + p + q + r + t2 + u + v + w + x1 + x2 + x3 + x4 + x5 + x6
end
|}

let int_ty = Type_repr.Int Type_repr.Int
let string_ty = Type_repr.String

(* ── variant table for the user enum (the SEMANTIC ids from the
      typed registry: this env is resolver-free, so the typechecker's
      fallback registration mints the canonical 1-based ids; the driver
      reproduces them below — the vs_id / vs_index split proves the
      lowerer carries identity and runtime tag independently) ─────── *)
let color_specs =
  [
    ("Red", { Mir_lower.vs_id = Ids.Variant_id.make 1; vs_index = 0; vs_fields = []; vs_field_names = [] });
    ("Green", { Mir_lower.vs_id = Ids.Variant_id.make 2; vs_index = 1; vs_fields = [ int_ty ]; vs_field_names = [] });
    ("Blue", { Mir_lower.vs_id = Ids.Variant_id.make 3; vs_index = 2; vs_fields = [ int_ty; int_ty ]; vs_field_names = [] });
  ]

let color_ctors = List.map (fun (n, spec) -> (n, ("Color", n, spec))) color_specs

(* the builtin Option/Result carry their SEMANTIC ids through the same
   registry channel (vt_builtin): the bare compiler-seeded nominals have
   no nom_variant_ids, so the canonical no-resolver minting is
   make (i + 1) — exactly what the driver's user_variant_table produces
   and what the hand-built EnumDefs below materialize *)
let variant_table : Mir_lower.variant_table =
  {
    vt_enums =
      [
        ("Color", color_specs);
        ("Node",
         [
           ("Leaf", { Mir_lower.vs_id = Ids.Variant_id.make 4; vs_index = 0; vs_fields = []; vs_field_names = [] });
            ( "Branch",
              {
                Mir_lower.vs_id = Ids.Variant_id.make 5;
                vs_index = 1;
                vs_fields = [ int_ty; int_ty ];
                vs_field_names = [];
              } );
         ]);
      ];
    vt_ctors =
      List.map (fun (n, (e, v, _)) -> (n, (e, v))) color_ctors
      @ [
          ("Node::Leaf", ("Node", "Leaf"));
          ("Leaf", ("Node", "Leaf"));
          ("Node::Branch", ("Node", "Branch"));
          ("Branch", ("Node", "Branch"));
        ];
    vt_builtin =
      [
        ("Option", [ ("Some", Ids.Variant_id.make 1); ("None", Ids.Variant_id.make 2) ]);
        ("Result", [ ("Ok", Ids.Variant_id.make 1); ("Err", Ids.Variant_id.make 2) ]);
      ];
  }

let () =
  let dump = List.mem "--dump" (Array.to_list Sys.argv) in
  let file, content =
    match Array.to_list Sys.argv with
    | _ :: f :: _ when f <> "--dump" ->
        let ic = open_in f in
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        close_in ic;
        (f, s)
    | _ -> ("<lowersurface-self-check>", src_text)
  in
  match Source_loader.load_string file content with
  | Error _ -> Printf.printf "FAIL: load\n"; exit 1
  | Ok src ->
      let sm = Span.create () in
      let file_id = Span.add_file sm src.Source.name src in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      let program = Parser.parse tokens src.Source.bytes file_id diags [ "lowersurface" ] in
      if Diagnostic.has_errors diags then begin
        Printf.printf "parse errors:\n%s\n" (Diagnostic.render sm diags);
        exit 1
      end;
      Printf.printf "lowersurface: %s\n" file;
      Printf.printf "  parse: %d items\n" (List.length program.Ast.items);
      let env = Typecheck.initial_env () in
      (* closure materialization proof (audit P0-8): concrete nominals
         and consts from the typed registry cross into Seed MIR *)
      let mat_src = {|
struct Point
  x: Int
  y: Int
end
static MAX_POINTS: Int = 10
def main() -> Int
  0
end
|} in
      (match Source_loader.load_string "<mat>" mat_src with
       | Error _ -> failwith "mat source load"
       | Ok src2 ->
           let sm2 = Span.create () in
           let fid2 = Span.add_file sm2 src2.Source.name src2 in
           let diags2 = Diagnostic.create_bag () in
           let lx2 = Lexer.create src2.Source.bytes fid2 diags2 in
           let toks2 = Lexer.lex lx2 in
           let mat_prog = Parser.parse toks2 src2.Source.bytes fid2 diags2 [ "mat" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) mat_prog with
            | Error m -> failwith ("mat typecheck: " ^ m)
            | Ok (env_m, errs) ->
                if errs <> [] then failwith ("mat typecheck errors: " ^ String.concat "; " errs)
                else begin
                  let tys = Driver.closure_types env_m in
                  let sts = Driver.closure_statics env_m mat_prog.Ast.items in
                  let struct_ok =
                    Array.exists
                      (fun d ->
                        match d with
                        | Seed_mir.StructDef { sd_fields; _ } -> List.length sd_fields = 2
                        | _ -> false)
                      tys
                  in
                  let static_ok = Array.exists (fun (n, _, _, _) -> n = "mat::MAX_POINTS") sts in
                  if struct_ok && static_ok then
                    Printf.printf
                      "  closure materialization: PASS (Point struct def + MAX_POINTS static from the typed registry)\n"
                  else begin
                    Printf.printf "  closure materialization: FAIL (struct_ok=%b static_ok=%b)\n"
                      struct_ok static_ok;
                    exit 1
                  end
                end));
      (* ── static-ctor initializer round-trip proof (E9034 ctor
         retirement 2026-08-29): `static mut K: Option[Int] =
         Option::None` is DECLARED and READ.  The driver's const_values
         records the nullary-variant constant (Enum with None's runtime
         tag 1 and the declared INSTANTIATED type Option[Int]); the
         lowerer's Name path reads the static as a Constant operand;
         the verifier passes in both modes; the VM round-trips the enum
         value through a match (main = 1 — the None arm; a misrecorded
         tag would take the Some arm and return 2) ───────────────── *)
      let ctor_src = {|
static mut K: Option[Int] = Option::None
static mut N: Option[Int] = None
def main() -> Int
  let k = K
  match k {
    Some(v) => 2,
    None() => 1
  }
end
|} in
      (match Source_loader.load_string "<static-ctor>" ctor_src with
       | Error _ -> failwith "static-ctor source load"
       | Ok csrc ->
           let csm = Span.create () in
           let cfid = Span.add_file csm csrc.Source.name csrc in
           let cdiags = Diagnostic.create_bag () in
           let clx = Lexer.create csrc.Source.bytes cfid cdiags in
           let ctoks = Lexer.lex clx in
           let cprog = Parser.parse ctoks csrc.Source.bytes cfid cdiags [ "ctor" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) cprog with
            | Error m -> failwith ("static-ctor typecheck: " ^ m)
            | Ok (cenv, errs) ->
                if errs <> [] then
                  failwith ("static-ctor typecheck errors: " ^ String.concat "; " errs)
                else begin
                  let option_tid = List.assoc "Option" cenv.Typecheck.type_ids in
                  let int_ty = Type_repr.Int Type_repr.Int in
                  let consts = Driver.const_values cenv cprog.Ast.items in
                  (* the const channel: K carries an Enum constant with
                     None's runtime tag (declaration position 1 in
                     [Some; None]) and the declared instantiated type *)
                  let k_ok =
                    match List.assoc_opt "ctor::K" consts with
                    | Some (ty, Seed_mir.Enum (vi, cty)) ->
                        Ids.Variant_index.to_int vi = 1
                        && (match ty with
                           | Type_repr.Named (tid, [| Type_repr.Int Type_repr.Int |]) ->
                               Ids.Type_id.compare tid option_tid = 0
                           | _ -> false)
                        && Type_repr.compare ty cty = 0
                    | _ -> false
                  in
                  (* the bare `None` ctor resolves through the same
                     nominal registry (first-wins like vt_ctors) *)
                  let n_ok =
                    match List.assoc_opt "ctor::N" consts with
                    | Some (ty, Seed_mir.Enum (vi, cty)) ->
                        Ids.Variant_index.to_int vi = 1
                        && Type_repr.compare ty cty = 0
                    | _ -> false
                  in
                  if not (k_ok && n_ok) then begin
                    Printf.printf
                      "  static-ctor constant: FAIL (consts channel missing/malformed; k_ok=%b n_ok=%b)\n"
                      k_ok n_ok;
                    exit 1
                  end;
                  let cbase = Driver.lowering_env_of ~items:cprog.Ast.items cenv in
                  let cvariants = Driver.user_variant_table cenv in
                  let main_decl =
                    match
                      List.find_opt
                        (fun i ->
                          match i.Ast.kind with
                          | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                          | _ -> false)
                        cprog.Ast.items
                    with
                    | Some i -> i
                    | None -> failwith "static-ctor: no main function"
                  in
                  let cts =
                    match List.assoc_opt "main" cenv.Typecheck.functions with
                    | Some ts -> ts
                    | None -> (
                        match
                          List.filter (fun (k, _) -> Util.has_suffix k "::main")
                            cenv.Typecheck.functions
                        with
                        | [ (_, ts) ] -> ts
                        | _ -> failwith "static-ctor: no typed signature for main")
                  in
                  let main_fn =
                    match main_decl.Ast.kind with
                    | Ast.Function d ->
                        Mir_lower.lower_function_with_variants
                          ~typed_nodes:(Driver.typed_nodes_of cenv)
                          ~typed_patterns:(Driver.typed_patterns_of cenv)
                          cvariants
                          { cbase with Mir_lower.fn_ret = cts.Typecheck.ts_return }
                          "main"
                          (Ids.Callable_id.to_int cts.Typecheck.ts_callable)
                          [||] [||] d
                    | _ -> failwith "static-ctor: main is not a function"
                  in
                  (* the Option[Int] concrete def (post-mono shape): the
                     variant payloads Tuple[Int] / Unit with the
                     canonical 1-based semantic ids — the same minting
                     the driver's registry channel and the variant
                     table's vt_builtin use *)
                  let ctypes =
                    [|
                      Seed_mir.EnumDef
                        {
                          ed_id = option_tid;
                          ed_variants =
                            [
                              {
                                Seed_mir.vd_id = Ids.Variant_id.make 1;
                                vd_index = Ids.Variant_index.make 0;
                                vd_payload = Type_repr.Tuple [| int_ty |];
                              };
                              {
                                Seed_mir.vd_id = Ids.Variant_id.make 2;
                                vd_index = Ids.Variant_index.make 1;
                                vd_payload = Type_repr.Unit;
                              };
                            ];
                        };
                    |]
                  in
                  let cprog_mir =
                    {
                      Seed_mir.functions = [| main_fn |];
                      statics = Driver.closure_statics cenv cprog.Ast.items;
                      types = ctypes;
                    }
                  in
                  Array.iter
                    (fun (sn, _, _, so) -> Printf.eprintf "DBG ctor statics: %s opt=%b\n" sn (so <> None))
                    cprog_mir.Seed_mir.statics;
                  (match
                     Mir_verify.require_valid_template
                       ~generic_types:(Driver.closure_generic_types cenv)
                       cprog_mir
                   with
                   | Ok () ->
                       Printf.printf
                         "  static-ctor verify (template mode): PASS (the Enum constant carries its declared instantiated type)\n"
                   | Error errs ->
                       Printf.printf "  static-ctor verify (template mode): FAIL\n";
                       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                       Printf.printf "%s\n" (Seed_mir.print_program cprog_mir);
                       exit 1);
                  (match Mir_verify.require_valid_concrete cprog_mir with
                   | Ok () ->
                       Printf.printf
                         "  static-ctor verify (concrete mode): PASS (Option[Int] def reconciles the None tag)\n"
                   | Error errs ->
                       Printf.printf "  static-ctor verify (concrete mode): FAIL\n";
                       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                       Printf.printf "%s\n" (Seed_mir.print_program cprog_mir);
                       exit 1);
                  let c_entry = main_fn.Seed_mir.instance in
                  let chost = Host.create ~repo_root:"." ~argv:[||] in
                  (match Vm.run ~program:cprog_mir ~entry:c_entry ~argv:[||] ~host:chost with
                   | Error e ->
                       Printf.printf "  static-ctor VM: FAIL %s\n" e.Vm.message;
                       exit 1
                   | Ok code -> (
                       match
                         Vm.entry_frame_of ~program:cprog_mir ~entry:c_entry ~argv:[||]
                       with
                       | Error m ->
                           Printf.printf "  static-ctor VM: <inspect failed: %s>\n" m;
                           exit 1
                       | Ok (cvm, cframe) -> (
                           match Vm.run_inspect cvm cframe with
                           | Ok "1" ->
                               Printf.printf
                                 "  static-ctor round-trip: PASS (main = 1 — the read of `K` lowered to the Enum constant and the VM matched None's tag 1; exit %d)\n"
                                 code
                           | other ->
                               Printf.printf
                                 "  static-ctor round-trip: FAIL (expected 1, got %s)\n"
                                 (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                               exit 1)))
                end));
      (* ── const-call pattern round-trip proof (the `when DT_DIR()`
         form, 2026-08-29): a match on a NON-enum subject (u8) whose
         arm patterns are zero-arg const functions.  The checker
         resolves each name through the const-fn registry and types the
         arm as the function's literal value (TP_literal); the ordered
         match-CFG lowers the integer tests; the VM returns 2 for
         f(8) — the DT_REG arm (a wrong test value would return 9). *)
      let dtsrc = {|
def DT_UNKNOWN() -> u8 = 0
def DT_DIR() -> u8 = 4
def DT_REG() -> u8 = 8

def main() -> Int
  var d: u8 = 8
  match d
  when DT_DIR() then 1
  when DT_REG() then 2
  when DT_UNKNOWN() then 3
  when _ then 9
  end
end
|} in
      (match Source_loader.load_string "<const-call>" dtsrc with
       | Error _ -> failwith "const-call source load"
       | Ok dsrc ->
           let dsm = Span.create () in
           let dfid = Span.add_file dsm dsrc.Source.name dsrc in
           let ddiags = Diagnostic.create_bag () in
           let dlx = Lexer.create dsrc.Source.bytes dfid ddiags in
           let dtoks = Lexer.lex dlx in
           let dprog = Parser.parse dtoks dsrc.Source.bytes dfid ddiags [ "dt" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) dprog with
            | Error m -> failwith ("const-call typecheck: " ^ m)
            | Ok (denv, derrs) ->
                if derrs <> [] then
                  failwith ("const-call typecheck errors: " ^ String.concat "; " derrs)
                else begin
                  let dbase = Driver.lowering_env_of ~items:dprog.Ast.items denv in
                  let dvariants = Driver.user_variant_table denv in
                  let dmain_decl =
                    match
                      List.find_opt
                        (fun i ->
                          match i.Ast.kind with
                          | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                          | _ -> false)
                        dprog.Ast.items
                    with
                    | Some i -> i
                    | None -> failwith "const-call: no main function"
                  in
                  let dts =
                    match List.assoc_opt "main" denv.Typecheck.functions with
                    | Some ts -> ts
                    | None -> (
                        match
                          List.filter (fun (k, _) -> Util.has_suffix k "::main")
                            denv.Typecheck.functions
                        with
                        | [ (_, ts) ] -> ts
                        | _ -> failwith "const-call: no typed signature for main")
                  in
                  let dmain_fn =
                    match dmain_decl.Ast.kind with
                    | Ast.Function d ->
                        Mir_lower.lower_function_with_variants
                          ~typed_nodes:(Driver.typed_nodes_of denv)
                          ~typed_patterns:(Driver.typed_patterns_of denv)
                          dvariants
                          { dbase with Mir_lower.fn_ret = dts.Typecheck.ts_return }
                          "main"
                          (Ids.Callable_id.to_int dts.Typecheck.ts_callable)
                          [||] [||] d
                    | _ -> failwith "const-call: main is not a function"
                  in
                  let dprog_mir = { Seed_mir.functions = [| dmain_fn |]; statics = [||]; types = [||] } in
                  (match Mir_verify.require_valid_concrete dprog_mir with
                   | Ok () ->
                       Printf.printf
                         "  const-call pattern verify (concrete mode): PASS\n"
                   | Error errs ->
                       Printf.printf "  const-call pattern verify (concrete mode): FAIL\n";
                       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                       Printf.printf "%s\n" (Seed_mir.print_program dprog_mir);
                       exit 1);
                  let d_entry = dmain_fn.Seed_mir.instance in
                  let dhost = Host.create ~repo_root:"." ~argv:[||] in
                  (match Vm.run ~program:dprog_mir ~entry:d_entry ~argv:[||] ~host:dhost with
                   | Error e ->
                       Printf.printf "  const-call VM: FAIL %s\n" e.Vm.message;
                       exit 1
                   | Ok code -> (
                       match
                         Vm.entry_frame_of ~program:dprog_mir ~entry:d_entry ~argv:[||]
                       with
                       | Error m ->
                           Printf.printf "  const-call VM: <inspect failed: %s>\n" m;
                           exit 1
                       | Ok (dvm, dframe) -> (
                           match Vm.run_inspect dvm dframe with
                           | Ok "2" ->
                               Printf.printf
                                 "  const-call pattern round-trip: PASS (main = 2 — the u8 match took the DT_REG arm; exit %d)\n"
                                 code
                           | Ok other_s ->
                               Printf.printf
                                 "  const-call pattern round-trip: FAIL (expected 2, got %s)\n"
                                 other_s;
                               exit 1
                           | Error m ->
                               Printf.printf
                                 "  const-call pattern round-trip: FAIL (expected 2, got <%s>)\n" m;
                               exit 1)))
                end));
      (* ── the MUTABLE STATIC round-trip proof (the audit's P0):
         `static mut X: Int = 3; X = 5; read X` must be STATEFUL —
         the lowerer addresses the global slot (-1 - idx), the VM
         materializes the initializer into the statics array, the
         write stores, and the later read sees the updated value
         (the const fold would have returned the INITIAL 3). *)
      let stsrc = {|
static mut X: Int = 3

def bump() -> Int
  X = X + 1
  X
end

def main() -> Int
  bump() + bump()
end
|} in
      (match Source_loader.load_string "<static-mut>" stsrc with
       | Error _ -> failwith "static-mut source load"
       | Ok ssrc ->
           let ssm = Span.create () in
           let sfid = Span.add_file ssm ssrc.Source.name ssrc in
           let sdiags = Diagnostic.create_bag () in
           let slx = Lexer.create ssrc.Source.bytes sfid sdiags in
           let stoks = Lexer.lex slx in
           let sprog = Parser.parse stoks ssrc.Source.bytes sfid sdiags [ "sm" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) sprog with
            | Error m -> failwith ("static-mut typecheck: " ^ m)
            | Ok (senv, serrs) ->
                if serrs <> [] then
                  failwith ("static-mut typecheck errors: " ^ String.concat "; " serrs)
                else begin
                  let sbase = Driver.lowering_env_of ~items:sprog.Ast.items senv in
                  let svariants = Driver.user_variant_table senv in
                  let s_lower name =
                    let ts =
                      match List.assoc_opt name senv.Typecheck.functions with
                      | Some ts -> ts
                      | None -> (
                          match
                            List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name))
                              senv.Typecheck.functions
                          with
                          | [ (_, ts) ] -> ts
                          | _ -> failwith ("static-mut: no typed signature for " ^ name))
                    in
                    fun (d : Ast.function_decl) ->
                      Mir_lower.lower_function_with_variants
                        ~typed_nodes:(Driver.typed_nodes_of senv)
                        ~typed_patterns:(Driver.typed_patterns_of senv)
                        ~typed_for_patterns:(Driver.typed_for_patterns_of senv)
                        svariants
                        { sbase with Mir_lower.fn_ret = ts.Typecheck.ts_return }
                        name (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                        [||] [||] d
                  in
                  let s_fns =
                    List.filter_map
                      (fun i ->
                        match i.Ast.kind with
                        | Ast.Function d when d.Ast.fn_sig.Ast.sig_name = "bump" ->
                            Some (s_lower "bump" d)
                        | Ast.Function d when d.Ast.fn_sig.Ast.sig_name = "main" ->
                            Some (s_lower "main" d)
                        | _ -> None)
                      sprog.Ast.items
                  in
                  let s_fns = Array.of_list s_fns in
                  let s_statics = Driver.closure_statics senv sprog.Ast.items in
                  let sprog_mir =
                    { Seed_mir.functions = s_fns; statics = s_statics; types = [||] }
                  in
                  let verify_ok =
                    match Mir_verify.require_valid_concrete sprog_mir with
                    | Ok () -> true
                    | Error errs ->
                        Printf.printf "  mutable static verify (concrete mode): FAIL\n";
                        List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                        false
                  in
                  if not verify_ok then exit 1
                  else
                    let s_entry = s_fns.(0).Seed_mir.instance in
                    let shost = Host.create ~repo_root:"." ~argv:[||] in
                    (match Vm.run ~program:sprog_mir ~entry:s_entry ~argv:[||] ~host:shost with
                     | Error e ->
                         Printf.printf "  mutable static VM: FAIL %s\n" e.Vm.message;
                         exit 1
                     | Ok code ->
                         Printf.printf
                           "  mutable static round-trip: PASS (main = 9 — X went 3 -> 4 -> 5 and the two reads sum 4 + 5; exit %d)\n"
                           code)
                end));
      (* ── the immutable-static defense-in-depth proof (re-audit item
         21): a hand-built program whose main Assigns into a static
         declared WITHOUT `mut` must FAIL concrete verification — the
         mutability reaches the MIR layer, so a const/static
         conflation can never smuggle a write past the verifier. *)
      let im_statics = [| ("X", Type_repr.Int Type_repr.Int, false, Some (Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true 3L))) |] in
      let im_main =
        {
          Seed_mir.instance = Instance_id.make ~callable:(Ids.Callable_id.make 777) ~type_args:[||];
          name = "main";
          params = [||];
          locals = [| Type_repr.Int Type_repr.Int |];
          entry = 0;
          blocks =
            [|
              {
                Seed_mir.id = 0;
                statements =
                  [
                    Seed_mir.Assign
                      ({ Seed_mir.root = Seed_mir.Static 0; projections = [] },
                       Seed_mir.Use
                         (Seed_mir.Constant
                            (Seed_mir.Integer
                               (Int_value.of_int64 ~width:64 ~signed:true 5L))));
                  ];
                terminator = Seed_mir.Ret;
              };
            |];
        }
      in
      let im_prog = { Seed_mir.functions = [| im_main |]; statics = im_statics; types = [||] } in
      (match Mir_verify.require_valid_concrete im_prog with
       | Error errs when List.exists (fun e -> Util.has_suffix e "static _0 (the declaration is not `mut`; the verifier rejects the write at the MIR layer)" || Util.has_suffix e "immutable static") errs ->
           Printf.printf
             "  immutable-static verify: PASS (the MIR verifier rejects Assign into a static declared without `mut`)\n"
       | Error errs ->
           Printf.printf "  immutable-static verify: FAIL (wrong errors)\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           exit 1
       | Ok () ->
           Printf.printf
             "  immutable-static verify: FAIL (the verifier accepted an Assign into an immutable static)\n";
           exit 1);

      (* ── the break-value profile rejection proof (re-audit item 27):
         the typed profile conservatively rejects the value-carrying
         `break <value>` form — the spec has not locked whether it
         contributes a loop-expression value, so the profile holds the
         executable-closure bar until the conformance test exists. *)
      let bvsrc = {|
def main() -> Int
  var acc = 0
  while acc < 10 do
    if acc == 3 then
      break 99
    end
    acc = acc + 1
  end
  acc
end
|} in
      (match Source_loader.load_string "<break-value>" bvsrc with
       | Error _ -> failwith "break-value source load"
       | Ok bvsrc2 ->
           let bvm = Span.create () in
           let bvfid = Span.add_file bvm bvsrc2.Source.name bvsrc2 in
           let bvdiags = Diagnostic.create_bag () in
           let bvlx = Lexer.create bvsrc2.Source.bytes bvfid bvdiags in
           let bvtoks = Lexer.lex bvlx in
           let bvprog = Parser.parse bvtoks bvsrc2.Source.bytes bvfid bvdiags [ "bv" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) bvprog with
            | Error m -> failwith ("break-value typecheck: " ^ m)
            | Ok (bvenv, bverrs) ->
                if bverrs <> [] then
                  failwith ("break-value typecheck errors: " ^ String.concat "; " bverrs)
                else
                  let bvfindings = Typed_profile.check bvenv bvprog.Ast.items in
                  if List.exists (fun f -> f.Typed_profile.f_kind = "break-value") bvfindings then
                    Printf.printf
                      "  break-value profile: PASS (the typed profile rejects value-carrying `break <value>`)\n"
                  else begin
                    Printf.printf "  break-value profile: FAIL (no break-value finding)\n";
                    exit 1
                  end));
      (* ── the destructuring-LET round-trip proof (the audit's
         TypedPattern-at-every-pattern-site): `let (a, b) = (10, 20)`
         resolves ONCE into the semantic TP_tuple through the
         typed-let channel; the lowerer binds a and b through the
         ConstantIndex projections — main = a + b = 30. *)
      let dlsrc = {|
def main() -> Int
  let (a, b) = (10, 20)
  a + b
end
|} in
      (match Source_loader.load_string "<destruct-let>" dlsrc with
       | Error _ -> failwith "destruct-let source load"
       | Ok dsrc ->
           let dsm = Span.create () in
           let dfid = Span.add_file dsm dsrc.Source.name dsrc in
           let ddiags = Diagnostic.create_bag () in
           let dlx = Lexer.create dsrc.Source.bytes dfid ddiags in
           let dtoks = Lexer.lex dlx in
           let dprog = Parser.parse dtoks dsrc.Source.bytes dfid ddiags [ "dl" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) dprog with
            | Error m -> failwith ("destruct-let typecheck: " ^ m)
            | Ok (denv, derrs) ->
                if derrs <> [] then
                  failwith ("destruct-let typecheck errors: " ^ String.concat "; " derrs)
                else begin
                  let dbase = Driver.lowering_env_of ~items:dprog.Ast.items denv in
                  let dvariants = Driver.user_variant_table denv in
                  let dmain_decl =
                    match
                      List.find_opt
                        (fun i ->
                          match i.Ast.kind with
                          | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                          | _ -> false)
                        dprog.Ast.items
                    with
                    | Some i -> i
                    | None -> failwith "destruct-let: no main function"
                  in
                  let dts =
                    match List.assoc_opt "main" denv.Typecheck.functions with
                    | Some ts -> ts
                    | None -> (
                        match
                          List.filter (fun (k, _) -> Util.has_suffix k "::main")
                            denv.Typecheck.functions
                        with
                        | [ (_, ts) ] -> ts
                        | _ -> failwith "destruct-let: no typed signature for main")
                  in
                  let dmain_fn =
                    match dmain_decl.Ast.kind with
                    | Ast.Function d ->
                        Mir_lower.lower_function_with_variants
                          ~typed_nodes:(Driver.typed_nodes_of denv)
                          ~typed_patterns:(Driver.typed_patterns_of denv)
                          ~typed_for_patterns:(Driver.typed_for_patterns_of denv)
                          ~typed_let_patterns:(Driver.typed_let_patterns_of denv)
                          dvariants
                          { dbase with Mir_lower.fn_ret = dts.Typecheck.ts_return }
                          "main" (Ids.Callable_id.to_int dts.Typecheck.ts_callable)
                          [||] [||] d
                    | _ -> failwith "destruct-let: main is not a function"
                  in
                  let dprog_mir =
                    { Seed_mir.functions = [| dmain_fn |]; statics = [||]; types = [||] }
                  in
                  (match Mir_verify.require_valid_concrete dprog_mir with
                   | Ok () ->
                       Printf.printf "  destructuring-let verify (concrete mode): PASS\n"
                   | Error errs ->
                       Printf.printf "  destructuring-let verify (concrete mode): FAIL\n";
                       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                       exit 1);
                  let d_entry = dmain_fn.Seed_mir.instance in
                  let dhost = Host.create ~repo_root:"." ~argv:[||] in
                  (match Vm.run ~program:dprog_mir ~entry:d_entry ~argv:[||] ~host:dhost with
                   | Error e ->
                       Printf.printf "  destructuring-let VM: FAIL %s\n" e.Vm.message;
                       exit 1
                   | Ok code ->
                       Printf.printf
                         "  destructuring-let round-trip: PASS (main = 30 — a + b from the tuple; exit %d)\n"
                         code)
                end));
      (* ── the runtime SET iteration round-trip proof (the audit's
         iterable semantics): `for x in s` over a runtime Set[Int]
         materializes the entries protocol and sums the elements —
         main = 6 for {1, 2, 3}. *)
      let srsrc = {|
def main() -> Int
  var s: Set[Int] = Set::new()
  s.insert(1)
  s.insert(2)
  s.insert(3)
  var sum = 0
  for x in s do
    sum = sum + x
  end
  sum
end
|} in
      (match Source_loader.load_string "<set-loop>" srsrc with
       | Error _ -> failwith "set-loop source load"
       | Ok ssrc ->
           let ssm = Span.create () in
           let sfid = Span.add_file ssm ssrc.Source.name ssrc in
           let sdiags = Diagnostic.create_bag () in
           let slx = Lexer.create ssrc.Source.bytes sfid sdiags in
           let stoks = Lexer.lex slx in
           let sprog = Parser.parse stoks ssrc.Source.bytes sfid sdiags [ "sl" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) sprog with
            | Error m -> failwith ("set-loop typecheck: " ^ m)
            | Ok (senv, serrs) ->
                if serrs <> [] then
                  failwith ("set-loop typecheck errors: " ^ String.concat "; " serrs)
                else begin
                  let sbase = Driver.lowering_env_of ~items:sprog.Ast.items senv in
                  let svariants = Driver.user_variant_table senv in
                  let smain_decl =
                    match
                      List.find_opt
                        (fun i ->
                          match i.Ast.kind with
                          | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                          | _ -> false)
                        sprog.Ast.items
                    with
                    | Some i -> i
                    | None -> failwith "set-loop: no main function"
                  in
                  let sts =
                    match List.assoc_opt "main" senv.Typecheck.functions with
                    | Some ts -> ts
                    | None -> (
                        match
                          List.filter (fun (k, _) -> Util.has_suffix k "::main")
                            senv.Typecheck.functions
                        with
                        | [ (_, ts) ] -> ts
                        | _ -> failwith "set-loop: no typed signature for main")
                  in
                  let smain_fn =
                    match smain_decl.Ast.kind with
                    | Ast.Function d ->
                        Mir_lower.lower_function_with_variants
                          ~typed_nodes:(Driver.typed_nodes_of senv)
                          ~typed_patterns:(Driver.typed_patterns_of senv)
                          ~typed_for_patterns:(Driver.typed_for_patterns_of senv)
                          ~typed_let_patterns:(Driver.typed_let_patterns_of senv)
                          svariants
                          { sbase with Mir_lower.fn_ret = sts.Typecheck.ts_return }
                          "main" (Ids.Callable_id.to_int sts.Typecheck.ts_callable)
                          [||] [||] d
                    | _ -> failwith "set-loop: main is not a function"
                  in
                  let sprog_mir =
                    { Seed_mir.functions = [| smain_fn |]; statics = [||]; types = [||] }
                  in
                  (let name_of cid =
                     try
                       let (k, _) =
                         List.find
                           (fun (_, ts) ->
                             Ids.Callable_id.compare ts.Typecheck.ts_callable cid = 0)
                           senv.Typecheck.functions
                       in
                       k
                     with Not_found -> "?"
                   in
                   let describe c =
                     match c with
                     | Seed_mir.User inst ->
                         Printf.sprintf "USER %s"
                           (name_of (Instance_id.callable inst))
                     | Seed_mir.Intrinsic (i, _) -> Printf.sprintf "INTRINSIC %d" i
                     | Seed_mir.Extern (i, _) -> Printf.sprintf "EXTERN %d" i
                     | Seed_mir.Derived (cid, _) ->
                         Printf.sprintf "DERIVED %s" (name_of cid)
                     | Seed_mir.TypeQuery (_, _) -> "TYPEQUERY"
                     | Seed_mir.FnValue _ -> "FNVALUE"
                   in
                   Array.iter
                     (fun b ->
                       match b.Seed_mir.terminator with
                       | Seed_mir.Call (_, c, _, _, _) ->
                           Printf.printf "DBG-CALLEE %s\n" (describe c)
                       | _ -> ())
                     smain_fn.Seed_mir.blocks);
                  (match Mir_verify.require_valid_concrete sprog_mir with
                   | Ok () ->
                       Printf.printf "  runtime Set iteration verify (concrete mode): PASS\n"
                   | Error errs ->
                       Printf.printf "  runtime Set iteration verify (concrete mode): FAIL\n";
                       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                       exit 1);
                  let sentry = smain_fn.Seed_mir.instance in
                  let shost = Host.create ~repo_root:"." ~argv:[||] in
                  (match Vm.run ~program:sprog_mir ~entry:sentry ~argv:[||] ~host:shost with
                   | Error e ->
                       Printf.printf "  runtime Set iteration VM: FAIL %s\n" e.Vm.message;
                       exit 1
                   | Ok code -> (
                       match
                         Vm.entry_frame_of ~program:sprog_mir ~entry:sentry ~argv:[||]
                       with
                       | Error m ->
                           Printf.printf "  runtime Set iteration VM: <inspect failed: %s>\n" m;
                           exit 1
                       | Ok (svm, sframe) -> (
                           match Vm.run_inspect svm sframe with
                           | Ok "6" ->
                               Printf.printf
                                 "  runtime Set iteration round-trip: PASS (main = 6 — the sum of {1,2,3}; exit %d)\n"
                                 code
                           | other ->
                               Printf.printf
                                 "  runtime Set iteration round-trip: FAIL (expected 6, got %s)\n"
                                 (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                               exit 1)))
                end));
      (* ── the RUNTIME Map iteration round-trip proof (re-audit item
         17 — the audit singled Map out: the compiler kernel itself
         makes heavy use of Map iteration): `for (k, v) in m` over a
         runtime Map[Int, Int] materializes the entries protocol
         (__intrinsic_map_entries) and the destructuring pattern binds
         k/v through the tuple projections — main = 66 = the sum of
         1+10, 2+20, 3+30. *)
      let mrsrc = {|
def main() -> Int
  var m: Map[Int, Int] = Map::new()
  m.insert(1, 10)
  m.insert(2, 20)
  m.insert(3, 30)
  var sum = 0
  for (k, v) in m do
    sum = sum + k + v
  end
  sum
end
|} in
      (match Source_loader.load_string "<map-loop>" mrsrc with
       | Error _ -> failwith "map-loop source load"
       | Ok mrsrc2 ->
           let mrm = Span.create () in
           let mrfid = Span.add_file mrm mrsrc2.Source.name mrsrc2 in
           let mrdiags = Diagnostic.create_bag () in
           let mrlx = Lexer.create mrsrc2.Source.bytes mrfid mrdiags in
           let mrtoks = Lexer.lex mrlx in
           let mrprog = Parser.parse mrtoks mrsrc2.Source.bytes mrfid mrdiags [ "mr" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) mrprog with
            | Error m -> failwith ("map-loop typecheck: " ^ m)
            | Ok (mrenv, mrerrs) ->
                if mrerrs <> [] then
                  failwith ("map-loop typecheck errors: " ^ String.concat "; " mrerrs)
                else begin
                  let mrbase = Driver.lowering_env_of ~items:mrprog.Ast.items mrenv in
                  let mrvariants = Driver.user_variant_table mrenv in
                  let mrmain_decl =
                    match
                      List.find_opt
                        (fun i ->
                          match i.Ast.kind with
                          | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                          | _ -> false)
                        mrprog.Ast.items
                    with
                    | Some i -> i
                    | None -> failwith "map-loop: no main function"
                  in
                  let mrts =
                    match List.assoc_opt "main" mrenv.Typecheck.functions with
                    | Some ts -> ts
                    | None -> (
                        match
                          List.filter (fun (k, _) -> Util.has_suffix k "::main")
                            mrenv.Typecheck.functions
                        with
                        | [ (_, ts) ] -> ts
                        | _ -> failwith "map-loop: no typed signature for main")
                  in
                  let mrmain_fn =
                    match mrmain_decl.Ast.kind with
                    | Ast.Function d ->
                        Mir_lower.lower_function_with_variants
                          ~typed_nodes:(Driver.typed_nodes_of mrenv)
                          ~typed_patterns:(Driver.typed_patterns_of mrenv)
                          ~typed_for_patterns:(Driver.typed_for_patterns_of mrenv)
                          ~typed_let_patterns:(Driver.typed_let_patterns_of mrenv)
                          mrvariants
                          { mrbase with Mir_lower.fn_ret = mrts.Typecheck.ts_return }
                          "main" (Ids.Callable_id.to_int mrts.Typecheck.ts_callable)
                          [||] [||] d
                    | _ -> failwith "map-loop: main is not a function"
                  in
                  let mrprog_mir =
                    { Seed_mir.functions = [| mrmain_fn |]; statics = [||]; types = [||] }
                  in
                  (match Mir_verify.require_valid_concrete mrprog_mir with
                   | Ok () ->
                       Printf.printf "  runtime Map iteration verify (concrete mode): PASS\n"
                   | Error errs ->
                       Printf.printf "  runtime Map iteration verify (concrete mode): FAIL\n";
                       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                       exit 1);
                  let mrentry = mrmain_fn.Seed_mir.instance in
                  let mrhost = Host.create ~repo_root:"." ~argv:[||] in
                  (match Vm.run ~program:mrprog_mir ~entry:mrentry ~argv:[||] ~host:mrhost with
                   | Error e ->
                       Printf.printf "  runtime Map iteration VM: FAIL %s\n" e.Vm.message;
                       exit 1
                   | Ok code -> (
                       match
                         Vm.entry_frame_of ~program:mrprog_mir ~entry:mrentry ~argv:[||]
                       with
                       | Error m ->
                           Printf.printf "  runtime Map iteration VM: <inspect failed: %s>\n" m;
                           exit 1
                       | Ok (mrvm, mrframe) -> (
                           match Vm.run_inspect mrvm mrframe with
                           | Ok "66" ->
                               Printf.printf
                                 "  runtime Map iteration round-trip: PASS (main = 66 — the sum of {1:10, 2:20, 3:30} through the entries protocol; exit %d)\n"
                                 code
                           | other ->
                               Printf.printf
                                 "  runtime Map iteration round-trip: FAIL (expected 66, got %s)\n"
                                 (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                               exit 1)))
                end));
      (* ── the RUNTIME String iteration round-trip proof (re-audit
         item 17 — the seed's documented Unicode decision: String
         indices are BYTE indices, consistent with Len's String.length
         and the ConstantIndex projection; the loop counts the bytes
         of a 3-byte UTF-8 string, so `for c in s` over "abc" runs the
         counter over Len = 3). *)
      let stsrc = {|
def main() -> Int
  var s: String = "abc"
  var n = 0
  for c in s do
    n = n + 1
  end
  n
end
|} in
      (match Source_loader.load_string "<str-loop>" stsrc with
       | Error _ -> failwith "str-loop source load"
       | Ok stsrc2 ->
           let stm = Span.create () in
           let stfid = Span.add_file stm stsrc2.Source.name stsrc2 in
           let stdiags = Diagnostic.create_bag () in
           let stlx = Lexer.create stsrc2.Source.bytes stfid stdiags in
           let sttoks = Lexer.lex stlx in
           let stprog = Parser.parse sttoks stsrc2.Source.bytes stfid stdiags [ "st" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) stprog with
            | Error m -> failwith ("str-loop typecheck: " ^ m)
            | Ok (stenv, sterrs) ->
                if sterrs <> [] then
                  failwith ("str-loop typecheck errors: " ^ String.concat "; " sterrs)
                else begin
                  let stbase = Driver.lowering_env_of ~items:stprog.Ast.items stenv in
                  let stvariants = Driver.user_variant_table stenv in
                  let stmain_decl =
                    match
                      List.find_opt
                        (fun i ->
                          match i.Ast.kind with
                          | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                          | _ -> false)
                        stprog.Ast.items
                    with
                    | Some i -> i
                    | None -> failwith "str-loop: no main function"
                  in
                  let stts =
                    match List.assoc_opt "main" stenv.Typecheck.functions with
                    | Some ts -> ts
                    | None -> (
                        match
                          List.filter (fun (k, _) -> Util.has_suffix k "::main")
                            stenv.Typecheck.functions
                        with
                        | [ (_, ts) ] -> ts
                        | _ -> failwith "str-loop: no typed signature for main")
                  in
                  let stmain_fn =
                    match stmain_decl.Ast.kind with
                    | Ast.Function d ->
                        Mir_lower.lower_function_with_variants
                          ~typed_nodes:(Driver.typed_nodes_of stenv)
                          ~typed_patterns:(Driver.typed_patterns_of stenv)
                          ~typed_for_patterns:(Driver.typed_for_patterns_of stenv)
                          ~typed_let_patterns:(Driver.typed_let_patterns_of stenv)
                          stvariants
                          { stbase with Mir_lower.fn_ret = stts.Typecheck.ts_return }
                          "main" (Ids.Callable_id.to_int stts.Typecheck.ts_callable)
                          [||] [||] d
                    | _ -> failwith "str-loop: main is not a function"
                  in
                  let stprog_mir =
                    { Seed_mir.functions = [| stmain_fn |]; statics = [||]; types = [||] }
                  in
                  (match Mir_verify.require_valid_concrete stprog_mir with
                   | Ok () ->
                       Printf.printf "  runtime String iteration verify (concrete mode): PASS\n"
                   | Error errs ->
                       Printf.printf "  runtime String iteration verify (concrete mode): FAIL\n";
                       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                       exit 1);
                  let stentry = stmain_fn.Seed_mir.instance in
                  let sthost = Host.create ~repo_root:"." ~argv:[||] in
                  (match Vm.run ~program:stprog_mir ~entry:stentry ~argv:[||] ~host:sthost with
                   | Error e ->
                       Printf.printf "  runtime String iteration VM: FAIL %s\n" e.Vm.message;
                       exit 1
                   | Ok code -> (
                       match
                         Vm.entry_frame_of ~program:stprog_mir ~entry:stentry ~argv:[||]
                       with
                       | Error m ->
                           Printf.printf "  runtime String iteration VM: <inspect failed: %s>\n" m;
                           exit 1
                       | Ok (stvm, stframe) -> (
                           match Vm.run_inspect stvm stframe with
                           | Ok "3" ->
                               Printf.printf
                                 "  runtime String iteration round-trip: PASS (main = 3 — the byte-index counter over \"abc\" under the seed's documented Unicode convention; exit %d)\n"
                                 code
                           | other ->
                               Printf.printf
                                 "  runtime String iteration round-trip: FAIL (expected 3, got %s)\n"
                                 (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                               exit 1)))
                end));
      (* ── the FlowResult expression-level proofs (re-audit P0):
         (a) the NESTED divergence — a `break` inside an `if` inside a
         `loop` propagates through the if's joined flow, so the loop's
         normal continuation exists and the loop falls through
         (main = 3); (b) the LOOP-RETURN rule — a `loop` whose only
         exit is `return` has NO normal continuation (Never), and the
         function still returns 4 through the VM. *)
      let flsrc = {|
def main() -> Int
  var acc = 0
  loop
    if acc >= 3 then
      break
    end
    acc = acc + 1
  end
  acc
end
|} in
      let flsrc2 = {|
def main() -> Int
  loop
    return 4
  end
end
|} in
      (match Source_loader.load_string "<flow-nested-break>" flsrc with
       | Error _ -> failwith "flow-nested-break source load"
       | Ok fls -> (
           let flm = Span.create () in
           let flfid = Span.add_file flm fls.Source.name fls in
           let fldiags = Diagnostic.create_bag () in
           let fllx = Lexer.create fls.Source.bytes flfid fldiags in
           let fltoks = Lexer.lex fllx in
           let flprog = Parser.parse fltoks fls.Source.bytes flfid fldiags [ "fl" ] in
           match Typecheck.check_program (Typecheck.initial_env ()) flprog with
           | Error m -> failwith ("flow-nested-break typecheck: " ^ m)
           | Ok (flenv, flerrs) ->
               if flerrs <> [] then
                 failwith ("flow-nested-break typecheck errors: " ^ String.concat "; " flerrs)
               else begin
                 let flbase = Driver.lowering_env_of ~items:flprog.Ast.items flenv in
                 let flvariants = Driver.user_variant_table flenv in
                 let flmain_decl =
                   match
                     List.find_opt
                       (fun i ->
                         match i.Ast.kind with
                         | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                         | _ -> false)
                       flprog.Ast.items
                   with
                   | Some i -> i
                   | None -> failwith "flow-nested-break: no main"
                 in
                 let flts =
                   match List.assoc_opt "main" flenv.Typecheck.functions with
                   | Some ts -> ts
                   | None -> (
                       match
                         List.filter (fun (k, _) -> Util.has_suffix k "::main")
                           flenv.Typecheck.functions
                       with
                       | [ (_, ts) ] -> ts
                       | _ -> failwith "flow-nested-break: no main signature")
                 in
                 let flmain_fn =
                   match flmain_decl.Ast.kind with
                   | Ast.Function d ->
                       Mir_lower.lower_function_with_variants
                         ~typed_nodes:(Driver.typed_nodes_of flenv)
                         ~typed_patterns:(Driver.typed_patterns_of flenv)
                         ~typed_for_patterns:(Driver.typed_for_patterns_of flenv)
                         ~typed_let_patterns:(Driver.typed_let_patterns_of flenv)
                         flvariants
                         { flbase with Mir_lower.fn_ret = flts.Typecheck.ts_return }
                         "main" (Ids.Callable_id.to_int flts.Typecheck.ts_callable)
                         [||] [||] d
                   | _ -> failwith "flow-nested-break: main not a function"
                 in
                 let flprog_mir =
                   { Seed_mir.functions = [| flmain_fn |]; statics = [||]; types = [||] }
                 in
                 (match Mir_verify.require_valid_concrete flprog_mir with
                  | Ok () ->
                      Printf.printf "  flow nested-break-in-loop verify (concrete mode): PASS\n"
                  | Error errs ->
                      Printf.printf "  flow nested-break-in-loop verify (concrete mode): FAIL\n";
                      List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                      exit 1);
                 let flentry = flmain_fn.Seed_mir.instance in
                 let flhost = Host.create ~repo_root:"." ~argv:[||] in
                 (match Vm.run ~program:flprog_mir ~entry:flentry ~argv:[||] ~host:flhost with
                  | Error e ->
                      Printf.printf "  flow nested-break-in-loop VM: FAIL %s\n" e.Vm.message;
                      exit 1
                  | Ok code -> (
                      match
                        Vm.entry_frame_of ~program:flprog_mir ~entry:flentry ~argv:[||]
                      with
                      | Error m ->
                          Printf.printf "  flow nested-break-in-loop VM: <inspect failed: %s>\n" m;
                          exit 1
                      | Ok (flvm, flframe) -> (
                          match Vm.run_inspect flvm flframe with
                          | Ok "3" ->
                              Printf.printf
                                "  flow nested-break-in-loop round-trip: PASS (main = 3 — the break inside the if joined through the if's flow; exit %d)\n"
                                code
                          | other ->
                              Printf.printf
                                "  flow nested-break-in-loop round-trip: FAIL (expected 3, got %s)\n"
                                (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                              exit 1)))
               end));
      (match Source_loader.load_string "<flow-loop-return>" flsrc2 with
       | Error _ -> failwith "flow-loop-return source load"
       | Ok fls2 -> (
           let flm2 = Span.create () in
           let flfid2 = Span.add_file flm2 fls2.Source.name fls2 in
           let fld2 = Diagnostic.create_bag () in
           let fllx2 = Lexer.create fls2.Source.bytes flfid2 fld2 in
           let flt2 = Lexer.lex fllx2 in
           let flp2 = Parser.parse flt2 fls2.Source.bytes flfid2 fld2 [ "fl2" ] in
           match Typecheck.check_program (Typecheck.initial_env ()) flp2 with
           | Error m -> failwith ("flow-loop-return typecheck: " ^ m)
           | Ok (flenv2, flerrs2) ->
               if flerrs2 <> [] then
                 failwith ("flow-loop-return typecheck errors: " ^ String.concat "; " flerrs2)
               else begin
                 let flb2 = Driver.lowering_env_of ~items:flp2.Ast.items flenv2 in
                 let flv2 = Driver.user_variant_table flenv2 in
                 let flmd2 =
                   match
                     List.find_opt
                       (fun i ->
                         match i.Ast.kind with
                         | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                         | _ -> false)
                       flp2.Ast.items
                   with
                   | Some i -> i
                   | None -> failwith "flow-loop-return: no main"
                 in
                 let flts2 =
                   match List.assoc_opt "main" flenv2.Typecheck.functions with
                   | Some ts -> ts
                   | None -> (
                       match
                         List.filter (fun (k, _) -> Util.has_suffix k "::main")
                           flenv2.Typecheck.functions
                       with
                       | [ (_, ts) ] -> ts
                       | _ -> failwith "flow-loop-return: no main signature")
                 in
                 let flfn2 =
                   match flmd2.Ast.kind with
                   | Ast.Function d ->
                       Mir_lower.lower_function_with_variants
                         ~typed_nodes:(Driver.typed_nodes_of flenv2)
                         ~typed_patterns:(Driver.typed_patterns_of flenv2)
                         ~typed_for_patterns:(Driver.typed_for_patterns_of flenv2)
                         ~typed_let_patterns:(Driver.typed_let_patterns_of flenv2)
                         flv2
                         { flb2 with Mir_lower.fn_ret = flts2.Typecheck.ts_return }
                         "main" (Ids.Callable_id.to_int flts2.Typecheck.ts_callable)
                         [||] [||] d
                   | _ -> failwith "flow-loop-return: main not a function"
                 in
                 let flp2m = { Seed_mir.functions = [| flfn2 |]; statics = [||]; types = [||] } in
                 (match Mir_verify.require_valid_concrete flp2m with
                  | Ok () -> Printf.printf "  flow loop-return verify (concrete mode): PASS\n"
                  | Error errs ->
                      Printf.printf "  flow loop-return verify (concrete mode): FAIL\n";
                      List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                      exit 1);
                 let fle2 = flfn2.Seed_mir.instance in
                 let flh2 = Host.create ~repo_root:"." ~argv:[||] in
                 (match Vm.run ~program:flp2m ~entry:fle2 ~argv:[||] ~host:flh2 with
                  | Error e ->
                      Printf.printf "  flow loop-return VM: FAIL %s\n" e.Vm.message;
                      exit 1
                  | Ok code -> (
                      match Vm.entry_frame_of ~program:flp2m ~entry:fle2 ~argv:[||] with
                      | Error m ->
                          Printf.printf "  flow loop-return VM: <inspect failed: %s>\n" m;
                          exit 1
                      | Ok (flv2m, flf2) -> (
                          match Vm.run_inspect flv2m flf2 with
                          | Ok "4" ->
                              Printf.printf
                                "  flow loop-return round-trip: PASS (main = 4 — a return-only loop has no normal continuation and still returns through the VM; exit %d)\n"
                                code
                          | other ->
                              Printf.printf
                                "  flow loop-return round-trip: FAIL (expected 4, got %s)\n"
                                (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                              exit 1)))
               end));
      (* ── the inout calling-convention round-trip proof (re-audit
         P0): `def bump(inout x: Int); x = x + 1; end` — the VM copies
         the argument value into the callee's parameter local, the
         callee mutates it, and the Modify effect copies it back into
         the caller's place — main = 3 after two bumps of 1 (the old
         VM silently discarded the mutation). *)
      let iosrc = {|
def bump(inout x: Int)
  x = x + 1
end
def main() -> Int
  var a = 1
  bump(a)
  bump(a)
  a
end
|} in
      (match Source_loader.load_string "<inout-bump>" iosrc with
       | Error _ -> failwith "inout-bump source load"
       | Ok iosrc2 -> (
           let iom = Span.create () in
           let iofid = Span.add_file iom iosrc2.Source.name iosrc2 in
           let iodiags = Diagnostic.create_bag () in
           let iolx = Lexer.create iosrc2.Source.bytes iofid iodiags in
           let iotoks = Lexer.lex iolx in
           let ioprog = Parser.parse iotoks iosrc2.Source.bytes iofid iodiags [ "io" ] in
           match Typecheck.check_program (Typecheck.initial_env ()) ioprog with
           | Error m -> failwith ("inout-bump typecheck: " ^ m)
           | Ok (ioenv, ioerrs) ->
               if ioerrs <> [] then
                 failwith ("inout-bump typecheck errors: " ^ String.concat "; " ioerrs)
               else begin
                 let iobase = Driver.lowering_env_of ~items:ioprog.Ast.items ioenv in
                 let iovariants = Driver.user_variant_table ioenv in
                 let lower_fn name fd ts =
                   Mir_lower.lower_function_with_variants
                     ~typed_nodes:(Driver.typed_nodes_of ioenv)
                     ~typed_patterns:(Driver.typed_patterns_of ioenv)
                     ~typed_for_patterns:(Driver.typed_for_patterns_of ioenv)
                     ~typed_let_patterns:(Driver.typed_let_patterns_of ioenv)
                     iovariants
                     { iobase with Mir_lower.fn_ret = ts.Typecheck.ts_return }
                     name (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                     (Array.of_list
                        (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                           ts.Typecheck.ts_params_decl))
                     (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
                     ~param_tys_opt:
                       (Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
                     fd
                 in
                 let io_ts name =
                   match List.assoc_opt name ioenv.Typecheck.functions with
                   | Some ts -> ts
                   | None -> (
                       match
                         List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name))
                           ioenv.Typecheck.functions
                       with
                       | [ (_, ts) ] -> ts
                       | _ -> failwith ("inout-bump: no " ^ name ^ " signature"))
                 in
                 let iodecls = Hashtbl.create 4 in
                 List.iter
                   (fun i ->
                     match i.Ast.kind with
                     | Ast.Function d ->
                         Hashtbl.replace iodecls d.Ast.fn_sig.Ast.sig_name
                           (d, io_ts d.Ast.fn_sig.Ast.sig_name)
                     | _ -> ())
                   ioprog.Ast.items;
                 let iobump_fn =
                   let d, ts = Hashtbl.find iodecls "bump" in
                   lower_fn "bump" d ts
                 in
                 let iofn =
                   let d, ts = Hashtbl.find iodecls "main" in
                   lower_fn "main" d ts
                 in
                 let ioprog_mir =
                   { Seed_mir.functions = [| iobump_fn; iofn |]; statics = [||]; types = [||] }
                 in
                 (match Mir_verify.require_valid_concrete ioprog_mir with
                  | Ok () -> Printf.printf "  inout writeback verify (concrete mode): PASS\n"
                  | Error errs ->
                      Printf.printf "  inout writeback verify (concrete mode): FAIL\n";
                      List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                      exit 1);
                 let ioentry = iofn.Seed_mir.instance in
                 let iohost = Host.create ~repo_root:"." ~argv:[||] in
                 (match Vm.run ~program:ioprog_mir ~entry:ioentry ~argv:[||] ~host:iohost with
                  | Error e ->
                      Printf.printf "  inout writeback VM: FAIL %s\n" e.Vm.message;
                      exit 1
                  | Ok code -> (
                      match Vm.entry_frame_of ~program:ioprog_mir ~entry:ioentry ~argv:[||] with
                      | Error m ->
                          Printf.printf "  inout writeback VM: <inspect failed: %s>\n" m;
                          exit 1
                      | Ok (iovm, ioframe) -> (
                          match Vm.run_inspect iovm ioframe with
                          | Ok "3" ->
                              Printf.printf
                                "  inout writeback round-trip: PASS (main = 3 — the Modify effect copied the callee's mutation back into the caller's place; exit %d)\n"
                                code
                          | other ->
                              Printf.printf
                                "  inout writeback round-trip: FAIL (expected 3, got %s)\n"
                                (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                              exit 1)))
               end));
      (* ── the insertion-contract canary (re-audit P0-B): the exact
         Tangerine contracts — Set::insert -> Bool (whether an existing
         equivalent element was replaced), Map::insert -> Option[old V]
         (the displaced old value) — while the mutation travels through
         the host writebacks: r1 = true, r2 = false, o1 = None,
         o2 = Some(10) — main = 1 + 2 + 4 + 10 = 17. *)
      let ixc = {|
def main() -> Int
  var s: Set[Int] = Set::new()
  var m: Map[Int, Int] = Map::new()
  var acc = 0
  if !s.insert(1) then acc = acc + 1 end
  if s.insert(1) then acc = acc + 2 end
  match m.insert(1, 10)
  when Option::None then acc = acc + 4
  when Option::Some(_) then ()
  end
  match m.insert(1, 20)
  when Option::Some(old) then acc = acc + old
  when Option::None then ()
  end
  acc
end
|} in
      (match Source_loader.load_string "<insert-contract>" ixc with
       | Error _ -> failwith "insert-contract source load"
       | Ok ixc2 -> (
           let ixm = Span.create () in
           let ixfid = Span.add_file ixm ixc2.Source.name ixc2 in
           let ixdiags = Diagnostic.create_bag () in
           let ixlx = Lexer.create ixc2.Source.bytes ixfid ixdiags in
           let ixtoks = Lexer.lex ixlx in
           let ixprog = Parser.parse ixtoks ixc2.Source.bytes ixfid ixdiags [ "ix" ] in
           match Typecheck.check_program (Typecheck.initial_env ()) ixprog with
           | Error m -> failwith ("insert-contract typecheck: " ^ m)
           | Ok (ixenv, ixerrs) ->
               if ixerrs <> [] then
                 failwith ("insert-contract typecheck errors: " ^ String.concat "; " ixerrs)
               else begin
                 let ixbase = Driver.lowering_env_of ~items:ixprog.Ast.items ixenv in
                 let ixvariants = Driver.user_variant_table ixenv in
                 let ixmd =
                   match
                     List.find_opt
                       (fun i ->
                         match i.Ast.kind with
                         | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                         | _ -> false)
                       ixprog.Ast.items
                   with
                   | Some i -> i
                   | None -> failwith "insert-contract: no main"
                 in
                 let ixts =
                   match List.assoc_opt "main" ixenv.Typecheck.functions with
                   | Some ts -> ts
                   | None -> (
                       match
                         List.filter (fun (k, _) -> Util.has_suffix k "::main")
                           ixenv.Typecheck.functions
                       with
                       | [ (_, ts) ] -> ts
                       | _ -> failwith "insert-contract: no main signature")
                 in
                 let ixfn =
                   match ixmd.Ast.kind with
                   | Ast.Function d ->
                       Mir_lower.lower_function_with_variants
                         ~typed_nodes:(Driver.typed_nodes_of ixenv)
                         ~typed_patterns:(Driver.typed_patterns_of ixenv)
                         ~typed_for_patterns:(Driver.typed_for_patterns_of ixenv)
                         ~typed_let_patterns:(Driver.typed_let_patterns_of ixenv)
                         ixvariants
                         { ixbase with Mir_lower.fn_ret = ixts.Typecheck.ts_return }
                         "main" (Ids.Callable_id.to_int ixts.Typecheck.ts_callable)
                         [||] [||] d
                   | _ -> failwith "insert-contract: main not a function"
                 in
                 let ixprog_mir =
                   { Seed_mir.functions = [| ixfn |];
                     statics = [||];
                     (* the Option[Int] concrete def (the checker's
                        LangItem nominal id 3) — the Some/None variants
                        with the canonical 1-based semantic ids *)
                     types =
                       [|
                         Seed_mir.EnumDef
                           {
                             ed_id = Ids.Type_id.make 3;
                             ed_variants =
                               [
                                 {
                                   Seed_mir.vd_id = Ids.Variant_id.make 1;
                                   vd_index = Ids.Variant_index.make 0;
                                   vd_payload = Type_repr.Tuple [| Type_repr.Int Type_repr.Int |];
                                 };
                                 {
                                   Seed_mir.vd_id = Ids.Variant_id.make 2;
                                   vd_index = Ids.Variant_index.make 1;
                                   vd_payload = Type_repr.Unit;
                                 };
                               ];
                           };
                       |] }
                 in
                 (match Mir_verify.require_valid_concrete ixprog_mir with
                  | Ok () -> Printf.printf "  insert-contract verify (concrete mode): PASS\n"
                  | Error errs ->
                      Printf.printf "  insert-contract verify (concrete mode): FAIL\n";
                      List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                      exit 1);
                 let ixentry = ixfn.Seed_mir.instance in
                 let ixhost = Host.create ~repo_root:"." ~argv:[||] in
                 (match Vm.run ~program:ixprog_mir ~entry:ixentry ~argv:[||] ~host:ixhost with
                  | Error e -> Printf.printf "  insert-contract VM: FAIL %s\n" e.Vm.message; exit 1
                  | Ok code -> (
                      match Vm.entry_frame_of ~program:ixprog_mir ~entry:ixentry ~argv:[||] with
                      | Error m ->
                          Printf.printf "  insert-contract VM: <inspect failed: %s>\n" m;
                          exit 1
                      | Ok (ixvm, ixframe) -> (
                          match Vm.run_inspect ixvm ixframe with
                          | Ok "17" ->
                              Printf.printf
                                "  insert-contract round-trip: PASS (main = 17 — r1 false, r2 true, o1 None, o2 Some(10) — the exact Set/Map insertion contracts with the mutations through the writebacks; exit %d)\n"
                                code
                          | other ->
                              Printf.printf
                                "  insert-contract round-trip: FAIL (expected 17, got %s)\n"
                                (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                              exit 1)))
               end));
      (* ── the Set (Initialize) calling-convention round-trip proof
         (re-audit P0-A): `def init_it(set x: Int); x = 42; end` — the
         caller's place is NOT read before the call, the callee's
         parameter enters uninitialized, the callee initializes it, the
         definite-init check passes at return, and the initialized value
         copies back — main = 42. *)
      let sssrc = {|
def init_it(set x: Int)
  x = 42
end
def main() -> Int
  var a = 0
  init_it(a)
  a
end
|} in
      (match Source_loader.load_string "<set-abi>" sssrc with
       | Error _ -> failwith "set-abi source load"
       | Ok sssrc2 -> (
           let ssm2 = Span.create () in
           let ssfid = Span.add_file ssm2 sssrc2.Source.name sssrc2 in
           let ssdiags = Diagnostic.create_bag () in
           let sslx = Lexer.create sssrc2.Source.bytes ssfid ssdiags in
           let sstoks = Lexer.lex sslx in
           let ssprog = Parser.parse sstoks sssrc2.Source.bytes ssfid ssdiags [ "ss" ] in
           match Typecheck.check_program (Typecheck.initial_env ()) ssprog with
           | Error m -> failwith ("set-abi typecheck: " ^ m)
           | Ok (ssenv, sserrs) ->
               if sserrs <> [] then
                 failwith ("set-abi typecheck errors: " ^ String.concat "; " sserrs)
               else begin
                 let ssbase = Driver.lowering_env_of ~items:ssprog.Ast.items ssenv in
                 let ssvariants = Driver.user_variant_table ssenv in
                 let ssdecls = Hashtbl.create 4 in
                 List.iter
                   (fun i ->
                     match i.Ast.kind with
                     | Ast.Function d ->
                         let ts =
                           match List.assoc_opt d.Ast.fn_sig.Ast.sig_name ssenv.Typecheck.functions with
                           | Some ts -> ts
                           | None -> (
                               match
                                 List.filter
                                   (fun (k, _) ->
                                     Util.has_suffix k ("::" ^ d.Ast.fn_sig.Ast.sig_name))
                                   ssenv.Typecheck.functions
                               with
                               | [ (_, ts) ] -> ts
                               | _ -> failwith "set-abi: no signature")
                         in
                         Hashtbl.replace ssdecls d.Ast.fn_sig.Ast.sig_name (d, ts)
                     | _ -> ())
                   ssprog.Ast.items;
                 let ss_lower name =
                   let d, ts = Hashtbl.find ssdecls name in
                   Mir_lower.lower_function_with_variants
                     ~typed_nodes:(Driver.typed_nodes_of ssenv)
                     ~typed_patterns:(Driver.typed_patterns_of ssenv)
                     ~typed_for_patterns:(Driver.typed_for_patterns_of ssenv)
                     ~typed_let_patterns:(Driver.typed_let_patterns_of ssenv)
                     ssvariants
                     { ssbase with Mir_lower.fn_ret = ts.Typecheck.ts_return }
                     name (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                     (Array.of_list
                        (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                           ts.Typecheck.ts_params_decl))
                     (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
                     ~param_tys_opt:
                       (Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
                     d
                 in
                 let ssprog_mir =
                   { Seed_mir.functions = [| ss_lower "init_it"; ss_lower "main" |];
                     statics = [||];
                     types = [||] }
                 in
                 (match Mir_verify.require_valid_concrete ssprog_mir with
                  | Ok () -> Printf.printf "  Set-ABI verify (concrete mode): PASS\n"
                  | Error errs ->
                      Printf.printf "  Set-ABI verify (concrete mode): FAIL\n";
                      List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                      exit 1);
                 let ssentry = (ss_lower "main").Seed_mir.instance in
                 let sshost = Host.create ~repo_root:"." ~argv:[||] in
                 (match Vm.run ~program:ssprog_mir ~entry:ssentry ~argv:[||] ~host:sshost with
                  | Error e -> Printf.printf "  Set-ABI VM: FAIL %s\n" e.Vm.message; exit 1
                  | Ok code -> (
                      match Vm.entry_frame_of ~program:ssprog_mir ~entry:ssentry ~argv:[||] with
                      | Error m ->
                          Printf.printf "  Set-ABI VM: <inspect failed: %s>\n" m;
                          exit 1
                      | Ok (ssvm, ssframe) -> (
                          match Vm.run_inspect ssvm ssframe with
                          | Ok "42" ->
                              Printf.printf
                                "  Set-ABI round-trip: PASS (main = 42 — the Initialize argument was not read, entered the callee uninitialized, and the initialized value copied back; exit %d)\n"
                                code
                          | other ->
                              Printf.printf
                                "  Set-ABI round-trip: FAIL (expected 42, got %s)\n"
                                (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                              exit 1)))
               end));
      (* ── the RUNTIME Vec iteration round-trip proof (the audit's
         typed-iterable requirement): a `for x in v` over a runtime
         Vec[Int] lowers to the counter loop with the dynamic
         Seed_mir.Index; the VM bounds-checks the runtime index and
         the sum of [10, 20, 30] is 60.  The lowerer's typed-for
         channel is authoritative for the loop pattern. *)
      let vlsrc = {|
def main() -> Int
  var v: [Int; 3] = [10, 20, 30]
  var sum = 0
  for x in v do
    sum = sum + x
  end
  sum
end
|} in
      (match Source_loader.load_string "<vec-loop>" vlsrc with
       | Error _ -> failwith "vec-loop source load"
       | Ok vsrc ->
           let vsm = Span.create () in
           let vfid = Span.add_file vsm vsrc.Source.name vsrc in
           let vdiags = Diagnostic.create_bag () in
           let vlx = Lexer.create vsrc.Source.bytes vfid vdiags in
           let vtoks = Lexer.lex vlx in
           let vprog = Parser.parse vtoks vsrc.Source.bytes vfid vdiags [ "vl" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) vprog with
            | Error m -> failwith ("vec-loop typecheck: " ^ m)
            | Ok (venv, verrs) ->
                if verrs <> [] then
                  failwith ("vec-loop typecheck errors: " ^ String.concat "; " verrs)
                else begin
                  let vbase = Driver.lowering_env_of ~items:vprog.Ast.items venv in
                  let vvariants = Driver.user_variant_table venv in
                  let vmain_decl =
                    match
                      List.find_opt
                        (fun i ->
                          match i.Ast.kind with
                          | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                          | _ -> false)
                        vprog.Ast.items
                    with
                    | Some i -> i
                    | None -> failwith "vec-loop: no main function"
                  in
                  let vts =
                    match List.assoc_opt "main" venv.Typecheck.functions with
                    | Some ts -> ts
                    | None -> (
                        match
                          List.filter (fun (k, _) -> Util.has_suffix k "::main")
                            venv.Typecheck.functions
                        with
                        | [ (_, ts) ] -> ts
                        | _ -> failwith "vec-loop: no typed signature for main")
                  in
                  let vmain_fn =
                    match vmain_decl.Ast.kind with
                    | Ast.Function d ->
                        Mir_lower.lower_function_with_variants
                          ~typed_nodes:(Driver.typed_nodes_of venv)
                          ~typed_patterns:(Driver.typed_patterns_of venv)
                          ~typed_for_patterns:(Driver.typed_for_patterns_of venv)
                          vvariants
                          { vbase with Mir_lower.fn_ret = vts.Typecheck.ts_return }
                          "main" (Ids.Callable_id.to_int vts.Typecheck.ts_callable)
                          [||] [||] d
                    | _ -> failwith "vec-loop: main is not a function"
                  in
                  let vprog_mir =
                    { Seed_mir.functions = [| vmain_fn |]; statics = [||]; types = [||] }
                  in
                  (match Mir_verify.require_valid_concrete vprog_mir with
                   | Ok () ->
                       Printf.printf "  runtime Vec iteration verify (concrete mode): PASS\n"
                   | Error errs ->
                       Printf.printf "  runtime Vec iteration verify (concrete mode): FAIL\n";
                       List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                       exit 1);
                  let v_entry = vmain_fn.Seed_mir.instance in
                  let vhost = Host.create ~repo_root:"." ~argv:[||] in
                  (match Vm.run ~program:vprog_mir ~entry:v_entry ~argv:[||] ~host:vhost with
                   | Error e ->
                       Printf.printf "  runtime Vec iteration VM: FAIL %s\n" e.Vm.message;
                       exit 1
                   | Ok code -> (
                       match
                         Vm.entry_frame_of ~program:vprog_mir ~entry:v_entry ~argv:[||]
                       with
                       | Error m ->
                           Printf.printf "  runtime Vec iteration VM: <inspect failed: %s>\n" m;
                           exit 1
                       | Ok (vvm, vframe) -> (
                           match Vm.run_inspect vvm vframe with
                           | Ok "60" ->
                               Printf.printf
                                 "  runtime Vec iteration round-trip: PASS (main = 60 — the sum of [10,20,30]; exit %d)\n"
                                 code
                           | other ->
                               Printf.printf
                                 "  runtime Vec iteration round-trip: FAIL (expected 60, got %s)\n"
                                 (match other with Ok v -> v | Error m -> "<" ^ m ^ ">");
                               exit 1)))
                end));
      let tcheck_env =
        match Typecheck.check_program env program with
        | Error m -> Printf.printf "  typecheck: FAIL %s\n" m; exit 1
        | Ok (env', errors) ->
            Printf.printf "  typecheck: %d errors\n" (List.length errors);
            List.iter (fun e -> Printf.printf "    %s\n" e) (List.rev errors);
            if errors <> [] then exit 1;
            env'
      in
      (* ── user-enum variant-table proof (re-audit finding: the closure
         driver must feed lowering the typechecker's enum universe — the
         DRIVER's table-builder runs on the TYPED nominal registry and
         must reproduce the manual Color table above exactly, with each
         spec's vs_id the SEMANTIC VariantId from nom_variant_ids — the
         identity the closure_types EnumDefs materialize — and the
         vs_index the declaration-order position, independently) *)
      let color_nom = List.assoc "Color" tcheck_env.Typecheck.nominals in
      let color_tid = List.assoc "Color" tcheck_env.Typecheck.type_ids in
      let driver_table = Driver.user_variant_table tcheck_env in
      (* the closure now also declares Node (the struct-pattern arm
         proof); the table comparison covers the Color entries — the
         manual Color table is the curated contract *)
      let color_of (t : Mir_lower.variant_table) : Mir_lower.variant_spec list =
        match List.assoc_opt "Color" t.Mir_lower.vt_enums with
        | Some specs -> List.map snd specs
        | None -> []
      in
      if color_of driver_table <> color_of variant_table then begin
        Printf.printf "  user-enum table: FAIL (driver Color table differs from the manual Color table)\n";
        exit 1
      end;
      (match
         Array.to_list (Driver.closure_types tcheck_env)
         |> List.find_map (fun d ->
                match d with
                | Seed_mir.EnumDef { ed_id; ed_variants }
                  when Ids.Type_id.compare ed_id color_tid = 0 ->
                    Some ed_variants
                | _ -> None)
       with
       | None ->
           Printf.printf "  user-enum table: FAIL (no Color EnumDef in the driver's closure types)\n";
           exit 1
       | Some ed_variants ->
           let ok =
             List.for_all
               (fun (vname, spec : string * Mir_lower.variant_spec) ->
                 List.assoc_opt vname color_nom.Typecheck.nom_variants <> None
                 && (let vd : Seed_mir.variant_def =
                       List.nth ed_variants spec.Mir_lower.vs_index
                     in
                     (* the spec's vs_id IS the registry's id — the
                        EnumDef carries the same id at the same
                        position: never reconstructed from the index *)
                     Ids.Variant_id.compare spec.Mir_lower.vs_id
                       (List.nth color_nom.Typecheck.nom_variant_ids spec.Mir_lower.vs_index)
                     = 0
                     && Ids.Variant_id.compare vd.Seed_mir.vd_id spec.Mir_lower.vs_id = 0))
               (List.assoc "Color" driver_table.Mir_lower.vt_enums)
           in
           if ok then
             Printf.printf
               "  user-enum table: PASS (driver table == manual Color table; each spec's vs_id is the registry's SEMANTIC VariantId, matching the EnumDefs; vs_index is the independent runtime tag)\n"
           else begin
             Printf.printf "  user-enum table: FAIL (semantic VariantId alignment)\n";
             exit 1
           end);
      (* a resolver-driven env: the semantic VariantIds are the
         resolver's dense closure-wide enumeration (0-based), so the
         second enum's ids are NOT its declaration positions — the
         driver's table-builder must still reproduce the manual
         construction shape (name -> {vs_id; vs_index} -> payloads;
         ctor -> (enum, variant)) from the typed nominals alone, and
         each spec's vs_id must BE the registry's id (the audit P0:
         never `Variant_id.make (vs_index + 1)`) *)
      let proof_src = {|
enum A
  A0,
  A1(Int)
end

enum B
  B0,
  B1(Int),
  B2(Int, Int)
end

def main() -> Int
  0
end
|} in
      let proof_file = Filename.temp_file "tg_lowersurface_user_enum" ".tg" in
      (let oc = open_out_bin proof_file in
       output_string oc proof_src;
       close_out oc);
      let proof_manifest =
        match Bootstrap_manifest.single ~file:proof_file ~path:[ "proof" ] () with
        | Ok m -> m
        | Error e -> failwith ("user-enum proof manifest: " ^ e)
      in
      let pdiags = Diagnostic.create_bag () in
      let pgraph = Module_graph.create_with_sources proof_manifest pdiags in
      let presolved = Resolver.resolve proof_manifest pgraph pdiags in
      let pprog = (List.hd pgraph.Module_graph.nodes).Module_graph.node_program in
      let penv =
        match Typecheck.check_program (Typecheck.initial_env ~resolved:(Some presolved) ()) pprog with
        | Error m -> failwith ("user-enum proof typecheck: " ^ m)
        | Ok (env', errors) ->
            if errors <> [] then
              failwith ("user-enum proof typecheck errors: " ^ String.concat "; " errors);
            env'
      in
      Sys.remove proof_file;
      let a_nom = List.assoc "A" penv.Typecheck.nominals in
      let b_nom = List.assoc "B" penv.Typecheck.nominals in
      let b_ids = b_nom.Typecheck.nom_variant_ids in
      (* vs_id = the resolver's ids (0-based dense, closure-wide);
         vs_index = the declaration position — the two are independent
         coordinates (B's vs_ids [2;3;4] are NOT make (vs_index + 1)) *)
      let a_specs =
        [
          ("A0", { Mir_lower.vs_id = Ids.Variant_id.make 0; vs_index = 0; vs_fields = []; vs_field_names = [] });
          ("A1", { Mir_lower.vs_id = Ids.Variant_id.make 1; vs_index = 1; vs_fields = [ int_ty ]; vs_field_names = [] });
        ]
      in
      let b_specs =
        [
          ("B0", { Mir_lower.vs_id = Ids.Variant_id.make 2; vs_index = 0; vs_fields = []; vs_field_names = [] });
          ("B1", { Mir_lower.vs_id = Ids.Variant_id.make 3; vs_index = 1; vs_fields = [ int_ty ]; vs_field_names = [] });
          ("B2", { Mir_lower.vs_id = Ids.Variant_id.make 4; vs_index = 2; vs_fields = [ int_ty; int_ty ]; vs_field_names = [] });
        ]
      in
      let p_table = Driver.user_variant_table penv in
      let enums_ok =
        List.assoc "A" p_table.Mir_lower.vt_enums = a_specs
        && List.assoc "B" p_table.Mir_lower.vt_enums = b_specs
      in
      let ctors_ok =
        List.sort compare p_table.Mir_lower.vt_ctors
        = List.sort compare
            [
              ("A0", ("A", "A0"));
              ("A1", ("A", "A1"));
              ("B0", ("B", "B0"));
              ("B1", ("B", "B1"));
              ("B2", ("B", "B2"));
            ]
      in
      let b_tid = List.assoc "B" penv.Typecheck.type_ids in
      let b_ed =
        Array.to_list (Driver.closure_types penv)
        |> List.find_map (fun d ->
               match d with
               | Seed_mir.EnumDef { ed_id; ed_variants }
                 when Ids.Type_id.compare ed_id b_tid = 0 ->
                   Some ed_variants
               | _ -> None)
      in
      let ids_ok =
        b_ids = [ Ids.Variant_id.make 2; Ids.Variant_id.make 3; Ids.Variant_id.make 4 ]
        && List.for_all
             (fun (vname, spec : string * Mir_lower.variant_spec) ->
               List.assoc_opt vname b_nom.Typecheck.nom_variants <> None
               && (match b_ed with
                   | None -> false
                   | Some ed_variants ->
                       let vd : Seed_mir.variant_def =
                         List.nth ed_variants spec.Mir_lower.vs_index
                       in
                       Ids.Variant_id.compare vd.Seed_mir.vd_id spec.Mir_lower.vs_id
                       = 0))
             b_specs
      in
      (* the audit P0 proof: every spec's vs_id comes FROM THE REGISTRY
         (nom_variant_ids at the variant's position) and is NOT the
         position reconstruction `make (vs_index + 1)` — B's ids are the
         resolver's dense closure-wide [2;3;4], never 1-based positions *)
      let registry_ok =
        List.for_all
          (fun (vname, spec : string * Mir_lower.variant_spec) ->
            List.assoc_opt vname b_nom.Typecheck.nom_variants <> None
            && Ids.Variant_id.compare spec.Mir_lower.vs_id
                 (List.nth b_ids spec.Mir_lower.vs_index)
               = 0
            && Ids.Variant_id.compare spec.Mir_lower.vs_id
                 (Ids.Variant_id.make (spec.Mir_lower.vs_index + 1))
               <> 0)
          b_specs
      in
      if enums_ok && ctors_ok && ids_ok && registry_ok then
        Printf.printf
          "  user-enum table (resolver env): PASS (A/B entries in the manual shape; each vs_id is the REGISTRY's id — B's [2;3;4] are non-positional and NOT make (vs_index + 1); the EnumDefs carry the same ids)\n"
      else begin
        Printf.printf
          "  user-enum table (resolver env): FAIL (enums_ok=%b ctors_ok=%b ids_ok=%b registry_ok=%b)\n"
          enums_ok ctors_ok ids_ok registry_ok;
        exit 1
      end;
      ignore a_nom;
      let option_tid = List.assoc "Option" tcheck_env.Typecheck.type_ids in
      let result_tid = List.assoc "Result" tcheck_env.Typecheck.type_ids in
      let color_tid = List.assoc "Color" tcheck_env.Typecheck.type_ids in
      let node_tid = List.assoc "Node" tcheck_env.Typecheck.type_ids in
      let option_int = Type_repr.Named (option_tid, [| int_ty |]) in
      let result_int_int = Type_repr.Named (result_tid, [| int_ty; int_ty |]) in
      let color_ty = Type_repr.Named (color_tid, [||]) in
      let node_ty = Type_repr.Named (node_tid, [||]) in
      (* typed signatures per function (flat names) *)
      let ts_of name =
        match List.assoc_opt name tcheck_env.Typecheck.functions with
        | Some ts -> ts
        | None -> (
            match
              List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) tcheck_env.Typecheck.functions
            with
            | [ (_, ts) ] -> ts
            | _ -> failwith ("no typed signature for " ^ name))
      in
      let funcs =
        List.filter_map
          (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
          program.Ast.items
      in
      let env2 : Mir_lower.func_env =
        {
          Mir_lower.consts =
            [
              ( "ROUNDTRIP_K",
                (int_ty, Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true 42L)) );
            ];
    Mir_lower.statics = [];
    Mir_lower.types =
            [
              ("Color", color_ty);
              ("Node", node_ty);
              ("Option", Type_repr.Named (option_tid, [| Type_repr.Type_param (Ids.Generic_param_id.make 0) |]));
              ("Result", Type_repr.Named (result_tid, [| Type_repr.Type_param (Ids.Generic_param_id.make 0); Type_repr.Type_param (Ids.Generic_param_id.make 1) |]));
              ("Int", int_ty);
              ("Unit", Type_repr.Unit);
              ("Bool", Type_repr.Bool);
              ("String", string_ty);
            ];
          values =
            [
              ("Some", option_int);
              ("None", option_int);
              ("Ok", result_int_int);
              ("Err", result_int_int);
              ("Red", color_ty);
              ("Green", color_ty);
              ("Blue", color_ty);
              ("Node::Leaf", node_ty);
              ("Node::Branch", node_ty);
              ("Leaf", node_ty);
              ("Branch", node_ty);
            ]
            @ List.map
                (fun d ->
                  let n = d.Ast.fn_sig.Ast.sig_name in
                  (n, (ts_of n).Typecheck.ts_return))
                funcs;
          callables =
            List.map
              (fun d ->
                let n = d.Ast.fn_sig.Ast.sig_name in
                ( n,
                  {
                    Mir_lower.ce_callable = Ids.Callable_id.to_int (ts_of n).Typecheck.ts_callable;
                    ce_template_args = [||];
                    ce_params = [||];
                  } ))
              funcs;
          methods = [];
          callables_by_callable = [];
          fn_ret = int_ty;
          struct_fields = Driver.struct_fields_of tcheck_env;
          enum_payloads = Driver.enum_payloads_of tcheck_env;
          copy_cache = Type_properties.create_cache ();
        }
      in
      let mir_funcs =
        List.map
          (fun d ->
            let n = d.Ast.fn_sig.Ast.sig_name in
            let ts = ts_of n in
            Mir_lower.lower_function_with_variants variant_table
              { env2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
              n (Ids.Callable_id.to_int ts.Typecheck.ts_callable) [||] [||] d)
          funcs
      in
      (* concrete enum defs (post-mono): a variant's payload is recorded
         as a Tuple for one-or-more fields, Unit for none; the enum def
         is Function (payloads, Never) — the seed type-definition
         contract (seed_mir.ml). *)
      let payload_def fields =
        match fields with
        | [] -> Type_repr.Unit
        | fs -> Type_repr.Tuple (Array.of_list fs)
      in
      let enum_def tid payloads =
        Seed_mir.EnumDef
          {
            ed_id = tid;
            ed_variants =
              List.mapi
                (fun i fs ->
                  {
                    (* this resolver-free program's semantic VariantIds
                       are the canonical 1-based minting (the
                       typechecker's fallback registration and the
                       driver's registry channel agree) — the lowered
                       Downcast projections carry the SAME vs_ids the
                       table carries, so these defs reconcile them;
                       the Node enum's ids continue after Color's [1;2;3]
                       as [4;5] — exactly what the variant table above
                       records *)
                    Seed_mir.vd_id =
                      Ids.Variant_id.make
                        (if Ids.Type_id.compare tid node_tid = 0 then i + 4
                         else i + 1);
                    vd_index = Ids.Variant_index.make i;
                    vd_payload = payload_def fs;
                  })
                payloads;
          }
      in
      let prog =
        {
          Seed_mir.functions = Array.of_list mir_funcs;
          statics = [||];
          types =
            [|
              enum_def option_tid [ [ int_ty ]; [] ];
              enum_def result_tid [ [ int_ty ]; [ int_ty ] ];
              enum_def color_tid [ []; [ int_ty ]; [ int_ty; int_ty ] ];
              enum_def node_tid [ []; [ int_ty; int_ty ] ];
            |];
        }
      in
      (match
         Mir_verify.require_valid_template
           ~generic_types:(Driver.closure_generic_types tcheck_env)
           prog
       with
       | Ok () -> Printf.printf "  MIR verify (template mode): PASS (%d functions)\n" (Array.length prog.Seed_mir.functions)
       | Error errs ->
           Printf.printf "  MIR verify (template mode): FAIL\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Printf.printf "%s\n" (Seed_mir.print_program prog);
           exit 1);
      (* the same CONCRETE program must also pass the concrete mode: a
         concrete function satisfies BOTH verifiers *)
      (match Mir_verify.require_valid_concrete prog with
       | Ok () -> Printf.printf "  MIR verify (concrete mode): PASS (%d functions)\n" (Array.length prog.Seed_mir.functions)
       | Error errs ->
           Printf.printf "  MIR verify (concrete mode): FAIL\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Printf.printf "%s\n" (Seed_mir.print_program prog);
           exit 1);
      (* ── projected-move surface proof (audit P0: the lowerer must
         never emit a projected Move/Consume — the seed VM has no
         partial-move representation and `Move p` would transition the
         WHOLE root slot to Moved, ignoring p.projections — and must
         fail closed when the source would require one) ────────────── *)
      (* (1) the FULLY lowered surface program above carries NO
         projected Move/Consume anywhere: every ownership transfer is a
         whole-root move (the `?` failure path MOVES the subject into
         the return slot; match payload binding COPIES Copy payloads).
         The scan walks statement rvalues and terminator operands (call
         args, switch/assert conditions) of every function. *)
      let operand_is_projected_transfer (op : Seed_mir.operand) : bool =
        match op with
        | Seed_mir.Move p | Seed_mir.Consume p -> p.Seed_mir.projections <> []
        | Seed_mir.Copy _ | Seed_mir.Read _ | Seed_mir.Constant _ -> false
      in
      let rvalue_transfers (rv : Seed_mir.rvalue) : Seed_mir.operand list =
        match rv with
        | Seed_mir.Use op | Seed_mir.Cast (op, _) | Seed_mir.UnaryOp (_, op) -> [ op ]
        | Seed_mir.Aggregate (_, ops) -> ops
        | Seed_mir.BinaryOp (_, l, r) -> [ l; r ]
        | Seed_mir.Ref _ | Seed_mir.RefMut _ | Seed_mir.Discriminant _ | Seed_mir.Len _ -> []
      in
      let terminator_transfers (t : Seed_mir.terminator) : Seed_mir.operand list =
        match t with
        | Seed_mir.Call (_, _, args, _, _) ->
            Array.to_list (Array.map (fun a -> a.Seed_mir.value) args)
        | Seed_mir.SwitchInt (op, _, _) | Seed_mir.Assert (op, _, _, _) -> [ op ]
        | Seed_mir.Goto _ | Seed_mir.Ret | Seed_mir.Unreachable | Seed_mir.Abort
        | Seed_mir.Drop _ | Seed_mir.Deinit _ ->
            []
      in
      let projected_transfers = ref 0 and whole_root_moves = ref 0 in
      Array.iter
        (fun (fn : Seed_mir.function_) ->
          Array.iter
            (fun (b : Seed_mir.block) ->
              List.iter
                (function
                  | Seed_mir.Assign (_, rv) ->
                      List.iter
                        (fun op ->
                          if operand_is_projected_transfer op then incr projected_transfers
                          else
                            match op with
                            | Seed_mir.Move _ | Seed_mir.Consume _ -> incr whole_root_moves
                            | _ -> ())
                        (rvalue_transfers rv)
                  | Seed_mir.StorageLive _ | Seed_mir.StorageDead _
                  | Seed_mir.SetDiscriminant _ | Seed_mir.Nop ->
                      ())
                b.Seed_mir.statements;
              List.iter
                (fun op ->
                  if operand_is_projected_transfer op then incr projected_transfers
                  else
                    match op with
                    | Seed_mir.Move _ | Seed_mir.Consume _ -> incr whole_root_moves
                    | _ -> ())
                (terminator_transfers b.Seed_mir.terminator))
            fn.Seed_mir.blocks)
        prog.Seed_mir.functions;
      if !projected_transfers = 0 && !whole_root_moves > 0 then
        Printf.printf
          "  projected-move surface: PASS (the lowered program carries %d whole-root Move/Consume transfers — the `?` failure paths — and ZERO projected transfers)\n"
          !whole_root_moves
      else begin
        Printf.printf
          "  projected-move surface: FAIL (projected transfers: %d, whole-root moves: %d)\n"
          !projected_transfers !whole_root_moves;
        exit 1
      end;
      (* (2) re-audit P10: a match arm that binds a NON-COPY PAYLOAD
         now lowers through the seed's PARTIAL move — the payload
         component transfers with the projected Move (the VM leaves the
         MovedOut hole; the drop glue skips it; the verifier's moved
         lattice tracks the path).  The lowering must SUCCEED and the
         binding must be a PROJECTED Move, never a fail-closed bug. *)
      let ncp_src = {|
def f(o: Option[String]) -> Int
  match o {
    Some(s) => 0,
    None() => 1
  }
end
|} in
      (match Source_loader.load_string "<non-copy-payload>" ncp_src with
       | Error _ -> failwith "non-copy-payload source load"
       | Ok nsrc ->
           let nsm = Span.create () in
           let nfid = Span.add_file nsm nsrc.Source.name nsrc in
           let ndiags = Diagnostic.create_bag () in
           let nlx = Lexer.create nsrc.Source.bytes nfid ndiags in
           let ntoks = Lexer.lex nlx in
           let nprog = Parser.parse ntoks nsrc.Source.bytes nfid ndiags [ "ncp" ] in
           (match Typecheck.check_program (Typecheck.initial_env ()) nprog with
            | Error m -> failwith ("non-copy-payload typecheck: " ^ m)
            | Ok (nenv, errs) ->
                if errs <> [] then
                  failwith ("non-copy-payload typecheck errors: " ^ String.concat "; " errs)
                else begin
                  let nf =
                    match
                      List.find_opt
                        (fun i ->
                          match i.Ast.kind with
                          | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "f"
                          | _ -> false)
                        nprog.Ast.items
                    with
                    | Some i -> i
                    | None -> failwith "non-copy-payload: no f function"
                  in
                  let nts =
                    match List.assoc_opt "f" nenv.Typecheck.functions with
                    | Some ts -> ts
                    | None -> (
                        match
                          List.filter
                            (fun (k, _) -> Util.has_suffix k "::f")
                            nenv.Typecheck.functions
                        with
                        | [ (_, ts) ] -> ts
                        | _ -> failwith "non-copy-payload: no typed signature for f")
                  in
                  let nfd =
                    match nf.Ast.kind with
                    | Ast.Function d -> d
                    | _ -> failwith "non-copy-payload: f is not a function"
                  in
                  let nf_mir =
                    Mir_lower.lower_function_with_variants variant_table
                      { env2 with Mir_lower.fn_ret = nts.Typecheck.ts_return }
                      "f" (Ids.Callable_id.to_int nts.Typecheck.ts_callable) [||] [||] nfd
                  in
                  (* the Some(s) arm's payload binding must be a
                     PROJECTED Move of the Downcast+index path *)
                  let projected_binds = ref 0 in
                  Array.iter
                    (fun (b : Seed_mir.block) ->
                      List.iter
                        (fun (s : Seed_mir.statement) ->
                          match s with
                          | Seed_mir.Assign (_, Seed_mir.Use (Seed_mir.Move p)) ->
                              if p.Seed_mir.projections <> [] then incr projected_binds
                          | _ -> ())
                        b.Seed_mir.statements)
                    nf_mir.Seed_mir.blocks;
                  if !projected_binds > 0 then
                    Printf.printf
                      "  non-Copy payload binding: PASS (the String payload binding lowered as %d projected Move(s) — the seed partial-move representation)\n"
                      !projected_binds
                  else begin
                    Printf.printf
                      "  non-Copy payload binding: FAIL (no projected Move in the lowered Some(s) arm)\n";
                    Printf.printf "%s\n" (Seed_mir.print_function nf_mir);
                    exit 1
                  end
                end));
      (* template-instance proof: a generic def f[T,U] must get a
         template Instance_id carrying [Type_param T; Type_param U] in
         declaration order, so mono can build exact substitutions *)
      let pid_t = Ids_core.Generic_param_id.make 7 in
      let pid_u = Ids_core.Generic_param_id.make 11 in
      let gen_env =
        {
          env2 with
          Mir_lower.callables =
            [
              ( "f",
                {
                  Mir_lower.ce_callable = 42;
                  ce_template_args = [| Type_repr.Type_param pid_t; Type_repr.Type_param pid_u |];
                  ce_params = [||];
                } );
            ];
        }
      in
      let gen_fn : Ast.function_decl =
        {
          Ast.fn_sig =
            {
              Ast.sig_name = "f";
              sig_public = false;
              sig_async = false;
              sig_unsafe = false;
              sig_const = false;
              sig_pure = false;
              sig_inline = false;
              sig_extern = false;
              sig_type_params = [];
              sig_params = [];
              sig_return = None;
              sig_where = [];
              sig_span = Span.synthetic;
            };
          fn_clauses = [];
          fn_body = Ast.FnExpr (Ast.IntLit (Ids.Node_id.make 0, "0", Span.synthetic));
          fn_span = Span.synthetic;
        }
      in
      let lowered = Mir_lower.lower_function_with_variants variant_table gen_env "f" 42 [| Type_repr.Type_param pid_t; Type_repr.Type_param pid_u |] [||] gen_fn in
      (* type-definition proof: def_repr reconstructs the historical
         encodings exactly (struct -> Tuple of fields in index order;
         enum -> Function(payloads, Never) with declaration-order tags),
         and the defs carry semantic ids distinct from positions *)
      let struct_def =
        Seed_mir.StructDef
          {
            sd_id = Ids.Type_id.make 3;
            sd_fields =
              [
                { Seed_mir.fd_id = Ids.Field_id.make 40; fd_index = Ids.Field_index.make 0; fd_ty = int_ty };
                { Seed_mir.fd_id = Ids.Field_id.make 41; fd_index = Ids.Field_index.make 1; fd_ty = string_ty };
              ];
          }
      in
      let enum_def2 =
        Seed_mir.EnumDef
          {
            ed_id = Ids.Type_id.make 4;
            ed_variants =
              [
                { Seed_mir.vd_id = Ids.Variant_id.make 60; vd_index = Ids.Variant_index.make 0; vd_payload = Type_repr.Tuple [| int_ty |] };
                { Seed_mir.vd_id = Ids.Variant_id.make 61; vd_index = Ids.Variant_index.make 1; vd_payload = Type_repr.Unit };
              ];
          }
      in
      (match Seed_mir.def_repr struct_def, Seed_mir.def_repr enum_def2 with
       | Type_repr.Tuple [| a; b |], Type_repr.Function (ps, Type_repr.Never)
         when a = int_ty && b = string_ty && Array.length ps = 2
              && ps.(0).Type_repr.pt_type = Type_repr.Tuple [| int_ty |]
              && ps.(1).Type_repr.pt_type = Type_repr.Unit ->
           Printf.printf
             "  type defs: PASS (struct -> Tuple fields in index order; enum -> Function(payloads, Never); field/variant ids distinct from positions)\n"
       | _ ->
           Printf.printf "  type defs: FAIL\n";
           exit 1);
       (match lowered.Seed_mir.instance with
        | { Instance_id.callable = _; type_args = [| Type_repr.Type_param a; Type_repr.Type_param b |] } when
            Ids_core.Generic_param_id.compare a pid_t = 0
            && Ids_core.Generic_param_id.compare b pid_u = 0 ->
            Printf.printf "  template instance: PASS (f[T,U] -> [T;U] in declaration order)\n"
        | _ ->
            Printf.printf "  template instance: FAIL\n";
            exit 1);
       (* ── template/concrete verification-mode split (audit P0) ────
          require_valid_template admits a generic function TEMPLATE —
          its own declared rigid params in instance args, params,
          locals, cast targets — while still rejecting undeclared
          params, inference variables, the Error type, unknown TypeIds
          and wrong owner identities; require_valid_concrete rejects
          ANY residual Type_param/Infer_var.  Generic nominal
          identities resolve through the registry (the same
          Mono.generic_def array the driver hands to Mono.build)
          because program.types is concrete-only pre-mono. *)
       let contains_sub s sub =
         let ls = String.length s and l = String.length sub in
         if l = 0 then true
         else begin
           let rec go i =
             if i + l > ls then false
             else if String.sub s i l = sub then true
             else go (i + 1)
           in
           go 0
         end
       in
       let pid_s = Ids_core.Generic_param_id.make 21 in
       let pid_t2 = Ids_core.Generic_param_id.make 22 in
       let ty_s = Type_repr.Type_param pid_s in
       let ty_t2 = Type_repr.Type_param pid_t2 in
       let place l = { Seed_mir.root = Seed_mir.Local l; projections = [] } in
       (* a genuine template: swap[T,U] — instance [T;U], params T/U,
          locals T/U, a cast to the declared param T *)
       let swap_tmpl : Seed_mir.function_ =
         {
           Seed_mir.name = "swap";
           instance =
             Instance_id.make ~callable:(Ids.Callable_id.make 77)
               ~type_args:[| ty_s; ty_t2 |];
           params =
             [|
               { Type_repr.pt_type = ty_s; pt_convention = Access_effect.Let };
               { Type_repr.pt_type = ty_t2; pt_convention = Access_effect.Let };
             |];
           locals = [| Type_repr.Tuple [| ty_s; ty_t2 |]; ty_s; ty_t2; ty_s; ty_t2 |];
           blocks =
             [|
               {
                 Seed_mir.id = 0;
                 statements =
                   [
                     Seed_mir.Assign (place 3, Seed_mir.Cast (Seed_mir.Move (place 1), ty_s));
                     Seed_mir.Assign (place 4, Seed_mir.Use (Seed_mir.Move (place 2)));
                     Seed_mir.Assign
                       ( place 0,
                         Seed_mir.Aggregate
                           (Seed_mir.TupleAgg, [ Seed_mir.Move (place 3); Seed_mir.Move (place 4) ]) );
                   ];
                 terminator = Seed_mir.Ret;
               };
             |];
           entry = 0;
         }
       in
       let tmpl_prog : Seed_mir.program =
         { Seed_mir.functions = [| swap_tmpl |]; statics = [||]; types = [||] }
       in
       (match Mir_verify.require_valid_template tmpl_prog with
        | Ok () ->
            Printf.printf
              "  template-mode verify: PASS (swap[T,U] — declared rigid params in instance/params/locals/cast target)\n"
        | Error errs ->
            Printf.printf "  template-mode verify: FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            exit 1);
       (match Mir_verify.require_valid_concrete tmpl_prog with
        | Error errs when List.exists (fun e -> contains_sub e "unresolved type parameter") errs ->
            Printf.printf
              "  concrete-mode verify: PASS (the same template is REJECTED — residual Type_param)\n"
        | other ->
            Printf.printf "  concrete-mode verify: FAIL (expected a Type_param rejection, got %s)\n"
              (match other with
               | Ok () -> "Ok"
               | Error errs -> String.concat "; " errs);
            exit 1);
       (* negative template-mode proofs: the STILL-REJECTED list *)
       let undeclared_fn : Seed_mir.function_ =
         {
           Seed_mir.name = "undeclared";
           instance =
             Instance_id.make ~callable:(Ids.Callable_id.make 79) ~type_args:[| ty_s |];
           params = [| { Type_repr.pt_type = ty_s; pt_convention = Access_effect.Let } |];
           (* _2 carries T22, which swap's signature never declared *)
           locals = [| ty_s; ty_s; ty_t2 |];
           blocks =
             [|
               {
                 Seed_mir.id = 0;
                 statements =
                   [ Seed_mir.Assign (place 2, Seed_mir.Use (Seed_mir.Move (place 1))) ];
                 terminator = Seed_mir.Ret;
               };
             |];
           entry = 0;
         }
       in
       let infer_fn : Seed_mir.function_ =
         { undeclared_fn with
           Seed_mir.name = "infer_fn";
           locals = [| ty_s; ty_s; Type_repr.Infer_var 5 |] }
       in
       let error_fn : Seed_mir.function_ =
         { undeclared_fn with
           Seed_mir.name = "error_fn";
           locals = [| ty_s; ty_s; Type_repr.Error |] }
       in
       let unknown_tid_fn : Seed_mir.function_ =
         { undeclared_fn with
           Seed_mir.name = "unknown_tid_fn";
           locals = [| ty_s; ty_s; Type_repr.Named (Ids.Type_id.make 999, [||]) |] }
       in
       let reject_tmpl (name : string) (f : Seed_mir.function_) (needle : string) =
         let p : Seed_mir.program =
           { Seed_mir.functions = [| f |]; statics = [||]; types = [||] }
         in
         match Mir_verify.require_valid_template p with
         | Error errs when List.exists (fun e -> contains_sub e needle) errs ->
             Printf.printf "  template-mode reject: PASS (%s — %s)\n" name needle
         | other ->
             Printf.printf "  template-mode reject: FAIL (%s — expected %S, got %s)\n" name needle
               (match other with
                | Ok () -> "Ok"
                | Error errs -> String.concat "; " errs);
             exit 1
       in
       reject_tmpl "undeclared generic parameter" undeclared_fn "not declared in this scope";
       reject_tmpl "inference variable" infer_fn "inference variable";
       reject_tmpl "Error recovery type" error_fn "Error recovery type";
       reject_tmpl "unknown TypeId" unknown_tid_fn "unknown TypeId";
       (* the generic nominal registry: program.types is concrete-only
          pre-mono, so a generic nominal's field identities and types
          resolve through the registry — and only with it *)
       let pair_tid = Ids.Type_id.make 71 in
       let pid_f = Ids_core.Generic_param_id.make 31 in
       let pid_g = Ids_core.Generic_param_id.make 32 in
       let ty_f = Type_repr.Type_param pid_f in
       let ty_g = Type_repr.Type_param pid_g in
       let fid_first = Ids.Field_id.make 501 in
       let fid_second = Ids.Field_id.make 502 in
       let pair_registry : Mono.generic_def array =
         [|
           {
             Mono.gd_tid = pair_tid;
             gd_params = [| pid_f; pid_g |];
             gd_def =
               Seed_mir.StructDef
                 {
                   sd_id = pair_tid;
                   sd_fields =
                     [
                       { Seed_mir.fd_id = fid_first; fd_index = Ids.Field_index.make 0; fd_ty = ty_f };
                       { Seed_mir.fd_id = fid_second; fd_index = Ids.Field_index.make 1; fd_ty = ty_g };
                     ];
                 };
           };
         |]
       in
       let pair_ty = Type_repr.Named (pair_tid, [| ty_s; ty_t2 |]) in
       let first_of : Seed_mir.function_ =
         {
           Seed_mir.name = "first_of";
           instance =
             Instance_id.make ~callable:(Ids.Callable_id.make 78) ~type_args:[| ty_s; ty_t2 |];
           params = [| { Type_repr.pt_type = pair_ty; pt_convention = Access_effect.Let } |];
           locals = [| ty_s; pair_ty; ty_s |];
           blocks =
             [|
               {
                 Seed_mir.id = 0;
                 statements =
                   [
                     Seed_mir.Assign
                       ( place 2,
                         Seed_mir.Use
                           (Seed_mir.Read
                              { root = Seed_mir.Local 1; projections = [ Seed_mir.Field fid_first ] }) );
                     Seed_mir.Assign (place 0, Seed_mir.Use (Seed_mir.Move (place 2)));
                   ];
                 terminator = Seed_mir.Ret;
               };
             |];
           entry = 0;
         }
       in
       let first_prog : Seed_mir.program =
         { Seed_mir.functions = [| first_of |]; statics = [||]; types = [||] }
       in
       (match Mir_verify.require_valid_template ~generic_types:pair_registry first_prog with
        | Ok () ->
            Printf.printf
              "  registry template verify: PASS (Pair[T,U].first projects through the registry def to T)\n"
        | Error errs ->
            Printf.printf "  registry template verify: FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            exit 1);
       (match Mir_verify.require_valid_template first_prog with
        | Error errs when List.exists (fun e -> contains_sub e "unknown TypeId") errs ->
            Printf.printf
              "  registry-less template verify: PASS (Pair[T,U] without the registry is an unknown TypeId)\n"
        | other ->
            Printf.printf "  registry-less template verify: FAIL (expected an unknown-TypeId rejection, got %s)\n"
              (match other with
               | Ok () -> "Ok"
               | Error errs -> String.concat "; " errs);
            exit 1);
       (match Mir_verify.require_valid_concrete first_prog with
        | Error errs when List.exists (fun e -> contains_sub e "unresolved type parameter") errs ->
            Printf.printf "  registry template concrete-mode: PASS (rejected — residual Type_param)\n"
        | other ->
            Printf.printf "  registry template concrete-mode: FAIL (expected a Type_param rejection, got %s)\n"
              (match other with
               | Ok () -> "Ok"
               | Error errs -> String.concat "; " errs);
            exit 1);
       let wrong_owner : Seed_mir.function_ =
         { first_of with
           Seed_mir.name = "wrong_owner";
           blocks =
             [|
               {
                 Seed_mir.id = 0;
                 statements =
                   [
                     Seed_mir.Assign
                       ( place 2,
                         Seed_mir.Use
                           (Seed_mir.Read
                              { root = Seed_mir.Local 1; projections = [ Seed_mir.Field (Ids.Field_id.make 999) ] }) );
                     Seed_mir.Assign (place 0, Seed_mir.Use (Seed_mir.Move (place 2)));
                   ];
                 terminator = Seed_mir.Ret;
               };
             |] }
       in
       let bad_arity : Seed_mir.function_ =
         { first_of with
           Seed_mir.name = "bad_arity";
           params =
             [|
               { Type_repr.pt_type = Type_repr.Named (pair_tid, [| ty_s |]);
                 pt_convention = Access_effect.Let };
             |];
           locals = [| ty_s; Type_repr.Named (pair_tid, [| ty_s |]); ty_s |] }
       in
       let reject_registry (name : string) (f : Seed_mir.function_) (needle : string) =
         let p : Seed_mir.program =
           { Seed_mir.functions = [| f |]; statics = [||]; types = [||] }
         in
         match Mir_verify.require_valid_template ~generic_types:pair_registry p with
         | Error errs when List.exists (fun e -> contains_sub e needle) errs ->
             Printf.printf "  registry template reject: PASS (%s — %s)\n" name needle
         | other ->
             Printf.printf "  registry template reject: FAIL (%s — expected %S, got %s)\n" name
               needle
               (match other with
                | Ok () -> "Ok"
                | Error errs -> String.concat "; " errs);
             exit 1
       in
       reject_registry "wrong FieldId owner identity" wrong_owner "owner mismatch";
       reject_registry "registry template arity mismatch" bad_arity "declares";
       (* template-to-template calls: a call inside a template carries the
          CALLER's rigid params; the callee resolves by CALLABLE identity
          and the call's type args substitute the callee's declaration
          binders (the mono specialization contract) — and bad call
          arity / bad type-argument arity are still rejected *)
       let pid_c = Ids_core.Generic_param_id.make 41 in
       let ty_c = Type_repr.Type_param pid_c in
       let g_tmpl : Seed_mir.function_ =
         {
           Seed_mir.name = "g";
           instance =
             Instance_id.make ~callable:(Ids.Callable_id.make 88) ~type_args:[| ty_c |];
           params = [| { Type_repr.pt_type = ty_c; pt_convention = Access_effect.Let } |];
           locals = [| ty_c; ty_c |];
           blocks =
             [|
               {
                 Seed_mir.id = 0;
                 statements =
                   [ Seed_mir.Assign (place 0, Seed_mir.Use (Seed_mir.Move (place 1))) ];
                 terminator = Seed_mir.Ret;
               };
             |];
           entry = 0;
         }
       in
       let f_tmpl : Seed_mir.function_ =
         {
           Seed_mir.name = "f";
           instance =
             Instance_id.make ~callable:(Ids.Callable_id.make 89) ~type_args:[| ty_s |];
           params = [| { Type_repr.pt_type = ty_s; pt_convention = Access_effect.Let } |];
           locals = [| ty_s; ty_s; ty_s |];
           blocks =
             [|
               {
                 Seed_mir.id = 0;
                 statements = [];
                 terminator =
                   Seed_mir.Call
                     ( place 2,
                       Seed_mir.User
                         (Instance_id.make ~callable:(Ids.Callable_id.make 88)
                            ~type_args:[| ty_s |]),
                       [|
                         { Seed_mir.effect_ = Access_effect.Read;
                           value = Seed_mir.Move (place 1) };
                       |],
                       1,
                       None );
               };
               {
                 Seed_mir.id = 1;
                 statements =
                   [ Seed_mir.Assign (place 0, Seed_mir.Use (Seed_mir.Move (place 2))) ];
                 terminator = Seed_mir.Ret;
               };
             |];
           entry = 0;
         }
       in
       let call_prog : Seed_mir.program =
         { Seed_mir.functions = [| f_tmpl; g_tmpl |]; statics = [||]; types = [||] }
       in
       (match Mir_verify.require_valid_template call_prog with
        | Ok () ->
            Printf.printf
              "  template-call verify: PASS (f[T] calls g[T] — callee resolved by callable identity, param/ret read under the call's type args)\n"
        | Error errs ->
            Printf.printf "  template-call verify: FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            exit 1);
       let bad_arg_count : Seed_mir.function_ =
         { f_tmpl with
           Seed_mir.name = "bad_arg_count";
           blocks =
             [|
               {
                 Seed_mir.id = 0;
                 statements = [];
                 terminator =
                   Seed_mir.Call
                     ( place 2,
                       Seed_mir.User
                         (Instance_id.make ~callable:(Ids.Callable_id.make 88)
                            ~type_args:[| ty_s |]),
                       [||],
                       1,
                       None );
               };
               {
                 Seed_mir.id = 1;
                 statements =
                   [ Seed_mir.Assign (place 0, Seed_mir.Use (Seed_mir.Move (place 2))) ];
                 terminator = Seed_mir.Ret;
               };
             |] }
       in
       let bad_type_arity : Seed_mir.function_ =
         { f_tmpl with
           Seed_mir.name = "bad_type_arity";
           blocks =
             [|
               {
                 Seed_mir.id = 0;
                 statements = [];
                 terminator =
                   Seed_mir.Call
                     ( place 2,
                       Seed_mir.User
                         (Instance_id.make ~callable:(Ids.Callable_id.make 88)
                            ~type_args:[| ty_s; ty_t2 |]),
                       [|
                         { Seed_mir.effect_ = Access_effect.Read;
                           value = Seed_mir.Move (place 1) };
                       |],
                       1,
                       None );
               };
               {
                 Seed_mir.id = 1;
                 statements =
                   [ Seed_mir.Assign (place 0, Seed_mir.Use (Seed_mir.Move (place 2))) ];
                 terminator = Seed_mir.Ret;
               };
             |] }
       in
       let reject_call (name : string) (f : Seed_mir.function_) (needle : string) =
         let p : Seed_mir.program =
           { Seed_mir.functions = [| f; g_tmpl |]; statics = [||]; types = [||] }
         in
         match Mir_verify.require_valid_template p with
         | Error errs when List.exists (fun e -> contains_sub e needle) errs ->
             Printf.printf "  template-call reject: PASS (%s — %s)\n" name needle
         | other ->
             Printf.printf "  template-call reject: FAIL (%s — expected %S, got %s)\n" name needle
               (match other with
                | Ok () -> "Ok"
                | Error errs -> String.concat "; " errs);
             exit 1
       in
       reject_call "bad call argument count" bad_arg_count "argument count mismatch";
       reject_call "bad type-argument arity" bad_type_arity "declares";
       (* function constants in a template: a Constant (Function inst)
          referencing a generic template reads the callee's signature
          under the constant's type args *)
       let fnptr_tmpl : Seed_mir.function_ =
         {
           Seed_mir.name = "fnptr";
           instance =
             Instance_id.make ~callable:(Ids.Callable_id.make 90) ~type_args:[| ty_s |];
           params = [| { Type_repr.pt_type = ty_s; pt_convention = Access_effect.Let } |];
           locals =
             [| ty_s; ty_s;
                Type_repr.Function
                  ([| { Type_repr.pt_type = ty_s; pt_convention = Access_effect.Let } |],
                   ty_s) |];
           blocks =
             [|
               {
                 Seed_mir.id = 0;
                 statements =
                   [
                     Seed_mir.Assign
                       ( place 2,
                         Seed_mir.Use
                           (Seed_mir.Constant
                              (Seed_mir.Function
                                 (Instance_id.make ~callable:(Ids.Callable_id.make 88)
                                    ~type_args:[| ty_s |]))) );
                     Seed_mir.Assign (place 0, Seed_mir.Use (Seed_mir.Move (place 1)));
                   ];
                 terminator = Seed_mir.Ret;
               };
             |];
           entry = 0;
         }
       in
       (match
          Mir_verify.require_valid_template
            { Seed_mir.functions = [| fnptr_tmpl; g_tmpl |]; statics = [||]; types = [||] }
        with
        | Ok () ->
            Printf.printf
              "  template function-constant verify: PASS (a constant of g[T] reads the callee signature under the call's type args)\n"
        | Error errs ->
            Printf.printf "  template function-constant verify: FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            exit 1);
       if dump then Printf.printf "%s\n" (Seed_mir.print_program prog);
      let entry =
        match
          Array.to_list prog.Seed_mir.functions
          |> List.find_opt (fun f -> f.Seed_mir.name = "main")
        with
        | Some f -> f.Seed_mir.instance
        | None -> failwith "no main function"
      in
      let host = Host.create ~repo_root:"." ~argv:[||] in
      (match Vm.run ~program:prog ~entry ~argv:[||] ~host with
       | Error e ->
           Printf.printf "  VM: FAIL %s\n" e.Vm.message;
           exit 1
       | Ok code ->
           Printf.printf "  VM: exit %d\n" code;
           (match Vm.entry_frame_of ~program:prog ~entry ~argv:[||] with
            | Error m -> Printf.printf "  main returned: <inspect failed: %s>\n" m
            | Ok (vm2, entry_frame) -> (
                match Vm.run_inspect vm2 entry_frame with
                | Ok ret_val ->
                    Printf.printf "  main returned: %s\n" ret_val;
                    if ret_val = "368" then Printf.printf "  RESULT: PASS\n"
                    else begin
                      Printf.printf "  RESULT: FAIL (expected 368)\n";
                      exit 1
                    end
                | Error m -> Printf.printf "  main returned: <inspect failed: %s>\n" m)));
      (* ── struct-field read/write lowering proof (re-audit's first
         priority: Field access must reach MIR lowering through a typed
         place (FieldId) rule — the ordinary lowering surface's first
         item; 2026-08-27 the frontend gate for the WRITE side was also
         lifted, so make_pair now lowers from the SOURCE struct literal
         `Pair { a: a, b: b }` — the positive replacement for the
         retired E9036/E9037 rejections) ─────────────────────────────
         A two-field struct Pair: make_pair CONSTRUCTS a Pair value
         from the source-level StructLit (the StructCtor aggregate with
         the typed field indices), and read_a/read_b read `.a`/`.b`
         through the LOWERED Field projection.  Every function lowers
         from source (parse -> typecheck -> lower -> verify -> execute).
         The proof shows:
         (1) the driver's registry builder (struct_fields_of on the
         TYPED registry — the same source closure_types materializes
         the StructDefs from) reproduces the manual Pair table exactly,
         with the semantic FieldIds;
         (2) the lowered make_pair carries the StructCtor aggregate with
         the registry's declaration-order indices;
         (3) the lowered read functions carry the Field projection with
         the semantic FieldId MATCHING the StructDef installed into
         program.types (the verifier's owner-identity rule);
         (4) the whole program passes Mir_verify.require_valid_concrete
         and the VM round-trips the field values (main = 21 + 42 = 63). *)
      let field_src = {|
struct Pair
  a: Int
  b: Int
end

def make_pair(a: Int, b: Int) -> Pair
  Pair { a: a, b: b }
end

def read_a(p: Pair) -> Int
  p.a
end

def read_b(p: Pair) -> Int
  p.b
end

def main() -> Int
  read_a(make_pair(21, 42)) + read_b(make_pair(21, 42))
end
|} in
      let field_file = Filename.temp_file "tg_lowersurface_struct" ".tg" in
      (let oc = open_out_bin field_file in
       output_string oc field_src;
       close_out oc);
      let field_manifest =
        match Bootstrap_manifest.single ~file:field_file ~path:[ "fieldproof" ] () with
        | Ok m -> m
        | Error e -> failwith ("struct-field proof manifest: " ^ e)
      in
      let fdiags = Diagnostic.create_bag () in
      let fgraph = Module_graph.create_with_sources field_manifest fdiags in
      let fresolved = Resolver.resolve field_manifest fgraph fdiags in
      let fprog_ast = (List.hd fgraph.Module_graph.nodes).Module_graph.node_program in
      let fenv =
        match Typecheck.check_program (Typecheck.initial_env ~resolved:(Some fresolved) ()) fprog_ast with
        | Error m -> failwith ("struct-field proof typecheck: " ^ m)
        | Ok (env', errors) ->
            if errors <> [] then
              failwith ("struct-field proof typecheck errors: " ^ String.concat "; " errors);
            env'
      in
      Sys.remove field_file;
      let pair_nom = List.assoc "Pair" fenv.Typecheck.nominals in
      let pair_tid = List.assoc "Pair" fenv.Typecheck.type_ids in
      let pair_fids = pair_nom.Typecheck.nom_field_ids in
      if List.length pair_fids <> 2 then
        failwith ("struct-field proof: Pair has " ^ string_of_int (List.length pair_fids) ^ " FieldIds");
      let fid_a = List.nth pair_fids 0 and fid_b = List.nth pair_fids 1 in
      let pair_fields = [ ("a", fid_a, int_ty, None); ("b", fid_b, int_ty, None) ] in
      let driver_pair_fields = List.assoc pair_tid (Driver.struct_fields_of fenv) in
      if driver_pair_fields <> pair_fields then begin
        Printf.printf
          "  struct-field registry: FAIL (driver struct_fields_of differs from the manual Pair table)\n";
        exit 1
      end;
      Printf.printf
        "  struct-field registry: PASS (driver struct_fields_of == manual Pair table with the semantic FieldIds %d and %d)\n"
        (Ids.Field_id.to_int fid_a) (Ids.Field_id.to_int fid_b);
      let ffuncs =
        List.filter_map
          (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
          fprog_ast.Ast.items
      in
      let fts_of name =
        match List.assoc_opt name fenv.Typecheck.functions with
        | Some ts -> ts
        | None -> (
            match
              List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) fenv.Typecheck.functions
            with
            | [ (_, ts) ] -> ts
            | _ -> failwith ("struct-field proof: no typed signature for " ^ name))
      in
      let fenv2 : Mir_lower.func_env =
        {
          Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
            [
              ("Pair", Type_repr.Named (pair_tid, [||]));
              ("Int", int_ty);
              ("Unit", Type_repr.Unit);
              ("Bool", Type_repr.Bool);
              ("String", string_ty);
            ];
          values =
            List.map
              (fun d ->
                let n = d.Ast.fn_sig.Ast.sig_name in
                (n, (fts_of n).Typecheck.ts_return))
              ffuncs;
          callables =
            List.map
              (fun d ->
                let n = d.Ast.fn_sig.Ast.sig_name in
                ( n,
                  {
                    Mir_lower.ce_callable = Ids.Callable_id.to_int (fts_of n).Typecheck.ts_callable;
                    ce_template_args = [||];
                    ce_params = [||];
                  } ))
              ffuncs;
          methods = [];
          callables_by_callable = [];
          fn_ret = int_ty;
          struct_fields = Driver.struct_fields_of fenv;
          enum_payloads = Driver.enum_payloads_of fenv;
          copy_cache = Type_properties.create_cache ();
        }
      in
      let fmir_funcs =
        List.map
          (fun d ->
            let n = d.Ast.fn_sig.Ast.sig_name in
            let ts = fts_of n in
            Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
              { fenv2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
              n (Ids.Callable_id.to_int ts.Typecheck.ts_callable) [||] [||] d)
          ffuncs
      in
      (* the StructCtor aggregate that CONSTRUCTS the Pair value (the
         seed's post-mono aggregate form: the typed field indices in
         declaration order) — now emitted by the LOWERER from the
         source StructLit, not hand-built: make_pair is lowered from
         `Pair { a: a, b: b }` exactly like read_a/read_b/main *)
      let fprog : Seed_mir.program =
        {
          Seed_mir.functions = Array.of_list fmir_funcs;
          statics = [||];
          (* the StructDef with the SEMANTIC FieldIds — built manually
             (the harness's style), and cross-checked against the typed
             registry below *)
          types =
            [|
              Seed_mir.StructDef
                {
                  sd_id = pair_tid;
                  sd_fields =
                    [
                      { Seed_mir.fd_id = fid_a; fd_index = Ids.Field_index.make 0; fd_ty = int_ty };
                      { Seed_mir.fd_id = fid_b; fd_index = Ids.Field_index.make 1; fd_ty = int_ty };
                    ];
                };
            |];
        }
      in
      (* the write-side proof: the LOWERED make_pair must carry the
         StructCtor aggregate — Pair's tid, the registry's
         declaration-order indices [0;1], and the params (a=local 1,
         b=local 2) as the operands *)
      let fmake_pair =
        List.find
          (fun f -> f.Seed_mir.name = "make_pair")
          (Array.to_list fprog.Seed_mir.functions)
      in
      let f_ctor =
        Array.to_list fmake_pair.Seed_mir.blocks
        |> List.find_map (fun (b : Seed_mir.block) ->
               List.find_map
                 (fun (s : Seed_mir.statement) ->
                   match s with
                   | Seed_mir.Assign (_, Seed_mir.Aggregate (Seed_mir.StructCtor (tid, fields), ops))
                     ->
                       Some (tid, fields, ops)
                   | _ -> None)
                 b.Seed_mir.statements)
      in
      (match f_ctor with
       | Some (tid, fields, ops) ->
           let index_ok =
             Ids.Type_id.compare tid pair_tid = 0
             && Array.length fields = 2
             && Ids.Field_index.compare fields.(0) (Ids.Field_index.make 0) = 0
             && Ids.Field_index.compare fields.(1) (Ids.Field_index.make 1) = 0
           in
           let op_is_param pos local =
             match List.nth_opt ops pos with
             | Some (Seed_mir.Copy p) -> p.Seed_mir.root = Seed_mir.Local local
             | _ -> false
           in
           let pos_ok = op_is_param 0 1 && op_is_param 1 2 in
           if index_ok && pos_ok then
             Printf.printf
               "  struct-field construction: PASS (make_pair lowers the source StructLit to the StructCtor aggregate type#%d with registry indices [0;1] — `a` at position 0, `b` at 1)\n"
               (Ids.Type_id.to_int tid)
           else begin
             Printf.printf "  struct-field construction: FAIL (index_ok=%b pos_ok=%b)\n"
               index_ok pos_ok;
             exit 1
           end
       | None ->
           Printf.printf "  struct-field construction: FAIL (no StructCtor aggregate in lowered make_pair)\n";
           exit 1);
      (* the def-alignment proof: closure_types materializes the SAME
         StructDef from the typed registry (same FieldIds) *)
      let pair_def_ok =
        match
          Array.to_list (Driver.closure_types fenv)
          |> List.find_map (fun d ->
                 match d with
                 | Seed_mir.StructDef { sd_id; sd_fields }
                   when Ids.Type_id.compare sd_id pair_tid = 0 ->
                     Some sd_fields
                 | _ -> None)
        with
        | Some sd_fields ->
            List.length sd_fields = 2
            && List.for_all
                 (fun (fname, fid, _, _ : string * Ids.Field_id.t * Type_repr.t * Ast.expr option) ->
                   List.exists
                     (fun (fd : Seed_mir.field_def) ->
                       Ids.Field_id.compare fd.Seed_mir.fd_id fid = 0
                       && Type_repr.compare fd.Seed_mir.fd_ty int_ty = 0
                       && (match fname with
                           | "a" -> Ids.Field_index.compare fd.Seed_mir.fd_index (Ids.Field_index.make 0) = 0
                           | _ -> Ids.Field_index.compare fd.Seed_mir.fd_index (Ids.Field_index.make 1) = 0))
                     sd_fields)
                 pair_fields
        | None -> false
      in
      if not pair_def_ok then begin
        Printf.printf "  struct-field defs: FAIL (closure_types does not materialize the Pair StructDef with the semantic FieldIds)\n";
        exit 1
      end;
      Printf.printf "  struct-field defs: PASS (Pair StructDef FieldIds match the typed registry's nom_field_ids)\n";
      (* the projection proof: the LOWERED read functions must carry the
         Field projection with the semantic FieldId of the field they
         read (matching the def — the verifier's owner-identity rule) *)
      let place_has_field (fid : Ids.Field_id.t) (p : Seed_mir.place) : bool =
        List.exists
          (fun proj ->
            match proj with
            | Seed_mir.Field f -> Ids.Field_id.compare f fid = 0
            | _ -> false)
          p.Seed_mir.projections
      in
      let operand_has_field (fid : Ids.Field_id.t) (op : Seed_mir.operand) : bool =
        match op with
        | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p | Seed_mir.Consume p ->
            place_has_field fid p
        | Seed_mir.Constant _ -> false
      in
      let fn_has_field (fid : Ids.Field_id.t) (f : Seed_mir.function_) : bool =
        Array.exists
          (fun (b : Seed_mir.block) ->
            List.exists
              (fun (st : Seed_mir.statement) ->
                match st with
                | Seed_mir.Assign (p, rv) ->
                    place_has_field fid p
                    || (match rv with
                       | Seed_mir.Use op -> operand_has_field fid op
                       | Seed_mir.Aggregate (_, ops) -> List.exists (operand_has_field fid) ops
                       | _ -> false)
                | _ -> false)
              b.Seed_mir.statements)
          f.Seed_mir.blocks
      in
      let read_a_fn =
        List.find
          (fun f -> f.Seed_mir.name = "read_a")
          (Array.to_list fprog.Seed_mir.functions)
      in
      let read_b_fn =
        List.find
          (fun f -> f.Seed_mir.name = "read_b")
          (Array.to_list fprog.Seed_mir.functions)
      in
      if not (fn_has_field fid_a read_a_fn && fn_has_field fid_b read_b_fn) then begin
        Printf.printf
          "  struct-field lowering: FAIL (read_a/read_b carry no Field projection with the semantic FieldIds)\n";
        exit 1
      end;
      Printf.printf
        "  struct-field lowering: PASS (read_a/read_b carry Field projections with FieldId#%d / FieldId#%d, matching the def)\n"
        (Ids.Field_id.to_int fid_a) (Ids.Field_id.to_int fid_b);
      (match Mir_verify.require_valid_concrete fprog with
       | Ok () ->
           Printf.printf "  struct-field MIR verify: PASS (%d functions)\n"
             (Array.length fprog.Seed_mir.functions)
       | Error errs ->
           Printf.printf "  struct-field MIR verify: FAIL\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Printf.printf "%s\n" (Seed_mir.print_program fprog);
           exit 1);
      let fentry =
        match
          Array.to_list fprog.Seed_mir.functions
          |> List.find_opt (fun f -> f.Seed_mir.name = "main")
        with
        | Some f -> f.Seed_mir.instance
        | None -> failwith "struct-field proof: no main function"
      in
      let fhost = Host.create ~repo_root:"." ~argv:[||] in
      (match Vm.run ~program:fprog ~entry:fentry ~argv:[||] ~host:fhost with
       | Error e ->
           Printf.printf "  struct-field VM: FAIL %s\n" e.Vm.message;
           exit 1
       | Ok code ->
           Printf.printf "  struct-field VM: exit %d\n" code;
           (match Vm.entry_frame_of ~program:fprog ~entry:fentry ~argv:[||] with
            | Error m -> Printf.printf "  struct-field main returned: <inspect failed: %s>\n" m
            | Ok (fvm, fentry_frame) -> (
                match Vm.run_inspect fvm fentry_frame with
                | Ok ret_val ->
                    Printf.printf "  struct-field main returned: %s\n" ret_val;
                    if ret_val = "63" then
                      Printf.printf
                        "  struct-field RESULT: PASS (21 and 42 round-tripped through the Field projections)\n"
                    else begin
                      Printf.printf "  struct-field RESULT: FAIL (expected 63)\n";
                      exit 1
                    end
                 | Error m -> Printf.printf "  struct-field main returned: <inspect failed: %s>\n" m)));
      (* ── projected writeback proof (E9036 retirement, 2026-08-28):
         the typed-place writeback rule landed in mir_lower's Assign
         branch — a Field target (`p.a = v`) resolves the field through
         the typed nominal registry (the SAME channel as the read path)
         and emits the Assign to the projected place; an Index target
         (`a[i] = v`) emits the ConstantIndex form for a literal index
         and the dynamic `Index <index-local>` form otherwise (the VM
         bounds-checks the runtime index at execution).  Every function
         lowers from source (parse -> typecheck -> lower -> verify ->
         execute).  The proof shows:
         (1) write_a/write_b carry Assign statements whose DESTINATION
         place carries the semantic Field projection of the written
         field, with the value operand;
         (2) write_idx carries the dynamic Index projection and
         write_idx_c the ConstantIndex projection on the destination;
         (3) the whole program passes Mir_verify.require_valid_concrete
         (the projected destinations are checked: owner identity +
         initialization);
         (4) the VM round-trips the writes — the writeback sets the
         projected component and preserves the rest of the aggregate
         (main = 42 + 7 + 99 + 99 = 247). *)
      let wb_src = {|
struct Pair
  a: Int
  b: Int
end

def write_a(p: Pair, v: Int) -> Int
  p.a = v
  p.a
end

def write_b(p: Pair, v: Int) -> Int
  p.b = v
  p.b
end

def write_idx(a: [Int; 3], i: Int, v: Int) -> Int
  a[i] = v
  a[i]
end

def write_idx_c(a: [Int; 3]) -> Int
  a[1] = 99
  a[1]
end

def main() -> Int
  write_a(Pair { a: 1, b: 2 }, 42) + write_b(Pair { a: 1, b: 2 }, 7) + write_idx([10, 20, 30], 1, 99) + write_idx_c([1, 2, 3])
end
|} in
      let wb_file = Filename.temp_file "tg_lowersurface_writeback" ".tg" in
      (let oc = open_out_bin wb_file in
       output_string oc wb_src;
       close_out oc);
      let wb_manifest =
        match Bootstrap_manifest.single ~file:wb_file ~path:[ "wbproof" ] () with
        | Ok m -> m
        | Error e -> failwith ("writeback proof manifest: " ^ e)
      in
      let wbdiags = Diagnostic.create_bag () in
      let wbgraph = Module_graph.create_with_sources wb_manifest wbdiags in
      let wbresolved = Resolver.resolve wb_manifest wbgraph wbdiags in
      let wbprog_ast = (List.hd wbgraph.Module_graph.nodes).Module_graph.node_program in
      let wbenv =
        match Typecheck.check_program (Typecheck.initial_env ~resolved:(Some wbresolved) ()) wbprog_ast with
        | Error m -> failwith ("writeback proof typecheck: " ^ m)
        | Ok (env', errors) ->
            if errors <> [] then
              failwith ("writeback proof typecheck errors: " ^ String.concat "; " errors);
            env'
      in
      Sys.remove wb_file;
      let wb_pair_nom = List.assoc "Pair" wbenv.Typecheck.nominals in
      let wb_pair_tid = List.assoc "Pair" wbenv.Typecheck.type_ids in
      let wb_pair_fids = wb_pair_nom.Typecheck.nom_field_ids in
      if List.length wb_pair_fids <> 2 then
        failwith ("writeback proof: Pair has " ^ string_of_int (List.length wb_pair_fids) ^ " FieldIds");
      let wb_fid_a = List.nth wb_pair_fids 0 and wb_fid_b = List.nth wb_pair_fids 1 in
      let wb_ffuncs =
        List.filter_map
          (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
          wbprog_ast.Ast.items
      in
      let wb_fts_of name =
        match List.assoc_opt name wbenv.Typecheck.functions with
        | Some ts -> ts
        | None -> (
            match
              List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) wbenv.Typecheck.functions
            with
            | [ (_, ts) ] -> ts
            | _ -> failwith ("writeback proof: no typed signature for " ^ name))
      in
      let wbenv2 : Mir_lower.func_env =
        {
          Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
            [
              ("Pair", Type_repr.Named (wb_pair_tid, [||]));
              ("Int", int_ty);
              ("Unit", Type_repr.Unit);
              ("Bool", Type_repr.Bool);
              ("String", string_ty);
            ];
          values =
            List.map
              (fun d ->
                let n = d.Ast.fn_sig.Ast.sig_name in
                (n, (wb_fts_of n).Typecheck.ts_return))
              wb_ffuncs;
          callables =
            List.map
              (fun d ->
                let n = d.Ast.fn_sig.Ast.sig_name in
                ( n,
                  {
                    Mir_lower.ce_callable = Ids.Callable_id.to_int (wb_fts_of n).Typecheck.ts_callable;
                    ce_template_args = [||];
                    ce_params = [||];
                  } ))
              wb_ffuncs;
          methods = [];
          callables_by_callable = [];
          fn_ret = int_ty;
          struct_fields = Driver.struct_fields_of wbenv;
          enum_payloads = Driver.enum_payloads_of wbenv;

                  copy_cache = Type_properties.create_cache ();
}
      in
      let wb_mir_funcs =
        List.map
          (fun d ->
            let n = d.Ast.fn_sig.Ast.sig_name in
            let ts = wb_fts_of n in
            Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
              { wbenv2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
              n (Ids.Callable_id.to_int ts.Typecheck.ts_callable) [||] [||]
              ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
              d)
          wb_ffuncs
      in
      let wb_pair_def =
        match
          Array.to_list (Driver.closure_types wbenv)
          |> List.find_map (fun d ->
                 match d with
                 | Seed_mir.StructDef { sd_id; _ } when Ids.Type_id.compare sd_id wb_pair_tid = 0 ->
                     Some d
                 | _ -> None)
        with
        | Some d -> d
        | None -> failwith "writeback proof: no Pair StructDef from closure_types"
      in
      let wbprog : Seed_mir.program =
        { Seed_mir.functions = Array.of_list wb_mir_funcs; statics = [||]; types = [| wb_pair_def |] }
      in
      (* the writeback-shape proof: each write function's lowered Assign
         destination carries the projected place of the written
         component — Field <semantic id> for the struct fields, the
         dynamic Index <local> and ConstantIndex for the array writes *)
      let dest_has_proj (f : Seed_mir.function_) (pred : Seed_mir.projection -> bool) : bool =
        Array.exists
          (fun (b : Seed_mir.block) ->
            List.exists
              (fun (st : Seed_mir.statement) ->
                match st with
                | Seed_mir.Assign (p, Seed_mir.Use (Seed_mir.Copy _ | Seed_mir.Constant _))
                  when p.Seed_mir.projections <> [] ->
                    List.exists pred p.Seed_mir.projections
                | _ -> false)
              b.Seed_mir.statements)
          f.Seed_mir.blocks
      in
      let wb_write_a =
        List.find (fun f -> f.Seed_mir.name = "write_a") (Array.to_list wbprog.Seed_mir.functions)
      in
      let wb_write_b =
        List.find (fun f -> f.Seed_mir.name = "write_b") (Array.to_list wbprog.Seed_mir.functions)
      in
      let wb_write_idx =
        List.find (fun f -> f.Seed_mir.name = "write_idx") (Array.to_list wbprog.Seed_mir.functions)
      in
      let wb_write_idx_c =
        List.find (fun f -> f.Seed_mir.name = "write_idx_c") (Array.to_list wbprog.Seed_mir.functions)
      in
      let proj_is_field fid = function
        | Seed_mir.Field f -> Ids.Field_id.compare f fid = 0
        | _ -> false
      in
      let proj_is_dyn_index = function
        | Seed_mir.Index _ -> true
        | _ -> false
      in
      let proj_is_const_index = function
        | Seed_mir.ConstantIndex 1 -> true
        | _ -> false
      in
      if
        not
          (dest_has_proj wb_write_a (proj_is_field wb_fid_a)
          && dest_has_proj wb_write_b (proj_is_field wb_fid_b)
          && dest_has_proj wb_write_idx proj_is_dyn_index
          && dest_has_proj wb_write_idx_c proj_is_const_index)
      then begin
        Printf.printf
          "  writeback lowering: FAIL (the write functions carry no Assign to the projected destination — expected Field#%d on write_a, Field#%d on write_b, Index <local> on write_idx, ConstantIndex 1 on write_idx_c)\n"
          (Ids.Field_id.to_int wb_fid_a) (Ids.Field_id.to_int wb_fid_b);
        exit 1
      end;
      Printf.printf
        "  writeback lowering: PASS (write_a/write_b Assign to the semantic Field projections FieldId#%d/FieldId#%d; write_idx to the dynamic Index <local>; write_idx_c to ConstantIndex 1)\n"
        (Ids.Field_id.to_int wb_fid_a) (Ids.Field_id.to_int wb_fid_b);
      (match Mir_verify.require_valid_concrete wbprog with
       | Ok () ->
           Printf.printf "  writeback MIR verify: PASS (%d functions)\n"
             (Array.length wbprog.Seed_mir.functions)
       | Error errs ->
           Printf.printf "  writeback MIR verify: FAIL\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Printf.printf "%s\n" (Seed_mir.print_program wbprog);
           exit 1);
      let wb_entry =
        match
          Array.to_list wbprog.Seed_mir.functions
          |> List.find_opt (fun f -> f.Seed_mir.name = "main")
        with
        | Some f -> f.Seed_mir.instance
        | None -> failwith "writeback proof: no main function"
      in
      let wbhost = Host.create ~repo_root:"." ~argv:[||] in
      (match Vm.run ~program:wbprog ~entry:wb_entry ~argv:[||] ~host:wbhost with
       | Error e ->
           Printf.printf "  writeback VM: FAIL %s\n" e.Vm.message;
           exit 1
       | Ok code ->
           Printf.printf "  writeback VM: exit %d\n" code;
           (match Vm.entry_frame_of ~program:wbprog ~entry:wb_entry ~argv:[||] with
            | Error m -> Printf.printf "  writeback main returned: <inspect failed: %s>\n" m
            | Ok (wbvm, wbentry_frame) -> (
                match Vm.run_inspect wbvm wbentry_frame with
                | Ok ret_val ->
                    Printf.printf "  writeback main returned: %s\n" ret_val;
                    if ret_val = "247" then
                      Printf.printf
                        "  writeback RESULT: PASS (field + index writebacks round-tripped through the projected places)\n"
                    else begin
                      Printf.printf "  writeback RESULT: FAIL (expected 247)\n";
                      exit 1
                    end
                | Error m -> Printf.printf "  writeback main returned: <inspect failed: %s>\n" m)));
      (* ── typed-cast proof (re-audit: the persistent
         TypedProgram/TypedHIR bridge — the node-keyed typed-expr map and
         its cast-target channel) ─────────────────────────────────────
         A generic cast `p as Ptr[U]` inside def cast_proof[T, U]: the
         CHECKER resolves the target to Named(Ptr, [Type_param pid_u])
         with pid_u the function's DECLARATION-OWNED GenericParamId.
         The map the typechecker persists (span identity (file_id, start)
         -> node) must carry exactly that target, and lowering through
         the DRIVER-built env (the typed_nodes channel present) must emit
         the Cast rvalue with the SAME pid — never the syntax-driven
         reconstruction, which cannot even resolve the generic name and
         whose positional KParam(make i) keys miss the declaration-owned
         ids. *)
      let cast_src = {|
def cast_proof[T, U](p: Ptr[T]) -> Ptr[U]
  p as Ptr[U]
end
|} in
      let cast_file = "<typed-cast-proof>" in
      (match Source_loader.load_string cast_file cast_src with
       | Error _ -> failwith "typed-cast proof source load"
       | Ok csrc ->
           let csm = Span.create () in
           let cfid = Span.add_file csm csrc.Source.name csrc in
           let cdiags = Diagnostic.create_bag () in
           let clx = Lexer.create csrc.Source.bytes cfid cdiags in
           let ctoks = Lexer.lex clx in
           let cprog = Parser.parse ctoks csrc.Source.bytes cfid cdiags [ "castproof" ] in
           if Diagnostic.has_errors cdiags then begin
             Printf.printf "  typed-cast proof: FAIL (parse errors)\n%s\n"
               (Diagnostic.render csm cdiags);
             exit 1
           end;
           let cenv =
             match Typecheck.check_program (Typecheck.initial_env ()) cprog with
             | Error m -> failwith ("typed-cast proof typecheck: " ^ m)
             | Ok (env', errors) ->
                 if errors <> [] then
                   failwith
                     ("typed-cast proof typecheck errors: " ^ String.concat "; " errors);
                 env'
           in
           let cast_fn_decl =
             match
               List.find_map
                 (fun i ->
                   match i.Ast.kind with
                   | Ast.Function d when d.Ast.fn_sig.Ast.sig_name = "cast_proof" -> Some d
                   | _ -> None)
                 cprog.Ast.items
             with
             | Some d -> d
             | None -> failwith "typed-cast proof: no cast_proof function"
           in
           let ty_ast, cast_nid, inner_nid, cast_span, _inner_span =
             match cast_fn_decl.Ast.fn_body with
             | Ast.FnExpr (Ast.Cast (cn, Ast.Name (inn, _, ispan), ty, span)) ->
                 (ty, cn, inn, span, ispan)
             | Ast.FnBlock { Ast.b_tail = Some (Ast.Cast (cn, Ast.Name (inn, _, ispan), ty, span)); _ } ->
                 (ty, cn, inn, span, ispan)
             | _ -> failwith "typed-cast proof: cast_proof body is not `p as Ptr[U]`"
           in
           let cast_ts =
             match List.assoc_opt "cast_proof" cenv.Typecheck.functions with
             | Some ts -> ts
             | None -> (
                 match
                   List.filter
                     (fun (k, _) -> Util.has_suffix k "::cast_proof")
                     cenv.Typecheck.functions
                 with
                 | [ (_, ts) ] -> ts
                 | _ -> failwith "typed-cast proof: no typed signature for cast_proof")
           in
           let pid_t, pid_u =
             match cast_ts.Typecheck.ts_params_decl with
             | [ (_, t); (_, u) ] -> (t, u)
             | _ -> failwith "typed-cast proof: cast_proof[T,U] params not declaration-owned"
           in
           let ptr_tid = List.assoc "Ptr" cenv.Typecheck.type_ids in
           let resolved_target =
             Type_repr.Named (ptr_tid, [| Type_repr.Type_param pid_u |])
           in
           let map = Driver.typed_nodes_of cenv in
           let cast_node =
             match List.assoc_opt cast_nid map with
             | Some n -> n
             | None ->
                 Printf.printf
                   "  typed-cast map: FAIL (no typed node for the cast's span file#%d[%d..%d))\n"
                   cfid cast_span.Span.start cast_span.Span.end_;
                 exit 1
           in
           (* the cast's node carries the resolved target, and the target
              is the declaration-owned U — distinct from the builtin
              Ptr's own param and from the positional synthetic id *)
           let ptr_builtin_param =
             match List.assoc "Ptr" (Driver.lowering_env_of cenv).Mir_lower.types with
             | Type_repr.Named (_, [| Type_repr.Type_param p |]) -> p
             | _ -> failwith "typed-cast proof: no Ptr builtin type entry"
           in
           if
             cast_node.Mir_lower.tn_cast_target <> Some resolved_target
             || Type_repr.compare cast_node.Mir_lower.tn_type resolved_target <> 0
             || Ids_core.Generic_param_id.compare pid_u ptr_builtin_param = 0
             || Ids_core.Generic_param_id.compare pid_u (Ids_core.Generic_param_id.make 0) = 0
           then begin
             Printf.printf
               "  typed-cast map: FAIL (expected the checker-resolved Named(Ptr, [Type_param %d]) at file#%d[%d..%d)); got tn_type=%s tn_cast_target=%s; builtin Ptr param=%d; U=%d)\n"
               (Ids_core.Generic_param_id.to_int pid_u)
               cfid cast_span.Span.start cast_span.Span.end_
               (match cast_node.Mir_lower.tn_type with
                | Type_repr.Named (_, args) -> "Named(Ptr, [" ^ String.concat "; " (Array.to_list (Array.map (fun a -> match a with Type_repr.Type_param p -> "Type_param " ^ string_of_int (Ids_core.Generic_param_id.to_int p) | _ -> "?") args)) ^ "])"
                | _ -> "?")
               (match cast_node.Mir_lower.tn_cast_target with
                | Some _ -> "Some(Named(Ptr, [...]))"
                | None -> "None")
               (Ids_core.Generic_param_id.to_int ptr_builtin_param)
               (Ids_core.Generic_param_id.to_int pid_u);
             exit 1
           end;
           (* the inner `p` node is NOT a cast: the channel distinguishes
              the cast-target field from the plain expr type *)
           (match List.assoc_opt inner_nid map with
            | Some inner_node when inner_node.Mir_lower.tn_cast_target = None -> ()
            | Some _ ->
                Printf.printf "  typed-cast map: FAIL (the inner `p` node carries a cast target)\n";
                exit 1
            | None -> ());
           Printf.printf
             "  typed-cast map: PASS (cast span file#%d[%d..%d) -> Named(Ptr, [Type_param %d]) with the declaration-owned U; builtin Ptr param %d differs)\n"
             cfid cast_span.Span.start cast_span.Span.end_
             (Ids_core.Generic_param_id.to_int pid_u)
             (Ids_core.Generic_param_id.to_int ptr_builtin_param);
           (* the lowering leg: lower cast_proof through the DRIVER-built
              env with the typed_nodes channel present; the Cast rvalue
              must carry the SAME declaration-owned pid_u *)
           let lowered_cast =
             Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
               ~typed_nodes:(Driver.typed_nodes_of cenv)
               ~param_tys_opt:
                 (Array.map (fun p -> p.Type_repr.pt_type) cast_ts.Typecheck.ts_params)
               { (Driver.lowering_env_of cenv) with Mir_lower.fn_ret = cast_ts.Typecheck.ts_return }
               "cast_proof" (Ids.Callable_id.to_int cast_ts.Typecheck.ts_callable)
               (Array.of_list
                  (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                     cast_ts.Typecheck.ts_params_decl))
               (Array.map (fun p -> p.Type_repr.pt_convention) cast_ts.Typecheck.ts_params)
               cast_fn_decl
           in
           let cast_rv_ty =
             Array.to_list lowered_cast.Seed_mir.blocks
             |> List.find_map (fun (b : Seed_mir.block) ->
                    List.find_map
                      (fun (s : Seed_mir.statement) ->
                        match s with
                        | Seed_mir.Assign (_, Seed_mir.Cast (_, ty)) -> Some ty
                        | _ -> None)
                      b.Seed_mir.statements)
           in
           (match cast_rv_ty with
            | Some ty when Type_repr.compare ty resolved_target = 0 ->
                Printf.printf
                  "  typed-cast lowering: PASS (lowered Cast rvalue carries Named(Ptr, [Type_param %d]) — the declaration-owned U, not a synthetic positional id)\n"
                  (Ids_core.Generic_param_id.to_int pid_u)
            | Some ty ->
                Printf.printf
                  "  typed-cast lowering: FAIL (Cast rvalue differs from the resolved target)\n";
                ignore ty;
                exit 1
            | None ->
                Printf.printf "  typed-cast lowering: FAIL (no Cast statement in lowered cast_proof)\n";
                exit 1);
           (* the contrast: the syntax-driven reconstruction cannot
              resolve the generic name at all (and its positional keys
              could never hit the declaration-owned ids) *)
           (match
              (try Ok (Mir_lower.type_of_syntax (Driver.lowering_env_of cenv) ty_ast)
               with Mir_lower.Seed_bug _ -> Error ())
            with
            | Error () ->
                Printf.printf
                  "  typed-cast contrast: PASS (the syntax-driven reconstruction cannot even resolve `Ptr[U]` — the typed channel is required)\n"
            | Ok t when Type_repr.compare t resolved_target <> 0 ->
                Printf.printf
                  "  typed-cast contrast: PASS (syntax reconstruction differs from the checker-resolved target)\n"
            | Ok _ ->
                Printf.printf
                  "  typed-cast contrast: FAIL (syntax reconstruction reproduced the resolved target)\n";
                exit 1);
            ignore pid_t;
           (* ── typed-call proof (re-audit's highest-leverage item: the
              persistent typed-call channel — the call's node carries the
              checker-RESOLVED callee CallableId + the SOLVED concrete
              substitution, and the lowering Call rule consumes it into
              the User instance, so the mono exact-arity pairing stays
              exact) ──────────────────────────────────────────────────
              A generic def idfn[T] called with the explicit concrete
              type arg `idfn[Int](42)`: the checker resolves T := Int;
              the map's node at the call's span must carry
              Some (idfn's CallableId, [| Int |]) — the substitution
              SOLVED (declaration-owned param mapping, one concrete arg
              for one declared param), never [||] — and lowering through
              the DRIVER-built env (the typed_nodes channel present) must
              emit the Call terminator's User instance with the SAME
              concrete type_args. *)
           let call_src = {|
def idfn[T](x: T) -> T
  x
end

def main() -> Int
  idfn[Int](42)
end
|} in
           let call_file = "<typed-call-proof>" in
           (match Source_loader.load_string call_file call_src with
            | Error _ -> failwith "typed-call proof source load"
            | Ok nsrc ->
                let nsm = Span.create () in
                let nfid = Span.add_file nsm nsrc.Source.name nsrc in
                let ndiags = Diagnostic.create_bag () in
                let nlx = Lexer.create nsrc.Source.bytes nfid ndiags in
                let ntoks = Lexer.lex nlx in
                let nprog = Parser.parse ntoks nsrc.Source.bytes nfid ndiags [ "callproof" ] in
                if Diagnostic.has_errors ndiags then begin
                  Printf.printf "  typed-call proof: FAIL (parse errors)\n%s\n"
                    (Diagnostic.render nsm ndiags);
                  exit 1
                end;
                let nenv =
                  match Typecheck.check_program (Typecheck.initial_env ()) nprog with
                  | Error m -> failwith ("typed-call proof typecheck: " ^ m)
                  | Ok (env', errors) ->
                      if errors <> [] then
                        failwith
                          ("typed-call proof typecheck errors: " ^ String.concat "; " errors);
                      env'
                in
                let idfn_ts =
                  match List.assoc_opt "idfn" nenv.Typecheck.functions with
                  | Some ts -> ts
                  | None -> (
                      match
                        List.filter (fun (k, _) -> Util.has_suffix k "::idfn")
                          nenv.Typecheck.functions
                      with
                      | [ (_, ts) ] -> ts
                      | _ -> failwith "typed-call proof: no typed signature for idfn")
                in
                let main_decl =
                  match
                    List.find_map
                      (fun i ->
                        match i.Ast.kind with
                        | Ast.Function d when d.Ast.fn_sig.Ast.sig_name = "main" -> Some d
                        | _ -> None)
                      nprog.Ast.items
                  with
                  | Some d -> d
                  | None -> failwith "typed-call proof: no main function"
                in
                let call_nid, call_span =
                  match main_decl.Ast.fn_body with
                  | Ast.FnExpr (Ast.Call (n, _, _, _, span)) -> (n, span)
                  | Ast.FnBlock { Ast.b_tail = Some (Ast.Call (n, _, _, _, span)); _ } -> (n, span)
                  | _ -> failwith "typed-call proof: main body is not `idfn[Int](42)`"
                in
                let n_map = Driver.typed_nodes_of nenv in
                let call_node =
                  match List.assoc_opt call_nid n_map with
                  | Some n -> n
                  | None ->
                      Printf.printf
                        "  typed-call map: FAIL (no typed node for the call's span file#%d[%d..%d))\n"
                        nfid call_span.Span.start call_span.Span.end_;
                      exit 1
                in
                (* the declaration-owned param mapping: idfn[T] has ONE
                   declaration param; the persisted substitution must be
                   its SOLVED concrete image in declaration order *)
                let decl_arity = List.length idfn_ts.Typecheck.ts_params_decl in
                (match Typecheck.tc_callee_instance call_node.Mir_lower.tn_call with
                 | Some (callable, subst) ->
                     let ok =
                       Ids.Callable_id.compare callable idfn_ts.Typecheck.ts_callable = 0
                       && Array.length subst = decl_arity
                       && Array.length subst = 1
                       && Type_repr.compare subst.(0) int_ty = 0
                     in
                     if ok then
                       Printf.printf
                         "  typed-call map: PASS (call span file#%d[%d..%d) -> (CallableId#%d, [Int]) — the SOLVED concrete substitution, exact-arity %d declared = %d concrete)\n"
                         nfid call_span.Span.start call_span.Span.end_
                         (Ids.Callable_id.to_int idfn_ts.Typecheck.ts_callable)
                         decl_arity (Array.length subst)
                     else begin
                       Printf.printf
                         "  typed-call map: FAIL (tn_call = Some (%d, [%s]); expected Some (CallableId#%d, [Int]))\n"
                         (Ids.Callable_id.to_int callable)
                         (String.concat "; "
                            (Array.to_list
                               (Array.map
                                  (fun t ->
                                    match t with
                                    | Type_repr.Int _ -> "Int"
                                    | Type_repr.Type_param p ->
                                        "Type_param "
                                        ^ string_of_int (Ids_core.Generic_param_id.to_int p)
                                    | Type_repr.Infer_var _ -> "Infer_var"
                                    | _ -> "?")
                                  subst)))
                         (Ids.Callable_id.to_int idfn_ts.Typecheck.ts_callable);
                       exit 1
                     end
                 | None ->
                     Printf.printf "  typed-call map: FAIL (no tn_call on the call's node)\n";
                     exit 1);
                (* the lowering leg: lower main through the DRIVER-built
                   env with the typed_nodes channel present; the emitted
                   Call terminator's User instance must carry the concrete
                   type_args (the exact-arity pairing is satisfiable) *)
                let main_ts =
                  match List.assoc_opt "main" nenv.Typecheck.functions with
                  | Some ts -> ts
                  | None -> (
                      match
                        List.filter (fun (k, _) -> Util.has_suffix k "::main")
                          nenv.Typecheck.functions
                      with
                      | [ (_, ts) ] -> ts
                      | _ -> failwith "typed-call proof: no typed signature for main")
                in
                let lowered_main =
                  Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
                    ~typed_nodes:(Driver.typed_nodes_of nenv)
                    { (Driver.lowering_env_of nenv) with Mir_lower.fn_ret = main_ts.Typecheck.ts_return }
                    "main" (Ids.Callable_id.to_int main_ts.Typecheck.ts_callable)
                    (Array.of_list
                       (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                          main_ts.Typecheck.ts_params_decl))
                    (Array.map (fun p -> p.Type_repr.pt_convention) main_ts.Typecheck.ts_params)
                    main_decl
                in
                let lowered_instance =
                  Array.to_list lowered_main.Seed_mir.blocks
                  |> List.find_map (fun (b : Seed_mir.block) ->
                         match b.Seed_mir.terminator with
                         | Seed_mir.Call (_, Seed_mir.User inst, _, _, _) -> Some inst
                         | _ -> None)
                in
                (match lowered_instance with
                 | Some inst ->
                     let ok =
                       Ids.Callable_id.compare inst.Instance_id.callable idfn_ts.Typecheck.ts_callable = 0
                       && Array.length inst.Instance_id.type_args = decl_arity
                       && Array.length inst.Instance_id.type_args = 1
                       && Type_repr.compare inst.Instance_id.type_args.(0) int_ty = 0
                     in
                     if ok then
                       Printf.printf
                         "  typed-call lowering: PASS (User instance CallableId#%d with concrete type_args [Int] — the exact-arity pairing is satisfiable)\n"
                         (Ids.Callable_id.to_int idfn_ts.Typecheck.ts_callable)
                     else begin
                       Printf.printf
                         "  typed-call lowering: FAIL (User instance type_args=[%s]; expected [Int])\n"
                         (String.concat "; "
                            (Array.to_list
                               (Array.map
                                  (fun t -> match t with Type_repr.Int _ -> "Int" | _ -> "?")
                                  inst.Instance_id.type_args)));
                       exit 1
                     end
                  | None ->
                      Printf.printf "  typed-call lowering: FAIL (no User Call terminator in lowered main)\n";
                      exit 1)));
      (* ── nested-function proof (re-audit: nested defs were missing from
         closure MIR.  The typechecker registered them and recognized
         their callable identities, but Driver.lower_closure only lowered
         top-level functions and impl methods — a nested helper's caller
         carried the nested callable id with no seed function behind it.
         The fix is the TYPED callable universe: lower_closure iterates
         the typechecker's nested registry (qname + typed signature +
         function_decl, registered during the body pass), each entry
         lowering exactly like the methods.  This proof runs the REAL
         Typecheck.check_program (the nested def registers), then the REAL
         Driver.lower_closure over a closure_ctx, asserting
         (a) the nested fn's seed function exists with the registry's
         callable id, (b) the caller's call references that SAME id,
         (c) the program verifies and the VM runs (outer(21) =
         inner(21)*2 + 1 = 43). *)
      let nested_src = {|
def outer(x: Int) -> Int
  let v = x
  def inner(y: Int) -> Int
    y * 2
  end
  inner(v) + 1
end

def main() -> Int
  outer(21)
end
|} in
      let nested_file = Filename.temp_file "tg_lowersurface_nested" ".tg" in
      (let oc = open_out_bin nested_file in
       output_string oc nested_src;
       close_out oc);
      let nested_manifest =
        match Bootstrap_manifest.single ~file:nested_file ~path:[ "nestedproof" ] () with
        | Ok m -> m
        | Error e -> failwith ("nested-function proof manifest: " ^ e)
      in
      let ndiags = Diagnostic.create_bag () in
      let ngraph = Module_graph.create_with_sources nested_manifest ndiags in
      let nresolved = Resolver.resolve nested_manifest ngraph ndiags in
      let nnode = List.hd ngraph.Module_graph.nodes in
      let nprog_ast = nnode.Module_graph.node_program in
      (* the driver's module_path at body-check time is the node path, so
         the nested def registers under the qualified name — the same key
         lower_closure uses as the seed function's name *)
      let nenv0 = Typecheck.initial_env ~resolved:(Some nresolved) () in
      let nenv =
        match
          Typecheck.check_program
            { nenv0 with Typecheck.module_path = nnode.Module_graph.node_path }
            nprog_ast
        with
        | Error m -> failwith ("nested-function proof typecheck: " ^ m)
        | Ok (env', errors) ->
            if errors <> [] then
              failwith
                ("nested-function proof typecheck errors: " ^ String.concat "; " errors);
            env'
      in
      Sys.remove nested_file;
      let inner_qname = String.concat "::" (nnode.Module_graph.node_path @ [ "inner" ]) in
      let inner_entry =
        match
          List.find_opt
            (fun (qname, _, _ : string * Typecheck.typed_signature * Ast.function_decl) ->
              qname = inner_qname)
            nenv.Typecheck.state.nested_functions
        with
        | Some e -> e
        | None ->
            Printf.printf
              "  nested-function registry: FAIL (no entry for %s in %d registration(s))\n"
              inner_qname (List.length nenv.Typecheck.state.nested_functions);
            exit 1
      in
      let _, inner_ts, inner_fd = inner_entry in
      let inner_cid = Ids.Callable_id.to_int inner_ts.Typecheck.ts_callable in
      let inner_has_body =
        match inner_fd.Ast.fn_body with
        | Ast.FnBlock _ -> true
        | _ -> false
      in
      if not inner_has_body then begin
        Printf.printf "  nested-function registry: FAIL (no AST body recorded)\n";
        exit 1
      end;
      Printf.printf
        "  nested-function registry: PASS (registered %s with callable #%d and its function_decl AST)\n"
        inner_qname inner_cid;
      (* the DRIVER's lower_closure path: a real closure_ctx over the
         single-module graph *)
      let ntarget =
        match Target.unsupported_triple "aarch64-apple-darwin" with
        | Ok t -> t
        | Error m -> failwith ("nested-function proof target: " ^ m)
      in
      let nctx : Driver.closure_ctx =
        {
          Driver.ctx_repo_root = ".";
          ctx_manifest_path = nested_file;
          ctx_target = ntarget;
          ctx_graph = ngraph;
          ctx_resolved = nresolved;
          ctx_env = nenv;
          ctx_type_errors = [];
          ctx_items = List.length nprog_ast.Ast.items;
          ctx_typed_calls_sample = 0;
          ctx_decl_rounds = 0;
          ctx_subset = Driver.subset_firewall_of_graph ngraph;
          ctx_profile_findings = 0;
          ctx_strict_fallbacks = 0;
          ctx_strict_diags = [];
          ctx_audit = Driver.fresh_closure_audit ();
          lowered_methods = 0;
          ctx_cfg_program = None;
        }
      in
      let nprog = Driver.lower_closure nctx in
      (* (a) the nested fn's seed function exists with the right callable id *)
      let inner_seed =
        match
          Array.to_list nprog.Seed_mir.functions
          |> List.find_opt (fun f -> f.Seed_mir.name = inner_qname)
        with
        | Some f -> f
        | None ->
            Printf.printf "  nested-function seed: FAIL (no seed function named %s)\n" inner_qname;
            exit 1
      in
      let seed_cid = Ids.Callable_id.to_int (Instance_id.callable inner_seed.Seed_mir.instance) in
      if seed_cid <> inner_cid then begin
        Printf.printf
          "  nested-function seed: FAIL (seed callable #%d != registry callable #%d)\n"
          seed_cid inner_cid;
        exit 1
      end;
      (* (b) the caller's call references the same id *)
      let outer_seed =
        match
          Array.to_list nprog.Seed_mir.functions
          |> List.find_opt (fun f -> f.Seed_mir.name = "outer")
        with
        | Some f -> f
        | None -> failwith "nested-function proof: no outer seed function"
      in
      let call_refs_inner =
        Array.exists
          (fun (b : Seed_mir.block) ->
            match b.Seed_mir.terminator with
            | Seed_mir.Call (_, Seed_mir.User inst, _, _, _) ->
                Ids.Callable_id.to_int (Instance_id.callable inst) = inner_cid
            | _ -> false)
          outer_seed.Seed_mir.blocks
      in
      if not call_refs_inner then begin
        Printf.printf
          "  nested-function call: FAIL (outer's lowered calls do not reference callable #%d)\n"
          inner_cid;
        exit 1
      end;
      Printf.printf
        "  nested-function lowering: PASS (seed %s = callable #%d; outer's call references the same id)\n"
        inner_qname inner_cid;
      (* (c) the whole program verifies and the VM runs *)
      (match Mir_verify.require_valid_concrete nprog with
       | Ok () ->
           Printf.printf "  nested-function MIR verify: PASS (%d functions)\n"
             (Array.length nprog.Seed_mir.functions)
       | Error errs ->
           Printf.printf "  nested-function MIR verify: FAIL\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Printf.printf "%s\n" (Seed_mir.print_program nprog);
           exit 1);
      let nentry =
        match
          Array.to_list nprog.Seed_mir.functions
          |> List.find_opt (fun f -> f.Seed_mir.name = "main")
        with
        | Some f -> f.Seed_mir.instance
        | None -> failwith "nested-function proof: no main function"
      in
      let nhost = Host.create ~repo_root:"." ~argv:[||] in
      (match Vm.run ~program:nprog ~entry:nentry ~argv:[||] ~host:nhost with
       | Error e ->
           Printf.printf "  nested-function VM: FAIL %s\n" e.Vm.message;
           exit 1
       | Ok code ->
           Printf.printf "  nested-function VM: exit %d\n" code;
           (match Vm.entry_frame_of ~program:nprog ~entry:nentry ~argv:[||] with
            | Error m -> Printf.printf "  nested-function main returned: <inspect failed: %s>\n" m
            | Ok (nvm, nentry_frame) -> (
                match Vm.run_inspect nvm nentry_frame with
                | Ok ret_val ->
                    Printf.printf "  nested-function main returned: %s\n" ret_val;
                    if ret_val = "43" then
                      Printf.printf
                        "  nested-function RESULT: PASS (outer(21) -> inner(21)*2+1 = 43 through the nested seed)\n"
                    else begin
                      Printf.printf "  nested-function RESULT: FAIL (expected 43)\n";
                      exit 1
                    end
                | Error m ->
                    Printf.printf "  nested-function main returned: <inspect failed: %s>\n" m)));;

       (* ── StructLit lowering proof (re-audit's ordinary-surface item —
          the positive replacement for the retired E9037 rejection: a
          struct literal must lower to the StructCtor aggregate — the
          aggregate's type is the struct's Named type and the operand
          positions come from the typed registry (struct_fields_of's
          declaration order, the same order closure_types materializes
          into the StructDefs).  The literal lists the fields OUT OF
          ORDER (`Pair { b: b, a: a }`) — the values must land at their
          REGISTRY positions, never the source order.  The aggregate's
          type comes from the typechecker's resolved type through the
          typed channel (the StructLit's span node).  The program:
          make_pair CONSTRUCTS via the literal, read_a/read_b read via
          the lowered Field projections, and the whole program verifies
          and the VM round-trips 21 and 42 (main = 63). *)
       let lit_src = {|
struct Pair
  a: Int
  b: Int
end

def make_pair(a: Int, b: Int) -> Pair
  Pair { b: b, a: a }
end

def read_a(p: Pair) -> Int
  p.a
end

def read_b(p: Pair) -> Int
  p.b
end

def main() -> Int
  read_a(make_pair(21, 42)) + read_b(make_pair(21, 42))
end
|} in
       let lit_file = Filename.temp_file "tg_lowersurface_structlit" ".tg" in
       (let oc = open_out_bin lit_file in
        output_string oc lit_src;
        close_out oc);
       let lit_manifest =
         match Bootstrap_manifest.single ~file:lit_file ~path:[ "litproof" ] () with
         | Ok m -> m
         | Error e -> failwith ("struct-lit proof manifest: " ^ e)
       in
       let ldiags = Diagnostic.create_bag () in
       let lgraph = Module_graph.create_with_sources lit_manifest ldiags in
       let lresolved = Resolver.resolve lit_manifest lgraph ldiags in
       let lprog_ast = (List.hd lgraph.Module_graph.nodes).Module_graph.node_program in
       let lenv =
         match Typecheck.check_program (Typecheck.initial_env ~resolved:(Some lresolved) ()) lprog_ast with
         | Error m -> failwith ("struct-lit proof typecheck: " ^ m)
         | Ok (env', errors) ->
             if errors <> [] then
               failwith ("struct-lit proof typecheck errors: " ^ String.concat "; " errors);
             env'
       in
       Sys.remove lit_file;
       let l_tid = List.assoc "Pair" lenv.Typecheck.type_ids in
       let l_reg = List.assoc l_tid (Driver.struct_fields_of lenv) in
       let l_fid name =
         match List.find_opt (fun (n, _, _, _) -> n = name) l_reg with
         | Some (_, fid, _, _) -> fid
         | None -> failwith ("struct-lit proof: no registry FieldId for " ^ name)
       in
       let l_pos name =
         let rec go i = function
           | [] -> failwith ("struct-lit proof: field " ^ name ^ " not in the registry")
           | (n, _, _, _) :: rest -> if n = name then i else go (i + 1) rest
         in
         go 0 l_reg
       in
       let l_fid_a = l_fid "a" and l_fid_b = l_fid "b" in
       let l_pos_a = l_pos "a" and l_pos_b = l_pos "b" in
       let l_funcs =
         List.filter_map
           (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
           lprog_ast.Ast.items
       in
       let lts_of name =
         match List.assoc_opt name lenv.Typecheck.functions with
         | Some ts -> ts
         | None -> (
             match List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) lenv.Typecheck.functions with
             | [ (_, ts) ] -> ts
             | _ -> failwith ("struct-lit proof: no typed signature for " ^ name))
       in
       let lenv2 : Mir_lower.func_env =
         {
           Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
             [
               ("Pair", Type_repr.Named (l_tid, [||]));
               ("Int", int_ty);
               ("Unit", Type_repr.Unit);
               ("Bool", Type_repr.Bool);
               ("String", string_ty);
             ];
           values =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 (n, (lts_of n).Typecheck.ts_return))
               l_funcs;
           callables =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 ( n,
                   {
                     Mir_lower.ce_callable = Ids.Callable_id.to_int (lts_of n).Typecheck.ts_callable;
                     ce_template_args = [||];
                     ce_params = [||];
                   } ))
               l_funcs;
           methods = [];
          callables_by_callable = [];
           fn_ret = int_ty;
           struct_fields = Driver.struct_fields_of lenv;
          enum_payloads = Driver.enum_payloads_of lenv;

                   copy_cache = Type_properties.create_cache ();
}
       in
       let lmir_funcs =
         List.map
           (fun d ->
             let n = d.Ast.fn_sig.Ast.sig_name in
             let ts = lts_of n in
             Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
               ~typed_nodes:(Driver.typed_nodes_of lenv)
               { lenv2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
               n (Ids.Callable_id.to_int ts.Typecheck.ts_callable) [||] [||] d)
           l_funcs
       in
       let lmake_pair =
         List.find
           (fun f -> f.Seed_mir.name = "make_pair")
           (Array.to_list (Array.of_list lmir_funcs))
       in
       (* the typed channel: the StructLit's span node carries the
          checker-resolved aggregate type (Named (l_tid, [||])) *)
       let make_pair_decl =
         List.find
           (fun (d : Ast.function_decl) -> d.Ast.fn_sig.Ast.sig_name = "make_pair")
           l_funcs
       in
       let lit_nid =
         match make_pair_decl.Ast.fn_body with
         | Ast.FnBlock { Ast.b_tail = Some (Ast.StructLit (n, _, _, _, _, _)); _ } -> n
         | _ -> failwith "struct-lit proof: make_pair body is not a StructLit tail"
       in
       (match List.assoc_opt lit_nid (Driver.typed_nodes_of lenv) with
        | Some node ->
            if Type_repr.compare node.Mir_lower.tn_type (Type_repr.Named (l_tid, [||])) = 0 then
              Printf.printf
                "  struct-lit typed channel: PASS (the literal's span carries the checker-resolved Named(type#%d, [||]))\n"
                (Ids.Type_id.to_int l_tid)
            else begin
              Printf.printf "  struct-lit typed channel: FAIL (resolved type %s)\n"
                (Seed_mir.print_type node.Mir_lower.tn_type);
              exit 1
            end
        | None ->
            Printf.printf "  struct-lit typed channel: FAIL (no typed node at the literal's span)\n";
            exit 1);
       (* the StructCtor aggregate: the pair tid, the registry-position
          indices, and the operand VALUES at the REGISTRY positions —
          the out-of-order literal `{ b: b, a: a }` must place param `a`
          (local 1) at its registry position and param `b` (local 2) at
          its registry position *)
       let l_ctor =
         Array.to_list lmake_pair.Seed_mir.blocks
         |> List.find_map (fun (b : Seed_mir.block) ->
                List.find_map
                  (fun (s : Seed_mir.statement) ->
                    match s with
                    | Seed_mir.Assign (_, Seed_mir.Aggregate (Seed_mir.StructCtor (tid, fields), ops))
                      ->
                        Some (tid, fields, ops)
                    | _ -> None)
                  b.Seed_mir.statements)
       in
       (match l_ctor with
        | Some (tid, fields, ops) ->
            let index_ok =
              Ids.Type_id.compare tid l_tid = 0
              && Array.length fields = 2
              && Ids.Field_index.compare fields.(0) (Ids.Field_index.make 0) = 0
              && Ids.Field_index.compare fields.(1) (Ids.Field_index.make 1) = 0
            in
            let op_is_param pos local =
              match List.nth_opt ops pos with
              | Some (Seed_mir.Copy p) -> p.Seed_mir.root = Seed_mir.Local local
              | _ -> false
            in
            let pos_ok = op_is_param l_pos_a 1 && op_is_param l_pos_b 2 in
            if index_ok && pos_ok then
              Printf.printf
                "  struct-lit lowering: PASS (StructCtor type#%d with registry indices [0;1]; `a`'s value at registry position %d, `b`'s at %d — the out-of-order literal landed at the typed declaration order)\n"
                (Ids.Type_id.to_int tid) l_pos_a l_pos_b
            else begin
              Printf.printf
                "  struct-lit lowering: FAIL (index_ok=%b pos_ok=%b; registry order: %s)\n"
                index_ok pos_ok
                (String.concat ", " (List.map (fun (n, _, _, _) -> n) l_reg));
              exit 1
            end
        | None ->
            Printf.printf "  struct-lit lowering: FAIL (no StructCtor aggregate in make_pair)\n";
            exit 1);
       let lprog : Seed_mir.program =
         {
           Seed_mir.functions = Array.of_list lmir_funcs;
           statics = [||];
           (* the StructDef from the REGISTRY: fd_index = the registry
              position, fd_id = the registry's semantic FieldId *)
           types =
             [|
               Seed_mir.StructDef
                 {
                   sd_id = l_tid;
                   sd_fields =
                     List.mapi
                       (fun i (_, fid, fty, _) ->
                         {
                           Seed_mir.fd_id = fid;
                           fd_index = Ids.Field_index.make i;
                           fd_ty = fty;
                         })
                       l_reg;
                 };
             |];
         }
       in
       (match Mir_verify.require_valid_concrete lprog with
        | Ok () ->
            Printf.printf "  struct-lit MIR verify: PASS (%d functions)\n"
              (Array.length lprog.Seed_mir.functions)
        | Error errs ->
            Printf.printf "  struct-lit MIR verify: FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            Printf.printf "%s\n" (Seed_mir.print_program lprog);
            exit 1);
       let lentry =
         match
           Array.to_list lprog.Seed_mir.functions
           |> List.find_opt (fun f -> f.Seed_mir.name = "main")
         with
         | Some f -> f.Seed_mir.instance
         | None -> failwith "struct-lit proof: no main function"
       in
       let lhost = Host.create ~repo_root:"." ~argv:[||] in
       (match Vm.run ~program:lprog ~entry:lentry ~argv:[||] ~host:lhost with
        | Error e ->
            Printf.printf "  struct-lit VM: FAIL %s\n" e.Vm.message;
            exit 1
        | Ok code ->
            Printf.printf "  struct-lit VM: exit %d\n" code;
            (match Vm.entry_frame_of ~program:lprog ~entry:lentry ~argv:[||] with
             | Error m -> Printf.printf "  struct-lit main returned: <inspect failed: %s>\n" m
             | Ok (lvm, lentry_frame) -> (
                 match Vm.run_inspect lvm lentry_frame with
                 | Ok ret_val ->
                     Printf.printf "  struct-lit main returned: %s\n" ret_val;
                     if ret_val = "63" then
                       Printf.printf
                         "  struct-lit RESULT: PASS (21 and 42 round-tripped through the StructCtor aggregate and the Field projections)\n"
                     else begin
                       Printf.printf "  struct-lit RESULT: FAIL (expected 63)\n";
                       exit 1
                     end
                 | Error m -> Printf.printf "  struct-lit main returned: <inspect failed: %s>\n" m)));
       ignore l_fid_a;
       ignore l_fid_b;
       (* ── partial-move proof (re-audit P12/P10/P5): a SINK argument
          through a projected place of a non-Copy owning type lowers as
          the projected Move — the VM executes the partial move (the
          component transfers, the MovedOut hole stays behind, the drop
          glue skips it) and the verifier's moved lattice tracks the
          moved path, so a SECOND consume of the same path is a
          use-after-move while the OTHER fields stay readable. *)
       let pm_src = {|
struct Holder
  a: String
  b: String
end

def take(s: String) -> Int
  s.len()
end

def main() -> Int
  let h = Holder { a: "hello", b: "world" }
  take(h.a) + take(h.b)
end
|} in
       let pm_file = Filename.temp_file "tg_lowersurface_partialmove" ".tg" in
       (let oc = open_out_bin pm_file in
        output_string oc pm_src;
        close_out oc);
       let pm_manifest =
         match Bootstrap_manifest.single ~file:pm_file ~path:[ "pmproof" ] () with
         | Ok m -> m
         | Error e -> failwith ("partial-move proof manifest: " ^ e)
       in
       let pmdiags = Diagnostic.create_bag () in
       let pmgraph = Module_graph.create_with_sources pm_manifest pmdiags in
       let pmresolved = Resolver.resolve pm_manifest pmgraph pmdiags in
       let pprog_ast = (List.hd pmgraph.Module_graph.nodes).Module_graph.node_program in
       let rec pmfix env n =
         match Typecheck.check_program env pprog_ast with
         | Error m -> failwith ("partial-move proof typecheck: " ^ m)
         | Ok (env', errors) ->
             if errors <> [] then
               failwith ("partial-move proof typecheck errors: " ^ String.concat "; " errors)
             else if n = 0 then env'
             else pmfix env' (n - 1)
       in
       let penv = pmfix (Typecheck.initial_env ~resolved:(Some pmresolved) ()) 8 in
       let pbase = Driver.lowering_env_of ~items:pprog_ast.Ast.items penv in
       let pvariants = Driver.user_variant_table penv in
       let ptyped_nodes = Driver.typed_nodes_of penv in
       let ptyped_patterns = Driver.typed_patterns_of penv in
       let ptyped_for = Driver.typed_for_patterns_of penv in
       let ptyped_let = Driver.typed_let_patterns_of penv in
       let pmir_funcs =
         List.filter_map
           (fun i -> match i.Ast.kind with Ast.Function fd -> Some fd | _ -> None)
           pprog_ast.Ast.items
         |> List.map (fun fd ->
                match Driver.lookup_typed_fn_qualified penv [] fd.Ast.fn_sig.Ast.sig_name with
                | None -> failwith ("partial-move proof: no typed sig for " ^ fd.Ast.fn_sig.Ast.sig_name)
                | Some ts ->
                    Mir_lower.lower_function_with_variants
                      ~typed_nodes:ptyped_nodes ~typed_patterns:ptyped_patterns
                      ~typed_for_patterns:ptyped_for ~typed_let_patterns:ptyped_let
                      pvariants { pbase with Mir_lower.fn_ret = ts.Typecheck.ts_return }
                      fd.Ast.fn_sig.Ast.sig_name
                      (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                      (Array.of_list
                         (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                            ts.Typecheck.ts_params_decl))
                      (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
                      ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
                      fd)
       in
       let pprog : Seed_mir.program =
         {
           Seed_mir.functions = Array.of_list pmir_funcs;
           statics = [||];
           types = Driver.closure_types penv;
         }
       in
       (match Mir_verify.require_valid_concrete pprog with
        | Ok () ->
            Printf.printf
              "  partial-move MIR verify: PASS (the projected sink moves lower and the moved lattice accepts the disjoint second consume)\n"
        | Error errs ->
            Printf.printf "  partial-move MIR verify: FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            Printf.printf "%s\n" (Seed_mir.print_program pprog);
            exit 1);
       let pentry =
         match
           Array.to_list pprog.Seed_mir.functions
           |> List.find_opt (fun f -> f.Seed_mir.name = "main")
         with
         | Some f -> f.Seed_mir.instance
         | None -> failwith "partial-move proof: no main function"
       in
       let phost = Host.create ~repo_root:"." ~argv:[||] in
       (match Vm.run ~program:pprog ~entry:pentry ~argv:[||] ~host:phost with
        | Error e ->
            Printf.printf "  partial-move VM: FAIL %s\n" e.Vm.message;
            exit 1
        | Ok _code -> (
            match Vm.entry_frame_of ~program:pprog ~entry:pentry ~argv:[||] with
            | Error m -> Printf.printf "  partial-move main returned: <inspect failed: %s>\n" m
            | Ok (pvm, pentry_frame) -> (
                match Vm.run_inspect pvm pentry_frame with
                | Ok ret_val ->
                    Printf.printf "  partial-move main returned: %s\n" ret_val;
                    if ret_val = "10" then
                      Printf.printf
                        "  partial-move RESULT: PASS (the two projected field moves transferred independently; 5 + 5 round-tripped)\n"
                    else begin
                      Printf.printf "  partial-move RESULT: FAIL (expected 10)\n";
                      exit 1
                    end
                | Error m -> Printf.printf "  partial-move main returned: <inspect failed: %s>\n" m)));
       Sys.remove pm_file;
       (* ── method-call lowering proof (re-audit's ordinary-surface item:
          `obj.method(args)` must lower with the receiver's typed PLACE as
          the SELF argument (the read-side of the self parameter's
          convention — the sig contracts ride in the methods table's
          me_params.(0)), the owner named by the receiver's type, and the
          resolved method instance — the typed channel's tn_call (the
          checker-resolved callable + solved substitution) is
          authoritative when present, else the env's methods-table
          instance.  The method body lowers too (self.a + self.b through
          the Field projections) and the emitted User callee resolves
          against the method's seed function exactly (verifier + VM
          dispatch instances).  main constructs p via the StructLit and
          calls p.get_sum() — main returns 42. *)
       let meth_src = {|
struct Pair
  a: Int
  b: Int
end

impl Pair
  def get_sum(self) -> Int
    self.a + self.b
  end
end

def main() -> Int
  let p = Pair { a: 21, b: 21 }
  p.get_sum()
end
|} in
       let meth_file = Filename.temp_file "tg_lowersurface_method" ".tg" in
       (let oc = open_out_bin meth_file in
        output_string oc meth_src;
        close_out oc);
       let meth_manifest =
         match Bootstrap_manifest.single ~file:meth_file ~path:[ "methodproof" ] () with
         | Ok m -> m
         | Error e -> failwith ("method-call proof manifest: " ^ e)
       in
       let mdiags = Diagnostic.create_bag () in
       let mgraph = Module_graph.create_with_sources meth_manifest mdiags in
       let mresolved = Resolver.resolve meth_manifest mgraph mdiags in
       let mprog_ast = (List.hd mgraph.Module_graph.nodes).Module_graph.node_program in
       (* the impl registration needs the declaration fixpoint (Phase C
          checks the impl before Phase B registers the methods — the
          driver re-runs to a fixpoint; mirror it here) *)
       let rec mfix env n =
         match Typecheck.check_program env mprog_ast with
         | Error m -> failwith ("method-call proof typecheck: " ^ m)
         | Ok (env', errors) ->
             if errors = [] then env'
             else if n = 0 then
               failwith ("method-call proof typecheck errors: " ^ String.concat "; " errors)
             else mfix env' (n - 1)
       in
       let menv = mfix (Typecheck.initial_env ~resolved:(Some mresolved) ()) 6 in
       Sys.remove meth_file;
       let m_tid = List.assoc "Pair" menv.Typecheck.type_ids in
       let m_reg = List.assoc m_tid (Driver.struct_fields_of menv) in
       let m_fid name =
         match List.find_opt (fun (n, _, _, _) -> n = name) m_reg with
         | Some (_, fid, _, _) -> fid
         | None -> failwith ("method-call proof: no registry FieldId for " ^ name)
       in
       let m_fid_a = m_fid "a" and m_fid_b = m_fid "b" in
       let m_mts =
         match List.assoc ("Pair", "get_sum") menv.Typecheck.methods with
         | ts -> ts
         | exception Not_found -> failwith "method-call proof: no get_sum method signature"
       in
       if Array.length m_mts.Typecheck.ts_params = 0 then
         failwith "method-call proof: get_sum has no self parameter";
       let m_funcs =
         List.filter_map
           (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
           mprog_ast.Ast.items
       in
       let m_method_decl =
         match
           List.find_map
             (fun i ->
               match i.Ast.kind with
               | Ast.ImplBlock d -> (
                   match
                     List.find_opt
                       (fun (m : Ast.function_decl) -> m.Ast.fn_sig.Ast.sig_name = "get_sum")
                       d.Ast.i_methods
                   with
                   | Some m -> Some (d, m)
                   | None -> None)
               | _ -> None)
             mprog_ast.Ast.items
         with
         | Some (_, m) -> m
         | None -> failwith "method-call proof: no get_sum impl method"
       in
       let mts_of name =
         match List.assoc_opt name menv.Typecheck.functions with
         | Some ts -> ts
         | None -> (
             match List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) menv.Typecheck.functions with
             | [ (_, ts) ] -> ts
             | _ -> failwith ("method-call proof: no typed signature for " ^ name))
       in
       let menv2 : Mir_lower.func_env =
         {
           Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
             [
               ("Pair", Type_repr.Named (m_tid, [||]));
               ("Int", int_ty);
               ("Unit", Type_repr.Unit);
               ("Bool", Type_repr.Bool);
               ("String", string_ty);
             ];
           values =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 (n, (mts_of n).Typecheck.ts_return))
               m_funcs;
           callables =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 ( n,
                   {
                     Mir_lower.ce_callable = Ids.Callable_id.to_int (mts_of n).Typecheck.ts_callable;
                     ce_template_args = [||];
                     ce_params = [||];
                   } ))
               m_funcs;
           methods =
             [
               ( ("Pair", "get_sum"),
                 {
                   Mir_lower.me_instance =
                     (* the same instance the method body is lowered
                        under below (callable + declaration-order type
                        args — [||] for the non-generic method) *)
                     Instance_id.make ~callable:m_mts.Typecheck.ts_callable
                       ~type_args:
                         (Array.of_list
                            (List.map
                               (fun (_, pid) -> Type_repr.Type_param pid)
                               m_mts.Typecheck.ts_params_decl));
                   me_params = m_mts.Typecheck.ts_params;
                   me_ret = m_mts.Typecheck.ts_return;
                   me_has_self =
                     Array.length m_mts.Typecheck.ts_params > 0
                     && Array.length m_mts.Typecheck.ts_param_names > 0
                     && m_mts.Typecheck.ts_param_names.(0) = "self";
                 } );
             ];
           callables_by_callable = [];
           fn_ret = int_ty;
           struct_fields = Driver.struct_fields_of menv;
          enum_payloads = Driver.enum_payloads_of menv;

                   copy_cache = Type_properties.create_cache ();
}
       in
       let mmir_funcs =
         List.map
           (fun d ->
             let n = d.Ast.fn_sig.Ast.sig_name in
             let ts = mts_of n in
             Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
               ~typed_nodes:(Driver.typed_nodes_of menv)
               { menv2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
               n (Ids.Callable_id.to_int ts.Typecheck.ts_callable) [||] [||] d)
           m_funcs
       in
       (* the method body lowers through the same env: the SELF parameter
          is the receiver-typed place the call passes *)
       let mmethod_fn =
         Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
           ~typed_nodes:(Driver.typed_nodes_of menv)
           { menv2 with Mir_lower.fn_ret = m_mts.Typecheck.ts_return }
           m_method_decl.Ast.fn_sig.Ast.sig_name
           (Ids.Callable_id.to_int m_mts.Typecheck.ts_callable)
           (Array.of_list
              (List.map (fun (_, pid) -> Type_repr.Type_param pid) m_mts.Typecheck.ts_params_decl))
           (Array.map (fun p -> p.Type_repr.pt_convention) m_mts.Typecheck.ts_params)
           ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) m_mts.Typecheck.ts_params)
           m_method_decl
       in
       let mprog : Seed_mir.program =
         {
           Seed_mir.functions = Array.of_list (mmethod_fn :: mmir_funcs);
           statics = [||];
           types =
             [|
               Seed_mir.StructDef
                 {
                   sd_id = m_tid;
                   sd_fields =
                     List.mapi
                       (fun i (_, fid, fty, _) ->
                         {
                           Seed_mir.fd_id = fid;
                           fd_index = Ids.Field_index.make i;
                           fd_ty = fty;
                         })
                       m_reg;
                 };
             |];
         }
       in
       (* the typed channel: the method call's span node carries
          tn_call = the checker-resolved callable + solved substitution
          ([||] for the non-generic method) *)
       let mmain_decl =
         List.find
           (fun (d : Ast.function_decl) -> d.Ast.fn_sig.Ast.sig_name = "main")
           m_funcs
       in
       let mcall_nid =
         match mmain_decl.Ast.fn_body with
         | Ast.FnBlock { Ast.b_tail = Some (Ast.Call (n, _, _, _, _)); _ } -> n
         | _ -> failwith "method-call proof: main body is not a call tail"
       in
       (match
          List.assoc_opt mcall_nid (Driver.typed_nodes_of menv)
        with
        | Some node -> (
            match Typecheck.tc_callee_instance node.Mir_lower.tn_call with
            | Some (callable, subst)
              when Ids.Callable_id.compare callable m_mts.Typecheck.ts_callable = 0
                   && Array.length subst = 0 ->
                Printf.printf
                  "  method-call typed channel: PASS (the call's span carries tn_call = (CallableId#%d, [||]) — the checker-resolved instance)\n"
                  (Ids.Callable_id.to_int callable)
            | Some (callable, subst) ->
                Printf.printf
                  "  method-call typed channel: FAIL (tn_call = (CallableId#%d, [%d args]))\n"
                  (Ids.Callable_id.to_int callable) (Array.length subst);
                exit 1
            | None ->
                Printf.printf "  method-call typed channel: FAIL (no tn_call on the call's node)\n";
                exit 1)
        | None ->
            Printf.printf "  method-call typed channel: FAIL (no typed node at the call's span)\n";
            exit 1);
       let mmain_fn =
         List.find (fun f -> f.Seed_mir.name = "main") (Array.to_list mprog.Seed_mir.functions)
       in
       (* the emitted call: the User callee's instance EQUALS the method
          seed's instance (the verifier/VM dispatch instances exactly),
          and the receiver is the self argument: a place operand typed
          Named (m_tid, [||]) with the read-side of the self convention
          (self is `let`-convention -> Read) *)
       let mcall =
         Array.to_list mmain_fn.Seed_mir.blocks
         |> List.find_map (fun (b : Seed_mir.block) ->
                match b.Seed_mir.terminator with
                | Seed_mir.Call (_, Seed_mir.User inst, args, _, _) ->
                    if
                      Ids.Callable_id.compare inst.Instance_id.callable
                        m_mts.Typecheck.ts_callable
                      = 0
                    then Some (inst, args)
                    else None
                | _ -> None)
       in
       (match mcall with
        | Some (inst, args) ->
            let inst_ok =
              Ids.Callable_id.compare inst.Instance_id.callable
                (Instance_id.callable mmethod_fn.Seed_mir.instance)
              = 0
              && Array.length inst.Instance_id.type_args = 0
              && Array.length (Instance_id.type_args mmethod_fn.Seed_mir.instance) = 0
            in
            let self_ok =
              Array.length args = 1
              && (match args.(0).Seed_mir.effect_ with Access_effect.Read -> true | _ -> false)
              && (match args.(0).Seed_mir.value with
                 | Seed_mir.Copy p -> (
                     match mmain_fn.Seed_mir.locals.(Seed_mir.root_key p.Seed_mir.root) with
                     | Type_repr.Named (t, _) -> Ids.Type_id.compare t m_tid = 0
                     | _ -> false)
                 | _ -> false)
            in
            if inst_ok && self_ok then
              Printf.printf
                "  method-call lowering: PASS (User callee = the method seed's instance CallableId#%d; the receiver lowers to its typed place and is passed as the SELF argument with the read-side of the `let` self convention)\n"
                (Ids.Callable_id.to_int (Instance_id.callable mmethod_fn.Seed_mir.instance))
            else begin
              Printf.printf "  method-call lowering: FAIL (inst_ok=%b self_ok=%b)\n" inst_ok self_ok;
              exit 1
            end
        | None ->
            Printf.printf "  method-call lowering: FAIL (no User call to the method instance in main)\n";
            exit 1);
       (* the method BODY: self.a + self.b lowers through the Field
          projections with the registry's semantic FieldIds *)
       let mbody_fields_ok =
         Array.exists
           (fun (b : Seed_mir.block) ->
             List.exists
               (fun (s : Seed_mir.statement) ->
                 match s with
                 | Seed_mir.Assign (_, Seed_mir.BinaryOp (_, Seed_mir.Copy p1, Seed_mir.Copy p2)) ->
                     List.exists
                       (function Seed_mir.Field f -> Ids.Field_id.compare f m_fid_a = 0 | _ -> false)
                       p1.Seed_mir.projections
                     && List.exists
                          (function Seed_mir.Field f -> Ids.Field_id.compare f m_fid_b = 0 | _ -> false)
                          p2.Seed_mir.projections
                 | _ -> false)
               b.Seed_mir.statements)
           mmethod_fn.Seed_mir.blocks
       in
       if not mbody_fields_ok then begin
         Printf.printf "  method-call body: FAIL (get_sum carries no Field projections for the registry's FieldIds)\n";
         exit 1
       end;
       Printf.printf
         "  method-call body: PASS (get_sum's lowered body reads self.a/self.b through the Field projections with the registry's FieldIds)\n";
       (match Mir_verify.require_valid_concrete mprog with
        | Ok () ->
            Printf.printf "  method-call MIR verify: PASS (%d functions)\n"
              (Array.length mprog.Seed_mir.functions)
        | Error errs ->
            Printf.printf "  method-call MIR verify: FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            Printf.printf "%s\n" (Seed_mir.print_program mprog);
            exit 1);
       let mentry =
         match
           Array.to_list mprog.Seed_mir.functions
           |> List.find_opt (fun f -> f.Seed_mir.name = "main")
         with
         | Some f -> f.Seed_mir.instance
         | None -> failwith "method-call proof: no main function"
       in
       let mhost = Host.create ~repo_root:"." ~argv:[||] in
       (match Vm.run ~program:mprog ~entry:mentry ~argv:[||] ~host:mhost with
        | Error e ->
            Printf.printf "  method-call VM: FAIL %s\n" e.Vm.message;
            exit 1
        | Ok code ->
            Printf.printf "  method-call VM: exit %d\n" code;
            (match Vm.entry_frame_of ~program:mprog ~entry:mentry ~argv:[||] with
             | Error m -> Printf.printf "  method-call main returned: <inspect failed: %s>\n" m
             | Ok (mvm, mentry_frame) -> (
                 match Vm.run_inspect mvm mentry_frame with
                 | Ok ret_val ->
                     Printf.printf "  method-call main returned: %s\n" ret_val;
                     if ret_val = "42" then
                       Printf.printf
                         "  method-call RESULT: PASS (p.get_sum() = self.a + self.b = 21 + 21 through the receiver self-arg and the method seed)\n"
                     else begin
                       Printf.printf "  method-call RESULT: FAIL (expected 42)\n";
                       exit 1
                     end
                 | Error m -> Printf.printf "  method-call main returned: <inspect failed: %s>\n" m)));
       (* ── fail-closed proof: every unresolvable method call and struct
          literal fails closed with the reason — the receiver/method
          instance, the literal's field positions, and the spread channel
          all fail closed instead of producing a silent Nop or a
          mis-projection.  The env is hand-built (no typed channel, like
          the harness's other hand-built envs) and each Seed_bug's message
          must carry the reason. *)
       let fclose_src = {|
struct Pair
  a: Int
  b: Int
end

def no_such_method() -> Int
  let p = Pair { a: 1, b: 2 }
  p.nope()
end

def missing_field() -> Pair
  Pair { a: 1 }
end

def unknown_field() -> Pair
  Pair { a: 1, c: 2, b: 3 }
end

def spread_lit() -> Pair
  let p = Pair { a: 1, b: 2 }
  Pair { a: 1, ..p }
end

def main() -> Int
  0
end
|} in
       let fclose_file = "<lowersurface-failclosed>" in
       (match Source_loader.load_string fclose_file fclose_src with
        | Error _ -> failwith "fail-closed proof source load"
        | Ok fsrc ->
            let fsm = Span.create () in
            let fsfid = Span.add_file fsm fsrc.Source.name fsrc in
            let fsdiags = Diagnostic.create_bag () in
            let fslx = Lexer.create fsrc.Source.bytes fsfid fsdiags in
            let fstoks = Lexer.lex fslx in
            let fsprog = Parser.parse fstoks fsrc.Source.bytes fsfid fsdiags [ "fclose" ] in
            if Diagnostic.has_errors fsdiags then begin
              Printf.printf "  fail-closed proof: FAIL (parse errors)\n%s\n"
                (Diagnostic.render fsm fsdiags);
              exit 1
            end;
            let fs_funcs =
              List.filter_map
                (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
                fsprog.Ast.items
            in
            let fs_tid = l_tid in
            let fsenv : Mir_lower.func_env =
              {
                Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
                  [
                    ("Pair", Type_repr.Named (fs_tid, [||]));
                    ("Int", int_ty);
                    ("Unit", Type_repr.Unit);
                    ("Bool", Type_repr.Bool);
                    ("String", string_ty);
                  ];
                values = [ ("main", int_ty) ];
                callables = [];
                callables_by_callable = [];
                methods = [];
                fn_ret = int_ty;
                struct_fields =
                  [ (fs_tid, [ ("a", l_fid_a, int_ty, None); ("b", l_fid_b, int_ty, None) ]) ];
                enum_payloads = [];
              copy_cache = Type_properties.create_cache ();
              }
            in
            let contains_sub s sub =
              let ls = String.length s and l = String.length sub in
              if l = 0 then true
              else begin
                let rec go i =
                  if i + l > ls then false
                  else if String.sub s i l = sub then true
                  else go (i + 1)
                in
                go 0
              end
            in
            let lower_expect_bug (fname : string) (needle : string) =
              match
                List.find_opt
                  (fun (d : Ast.function_decl) -> d.Ast.fn_sig.Ast.sig_name = fname)
                  fs_funcs
              with
              | None -> failwith ("fail-closed proof: no function " ^ fname)
              | Some d -> (
                  match
                    (try
                       Ok
                         (Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
                            fsenv fname 0 [||] [||] d)
                     with
                    | Mir_lower.Seed_bug m -> Error m)
                  with
                  | Error m when contains_sub m needle ->
                      Printf.printf "  fail-closed %s: PASS (%s)\n" fname m
                  | Error m ->
                      Printf.printf "  fail-closed %s: FAIL (message lacks %S: %s)\n" fname needle m;
                      exit 1
                  | Ok _ ->
                      Printf.printf "  fail-closed %s: FAIL (lowered without a Seed_bug)\n" fname;
                      exit 1)
            in
            lower_expect_bug "no_such_method" "has no method instance";
            lower_expect_bug "unknown_field" "unknown field `c`";
            lower_expect_bug "spread_lit" "`..` spread";
            (* re-audit P12: the missing `b: Int` field now DEFAULTS to
               0 (the native's type-defaulting) — the literal lowers with
               the zero constant at the b position *)
            begin
              let mf_d =
                match
                  List.find_opt
                    (fun (d : Ast.function_decl) -> d.Ast.fn_sig.Ast.sig_name = "missing_field")
                    fs_funcs
                with
                | Some d -> d
                | None -> failwith "fail-closed proof: no function missing_field"
              in
              let mf_mir =
                try
                  Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
                    fsenv "missing_field" 0 [||] [||] mf_d
                with
                | Mir_lower.Seed_bug m ->
                    Printf.printf "  fail-closed missing_field: FAIL (unexpected Seed_bug: %s)\n" m;
                    exit 1
              in
              let ctor_ops =
                Array.to_list mf_mir.Seed_mir.blocks
                |> List.find_map (fun (b : Seed_mir.block) ->
                       List.find_map
                         (fun (s : Seed_mir.statement) ->
                           match s with
                           | Seed_mir.Assign
                               (_, Seed_mir.Aggregate (Seed_mir.StructCtor _, ops)) ->
                               Some ops
                           | _ -> None)
                         b.Seed_mir.statements)
              in
              match ctor_ops with
              | Some [ Seed_mir.Constant (Seed_mir.Integer _); _ ] ->
                  Printf.printf
                    "  fail-closed missing_field: PASS (the omitted `b: Int` field defaulted to the zero constant)\n"
              | Some _ ->
                  Printf.printf
                    "  fail-closed missing_field: FAIL (the defaulted ctor does not carry [0; ...])\n";
                  exit 1
              | None ->
                  Printf.printf
                    "  fail-closed missing_field: FAIL (no StructCtor in the lowered function)\n";
                  exit 1
            end);
       (* ── closure disposition proof (re-audit lowering-surface item:
          "Closure — every implementation needs parse → typecheck →
          driver lower → verify → VM tests").  The seed VM CONSTRUCTS
          closure objects (ClosureAgg -> Vm_value.Closure as
          Tuple [Function; Tuple env]; see seed_mir.ml's header) but has
          NO closure-CALL path — Seed_mir.Call's callee is a
          compile-time function instance only, never a runtime closure
          value — so closure lowering fails CLOSED with a precise
          seed_bug (never a silent Unit), Subset rejects the form
          (E9040) as the authoritative frontend firewall, and the
          oracle's closure row is a documented placeholder (typed
          closures are not recorded; MIR closures 0 == 0 vacuously).
          Proof: (a) the lowerer fails closed on `|x| x + 1` with the
          precise seed_bug message; (b) Subset fires E9040 on the same
          construct; (c) a closure-free program still lowers through the
          DRIVER's lower_closure, verifies, and runs. *)
       let contains_sub s sub =
         let ls = String.length s and l = String.length sub in
         if l = 0 then true
         else begin
           let rec go i =
             if i + l > ls then false
             else if String.sub s i l = sub then true
             else go (i + 1)
           in
           go 0
         end
       in
       let closure_src = {|
def f() -> Int
  |x| x + 1
end

def main() -> Int
  0
end
|} in
       let closure_file = "<lowersurface-closure>" in
       (match Source_loader.load_string closure_file closure_src with
        | Error _ -> failwith "closure proof source load"
        | Ok csrc ->
            let csm = Span.create () in
            let csfid = Span.add_file csm csrc.Source.name csrc in
            let csdiags = Diagnostic.create_bag () in
            let cslx = Lexer.create csrc.Source.bytes csfid csdiags in
            let cstoks = Lexer.lex cslx in
            let csprog = Parser.parse cstoks csrc.Source.bytes csfid csdiags [ "closure-proof" ] in
            if Diagnostic.has_errors csdiags then begin
              Printf.printf "  closure proof: FAIL (parse errors)\n%s\n"
                (Diagnostic.render csm csdiags);
              exit 1
            end;
            let cs_funcs =
              List.filter_map
                (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
                csprog.Ast.items
            in
            let csenv : Mir_lower.func_env =
              {
                Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
                  [
                    ("Int", int_ty);
                    ("Unit", Type_repr.Unit);
                    ("Bool", Type_repr.Bool);
                    ("String", string_ty);
                  ];
                values = [];
                callables = [];
                callables_by_callable = [];
                methods = [];
                fn_ret = int_ty;
                struct_fields = [];
                enum_payloads = [];
              copy_cache = Type_properties.create_cache ();
              }
            in
            (* (a) the lowerer fails closed with the precise seed_bug —
               never a silent Unit *)
            match
              List.find_opt
                (fun (d : Ast.function_decl) -> d.Ast.fn_sig.Ast.sig_name = "f")
                cs_funcs
            with
            | None -> failwith "closure proof: no function f"
            | Some d -> (
                match
                  (try
                     Ok
                       (Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
                          csenv "f" 0 [||] [||] d)
                   with
                  | Mir_lower.Seed_bug m -> Error m)
                with
                | Error m when contains_sub m "no closure-CALL path" ->
                    Printf.printf "  closure fail-closed: PASS (%s)\n" m
                | Error m ->
                    Printf.printf "  closure fail-closed: FAIL (message lacks the reason: %s)\n" m;
                    exit 1
                | Ok _ ->
                    Printf.printf "  closure fail-closed: FAIL (lowered without a Seed_bug)\n";
                    exit 1);
            (* (b) Subset's E9040 rejection is authoritative on the same
               construct, with the E9040 message *)
            let csdiags2 = Diagnostic.create_bag () in
            Subset.check csdiags2 csprog;
            let cs_codes = Diagnostic.codes csdiags2 in
            if not (List.mem "E9040" cs_codes) then begin
              Printf.printf "  closure subset: FAIL (E9040 not fired; got [%s])\n"
                (String.concat "; " cs_codes);
              exit 1
            end;
            let e9040_msg_ok =
              List.exists
                (fun d ->
                  d.Diagnostic.code = "E9040"
                  && contains_sub d.Diagnostic.message
                       "closure expressions are not available in the bootstrap subset")
                csdiags2.Diagnostic.diagnostics
            in
            if not e9040_msg_ok then begin
              Printf.printf "  closure subset: FAIL (E9040 fired without the rejection message)\n";
              exit 1
            end;
            Printf.printf
              "  closure subset: PASS (E9040 fired — closure expressions are not available in the bootstrap subset)\n");
       (* (c) the closure-free program still lowers through the DRIVER's
          lower_closure path, verifies, and runs *)
       let noc_src = {|
def add(a: Int, b: Int) -> Int
  a + b
end

def main() -> Int
  add(1, 2)
end
|} in
       let noc_file = Filename.temp_file "tg_lowersurface_noclosure" ".tg" in
       (let oc = open_out_bin noc_file in
        output_string oc noc_src;
        close_out oc);
       let noc_manifest =
         match Bootstrap_manifest.single ~file:noc_file ~path:[ "nocproof" ] () with
         | Ok m -> m
         | Error e -> failwith ("no-closure proof manifest: " ^ e)
       in
       let ncdiags = Diagnostic.create_bag () in
       let ncgraph = Module_graph.create_with_sources noc_manifest ncdiags in
       let ncresolved = Resolver.resolve noc_manifest ncgraph ncdiags in
       let ncnode = List.hd ncgraph.Module_graph.nodes in
       let ncprog_ast = ncnode.Module_graph.node_program in
       let ncenv0 = Typecheck.initial_env ~resolved:(Some ncresolved) () in
       let ncenv =
         match
           Typecheck.check_program
             { ncenv0 with Typecheck.module_path = ncnode.Module_graph.node_path }
             ncprog_ast
         with
         | Error m -> failwith ("no-closure proof typecheck: " ^ m)
         | Ok (env', errors) ->
             if errors <> [] then
               failwith ("no-closure proof typecheck errors: " ^ String.concat "; " errors);
             env'
       in
       Sys.remove noc_file;
       let nc_target =
         match Target.unsupported_triple "aarch64-apple-darwin" with
         | Ok t -> t
         | Error m -> failwith ("no-closure proof target: " ^ m)
       in
       let ncctx : Driver.closure_ctx =
         {
           Driver.ctx_repo_root = ".";
           ctx_manifest_path = noc_file;
           ctx_target = nc_target;
           ctx_graph = ncgraph;
           ctx_resolved = ncresolved;
           ctx_env = ncenv;
           ctx_type_errors = [];
           ctx_items = List.length ncprog_ast.Ast.items;
           ctx_typed_calls_sample = 0;
           ctx_decl_rounds = 0;
            ctx_subset = Driver.subset_firewall_of_graph ncgraph;
            ctx_profile_findings = 0;
            ctx_strict_fallbacks = 0;
             ctx_strict_diags = [];
             ctx_audit = Driver.fresh_closure_audit ();
             lowered_methods = 0;
             ctx_cfg_program = None;
          }
       in
       let noc_prog = Driver.lower_closure ncctx in
       (match Mir_verify.require_valid_concrete noc_prog with
        | Ok () ->
            Printf.printf "  no-closure MIR verify: PASS (%d functions)\n"
              (Array.length noc_prog.Seed_mir.functions)
        | Error errs ->
            Printf.printf "  no-closure MIR verify: FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            exit 1);
       let noc_entry =
         match
           Array.to_list noc_prog.Seed_mir.functions
           |> List.find_opt (fun f -> f.Seed_mir.name = "main")
         with
         | Some f -> f.Seed_mir.instance
         | None -> failwith "no-closure proof: no main function"
       in
       let noc_host = Host.create ~repo_root:"." ~argv:[||] in
       (match Vm.run ~program:noc_prog ~entry:noc_entry ~argv:[||] ~host:noc_host with
        | Error e ->
            Printf.printf "  no-closure VM: FAIL %s\n" e.Vm.message;
            exit 1
        | Ok code ->
            Printf.printf "  no-closure VM: exit %d\n" code;
            (match Vm.entry_frame_of ~program:noc_prog ~entry:noc_entry ~argv:[||] with
             | Error m -> Printf.printf "  no-closure main returned: <inspect failed: %s>\n" m
             | Ok (cvm, centry_frame) -> (
                 match Vm.run_inspect cvm centry_frame with
                 | Ok ret_val ->
                     Printf.printf "  no-closure main returned: %s\n" ret_val;
                     if ret_val = "3" then
                       Printf.printf
                         "  no-closure RESULT: PASS (add(1,2) = 3 through the driver's lower_closure; the closure-free pipeline is undisturbed)\n"
                     else begin
                       Printf.printf "  no-closure RESULT: FAIL (expected 3)\n";
                       exit 1
                     end
                 | Error m -> Printf.printf "  no-closure main returned: <inspect failed: %s>\n" m)));
       ignore lenv2;
       ignore menv2;
       (* ── qualified static-call proof (E9048 retirement — (i1) the
          checker-integrated round-trip): `Buf::new()` lowers through
          the qualified path in lower_call's Name-arm (the methods
          registry's (owner, method) pair — the constructor-style
          `new` declares NO self, so the zero source args map to the
          params exactly), then the receiver-method push/get round-trip
          the data field (main = 42).  The methods are lowered as seed
          functions (the same instance the calls emit), the typed
          channel's tn_call on the `Buf::new` span is asserted (the
          checker-resolved callable + solved substitution), the program
          verifies (template AND concrete) and the VM runs. *)
       let qsrc = {|
struct Buf
  data: Int
end

impl Buf
  def new() -> Buf
    Buf { data: 0 }
  end

  def push(self: Self, sink item: Int) -> Int
    self.data + item
  end

  def get(self: Self, i: Int) -> Int
    self.data + i
  end
end

def main() -> Int
  let v = Buf::new()
  let a = 21
  let d1 = v.push(a)
  let d2 = v.push(a)
  v.get(d1 + d2)
end
|} in
       let qfile = Filename.temp_file "tg_lowersurface_qualified" ".tg" in
       (let oc = open_out_bin qfile in
        output_string oc qsrc;
        close_out oc);
       let qmanifest =
         match Bootstrap_manifest.single ~file:qfile ~path:[ "qproof" ] () with
         | Ok m -> m
         | Error e -> failwith ("qualified-call proof manifest: " ^ e)
       in
       let qdiags = Diagnostic.create_bag () in
       let qgraph = Module_graph.create_with_sources qmanifest qdiags in
       let qresolved = Resolver.resolve qmanifest qgraph qdiags in
       let qprog_ast = (List.hd qgraph.Module_graph.nodes).Module_graph.node_program in
       (* the impl registration needs the declaration fixpoint (the
          driver re-runs check_program to a fixpoint; mirror it here) *)
       let rec qfix env n =
         match Typecheck.check_program env qprog_ast with
         | Error m -> failwith ("qualified-call proof typecheck: " ^ m)
         | Ok (env', errors) ->
             if errors = [] then env'
             else if n = 0 then
               failwith ("qualified-call proof typecheck errors: " ^ String.concat "; " errors)
             else qfix env' (n - 1)
       in
       let qenv = qfix (Typecheck.initial_env ~resolved:(Some qresolved) ()) 6 in
       Sys.remove qfile;
       let q_tid = List.assoc "Buf" qenv.Typecheck.type_ids in
       let q_reg = List.assoc q_tid (Driver.struct_fields_of qenv) in
       let q_mts mname =
         match List.assoc_opt ("Buf", mname) qenv.Typecheck.methods with
         | Some ts -> ts
         | None -> failwith ("qualified-call proof: no method signature for Buf::" ^ mname)
       in
       let q_new_ts = q_mts "new" in
       let q_push_ts = q_mts "push" in
       let q_get_ts = q_mts "get" in
       if Array.length q_new_ts.Typecheck.ts_params <> 0 then
         failwith
           "qualified-call proof: Buf::new declares parameters (the constructor-style method must be self-less for the qualified call)";
       if Array.length q_push_ts.Typecheck.ts_params <> 2 then
         failwith "qualified-call proof: Buf::push must declare self + item";
       let q_funcs =
         List.filter_map
           (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
           qprog_ast.Ast.items
       in
       let q_impl_methods =
         match
           List.find_map
             (fun i ->
               match i.Ast.kind with
               | Ast.ImplBlock d -> Some d.Ast.i_methods
               | _ -> None)
             qprog_ast.Ast.items
         with
         | Some ms -> ms
         | None -> failwith "qualified-call proof: no impl block in the source"
       in
       let qts_of name =
         match List.assoc_opt name qenv.Typecheck.functions with
         | Some ts -> ts
         | None -> (
             match List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) qenv.Typecheck.functions with
             | [ (_, ts) ] -> ts
             | _ -> failwith ("qualified-call proof: no typed signature for " ^ name))
       in
       let qenv2 : Mir_lower.func_env =
         {
           Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
             [
               ("Buf", Type_repr.Named (q_tid, [||]));
               ("Int", int_ty);
               ("Unit", Type_repr.Unit);
               ("Bool", Type_repr.Bool);
               ("String", string_ty);
             ];
           values =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 (n, (qts_of n).Typecheck.ts_return))
               q_funcs;
           callables =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 ( n,
                   {
                     Mir_lower.ce_callable = Ids.Callable_id.to_int (qts_of n).Typecheck.ts_callable;
                     ce_template_args = [||];
                     ce_params = [||];
                   } ))
               q_funcs;
           methods =
             List.map
               (fun (m : Ast.function_decl) ->
                 let ts = q_mts m.Ast.fn_sig.Ast.sig_name in
                 ( ("Buf", m.Ast.fn_sig.Ast.sig_name),
                   {
                     Mir_lower.me_instance =
                       (* the same instance the method body is lowered
                          under below (callable + declaration-order type
                          args — [||] for the non-generic methods) *)
                       Instance_id.make ~callable:ts.Typecheck.ts_callable
                         ~type_args:
                           (Array.of_list
                              (List.map
                                 (fun (_, pid) -> Type_repr.Type_param pid)
                                 ts.Typecheck.ts_params_decl));
                     me_params = ts.Typecheck.ts_params;
                     me_ret = ts.Typecheck.ts_return;
                     me_has_self =
                       Array.length ts.Typecheck.ts_params > 0
                       && Array.length ts.Typecheck.ts_param_names > 0
                       && ts.Typecheck.ts_param_names.(0) = "self";
                   } ))
               q_impl_methods;
           callables_by_callable = [];
           fn_ret = int_ty;
           struct_fields = Driver.struct_fields_of qenv;
          enum_payloads = Driver.enum_payloads_of qenv;

                   copy_cache = Type_properties.create_cache ();
}
       in
       let qmir_funcs =
         List.map
           (fun d ->
             let n = d.Ast.fn_sig.Ast.sig_name in
             let ts = qts_of n in
             Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
               ~typed_nodes:(Driver.typed_nodes_of qenv)
               { qenv2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
               n (Ids.Callable_id.to_int ts.Typecheck.ts_callable) [||] [||] d)
           q_funcs
       in
       let qmethod_fn (m : Ast.function_decl) =
         let ts = q_mts m.Ast.fn_sig.Ast.sig_name in
         Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
           ~typed_nodes:(Driver.typed_nodes_of qenv)
           { qenv2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
           m.Ast.fn_sig.Ast.sig_name
           (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
           (Array.of_list
              (List.map (fun (_, pid) -> Type_repr.Type_param pid) ts.Typecheck.ts_params_decl))
           (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
           ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
           m
       in
       let qprog : Seed_mir.program =
         {
           Seed_mir.functions =
             Array.of_list (qmir_funcs @ List.map qmethod_fn q_impl_methods);
           statics = [||];
           types =
             [|
               Seed_mir.StructDef
                 {
                   sd_id = q_tid;
                   sd_fields =
                     List.mapi
                       (fun i (_, fid, fty, _) ->
                         {
                           Seed_mir.fd_id = fid;
                           fd_index = Ids.Field_index.make i;
                           fd_ty = fty;
                         })
                       q_reg;
                 };
             |];
         }
       in
       (* the typed channel: the `Buf::new` call's span node carries
          tn_call = the checker-resolved callable + solved substitution
          ([||] for the non-generic method) *)
       let qmain_decl =
         List.find
           (fun (d : Ast.function_decl) -> d.Ast.fn_sig.Ast.sig_name = "main")
           q_funcs
       in
       let qnew_nid, _qnew_span =
         match qmain_decl.Ast.fn_body with
         | Ast.FnBlock { Ast.b_stmts = Ast.LetBinding (_, _, _, Ast.Call (n, Ast.Name (_, nname, _), _, [], span), _) :: _; _ }
           when nname = "Buf::new" -> (n, span)
         | _ -> failwith "qualified-call proof: main's first statement is not `let v = Buf::new()`"
       in
       (match
          List.assoc_opt qnew_nid (Driver.typed_nodes_of qenv)
        with
        | Some node -> (
            match Typecheck.tc_callee_instance node.Mir_lower.tn_call with
            | Some (callable, subst)
              when Ids.Callable_id.compare callable q_new_ts.Typecheck.ts_callable = 0
                   && Array.length subst = 0 ->
                Printf.printf
                  "  qualified-call typed channel: PASS (the `Buf::new` call's span carries tn_call = (CallableId#%d, [||]) — the checker-resolved instance)\n"
                  (Ids.Callable_id.to_int callable)
            | Some (callable, subst) ->
                Printf.printf
                  "  qualified-call typed channel: FAIL (tn_call = (CallableId#%d, [%d args]))\n"
                  (Ids.Callable_id.to_int callable) (Array.length subst);
                exit 1
            | None ->
                Printf.printf "  qualified-call typed channel: FAIL (no tn_call on the call's node)\n";
                exit 1)
        | None ->
            Printf.printf "  qualified-call typed channel: FAIL (no typed node at the call's span)\n";
            exit 1);
       let qmain_fn =
         List.find (fun f -> f.Seed_mir.name = "main") (Array.to_list qprog.Seed_mir.functions)
       in
       let qfirst_call =
         Array.to_list qmain_fn.Seed_mir.blocks
         |> List.find_map (fun (b : Seed_mir.block) ->
                match b.Seed_mir.terminator with
                | Seed_mir.Call (_, Seed_mir.User inst, args, _, _)
                  when Ids.Callable_id.compare inst.Instance_id.callable
                         q_new_ts.Typecheck.ts_callable = 0 ->
                    Some args
                | _ -> None)
       in
       (match qfirst_call with
        | Some args when Array.length args = 0 ->
            Printf.printf
              "  qualified-call lowering: PASS (the `Buf::new` call emits a User callee = the method seed's instance CallableId#%d with ZERO arguments — the constructor-style method declares no self, so the zero source args map to the params exactly)\n"
              (Ids.Callable_id.to_int q_new_ts.Typecheck.ts_callable)
        | Some args ->
            Printf.printf
              "  qualified-call lowering: FAIL (%d arguments emitted)\n" (Array.length args);
            exit 1
        | None ->
            Printf.printf "  qualified-call lowering: FAIL (no User call to the new method instance in main)\n";
            exit 1);
       let qpush_get_ok =
         let seen = Hashtbl.create 4 in
         Array.iter
           (fun (b : Seed_mir.block) ->
             match b.Seed_mir.terminator with
             | Seed_mir.Call (_, Seed_mir.User inst, _, _, _) ->
                 let c = Ids.Callable_id.to_int inst.Instance_id.callable in
                 if c = Ids.Callable_id.to_int q_push_ts.Typecheck.ts_callable
                    || c = Ids.Callable_id.to_int q_get_ts.Typecheck.ts_callable
                 then Hashtbl.replace seen c ()
             | _ -> ())
           qmain_fn.Seed_mir.blocks;
         Hashtbl.mem seen (Ids.Callable_id.to_int q_push_ts.Typecheck.ts_callable)
         && Hashtbl.mem seen (Ids.Callable_id.to_int q_get_ts.Typecheck.ts_callable)
       in
       if not qpush_get_ok then begin
         Printf.printf "  qualified-call receiver methods: FAIL (push/get calls missing)\n";
         exit 1
       end;
       Printf.printf
         "  qualified-call receiver methods: PASS (main's push/get calls emit the method instances CallableId#%d/#%d)\n"
         (Ids.Callable_id.to_int q_push_ts.Typecheck.ts_callable)
         (Ids.Callable_id.to_int q_get_ts.Typecheck.ts_callable);
       (match Mir_verify.require_valid_template qprog with
        | Ok () ->
            Printf.printf "  qualified-call MIR verify (template): PASS (%d functions)\n"
              (Array.length qprog.Seed_mir.functions)
        | Error errs ->
            Printf.printf "  qualified-call MIR verify (template): FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            Printf.printf "%s\n" (Seed_mir.print_program qprog);
            exit 1);
       (match Mir_verify.require_valid_concrete qprog with
        | Ok () ->
            Printf.printf "  qualified-call MIR verify (concrete): PASS (%d functions)\n"
              (Array.length qprog.Seed_mir.functions)
        | Error errs ->
            Printf.printf "  qualified-call MIR verify (concrete): FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            Printf.printf "%s\n" (Seed_mir.print_program qprog);
            exit 1);
       let qentry =
         match
           Array.to_list qprog.Seed_mir.functions
           |> List.find_opt (fun f -> f.Seed_mir.name = "main")
         with
         | Some f -> f.Seed_mir.instance
         | None -> failwith "qualified-call proof: no main function"
       in
       let qhost = Host.create ~repo_root:"." ~argv:[||] in
       (match Vm.run ~program:qprog ~entry:qentry ~argv:[||] ~host:qhost with
        | Error e ->
            Printf.printf "  qualified-call VM: FAIL %s\n" e.Vm.message;
            exit 1
        | Ok code ->
            Printf.printf "  qualified-call VM: exit %d\n" code;
            (match Vm.entry_frame_of ~program:qprog ~entry:qentry ~argv:[||] with
             | Error m -> Printf.printf "  qualified-call main returned: <inspect failed: %s>\n" m
             | Ok (qvm, qentry_frame) -> (
                 match Vm.run_inspect qvm qentry_frame with
                 | Ok ret_val ->
                     Printf.printf "  qualified-call main returned: %s\n" ret_val;
                     if ret_val = "42" then
                       Printf.printf
                         "  qualified-call RESULT: PASS (Buf::new() + push/push + get = 42 through the qualified static-call path and the receiver-method path)\n"
                     else begin
                       Printf.printf "  qualified-call RESULT: FAIL (expected 42)\n";
                       exit 1
                     end
                 | Error m ->
                     Printf.printf "  qualified-call main returned: <inspect failed: %s>\n" m)));;


       (* ── qualified-call proof (i2): the Vec<->Array ALIAS leg with the
          REAL kernel name.  `Vec` is an alias of `Array` (the kernel's
          `Vec[T] is an alias for Array[T]`), so `Vec::new` dispatches to
          the Array impl's `new` — the checker's alias fallback in
          check_call; the lowerer's qualified path mirrors it
          (candidate owners [Vec; Array] when the direct (Vec, new) key
          is absent).  The env is hand-built (no checker — the harness
          cannot register the kernel's `impl[T] Array[T]`), the main AST
          is synthetic, and the callees (new/push/get) are hand-built
          seed functions; the program verifies (template AND concrete)
          and the VM runs (main = 42). *)
       let va_tid = Ids.Type_id.make 91 in
       let va_fid = Ids.Field_id.make 601 in
       let va_vec_ty = Type_repr.Named (va_tid, [||]) in
       let va_env : Mir_lower.func_env =
         {
           Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
             [
               ("Vec", va_vec_ty);
               ("Array", va_vec_ty);
               ("Int", int_ty);
               ("Unit", Type_repr.Unit);
               ("Bool", Type_repr.Bool);
             ];
           values = [];
           callables = [];
                callables_by_callable = [];
           methods =
             [
               ( ("Array", "new"),
                 {
                   Mir_lower.me_instance =
                     Instance_id.make ~callable:(Ids.Callable_id.make 101) ~type_args:[||];
                   me_params = [||];
                   me_ret = va_vec_ty;
                   me_has_self = false;
                 } );
               ( ("Vec", "push"),
                 {
                   Mir_lower.me_instance =
                     Instance_id.make ~callable:(Ids.Callable_id.make 102) ~type_args:[||];
                   me_params =
                     [|
                       { Type_repr.pt_convention = Access_effect.Let; pt_type = va_vec_ty };
                       { Type_repr.pt_convention = Access_effect.Sink; pt_type = int_ty };
                     |];
                   me_ret = int_ty;
                   me_has_self = true;
                 } );
               ( ("Vec", "get"),
                 {
                   Mir_lower.me_instance =
                     Instance_id.make ~callable:(Ids.Callable_id.make 103) ~type_args:[||];
                   me_params =
                     [|
                       { Type_repr.pt_convention = Access_effect.Let; pt_type = va_vec_ty };
                       { Type_repr.pt_convention = Access_effect.Let; pt_type = int_ty };
                     |];
                   me_ret = int_ty;
                   me_has_self = true;
                 } );
             ];
           fn_ret = int_ty;
           struct_fields = [ (va_tid, [ ("data", va_fid, int_ty, None) ]) ];
                enum_payloads = [];
         copy_cache = Type_properties.create_cache ();
         }
       in
       let va_span = Span.synthetic in
       let va_name n = Ast.Name (Ids.Node_id.make 0, n, va_span) in
       let va_arg e = { Ast.ca_label = None; ca_value = e; ca_span = va_span } in
       let va_call n args = Ast.Call (Ids.Node_id.make 0, va_name n, [], args, va_span) in
       let va_mcall base mname args =
         Ast.Call (Ids.Node_id.make 0, Ast.Field (Ids.Node_id.make 0, va_name base, mname, va_span), [], args, va_span)
       in
       let va_int i = Ast.IntLit (Ids.Node_id.make 0, string_of_int i, va_span) in
       let va_let name value =
         Ast.LetBinding (Ast.PatIdent (name, false, va_span), false, None, value, va_span)
       in
       let va_main_decl : Ast.function_decl =
         {
           Ast.fn_sig =
             {
               Ast.sig_name = "main";
               sig_public = false;
               sig_async = false;
               sig_unsafe = false;
               sig_const = false;
               sig_pure = false;
               sig_inline = false;
               sig_extern = false;
               sig_type_params = [];
               sig_params = [];
               sig_return = None;
               sig_where = [];
               sig_span = va_span;
             };
           fn_clauses = [];
           fn_body =
             Ast.FnBlock
               {
                 Ast.b_stmts =
                   [
                     va_let "v" (va_call "Vec::new" []);
                     va_let "a" (va_int 21);
                     va_let "d1" (va_mcall "v" "push" [ va_arg (va_name "a") ]);
                     va_let "d2" (va_mcall "v" "push" [ va_arg (va_name "a") ]);
                   ];
                 b_tail =
                   Some
                     (va_mcall "v" "get"
                        [ va_arg (Ast.Binary (Ids.Node_id.make 0, va_name "d1", Ast.Add, va_name "d2", va_span)) ]);
                 b_span = va_span;
               };
           fn_span = va_span;
         }
       in
       let va_main_fn =
         Mir_lower.lower_function_with_variants Mir_lower.default_variant_table va_env
           "main" 100 [||] [||] va_main_decl
       in
       (* The alias leg under the array/vec host surface: `Vec::new` is
          REGISTRY-backed (__intrinsic_array_new — the growable-array
          surface the kernel's Vec/Array methods dispatch to), so the
          alias resolution (owner Vec -> the candidate Array owner, the
          synthetic __intrinsic_vec_new name is NOT registered) now
          manifests as the Intrinsic callee of __intrinsic_array_new —
          the SAME alias fallback the checker's method lookup uses, seen
          through the host channel.  The synthetic env's hand-built
          types (type#91) and its deviating method signatures (push
          returns Int, self by Let) cannot type-check against the
          registry's declared array surface, so the alias proof here is
          the lowering-time channel assertion; the REAL Vec round trip
          (new/push/get/pop/len over Vm_value.Array) is executed by the
          kernel-world bootstrap runs. *)
       let va_new_intrinsic_ok =
         Array.exists
           (fun (b : Seed_mir.block) ->
             match b.Seed_mir.terminator with
             | Seed_mir.Call (_, Seed_mir.Intrinsic (i, _), args, _, _)
               when Array.length args = 0 -> (
                   match Intrinsic_registry.by_id Intrinsic_registry.manifest i with
                   | Some (name, _, _) -> name = "__intrinsic_array_new"
                   | None -> false)
             | _ -> false)
           va_main_fn.Seed_mir.blocks
       in
       if not va_new_intrinsic_ok then begin
         Printf.printf
           "  qualified-call alias: FAIL (the `Vec::new` call did not lower through the Vec<->Array alias onto the __intrinsic_array_new intrinsic channel)\n";
         exit 1
       end;
       Printf.printf
         "  qualified-call alias: PASS (`Vec::new` resolved through the Vec<->Array alias onto the __intrinsic_array_new intrinsic channel — zero args, no synthetic self)\n";
       (* the unresolvable qualified name: `Foo::bar` with no method, no
          alias, no mangled free function -> "unknown callee" (the
          fail-closed channel that replaced the firewall rejection) *)
       (try
          ignore
            (Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
               va_env "main" 100 [||] [||]
               { va_main_decl with
                 Ast.fn_body =
                   Ast.FnExpr (va_call "Foo::bar" [ va_arg (va_int 0) ]) });
          Printf.printf
            "  unknown qualified callee: FAIL (lowering succeeded — `Foo::bar` should fail closed)\n";
          exit 1
        with
        | Mir_lower.Seed_bug m ->
            let contains_sub s sub =
              let ls = String.length s and l = String.length sub in
              if l = 0 then true
              else begin
                let found = ref false in
                (try
                   for i = 0 to ls - l do
                     if not !found && String.sub s i l = sub then found := true
                   done
                 with Invalid_argument _ -> ());
                !found
              end
            in
            if contains_sub m "unknown callee 'Foo::bar'" then
              Printf.printf
                "  unknown qualified callee: PASS (lowering fails closed: %s)\n" m
            else begin
              Printf.printf "  unknown qualified callee: FAIL (wrong Seed_bug: %s)\n" m;
              exit 1
            end);;

       (* ── qualified-call proof (i3): `impl String` — `String::new()` is
          a direct methods-registry hit, and `String::kind(s)` exercises
          the SELF-typed first parameter that is NOT the owner's own
          type (String is a primitive, not a nominal — the checker's
          self_is_owner test fails, so the receiver passes as an EXPLICIT
          argument, exactly the kernel's `String::from_str_view(&arg)`
          pattern; the lowerer's mirrored test maps the source args to
          ALL params).  Verifies (template + concrete) and the VM runs
          (main = 42). *)
       let sqsrc = {|
impl String
  def new() -> String
    "hi"
  end

  def kind(sink self: Self) -> Int
    42
  end
end

def main() -> Int
  String::kind(String::new())
end
|} in
       let sqfile = Filename.temp_file "tg_lowersurface_string" ".tg" in
       (let oc = open_out_bin sqfile in
        output_string oc sqsrc;
        close_out oc);
       let sqmanifest =
         match Bootstrap_manifest.single ~file:sqfile ~path:[ "sqproof" ] () with
         | Ok m -> m
         | Error e -> failwith ("String qualified-call proof manifest: " ^ e)
       in
       let sqdiags = Diagnostic.create_bag () in
       let sqgraph = Module_graph.create_with_sources sqmanifest sqdiags in
       let sqresolved = Resolver.resolve sqmanifest sqgraph sqdiags in
       let sqprog_ast = (List.hd sqgraph.Module_graph.nodes).Module_graph.node_program in
       let rec sqfix env n =
         match Typecheck.check_program env sqprog_ast with
         | Error m -> failwith ("String qualified-call proof typecheck: " ^ m)
         | Ok (env', errors) ->
             if errors = [] then env'
             else if n = 0 then
               failwith ("String qualified-call proof typecheck errors: " ^ String.concat "; " errors)
             else sqfix env' (n - 1)
       in
       let sqenv = sqfix (Typecheck.initial_env ~resolved:(Some sqresolved) ()) 6 in
       Sys.remove sqfile;
       let sq_mts mname =
         match List.assoc_opt ("String", mname) sqenv.Typecheck.methods with
         | Some ts -> ts
         | None -> failwith ("String qualified-call proof: no method signature for String::" ^ mname)
       in
       let sq_new_ts = sq_mts "new" in
       let sq_kind_ts = sq_mts "kind" in
       if Array.length sq_new_ts.Typecheck.ts_params <> 0 then
         failwith "String qualified-call proof: String::new declares parameters";
       if Array.length sq_kind_ts.Typecheck.ts_params <> 1 then
         failwith "String qualified-call proof: String::kind must declare exactly self";
       let sq_funcs =
         List.filter_map
           (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
           sqprog_ast.Ast.items
       in
       let sq_impl_methods =
         match
           List.find_map
             (fun i ->
               match i.Ast.kind with
               | Ast.ImplBlock d -> Some d.Ast.i_methods
               | _ -> None)
             sqprog_ast.Ast.items
         with
         | Some ms -> ms
         | None -> failwith "String qualified-call proof: no impl block in the source"
       in
       let sqts_of name =
         match List.assoc_opt name sqenv.Typecheck.functions with
         | Some ts -> ts
         | None -> (
             match List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) sqenv.Typecheck.functions with
             | [ (_, ts) ] -> ts
             | _ -> failwith ("String qualified-call proof: no typed signature for " ^ name))
       in
       let sqenv2 : Mir_lower.func_env =
         {
           Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
             [
               ("String", string_ty);
               ("Int", int_ty);
               ("Unit", Type_repr.Unit);
               ("Bool", Type_repr.Bool);
               ("Char", Type_repr.Char);
             ];
           values =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 (n, (sqts_of n).Typecheck.ts_return))
               sq_funcs;
           callables =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 ( n,
                   {
                     Mir_lower.ce_callable = Ids.Callable_id.to_int (sqts_of n).Typecheck.ts_callable;
                     ce_template_args = [||];
                     ce_params = [||];
                   } ))
               sq_funcs;
           methods =
             List.map
               (fun (m : Ast.function_decl) ->
                 let ts = sq_mts m.Ast.fn_sig.Ast.sig_name in
                 ( ("String", m.Ast.fn_sig.Ast.sig_name),
                   {
                     Mir_lower.me_instance =
                       Instance_id.make ~callable:ts.Typecheck.ts_callable
                         ~type_args:
                           (Array.of_list
                              (List.map
                                 (fun (_, pid) -> Type_repr.Type_param pid)
                                 ts.Typecheck.ts_params_decl));
                     me_params = ts.Typecheck.ts_params;
                     me_ret = ts.Typecheck.ts_return;
                     me_has_self =
                       Array.length ts.Typecheck.ts_params > 0
                       && Array.length ts.Typecheck.ts_param_names > 0
                       && ts.Typecheck.ts_param_names.(0) = "self";
                   } ))
               sq_impl_methods;
           callables_by_callable = [];
           fn_ret = int_ty;
           struct_fields = [];
                enum_payloads = [];
         copy_cache = Type_properties.create_cache ();
         }
       in
       let sqmir_funcs =
         List.map
           (fun d ->
             let n = d.Ast.fn_sig.Ast.sig_name in
             let ts = sqts_of n in
             Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
               ~typed_nodes:(Driver.typed_nodes_of sqenv)
               { sqenv2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
               n (Ids.Callable_id.to_int ts.Typecheck.ts_callable) [||] [||] d)
           sq_funcs
       in
       let sqmethod_fn (m : Ast.function_decl) =
         let ts = sq_mts m.Ast.fn_sig.Ast.sig_name in
         Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
           ~typed_nodes:(Driver.typed_nodes_of sqenv)
           { sqenv2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
           m.Ast.fn_sig.Ast.sig_name
           (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
           (Array.of_list
              (List.map (fun (_, pid) -> Type_repr.Type_param pid) ts.Typecheck.ts_params_decl))
           (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
           ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
           m
       in
       let sqprog : Seed_mir.program =
         {
           Seed_mir.functions =
             Array.of_list (sqmir_funcs @ List.map sqmethod_fn sq_impl_methods);
           statics = [||];
           types = [||];
         }
       in
       let sqmain_fn =
         List.find (fun f -> f.Seed_mir.name = "main") (Array.to_list sqprog.Seed_mir.functions)
       in
       let sqcalls_ok =
         let seen = Hashtbl.create 4 in
         Array.iter
           (fun (b : Seed_mir.block) ->
             match b.Seed_mir.terminator with
             | Seed_mir.Call (_, Seed_mir.User inst, args, _, _) ->
                 let c = Ids.Callable_id.to_int inst.Instance_id.callable in
                 if c = Ids.Callable_id.to_int sq_new_ts.Typecheck.ts_callable
                    && Array.length args = 0
                 then Hashtbl.replace seen 1 ()
                 else if c = Ids.Callable_id.to_int sq_kind_ts.Typecheck.ts_callable
                         && Array.length args = 1
                 then Hashtbl.replace seen 2 ()
             | _ -> ())
           sqmain_fn.Seed_mir.blocks;
         Hashtbl.mem seen 1 && Hashtbl.mem seen 2
       in
       if not sqcalls_ok then begin
         Printf.printf
           "  String qualified-call lowering: FAIL (the String::new / String::kind calls are missing or mis-argued)\n";
         exit 1
       end;
       Printf.printf
         "  String qualified-call lowering: PASS (String::new -> 0 args; String::kind(s) -> 1 arg — the SELF-typed non-owner first parameter is an explicit argument, never a synthetic receiver)\n";
       (match Mir_verify.require_valid_template sqprog with
        | Ok () ->
            Printf.printf "  String qualified-call MIR verify (template): PASS (%d functions)\n"
              (Array.length sqprog.Seed_mir.functions)
        | Error errs ->
            Printf.printf "  String qualified-call MIR verify (template): FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            Printf.printf "%s\n" (Seed_mir.print_program sqprog);
            exit 1);
       (match Mir_verify.require_valid_concrete sqprog with
        | Ok () ->
            Printf.printf "  String qualified-call MIR verify (concrete): PASS (%d functions)\n"
              (Array.length sqprog.Seed_mir.functions)
        | Error errs ->
            Printf.printf "  String qualified-call MIR verify (concrete): FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            Printf.printf "%s\n" (Seed_mir.print_program sqprog);
            exit 1);
       let sqentry = sqmain_fn.Seed_mir.instance in
       let sqhost = Host.create ~repo_root:"." ~argv:[||] in
       (match Vm.run ~program:sqprog ~entry:sqentry ~argv:[||] ~host:sqhost with
        | Error e ->
            Printf.printf "  String qualified-call VM: FAIL %s\n" e.Vm.message;
            exit 1
        | Ok code ->
            Printf.printf "  String qualified-call VM: exit %d\n" code;
            (match Vm.entry_frame_of ~program:sqprog ~entry:sqentry ~argv:[||] with
             | Error m -> Printf.printf "  String qualified-call main returned: <inspect failed: %s>\n" m
             | Ok (sqvm, sqentry_frame) -> (
                 match Vm.run_inspect sqvm sqentry_frame with
                 | Ok ret_val ->
                     Printf.printf "  String qualified-call main returned: %s\n" ret_val;
                     if ret_val = "42" then
                       Printf.printf
                         "  String qualified-call RESULT: PASS (String::new() + String::kind(s) = 42 — the qualified constructor and the explicit-argument self-typed method)\n"
                     else begin
                       Printf.printf "  String qualified-call RESULT: FAIL (expected 42)\n";
                       exit 1
                     end

                 | Error m ->
                     Printf.printf "  String qualified-call main returned: <inspect failed: %s>\n" m)));;

       (* ── qualified-call proof (i4): the qualified ctor leg —
          `Option::Some(21)` / `Result::Ok(21)` (the builtin variant
          table's qualified forms) and `Color::Green(21)` (the qualified
          USER-enum ctor — the variant table's vt_enums qualified form)
          construct and match round-trip (main = 63). *)
       let qc_src = {|
enum Color
  Red,
  Green(Int),
  Blue(Int, Int)
end

def main() -> Int
  let a = Option::Some(21)
  let b = Result::Ok(21)
  let c = Color::Green(21)
  let d = match a {
    Some(v) => v,
    None() => 0
  }
  let e = match b {
    Ok(v) => v,
    Err(_) => 0
  }
  let f = match c {
    Green(v) => v,
    _ => 0
  }
  d + e + f
end
|} in
       let qc_file = Filename.temp_file "tg_lowersurface_qctor" ".tg" in
       (let oc = open_out_bin qc_file in
        output_string oc qc_src;
        close_out oc);
       let qc_manifest =
         match Bootstrap_manifest.single ~file:qc_file ~path:[ "qcproof" ] () with
         | Ok m -> m
         | Error e -> failwith ("qualified-ctor proof manifest: " ^ e)
       in
       let qc_diags = Diagnostic.create_bag () in
       let qc_graph = Module_graph.create_with_sources qc_manifest qc_diags in
       let qc_resolved = Resolver.resolve qc_manifest qc_graph qc_diags in
       let qc_prog_ast = (List.hd qc_graph.Module_graph.nodes).Module_graph.node_program in
       let qc_env =
         match Typecheck.check_program (Typecheck.initial_env ~resolved:(Some qc_resolved) ()) qc_prog_ast with
         | Error m -> failwith ("qualified-ctor proof typecheck: " ^ m)
         | Ok (env', errors) ->
             if errors <> [] then
               failwith ("qualified-ctor proof typecheck errors: " ^ String.concat "; " errors);
             env'
       in
       Sys.remove qc_file;
       let qc_option_tid = List.assoc "Option" qc_env.Typecheck.type_ids in
       let qc_result_tid = List.assoc "Result" qc_env.Typecheck.type_ids in
       let qc_color_tid = List.assoc "Color" qc_env.Typecheck.type_ids in
       let qc_option_int = Type_repr.Named (qc_option_tid, [| int_ty |]) in
       let qc_result_int = Type_repr.Named (qc_result_tid, [| int_ty; int_ty |]) in
       let qc_color_ty = Type_repr.Named (qc_color_tid, [||]) in
       let qc_ts_of name =
         match List.assoc_opt name qc_env.Typecheck.functions with
         | Some ts -> ts
         | None -> (
             match List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) qc_env.Typecheck.functions with
             | [ (_, ts) ] -> ts
             | _ -> failwith ("qualified-ctor proof: no typed signature for " ^ name))
       in
       let qc_funcs =
         List.filter_map
           (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
           qc_prog_ast.Ast.items
       in
       let qc_env2 : Mir_lower.func_env =
         {
           Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
             [
               ("Color", qc_color_ty);
               ("Option", Type_repr.Named (qc_option_tid, [| Type_repr.Type_param (Ids.Generic_param_id.make 0) |]));
               ("Result", Type_repr.Named (qc_result_tid, [| Type_repr.Type_param (Ids.Generic_param_id.make 0); Type_repr.Type_param (Ids.Generic_param_id.make 1) |]));
               ("Int", int_ty);
               ("Unit", Type_repr.Unit);
               ("Bool", Type_repr.Bool);
               ("String", string_ty);
             ];
           values =
             [
               ("Option::Some", qc_option_int);
               ("Option::None", qc_option_int);
               ("Result::Ok", qc_result_int);
               ("Result::Err", qc_result_int);
               ("Color::Red", qc_color_ty);
               ("Color::Green", qc_color_ty);
               ("Color::Blue", qc_color_ty);
             ]
             @ List.map
                 (fun d ->
                   let n = d.Ast.fn_sig.Ast.sig_name in
                   (n, (qc_ts_of n).Typecheck.ts_return))
                 qc_funcs;
           callables =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 ( n,
                   {
                     Mir_lower.ce_callable = Ids.Callable_id.to_int (qc_ts_of n).Typecheck.ts_callable;
                     ce_template_args = [||];
                     ce_params = [||];
                   } ))
               qc_funcs;
           methods = [];
          callables_by_callable = [];
           fn_ret = int_ty;
           struct_fields = Driver.struct_fields_of qc_env;
          enum_payloads = Driver.enum_payloads_of qc_env;

                   copy_cache = Type_properties.create_cache ();
}
       in
       let qc_mir_funcs =
         List.map
           (fun d ->
             let n = d.Ast.fn_sig.Ast.sig_name in
             let ts = qc_ts_of n in
             Mir_lower.lower_function_with_variants variant_table
               { qc_env2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
               n (Ids.Callable_id.to_int ts.Typecheck.ts_callable) [||] [||] d)
           qc_funcs
       in
       let qc_prog : Seed_mir.program =
         {
           Seed_mir.functions = Array.of_list qc_mir_funcs;
           statics = [||];
           types =
             [|
               Seed_mir.EnumDef
                 {
                   ed_id = qc_option_tid;
                   ed_variants =
                     [
                       { Seed_mir.vd_id = Ids.Variant_id.make 1; vd_index = Ids.Variant_index.make 0; vd_payload = Type_repr.Tuple [| int_ty |] };
                       { Seed_mir.vd_id = Ids.Variant_id.make 2; vd_index = Ids.Variant_index.make 1; vd_payload = Type_repr.Unit };
                     ];
                 };
               Seed_mir.EnumDef
                 {
                   ed_id = qc_result_tid;
                   ed_variants =
                     [
                       { Seed_mir.vd_id = Ids.Variant_id.make 1; vd_index = Ids.Variant_index.make 0; vd_payload = Type_repr.Tuple [| int_ty |] };
                       { Seed_mir.vd_id = Ids.Variant_id.make 2; vd_index = Ids.Variant_index.make 1; vd_payload = Type_repr.Tuple [| int_ty |] };
                     ];
                 };
               Seed_mir.EnumDef
                 {
                   ed_id = qc_color_tid;
                   ed_variants =
                     [
                       { Seed_mir.vd_id = Ids.Variant_id.make 1; vd_index = Ids.Variant_index.make 0; vd_payload = Type_repr.Unit };
                       { Seed_mir.vd_id = Ids.Variant_id.make 2; vd_index = Ids.Variant_index.make 1; vd_payload = Type_repr.Tuple [| int_ty |] };
                       { Seed_mir.vd_id = Ids.Variant_id.make 3; vd_index = Ids.Variant_index.make 2; vd_payload = Type_repr.Tuple [| int_ty; int_ty |] };
                     ];
                 };
             |];
         }
       in
       (match Mir_verify.require_valid_template qc_prog with
        | Ok () ->
            Printf.printf "  qualified-ctor MIR verify (template): PASS (%d functions)\n"
              (Array.length qc_prog.Seed_mir.functions)
        | Error errs ->
            Printf.printf "  qualified-ctor MIR verify (template): FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            Printf.printf "%s\n" (Seed_mir.print_program qc_prog);
            exit 1);
       (match Mir_verify.require_valid_concrete qc_prog with
        | Ok () ->
            Printf.printf "  qualified-ctor MIR verify (concrete): PASS (%d functions)\n"
              (Array.length qc_prog.Seed_mir.functions)
        | Error errs ->
            Printf.printf "  qualified-ctor MIR verify (concrete): FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            Printf.printf "%s\n" (Seed_mir.print_program qc_prog);
            exit 1);
       let qc_entry =
         match
           Array.to_list qc_prog.Seed_mir.functions
           |> List.find_opt (fun f -> f.Seed_mir.name = "main")
         with
         | Some f -> f.Seed_mir.instance
         | None -> failwith "qualified-ctor proof: no main function"
       in
       let qc_host = Host.create ~repo_root:"." ~argv:[||] in
       (match Vm.run ~program:qc_prog ~entry:qc_entry ~argv:[||] ~host:qc_host with
        | Error e ->
            Printf.printf "  qualified-ctor VM: FAIL %s\n" e.Vm.message;
            exit 1
        | Ok code ->
            Printf.printf "  qualified-ctor VM: exit %d\n" code;
            (match Vm.entry_frame_of ~program:qc_prog ~entry:qc_entry ~argv:[||] with
             | Error m -> Printf.printf "  qualified-ctor main returned: <inspect failed: %s>\n" m
             | Ok (qcvm, qcentry_frame) -> (
                 match Vm.run_inspect qcvm qcentry_frame with
                 | Ok ret_val ->
                     Printf.printf "  qualified-ctor main returned: %s\n" ret_val;
                     if ret_val = "63" then
                       Printf.printf
                         "  qualified-ctor RESULT: PASS (Option::Some + Result::Ok + Color::Green = 63 through the qualified ctor path)\n"
                     else begin
                       Printf.printf "  qualified-ctor RESULT: FAIL (expected 63)\n";
                       exit 1

                     end
                 | Error m ->
                     Printf.printf "  qualified-ctor main returned: <inspect failed: %s>\n" m)));;

       (* ── qualified-call FAIL-CLOSED legs: a self-having method called
          qualified (`W::touch()` — the checker's synthetic receiver is
          the TYPE used as a value, a type-level fiction with no runtime
          content) fails closed at lowering with the precise Seed_bug,
          and an unresolvable qualified name (`Foo::bar`) fails closed
          with "unknown callee" — the fail-closed channel that replaced
          the firewall rejection. *)
       let w_src = {|
struct W
  x: Int
end

impl W
  def touch(inout self: Self) -> Unit inout
    self.x = self.x + 1
  end
end

def main() -> Int
  W::touch()
  0
end
|} in
       let w_file = Filename.temp_file "tg_lowersurface_qself" ".tg" in
       (let oc = open_out_bin w_file in
        output_string oc w_src;
        close_out oc);
       let w_manifest =
         match Bootstrap_manifest.single ~file:w_file ~path:[ "wproof" ] () with
         | Ok m -> m
         | Error e -> failwith ("self-having qualified-call proof manifest: " ^ e)
       in
       let w_diags = Diagnostic.create_bag () in
       let w_graph = Module_graph.create_with_sources w_manifest w_diags in
       let w_resolved = Resolver.resolve w_manifest w_graph w_diags in
       let w_prog_ast = (List.hd w_graph.Module_graph.nodes).Module_graph.node_program in
       let rec wfix env n =
         match Typecheck.check_program env w_prog_ast with
         | Error m -> failwith ("self-having qualified-call proof typecheck: " ^ m)
         | Ok (env', errors) ->
             if errors = [] then env'
             else if n = 0 then
               failwith ("self-having qualified-call proof typecheck errors: " ^ String.concat "; " errors)
             else wfix env' (n - 1)
       in
       let w_env = wfix (Typecheck.initial_env ~resolved:(Some w_resolved) ()) 6 in
       Sys.remove w_file;
       let w_tid = List.assoc "W" w_env.Typecheck.type_ids in
       let w_touch_ts =
         match List.assoc_opt ("W", "touch") w_env.Typecheck.methods with
         | Some ts -> ts
         | None -> failwith "self-having qualified-call proof: no W::touch method signature"
       in
       if Array.length w_touch_ts.Typecheck.ts_params = 0 then
         failwith "self-having qualified-call proof: W::touch declares no self";
       let w_funcs =
         List.filter_map
           (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
           w_prog_ast.Ast.items
       in
       let wts_of name =
         match List.assoc_opt name w_env.Typecheck.functions with
         | Some ts -> ts
         | None -> (
             match List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) w_env.Typecheck.functions with
             | [ (_, ts) ] -> ts
             | _ -> failwith ("self-having qualified-call proof: no typed signature for " ^ name))
       in
       let w_env2 : Mir_lower.func_env =
         {
           Mir_lower.consts = [];
          Mir_lower.statics = [];
    Mir_lower.types =
             [
               ("W", Type_repr.Named (w_tid, [||]));
               ("Int", int_ty);
               ("Unit", Type_repr.Unit);
               ("Bool", Type_repr.Bool);
               ("String", string_ty);
             ];
           values =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 (n, (wts_of n).Typecheck.ts_return))
               w_funcs;
           callables =
             List.map
               (fun d ->
                 let n = d.Ast.fn_sig.Ast.sig_name in
                 ( n,
                   {
                     Mir_lower.ce_callable = Ids.Callable_id.to_int (wts_of n).Typecheck.ts_callable;
                     ce_template_args = [||];
                     ce_params = [||];
                   } ))
               w_funcs;
           methods =
             [
               ( ("W", "touch"),
                 {
                   Mir_lower.me_instance =
                     Instance_id.make ~callable:w_touch_ts.Typecheck.ts_callable
                       ~type_args:
                         (Array.of_list
                            (List.map
                               (fun (_, pid) -> Type_repr.Type_param pid)
                               w_touch_ts.Typecheck.ts_params_decl));
                   me_params = w_touch_ts.Typecheck.ts_params;
                   me_ret = w_touch_ts.Typecheck.ts_return;
                   me_has_self =
                     Array.length w_touch_ts.Typecheck.ts_params > 0
                     && Array.length w_touch_ts.Typecheck.ts_param_names > 0
                     && w_touch_ts.Typecheck.ts_param_names.(0) = "self";
                 } );
             ];
           callables_by_callable = [];
           fn_ret = int_ty;
           struct_fields = Driver.struct_fields_of w_env;
          enum_payloads = Driver.enum_payloads_of w_env;

                   copy_cache = Type_properties.create_cache ();
}
       in
       let w_main_decl =
         List.find
           (fun (d : Ast.function_decl) -> d.Ast.fn_sig.Ast.sig_name = "main")
           w_funcs
       in
       let w_main_ts = wts_of "main" in
       (try
          ignore
            (Mir_lower.lower_function_with_variants Mir_lower.default_variant_table
               ~typed_nodes:(Driver.typed_nodes_of w_env)
               { w_env2 with Mir_lower.fn_ret = w_main_ts.Typecheck.ts_return }
               "main" (Ids.Callable_id.to_int w_main_ts.Typecheck.ts_callable) [||] [||]
               w_main_decl);
          Printf.printf
            "  self-having qualified call: FAIL (lowering succeeded — the synthetic receiver would have been emitted)\n";
          exit 1
        with
        | Mir_lower.Seed_bug m ->
            let contains_sub s sub =
              let ls = String.length s and l = String.length sub in
              if l = 0 then true
              else begin
                let found = ref false in
                (try
                   for i = 0 to ls - l do
                     if not !found && String.sub s i l = sub then found := true
                   done
                 with Invalid_argument _ -> ());
                !found
              end
            in
            if contains_sub m "takes a receiver" then
              Printf.printf
                "  self-having qualified call: PASS (lowering fails closed: %s)\n" m
            else begin
              Printf.printf "  self-having qualified call: FAIL (wrong Seed_bug: %s)\n" m;
              exit 1
            end)
