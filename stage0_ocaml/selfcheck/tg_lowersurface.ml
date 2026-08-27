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
     (g) the projected-move surface proof (audit P0): the lowered
         surface NEVER emits a projected Move/Consume (the seed VM has
         no partial-move representation — `Move p` transitions the
         WHOLE root slot to Moved, ignoring p.projections — so the
         lowerer moves whole roots only): a full scan of the lowered
         surface program finds ZERO projected transfers and a non-zero
         number of whole-root moves (the `?` failure paths), and a
         source program whose match arm must bind a NON-COPY payload
         (which would require a projected move) fails closed at
         lowering with the precise "non-Copy payload binding" Seed_bug.

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

(* ── variant table for the user enum (the SEMANTIC ids from the
      typed registry: this env is resolver-free, so the typechecker's
      fallback registration mints the canonical 1-based ids; the driver
      reproduces them below — the vs_id / vs_index split proves the
      lowerer carries identity and runtime tag independently) ─────── *)
let color_specs =
  [
    ("Red", { Mir_lower.vs_id = Ids.Variant_id.make 1; vs_index = 0; vs_fields = [] });
    ("Green", { Mir_lower.vs_id = Ids.Variant_id.make 2; vs_index = 1; vs_fields = [ int_ty ] });
    ("Blue", { Mir_lower.vs_id = Ids.Variant_id.make 3; vs_index = 2; vs_fields = [ int_ty; int_ty ] });
  ]

let color_ctors = List.map (fun (n, spec) -> (n, ("Color", n, spec))) color_specs

(* the builtin Option/Result carry their SEMANTIC ids through the same
   registry channel (vt_builtin): the bare compiler-seeded nominals have
   no nom_variant_ids, so the canonical no-resolver minting is
   make (i + 1) — exactly what the driver's user_variant_table produces
   and what the hand-built EnumDefs below materialize *)
let variant_table : Mir_lower.variant_table =
  {
    vt_enums = [ ("Color", color_specs) ];
    vt_ctors = List.map (fun (n, (e, v, _)) -> (n, (e, v))) color_ctors;
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
         must reproduce the manual Color table above exactly, with each
         spec's vs_id the SEMANTIC VariantId from nom_variant_ids — the
         identity the closure_types EnumDefs materialize — and the
         vs_index the declaration-order position, independently) *)
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
          ("A0", { Mir_lower.vs_id = Ids.Variant_id.make 0; vs_index = 0; vs_fields = [] });
          ("A1", { Mir_lower.vs_id = Ids.Variant_id.make 1; vs_index = 1; vs_fields = [ int_ty ] });
        ]
      in
      let b_specs =
        [
          ("B0", { Mir_lower.vs_id = Ids.Variant_id.make 2; vs_index = 0; vs_fields = [] });
          ("B1", { Mir_lower.vs_id = Ids.Variant_id.make 3; vs_index = 1; vs_fields = [ int_ty ] });
          ("B2", { Mir_lower.vs_id = Ids.Variant_id.make 4; vs_index = 2; vs_fields = [ int_ty; int_ty ] });
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
                    (* this resolver-free program's semantic VariantIds
                       are the canonical 1-based minting (the
                       typechecker's fallback registration and the
                       driver's registry channel agree) — the lowered
                       Downcast projections carry the SAME vs_ids the
                       table carries, so these defs reconcile them *)
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
      (match Mir_verify.require_valid_template prog with
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
      (* (2) fail-closed: a match arm that must BIND A NON-COPY PAYLOAD
         would require a projected move (the payload lives inside the
         subject's variant), which the seed cannot execute — the
         lowerer must fail closed with the precise Seed_bug, never emit
         the projected move *)
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
                  (try
                     ignore
                       (Mir_lower.lower_function_with_variants variant_table
                          { env2 with Mir_lower.fn_ret = nts.Typecheck.ts_return }
                          "f" (Ids.Callable_id.to_int nts.Typecheck.ts_callable) [||] [||] nfd);
                     Printf.printf
                       "  non-Copy payload binding: FAIL (lowering succeeded — a projected move would have been emitted)\n";
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
                       if contains_sub m "non-Copy payload binding in a variant match arm" then
                         Printf.printf
                           "  non-Copy payload binding: PASS (lowering fails closed on a String payload binding: %s)\n"
                           m
                       else begin
                         Printf.printf "  non-Copy payload binding: FAIL (wrong Seed_bug: %s)\n" m;
                         exit 1
                       end)
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
       let place l = { Seed_mir.local = l; projections = [] } in
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
                              { local = 1; projections = [ Seed_mir.Field fid_first ] }) );
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
                              { local = 1; projections = [ Seed_mir.Field (Ids.Field_id.make 999) ] }) );
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
                    if ret_val = "113" then Printf.printf "  RESULT: PASS\n"
                    else begin
                      Printf.printf "  RESULT: FAIL (expected 113)\n";
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
             | Some (Seed_mir.Copy p) -> p.Seed_mir.local = local
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
                let call_span =
                  match main_decl.Ast.fn_body with
                  | Ast.FnExpr (Ast.Call (_, _, _, span)) -> span
                  | Ast.FnBlock { Ast.b_tail = Some (Ast.Call (_, _, _, span)); _ } -> span
                  | _ -> failwith "typed-call proof: main body is not `idfn[Int](42)`"
                in
                let n_map = Driver.typed_nodes_of nenv in
                let call_node =
                  match List.assoc_opt (nfid, call_span.Span.start) n_map with
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
                (match call_node.Mir_lower.tn_call with
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
          lowered_methods = 0;
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
         match List.find_opt (fun (n, _, _) -> n = name) l_reg with
         | Some (_, fid, _) -> fid
         | None -> failwith ("struct-lit proof: no registry FieldId for " ^ name)
       in
       let l_pos name =
         let rec go i = function
           | [] -> failwith ("struct-lit proof: field " ^ name ^ " not in the registry")
           | (n, _, _) :: rest -> if n = name then i else go (i + 1) rest
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
           fn_ret = int_ty;
           struct_fields = Driver.struct_fields_of lenv;
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
       let lit_span =
         match make_pair_decl.Ast.fn_body with
         | Ast.FnBlock { Ast.b_tail = Some (Ast.StructLit (_, _, _, _, span)); _ } -> span
         | _ -> failwith "struct-lit proof: make_pair body is not a StructLit tail"
       in
       (match List.assoc_opt (lit_span.Span.file_id, lit_span.Span.start) (Driver.typed_nodes_of lenv) with
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
              | Some (Seed_mir.Copy p) -> p.Seed_mir.local = local
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
                (String.concat ", " (List.map (fun (n, _, _) -> n) l_reg));
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
                       (fun i (_, fid, fty) ->
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
         match List.find_opt (fun (n, _, _) -> n = name) m_reg with
         | Some (_, fid, _) -> fid
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
                 } );
             ];
           fn_ret = int_ty;
           struct_fields = Driver.struct_fields_of menv;
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
                       (fun i (_, fid, fty) ->
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
       let mcall_span =
         match mmain_decl.Ast.fn_body with
         | Ast.FnBlock { Ast.b_tail = Some (Ast.Call (_, _, _, span)); _ } -> span
         | _ -> failwith "method-call proof: main body is not a call tail"
       in
       (match
          List.assoc_opt (mcall_span.Span.file_id, mcall_span.Span.start)
            (Driver.typed_nodes_of menv)
        with
        | Some node -> (
            match node.Mir_lower.tn_call with
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
                     match mmain_fn.Seed_mir.locals.(p.Seed_mir.local) with
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
                methods = [];
                fn_ret = int_ty;
                struct_fields =
                  [ (fs_tid, [ ("a", l_fid_a, int_ty); ("b", l_fid_b, int_ty) ]) ];
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
            lower_expect_bug "missing_field" "initializes 1 of 2 field(s)";
            lower_expect_bug "unknown_field" "unknown field `c`";
            lower_expect_bug "spread_lit" "`..` spread");
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
                Mir_lower.types =
                  [
                    ("Int", int_ty);
                    ("Unit", Type_repr.Unit);
                    ("Bool", Type_repr.Bool);
                    ("String", string_ty);
                  ];
                values = [];
                callables = [];
                methods = [];
                fn_ret = int_ty;
                struct_fields = [];
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
           lowered_methods = 0;
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
       ignore menv2
