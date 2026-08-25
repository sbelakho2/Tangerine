(* tg_evidence.ml — deterministic per-phase pipeline evidence record.

   Runs the SAME pipeline functions the driver's bootstrap-check / compile
   use (src/driver.ml cmd_bootstrap_check): Bootstrap_manifest.load ->
   fingerprint -> Module_graph.create_with_sources -> Resolver.resolve ->
   the typecheck fixpoint (registration is non-fatal; modules with errors
   retry with the growing env until no module makes progress or the
   8-round cap) -> lowering (Driver.lower_closure) -> mono (Mono.build +
   residual Type_param walk + Mir_verify).  The driver's pipeline helpers
   print diagnostics to stdout, so this tool replicates the minimal call
   sequence with the same underlying functions and reuses the driver's
   non-printing helpers (Driver.lower_closure, Driver.resolve_bootstrap_entry,
   Driver.count_residual_type_params); module order is the driver's
   topological order (topological_nodes in src/driver.ml) minus its debug
   prints.

   Emits one `evidence <phase> ...` line per phase on stdout, in a fixed
   order, byte-identical across runs EXCEPT the run= line (unix epoch
   seconds), and exits 0 even when the gates fail (evidence is recorded,
   not gated).

   Phase fingerprint contract: every line is a canonical, order-stable
   hash/count.  The Swift seed (stage1-S) is expected to emit the
   equivalent lines for its own pipeline; the audit's Swift->OCaml
   migration comparison requires the phase fingerprints to MATCH between
   seeds for equivalent phases — the manifest line in particular, because
   both seeds consume the same bootstrap/compiler_kernel.manifest closure.

   Usage: tg_evidence.exe <repo-root>  (defaults to ".." when omitted). *)

let die fmt = Printf.ksprintf (fun s -> prerr_endline ("tg_evidence: " ^ s); exit 1) fmt

let repo_root =
  match Array.to_list Sys.argv with _ :: r :: _ -> r | _ -> ".."

let manifest_path = "bootstrap/compiler_kernel.manifest"

(* ── manifest -> fingerprint ────────────────────────────────────── *)

let manifest =
  match Bootstrap_manifest.load ~repo_root ~manifest_path with
  | Error m -> die "manifest load: %s" m
  | Ok m -> m

(* The evidence fingerprint is the loaded record's fingerprint, which is
   SHA-256 over the canonical manifest sequence (src/bootstrap_manifest.ml
   fingerprint_of): manifest content, "\n\000", version, "\n\000", then per
   entry in manifest order, '\000'-separated: logical module path, '\001',
   relative source path, '\001', source byte length, '\001', source SHA-256.
   Recompute it here with Sha256 to prove the evidence value is exactly the
   canonical-sequence hash (and that the loaded record agrees). *)
let verify_canonical_fingerprint (m : Bootstrap_manifest.t) (content : string) : bool =
  let buf = Buffer.create (String.length content + 64) in
  Buffer.add_string buf content;
  Buffer.add_string buf "\n\000";
  Buffer.add_string buf (match Bootstrap_manifest.version_of m with Some v -> v | None -> "");
  Buffer.add_string buf "\n\000";
  List.iteri
    (fun i e ->
      if i > 0 then Buffer.add_char buf '\000';
      Buffer.add_string buf (String.concat "::" e.Bootstrap_manifest.path);
      Buffer.add_char buf '\001';
      Buffer.add_string buf e.Bootstrap_manifest.file;
      Buffer.add_char buf '\001';
      Buffer.add_string buf (string_of_int (String.length e.Bootstrap_manifest.source));
      Buffer.add_char buf '\001';
      Buffer.add_string buf e.Bootstrap_manifest.source_hash)
    (Bootstrap_manifest.entries m);
  Sha256.digest (Buffer.contents buf) = Bootstrap_manifest.fingerprint m

let () =
  let manifest_content =
    let p =
      if Filename.is_relative manifest_path then Filename.concat repo_root manifest_path
      else manifest_path
    in
    match Source_loader.load p with
    | Error _ -> die "cannot re-read manifest for fingerprint verification: %s" p
    | Ok s -> s.Source.bytes
  in
  let fp = Bootstrap_manifest.fingerprint manifest in
  if not (verify_canonical_fingerprint manifest manifest_content) then
    die "fingerprint mismatch: canonical-sequence SHA-256 differs from the loaded record";
  Printf.printf "evidence manifest=%s\n" fp;

  (* ── module graph ──────────────────────────────────────────────── *)
  let diags = Diagnostic.create_bag () in
  let graph = Module_graph.create_with_sources manifest diags in
  Printf.printf "evidence graph modules=%d items=%d\n" graph.Module_graph.node_count
    graph.Module_graph.item_count;

  (* ── resolver ──────────────────────────────────────────────────── *)
  let resolved = Resolver.resolve manifest graph diags in
  if Diagnostic.has_errors diags then
    die "resolver diagnostics: %s" (Diagnostic.render (Module_graph.source_map graph) diags);
  let n_entries = List.length (Bootstrap_manifest.entries manifest) in
  let expr = List.length resolved.Resolver.expr_defs in
  let type_ = List.length resolved.Resolver.type_defs in
  let field = List.length resolved.Resolver.field_defs in
  let variant = List.length resolved.Resolver.variant_defs in
  let calls = List.length resolved.Resolver.call_candidates in
  Printf.printf "evidence resolver entries=%d defs=%d expr=%d type=%d field=%d variant=%d calls=%d\n"
    n_entries (expr + type_ + field + variant) expr type_ field variant calls;

  (* ── typecheck fixpoint (driver parity) ────────────────────────── *)

  (* Driver-parity module order (driver.ml topological_nodes): dedupe
     nodes by source file (lib_kernel re-export subtrees alias files),
     Kahn topological order over import edges, manifest-order fallback for
     the cyclic remainder. *)
  let topological_nodes (graph : Module_graph.t) : Module_graph.module_node list =
    let seen_files = Hashtbl.create 64 in
    let canonical =
      List.filter
        (fun node ->
          if Hashtbl.mem seen_files node.Module_graph.node_file then false
          else begin
            Hashtbl.add seen_files node.Module_graph.node_file ();
            true
          end)
        graph.Module_graph.nodes
    in
    let nodes = Array.of_list canonical in
    let n = Array.length nodes in
    let by_path = Hashtbl.create 64 in
    Array.iteri
      (fun i node -> Hashtbl.replace by_path (String.concat "::" node.Module_graph.node_path) i)
      nodes;
    let deps = Array.make n [] in
    let rdeps = Array.make n [] in
    Array.iteri
      (fun i node ->
        let imports =
          List.filter_map
            (fun it -> match it.Ast.kind with Ast.UseDecl u -> Some u | _ -> None)
            node.Module_graph.node_program.Ast.items
        in
        let add (path : string list) =
          match Hashtbl.find_opt by_path (String.concat "::" path) with
          | Some j when j <> i ->
              deps.(i) <- j :: deps.(i);
              rdeps.(j) <- i :: rdeps.(j)
          | _ -> ()
        in
        List.iter
          (fun (u : Ast.use_decl) ->
            match u.Ast.u_path with
            | Ast.UseSimple p | Ast.UseAliased (p, _) | Ast.UseGlob p -> add p
            | Ast.UseGroup (p, items) ->
                add p;
                List.iter
                  (fun (it : Ast.use_item) -> add (p @ [ it.Ast.ui_name ]))
                  items)
          imports)
      nodes;
    let indeg = Array.map List.length deps in
    let queue = Queue.create () in
    Array.iteri (fun i d -> if d = 0 then Queue.push i queue) indeg;
    let order = ref [] in
    while not (Queue.is_empty queue) do
      let i = Queue.pop queue in
      order := i :: !order;
      List.iter
        (fun j ->
          indeg.(j) <- indeg.(j) - 1;
          if indeg.(j) = 0 then Queue.push j queue)
        rdeps.(i)
    done;
    let order = List.rev !order in
    if List.length order <> n then begin
      let in_order = Hashtbl.create 16 in
      List.iter (fun i -> Hashtbl.add in_order i ()) order;
      let rest =
        List.filter (fun i -> not (Hashtbl.mem in_order i)) (List.init n Fun.id)
      in
      List.map (Array.get nodes) (order @ rest)
    end
    else List.map (Array.get nodes) order
  in
  let env = ref (Typecheck.initial_env ()) in
  let errs_by_mod : (string, string list) Hashtbl.t = Hashtbl.create 64 in
  let pending = ref (topological_nodes graph) in
  let rounds = ref 0 in
  while !pending <> [] && !rounds < 8 do
    incr rounds;
    let this_round = !pending in
    pending := [];
    List.iter
      (fun node ->
        let key = String.concat "::" node.Module_graph.node_path in
        match Typecheck.check_program !env node.Module_graph.node_program with
        | Error m -> Hashtbl.replace errs_by_mod key [ m ]
        | Ok (env', errors) ->
            env := env';
            Hashtbl.replace errs_by_mod key errors;
            if errors <> [] then pending := node :: !pending)
      this_round
  done;
  let type_errors =
    Hashtbl.fold
      (fun key errs acc -> List.map (fun e -> key ^ ": " ^ e) errs @ acc)
      errs_by_mod []
  in
  let n_errors = List.length type_errors in
  Printf.printf "evidence typecheck errors=%d rounds=%d\n" n_errors !rounds;

  (* ── lowering + mono counts ────────────────────────────────────── *)
  let ctx : Driver.closure_ctx =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> die "target: %s" m
    | Ok target ->
        {
          Driver.ctx_repo_root = repo_root;
          ctx_manifest_path = manifest_path;
          ctx_target = target;
          ctx_graph = graph;
          ctx_resolved = resolved;
          ctx_env = !env;
          ctx_type_errors = type_errors;
          ctx_items = graph.Module_graph.item_count;
          ctx_typed_calls_sample = 0;
          ctx_rounds = !rounds;
        }
  in
  let frontend = if n_errors = 0 then "PASS" else "FAIL" in
  let structural, mono_gate, pre, post, residual =
    if n_errors = 0 then begin
      let prog = Driver.lower_closure ctx in
      match Mir_verify.require_valid prog with
      | Error _ -> ("FAIL", "SKIPPED", 0, 0, 0)
      | Ok () -> (
          match Driver.resolve_bootstrap_entry prog None with
          | None -> ("PASS", "SKIPPED", 0, 0, 0)
          | Some (_, entry) -> (
              match Mono.build ~entry prog with
              | Error _ -> ("PASS", "FAIL", Array.length prog.Seed_mir.functions, 0, 0)
              | Ok fns ->
                  let mono_prog = { prog with Seed_mir.functions = fns } in
                  let pre = Array.length prog.Seed_mir.functions in
                  let post = Array.length fns in
                  let residual = Driver.count_residual_type_params mono_prog in
                  (match Mir_verify.require_valid mono_prog with
                   | Error _ -> ("PASS", "FAIL", pre, post, residual)
                   | Ok () -> ("PASS", "PASS", pre, post, residual))))
    end
    else ("SKIPPED", "SKIPPED", 0, 0, 0)
  in
  Printf.printf "evidence mono pre=%d post=%d residual=%d skipped=%d\n" pre post residual
    (if n_errors = 0 then 0 else 1);
  Printf.printf "evidence gates frontend=%s structural=%s mono=%s\n" frontend structural mono_gate;

  (* ── run stamp (the only non-deterministic line) ───────────────── *)
  Printf.printf "evidence run=%d\n" (int_of_float (Unix.time ()));
  exit 0
