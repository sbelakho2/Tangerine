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
         that the returned value reads after the defers run.

   Expected main return: 113 (see the derivation comment in src_text). *)

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
  a + b + c + d + e + f + g + h + i + j + k
end
|}

let int_ty = Type_repr.Int Type_repr.Int
let string_ty = Type_repr.String

(* ── variant table for the user enum (declaration order) ───────── *)
let color_specs =
  [
    ("Red", { Mir_lower.vs_index = 0; vs_fields = [] });
    ("Green", { Mir_lower.vs_index = 1; vs_fields = [ int_ty ] });
    ("Blue", { Mir_lower.vs_index = 2; vs_fields = [ int_ty; int_ty ] });
  ]

let color_ctors = List.map (fun (n, spec) -> (n, ("Color", n, spec))) color_specs

let variant_table : Mir_lower.variant_table =
  { vt_enums = [ ("Color", color_specs) ]; vt_ctors = List.map (fun (n, (e, v, _)) -> (n, (e, v))) color_ctors }

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
const MAX_POINTS: Int = 10
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
                  let sts = Driver.closure_statics env_m in
                  let struct_ok =
                    Array.exists
                      (fun d ->
                        match d with
                        | Seed_mir.StructDef { sd_fields; _ } -> List.length sd_fields = 2
                        | _ -> false)
                      tys
                  in
                  let static_ok = Array.exists (fun (n, _, _) -> n = "mat::MAX_POINTS") sts in
                  if struct_ok && static_ok then
                    Printf.printf
                      "  closure materialization: PASS (Point struct def + MAX_POINTS static from the typed registry)\n"
                  else begin
                    Printf.printf "  closure materialization: FAIL (struct_ok=%b static_ok=%b)\n"
                      struct_ok static_ok;
                    exit 1
                  end
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
         must reproduce the manual Color table above exactly, with the
         declaration-order indices aligned to the semantic VariantIds
         that closure_types materializes into the EnumDefs) *)
      let color_nom = List.assoc "Color" tcheck_env.Typecheck.nominals in
      let color_tid = List.assoc "Color" tcheck_env.Typecheck.type_ids in
      let driver_table = Driver.user_variant_table tcheck_env in
      if driver_table <> variant_table then begin
        Printf.printf "  user-enum table: FAIL (driver table differs from the manual Color table)\n";
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
                     Ids.Variant_id.compare vd.Seed_mir.vd_id
                       (List.nth color_nom.Typecheck.nom_variant_ids spec.Mir_lower.vs_index)
                     = 0))
               (List.assoc "Color" driver_table.Mir_lower.vt_enums)
           in
           if ok then
             Printf.printf
               "  user-enum table: PASS (driver table == manual Color table; vs_index aligns with the semantic VariantIds in the EnumDefs)\n"
           else begin
             Printf.printf "  user-enum table: FAIL (semantic VariantId alignment)\n";
             exit 1
           end);
      (* a resolver-driven env: the semantic VariantIds are the
         resolver's dense closure-wide enumeration, so the second enum's
         ids are NOT its declaration positions — the driver's
         table-builder must still reproduce the manual construction
         shape (name -> index -> payloads; ctor -> (enum, variant)) from
         the typed nominals alone *)
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
      let a_specs =
        [
          ("A0", { Mir_lower.vs_index = 0; vs_fields = [] });
          ("A1", { Mir_lower.vs_index = 1; vs_fields = [ int_ty ] });
        ]
      in
      let b_specs =
        [
          ("B0", { Mir_lower.vs_index = 0; vs_fields = [] });
          ("B1", { Mir_lower.vs_index = 1; vs_fields = [ int_ty ] });
          ("B2", { Mir_lower.vs_index = 2; vs_fields = [ int_ty; int_ty ] });
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
                       Ids.Variant_id.compare vd.Seed_mir.vd_id
                         (List.nth b_ids spec.Mir_lower.vs_index)
                       = 0))
             b_specs
      in
      if enums_ok && ctors_ok && ids_ok then
        Printf.printf
          "  user-enum table (resolver env): PASS (A/B entries in the manual shape; B's semantic VariantIds [2;3;4] are non-positional and aligned with the table indices via the EnumDefs)\n"
      else begin
        Printf.printf "  user-enum table (resolver env): FAIL (enums_ok=%b ctors_ok=%b ids_ok=%b)\n"
          enums_ok ctors_ok ids_ok;
        exit 1
      end;
      ignore a_nom;
      let option_tid = List.assoc "Option" tcheck_env.Typecheck.type_ids in
      let result_tid = List.assoc "Result" tcheck_env.Typecheck.type_ids in
      let color_tid = List.assoc "Color" tcheck_env.Typecheck.type_ids in
      let option_int = Type_repr.Named (option_tid, [| int_ty |]) in
      let result_int_int = Type_repr.Named (result_tid, [| int_ty; int_ty |]) in
      let color_ty = Type_repr.Named (color_tid, [||]) in
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
          Mir_lower.types =
            [
              ("Color", color_ty);
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
          fn_ret = int_ty;
          struct_fields = Driver.struct_fields_of tcheck_env;
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
                    (* semantic VariantIds are minted 1-based in
                       declaration order — the same deterministic scheme
                       the typechecker's fallback registration and
                       mir_lower's semantic_variant_id use (the lowered
                       Downcast projections carry these ids) *)
                    Seed_mir.vd_id = Ids.Variant_id.make (i + 1);
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
            |];
        }
      in
      (match Mir_verify.require_valid prog with
       | Ok () -> Printf.printf "  MIR verify: PASS (%d functions)\n" (Array.length prog.Seed_mir.functions)
       | Error errs ->
           Printf.printf "  MIR verify: FAIL\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Printf.printf "%s\n" (Seed_mir.print_program prog);
           exit 1);
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
          fn_body = Ast.FnExpr (Ast.IntLit ("0", Span.synthetic));
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
                    if ret_val = "113" then Printf.printf "  RESULT: PASS\n"
                    else begin
                      Printf.printf "  RESULT: FAIL (expected 113)\n";
                      exit 1
                    end
                | Error m -> Printf.printf "  main returned: <inspect failed: %s>\n" m)));
      (* ── struct-field lowering proof (re-audit's first priority: Field
         access must reach MIR lowering through a typed place (FieldId)
         rule — the ordinary lowering surface's first item) ─────────
         A two-field struct Pair: make_pair CONSTRUCTS a Pair value as a
         StructCtor aggregate with the typed field indices (the seed's
         aggregate construction form — source-level struct literals are
         still gated at the frontend), and read_a/read_b read `.a`/`.b`
         through the LOWERED Field projection.  The proof shows:
         (1) the driver's registry builder (struct_fields_of on the
         TYPED registry — the same source closure_types materializes
         the StructDefs from) reproduces the manual Pair table exactly,
         with the semantic FieldIds;
         (2) the lowered read functions carry the Field projection with
         the semantic FieldId MATCHING the StructDef installed into
         program.types (the verifier's owner-identity rule);
         (3) the whole program passes Mir_verify.require_valid and the
         VM round-trips the field values (main = 21 + 42 = 63). *)
      let field_src = {|
struct Pair
  a: Int
  b: Int
end

def make_pair(a: Int, b: Int) -> Pair
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
      let pair_fields = [ ("a", fid_a, int_ty); ("b", fid_b, int_ty) ] in
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
          fn_ret = int_ty;
          struct_fields = Driver.struct_fields_of fenv;
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
         declaration order; the lowered Field projections resolve
         through the semantic FieldIds of the def — the declaration
         position is def metadata, never in the projection) *)
      let make_pair_fn : Seed_mir.function_ =
        {
          Seed_mir.name = "make_pair";
          instance =
            Instance_id.make ~callable:(fts_of "make_pair").Typecheck.ts_callable ~type_args:[||];
          params =
            [|
              { Type_repr.pt_convention = Access_effect.Let; pt_type = int_ty };
              { Type_repr.pt_convention = Access_effect.Let; pt_type = int_ty };
            |];
          locals = [| Type_repr.Named (pair_tid, [||]); int_ty; int_ty |];
          blocks =
            [|
              {
                Seed_mir.id = 0;
                statements =
                  [
                    Seed_mir.Assign
                      ( { Seed_mir.local = 0; projections = [] },
                        Seed_mir.Aggregate
                          ( Seed_mir.StructCtor
                              ( pair_tid,
                                [| Ids.Field_index.make 0; Ids.Field_index.make 1 |] ),
                            [
                              Seed_mir.Copy { Seed_mir.local = 1; projections = [] };
                              Seed_mir.Copy { Seed_mir.local = 2; projections = [] };
                            ] ) );
                  ];
                terminator = Seed_mir.Ret;
              };
            |];
          entry = 0;
        }
      in
      let fprog : Seed_mir.program =
        {
          Seed_mir.functions =
            Array.of_list
              (make_pair_fn
               :: List.filter (fun f -> f.Seed_mir.name <> "make_pair") fmir_funcs);
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
                 (fun (fname, fid, _ : string * Ids.Field_id.t * Type_repr.t) ->
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
      (match Mir_verify.require_valid fprog with
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
           let ty_ast, cast_span, inner_span =
             match cast_fn_decl.Ast.fn_body with
             | Ast.FnExpr (Ast.Cast (Ast.Name (_, ispan), ty, span)) -> (ty, span, ispan)
             | Ast.FnBlock { Ast.b_tail = Some (Ast.Cast (Ast.Name (_, ispan), ty, span)); _ } ->
                 (ty, span, ispan)
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
             match List.assoc_opt (cfid, cast_span.Span.start) map with
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
           (match List.assoc_opt (cfid, inner_span.Span.start) map with
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
           ignore pid_t)
