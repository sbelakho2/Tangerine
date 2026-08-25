(* tg_selfcheck.ml — Resolver self-check.

   Parses and resolves a single Tangerine source file (default: the
   differential corpus 11_modules.tg) through the bootstrap pipeline
   (manifest -> module graph -> resolver) and reports the resolved item
   counts.  Exits 0 only when resolution produced no diagnostics. *)

let default_file = "../tests/differential/corpus/11_modules.tg"
let default_path = [ "tests"; "differential"; "corpus"; "11_modules" ]

let corpus_args () =
  match Array.to_list Sys.argv with
  | _ :: file :: path_segs when path_segs <> [] ->
      (file, List.rev path_segs)
  | _ :: file :: [] -> (file, default_path)
  | _ -> (default_file, default_path)

let () =
  let file, module_path = corpus_args () in
  let diags = Diagnostic.create_bag () in
  let manifest =
    match
      Bootstrap_manifest.single
        ~version:(List.hd Bootstrap_manifest.supported_versions)
        ~file ~path:module_path ()
    with
    | Ok m -> m
    | Error e ->
        Printf.eprintf "self-check: cannot load single-module manifest for %s: %s\n" file e;
        exit 1
  in
  let graph = Module_graph.create manifest diags in
  let resolved = Resolver.resolve manifest graph diags in
  Printf.printf "self-check: %s\n" file;
  Printf.printf "  manifest module: %s\n" (String.concat "::" module_path);
  Printf.printf "  modules: %d\n" (graph.Module_graph.node_count);
  Printf.printf "  items: %d\n" (graph.Module_graph.item_count);
  Printf.printf "  expr_defs: %d\n" (List.length resolved.Resolver.expr_defs);
  Printf.printf "  type_defs: %d\n" (List.length resolved.Resolver.type_defs);
  Printf.printf "  field_defs: %d\n" (List.length resolved.Resolver.field_defs);
  Printf.printf "  variant_defs: %d\n" (List.length resolved.Resolver.variant_defs);
  Printf.printf "  call_candidates: %d\n" (List.length resolved.Resolver.call_candidates);
  if Diagnostic.has_errors diags || Diagnostic.has_warnings diags then begin
    Printf.printf "  diagnostics: %d errors, %d warnings\n"
      (Diagnostic.error_count diags)
      (Diagnostic.warning_count diags);
    prerr_string (Diagnostic.render (Module_graph.source_map graph) diags);
    prerr_newline ();
    exit 1
  end
  else begin
    Printf.printf "  diagnostics: 0\n";
    Printf.printf "OK: parse + resolve succeeded with no diagnostics\n";
    exit 0
  end

(* Abstraction proof: a Type_id is accepted at the Type_repr.Named boundary. *)
let _ : Type_repr.t = Type_repr.Named (Ids_core.Type_id.make 1, [||])
