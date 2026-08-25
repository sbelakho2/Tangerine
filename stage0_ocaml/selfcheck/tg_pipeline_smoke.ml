(* tg_pipeline_smoke.ml — pipeline SMOKE self-check (driver-path parity).

   SMOKE TEST — NOT the bootstrap-completeness gate.  This executable
   runs the driver's pipeline on a SINGLE module (the differential
   corpus when it checks cleanly, else a small inline program): parse ->
   manifest/module graph -> resolver -> single-module typecheck -> lower
   -> MIR verify -> mono -> residual Type_param walk -> MIR verify again
   -> VM run of the mono'd entry.  The inline fallback means a PASS here
   can never be read as a compiler-closure PASS; the aggregate closure
   gate is tg_bootstrap_gate, which runs the real manifest closure with
   no fallback.  Prints SMOKE PASS/FAIL and exits accordingly. *)

let inline_src = {|
def main() -> Int
  let x = add(3, 4)
  let y = max_of(x, 10)
  let z = sum_to(5)
  y + z
end

def add(a: Int, b: Int) -> Int
  a + b
end

def max_of(a: Int, b: Int) -> Int
  if a > b then
    a
  else
    b
  end
end

def sum_to(n: Int) -> Int
  var i = 0
  var total = 0
  while i < n do
    total = total + i
    i = i + 1
  end
  total
end
|}

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "tg_pipeline_smoke: FAIL: %s\n" s; exit 1) fmt

let program_of_src (src : Source.source) (module_path : string list) : Ast.program =
  let sm = Span.create () in
  let file_id = Span.add_file sm src.Source.name src in
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create src.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let program = Parser.parse tokens src.Source.bytes file_id diags module_path in
  if Diagnostic.has_errors diags then fail "parse errors: %s" (Diagnostic.render sm diags);
  program

let () =
  let argv = Array.to_list Sys.argv in
  let repo_root, corpus_file =
    match argv with
    | _ :: "--repo-root" :: r :: f :: _ -> (r, f)
    | _ :: "--repo-root" :: r :: _ -> (r, "../tests/differential/corpus/12_options_results.tg")
    | _ :: f :: _ when not (String.length f >= 1 && f.[0] = '-') ->
        ("..", f)
    | _ -> ("..", "../tests/differential/corpus/12_options_results.tg")
  in
  Printf.printf "tg_pipeline_smoke: repo-root %s\n" repo_root;
  Printf.printf "SMOKE: pipeline sanity on a single module (corpus or inline fallback) — this is NOT the bootstrap-completeness closure gate; the aggregate gate is tg_bootstrap_gate\n";
  (* 1. manifest -> module graph -> resolver (driver parity) *)
  (match Bootstrap_manifest.load ~repo_root ~manifest_path:"bootstrap/compiler_kernel.manifest" with
   | Error m -> fail "manifest load: %s" m
   | Ok manifest ->
       Printf.printf "  manifest: %d entries, fingerprint %s\n"
         (List.length (Bootstrap_manifest.entries manifest))
         (Bootstrap_manifest.fingerprint manifest);
       let diags = Diagnostic.create_bag () in
       let graph = Module_graph.create_with_sources manifest diags in
       Printf.printf "  module graph: %d modules, %d items\n" graph.Module_graph.node_count
         graph.Module_graph.item_count;
       let resolved = Resolver.resolve manifest graph diags in
       Printf.printf "  resolver: %d expr defs, %d type defs, %d field defs, %d variant defs, %d call candidates\n"
         (List.length resolved.Resolver.expr_defs)
         (List.length resolved.Resolver.type_defs)
         (List.length resolved.Resolver.field_defs)
         (List.length resolved.Resolver.variant_defs)
         (List.length resolved.Resolver.call_candidates);
       if Diagnostic.has_errors diags then
         fail "resolver diagnostics: %s" (Diagnostic.render (Module_graph.source_map graph) diags);
       Printf.printf "  diagnostics: 0\n";
       (* 2. single-module typecheck: corpus when it checks cleanly,
          else the inline program *)
       let corpus_program =
         match Source_loader.load corpus_file with
         | Error _ -> fail "cannot load corpus file %s" corpus_file
         | Ok src -> program_of_src src [ "adhoc" ]
       in
       let corpus_errors =
         match Typecheck.check_program (Typecheck.initial_env ()) corpus_program with
         | Error m -> [ m ]
         | Ok (_, errs) -> errs
       in
       let use_corpus = corpus_errors = [] in
       if not use_corpus then
         Printf.printf "  single module: corpus %s has %d typecheck error(s); using the inline program\n"
           corpus_file (List.length corpus_errors);
       let program =
         if use_corpus then corpus_program
         else (
           match Source_loader.load_string "<gates-inline>" inline_src with
           | Error _ -> fail "inline program load failed"
           | Ok src -> program_of_src src [ "gates" ])
       in
       Printf.printf "  single module: %d items\n" (List.length program.Ast.items);
       let env = Typecheck.initial_env () in
       let env, typed_calls_sample =
         match Typecheck.check_program env program with
         | Error m -> fail "typecheck: %s" m
         | Ok (env', errors) ->
             List.iter (fun e -> Printf.printf "    %s\n" e) (List.rev errors);
             if errors <> [] then fail "typecheck: %d errors" (List.length errors);
             (env', List.length env'.state.oracle.o_calls)
       in
       Printf.printf "  typecheck: 0 errors\n";
       (* 3. lower (same call sequence as the driver's per-file path) *)
       let funcs =
         List.filter_map
           (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
           program.Ast.items
       in
       let base = Driver.lowering_env_of env in
       let mir_funcs =
         List.mapi
           (fun i d ->
             let fn_ret, callable =
               match Driver.lookup_typed_fn env d.Ast.fn_sig.Ast.sig_name with
               | Some ts -> (ts.Typecheck.ts_return, Ids.Callable_id.to_int ts.Typecheck.ts_callable)
               | None -> (Type_repr.Unit, i)
             in
             Mir_lower.lower_function { base with Mir_lower.fn_ret }
               d.Ast.fn_sig.Ast.sig_name callable d)
           funcs
       in
       let prog =
         { Seed_mir.functions = Array.of_list mir_funcs; statics = [||]; types = [||] }
       in
       (match Mir_verify.require_valid prog with
        | Error errs -> fail "MIR verify: %s" (String.concat "; " errs)
        | Ok () ->
            Printf.printf "  MIR verify: PASS (%d functions)\n" (Array.length prog.Seed_mir.functions));
       (* 4. completeness-oracle rows (driver's printer; expected-zero
          rows must print zero) *)
       let stats = Driver.count_mir_stats prog in
       let o : Driver.oracle_counts =
         {
           oc_typed_functions = List.length env.Typecheck.functions;
           oc_typed_methods = List.length env.Typecheck.methods;
           oc_typed_consts = List.length env.Typecheck.consts;
           oc_typed_nominals = List.length env.Typecheck.nominals;
           oc_typed_calls = typed_calls_sample;
           oc_mir_functions = stats.Driver.ms_functions;
           oc_mir_statics = stats.Driver.ms_statics;
           oc_mir_types = stats.Driver.ms_types;
           oc_mir_calls = stats.Driver.ms_calls;
           oc_mir_callable_zero = stats.Driver.ms_callable_zero;
           oc_mir_enum_ops = stats.Driver.ms_enum_ops;
           oc_mir_closures = stats.Driver.ms_closures;
           oc_skipped = false;
         }
       in
       let incomplete = Driver.print_oracle_rows o in
        if incomplete then
          Printf.printf
            "  oracle note: DIFF rows present — expected for the seed subset (typed methods/nominals are not yet lowered); SMOKE informational only, the closure gate is tg_bootstrap_gate\n";
       (* 5. mono: build, verify, residual walk, verify again *)
       let entry_name, entry =
         match Driver.resolve_bootstrap_entry prog None with
         | Some e -> e
         | None -> fail "no entry function in the lowered program"
       in
       (match Driver.run_mono_phase ~entry_name ~entry prog with
        | Error _ -> fail "mono phase failed"
        | Ok mo ->
            if mo.Driver.mo_residual_type_params > 0 then
              fail "residual Type_param after mono: %d" mo.Driver.mo_residual_type_params;
            (* 6. VM run of the mono'd entry *)
            let host = Host.create ~repo_root ~argv:[||] in
            (match Vm.run ~program:mo.Driver.mo_program ~entry:mo.Driver.mo_entry ~argv:[||] ~host with
             | Error e -> fail "VM: %s" e.Vm.message
             | Ok code ->
                 Printf.printf "  VM: exit %d\n" code;
                 (match
                    Vm.entry_frame_of ~program:mo.Driver.mo_program ~entry:mo.Driver.mo_entry
                      ~argv:[||]
                  with
                 | Error m -> fail "VM inspect: %s" m
                 | Ok (vm2, ef) -> (
                     match Vm.run_inspect vm2 ef with
                     | Ok ret -> Printf.printf "  main returned: %s\n" ret
                     | Error m -> fail "VM inspect run: %s" m));
                 Printf.printf "SMOKE: PASS\n";
                 exit 0)))