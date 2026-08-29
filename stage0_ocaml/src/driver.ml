(* driver.ml — CLI driver for the OCaml stage0 bootstrap compiler.

   Command surface (audit §47-51):
     lex <file>             Lex and print tokens
     parse <file>           UTF8 -> lex -> parse -> structural verification
     check <file>           parse + bootstrap profile + resolution + typing
     dump-ast <file>        Deterministic AST dump
     dump-resolved <file>   Resolution report
     dump-types <file>      Typing report
     lower <file>           check + mono + Seed MIR + verifier + dump
     interpret <args...>    Interpret a compiled Seed MIR artifact
     compile <args...>      Bootstrap compile (interprets the compiler)
     bootstrap-check        Full seed-quality gate over the manifest
     version / help

   Strict option parsing: an unknown option exits nonzero (audit §47). *)

let version_string = "tg_stage0 0.2.0 (OCaml bootstrap seed)"

let usage =
  {|Usage: tg_stage0 <command> [args]

Commands:
  lex <file>                Lex a .tg file and print tokens
  parse <file>              UTF8 -> lex -> parse -> structural verification
  check <file>              parse + profile + resolution + typing
  dump-ast <file>           Deterministic AST dump
  lower <file>              check + mono + Seed MIR + verifier + dump
  bootstrap-check           Full seed-quality gate over the manifest closure
    --repo-root ROOT
    --manifest FILE
    --target TRIPLE
    --entry NAME
    --strict                Resolve the closure in strict mode (per-module
                            authority; no flat unique-name recovery)
    --diagnostics-jsonl P   Write the structured per-diagnostic JSONL (one
                            JSON object per typecheck diagnostic) to P
  compile ...               Bootstrap compile (interprets the compiler)
    --repo-root ROOT
    --manifest FILE
    --target TRIPLE
    --entry NAME
    --strict                Resolve the closure in strict mode
    --diagnostics-jsonl P   Write the structured per-diagnostic JSONL to P
    -- <kernel args...>     Passed verbatim to the kernel's bootstrap_main
                            (e.g. -- compile hello.tg -o /tmp/out)
  version                   Print version info
  help                      Print this help message
|}

let die fmt = Printf.ksprintf (fun s -> prerr_endline ("error: " ^ s); exit 1) fmt

(* ── Strict option parsing (audit §47) ─────────────────────────── *)

type 'a opt_spec = {
  name : string;
  takes_value : bool;
  apply : string option -> 'a -> 'a;
}

let parse_options (specs : 'a opt_spec list) (default : 'a) (args : string list) :
    'a * string list =
  let rec go acc = function
    | [] -> (acc, [])
    | "--" :: rest -> (acc, rest)   (* everything after -- is positional *)
    | arg :: rest ->
        if String.length arg >= 2 && arg.[0] = '-' && arg <> "-" then begin
          let eq = String.index_opt arg '=' in
          let name, inline =
            match eq with
            | Some i -> (String.sub arg 0 i, Some (String.sub arg (i + 1) (String.length arg - i - 1)))
            | None -> (arg, None)
          in
          match List.find_opt (fun s -> s.name = name) specs with
          | None -> die "unknown option '%s'" name
          | Some spec ->
              if spec.takes_value then begin
                match inline with
                | Some v -> go (spec.apply (Some v) acc) rest
                | None -> (
                    match rest with
                    | v :: rest' when not (String.length v >= 2 && v.[0] = '-') ->
                        go (spec.apply (Some v) acc) rest'
                    | _ -> die "option '%s' requires a value" name)
              end
              else begin
                if inline <> None then die "option '%s' does not take a value" name;
                go (spec.apply None acc) rest
              end
        end
        else (acc, arg :: rest)
  in
  go default args

(* ── Front-end (parse / check / dump-ast) ──────────────────────── *)

let load_source_or_report (path : string) : Source.source option =
  match Source_loader.load path with
  | Ok s -> Some s
  | Error e -> (
      match e with
      | Source_loader.Unreadable p -> die "cannot read file '%s'" p
      | Source_loader.NotUTF8 (p, uerr) ->
          die "E9029: source file is not valid UTF-8: '%s' (%s at byte %d)" p
            (Utf8.error_string uerr.Utf8.kind) uerr.Utf8.offset
      | Source_loader.Security (p, msg) -> die "source security scan failed: '%s' (%s)" p msg)

let front_end (path : string) : (Diagnostic.bag * Span.source_map * Ast.program) =
  let src = match load_source_or_report path with Some s -> s | None -> exit 1 in
  let sm = Span.create () in
  let file_id = Span.add_file sm src.Source.name src in
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create src.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let module_path = Parser.module_path_of_file path in
  let program = Parser.parse tokens src.Source.bytes file_id diags module_path in
  if not (Diagnostic.has_errors diags) then Verify.verify diags program;
  (diags, sm, program)

let report_errors (diags : Diagnostic.bag) (sm : Span.source_map) : unit =
  if Diagnostic.has_errors diags || Diagnostic.has_warnings diags then begin
    prerr_string ("\n" ^ Diagnostic.render sm diags ^ "\n");
    if Diagnostic.has_errors diags then exit 1
  end

(* Flat-namespace signature lookup (kernel code uses bare names). *)
let lookup_typed_fn (env : Typecheck.env) (name : string) : Typecheck.typed_signature option =
  match List.assoc_opt name env.Typecheck.functions with
  | Some ts -> Some ts
  | None -> (
      match List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) env.Typecheck.functions with
      | [ (_, ts) ] -> Some ts
      | _ -> None)

(* ── Struct-field registry (re-audit finding: Field access reached MIR
      lowering without a typed place (FieldId) rule — the lowerer's only
      struct-field emission channel was the out-of-scope typed registry) ──
   Every Struct/Enum nominal of the typed registry crosses into the
   lowering env: Type_id -> (field name, semantic FieldId, field type)
   triples (enums carry no fields — their entries are empty, so a field
   on an enum fails closed at lowering instead of mis-projecting).
   Field types are recorded in the nominal's OWN parameter scope and the
   lowering substitutes the nominal's generic params at each use.  The
   semantic FieldIds are the typed registry's nom_field_ids — the SAME
   identities closure_types materializes into the StructDefs — with the
   same deterministic fallback (1-based declaration order) when the
   identity lists are not parallel to the field lists. *)
(* The const/static VALUE table: the checker's consts registry carries
   the declared types; the literal initializers evaluate into
   Seed_mir.constant values (the E9034 literal forms retire — the
   driver's statics and the lowering env carry the values; the subset
   rejects the non-literal forms until the evaluator grows).  The ctor
   initializer forms (E9034 ctor retirement 2026-08-29) evaluate into
   the new constant forms: a nullary enum-variant value (`Option::None`
   — the variant's runtime tag is its declaration-order position in the
   typed nominal's variant list, the SAME position user_variant_table
   and closure_types materialize as vs_index/vd_index, the EnumCtor tag
   convention; the builtin Option/Result go through the same registry),
   an EMPTY struct literal (`SystemAllocator {}`) and the empty
   container (`Vec::new()`).  Each ctor constant carries the checker's
   instantiated declared type, so verify_statics' constant_type
   comparison is exact. *)
let const_values (env : Typecheck.env) (items : Ast.item list) :
    (string * (Type_repr.t * Seed_mir.constant)) list =
  let variant_tag (qual : string) (vname : string) : int option =
    if qual = "" then
      (* a bare ctor name (`None`): the FIRST nominal carrying the
         variant — the same first-wins convention the variant table's
         vt_ctors channel uses *)
      let rec find = function
        | [] -> None
        | (_, nom) :: rest -> (
            match
              List.assoc_opt vname
                (List.mapi (fun i (vn, _) -> (vn, i)) nom.Typecheck.nom_variants)
            with
            | Some i -> Some i
            | None -> find rest)
      in
      find env.Typecheck.nominals
    else
      match List.filter (fun (name, _) -> name = qual) env.Typecheck.nominals with
      | (_, nom) :: _ ->
          List.assoc_opt vname
            (List.mapi (fun i (vn, _) -> (vn, i)) nom.Typecheck.nom_variants)
      | [] -> None
  in
  let lit_constant (d : Ast.const_decl) (ty : Type_repr.t) :
      Seed_mir.constant option =
    match d.Ast.c_value with
    | Ast.BoolLit (_, b, _) -> Some (Seed_mir.Bool b)
    | Ast.CharLit (_, c, _) -> (
        let b = Bytes.of_string c in
        match Utf8.decode_at b 0 with
        | Ok (u, _) -> Some (Seed_mir.Char u)
        | Error _ -> None)
    | Ast.StringLit (_, s, _) -> Some (Seed_mir.String s)
    | Ast.FloatLit (_, lit, _) -> (
        match float_of_string_opt lit with
        | Some f -> Some (Seed_mir.Float64 (Int64.bits_of_float f))
        | None -> None)
    | Ast.IntLit (_, lit, _) -> (
        match Literal.parse_integer ~span:Span.synthetic lit with
        | Some p -> (
            let kind =
              match p.Literal.suffix with
              | Literal.I8 -> Type_repr.I8 | Literal.I16 -> Type_repr.I16
              | Literal.I32 -> Type_repr.I32 | Literal.I64 -> Type_repr.I64
              | Literal.I128 -> Type_repr.I128
              | Literal.U8 -> Type_repr.U8 | Literal.U16 -> Type_repr.U16
              | Literal.U32 -> Type_repr.U32 | Literal.U64 -> Type_repr.U64
              | Literal.U128 -> Type_repr.U128
              | Literal.Int -> Type_repr.Int | Literal.UInt -> Type_repr.UInt
              | Literal.No_int_suffix -> Type_repr.Int
            in
            if Big_nat.fits_ocaml_int p.Literal.magnitude then
              Some
                (Mir_lower.int_constant_of kind
                   (Int64.of_int (Big_nat.to_ocaml_int p.Literal.magnitude)))
            else None)
        | None -> None)
    | Ast.Unary (_, Ast.Neg, Ast.IntLit (_, lit, _), _) -> (
        (* a negated integer initializer `const MIN: Int = -128` *)
        match Literal.parse_integer ~span:Span.synthetic lit with
        | Some p -> (
            let kind =
              match p.Literal.suffix with
              | Literal.I8 -> Type_repr.I8 | Literal.I16 -> Type_repr.I16
              | Literal.I32 -> Type_repr.I32 | Literal.I64 -> Type_repr.I64
              | Literal.I128 -> Type_repr.I128
              | Literal.U8 -> Type_repr.U8 | Literal.U16 -> Type_repr.U16
              | Literal.U32 -> Type_repr.U32 | Literal.U64 -> Type_repr.U64
              | Literal.U128 -> Type_repr.U128
              | Literal.Int -> Type_repr.Int | Literal.UInt -> Type_repr.UInt
              | Literal.No_int_suffix -> Type_repr.Int
            in
            if Big_nat.fits_ocaml_int p.Literal.magnitude then
              Some
                (Mir_lower.int_constant_of kind
                   (Int64.neg (Int64.of_int (Big_nat.to_ocaml_int p.Literal.magnitude))))
            else None)
        | None -> None)
    | Ast.Name (_, n, _) -> (
        (* a nullary enum-variant ctor value (`Option::None`, or a bare
           `None` / user-enum nullary variant) — the ctor constant *)
        match String.index_opt n ':' with
        | Some i when i + 1 < String.length n && n.[i + 1] = ':' ->
            let qual = String.sub n 0 i in
            let vname = String.sub n (i + 2) (String.length n - i - 2) in
            Option.map
              (fun tag -> Seed_mir.Enum (Ids.Variant_index.make tag, ty))
              (variant_tag qual vname)
        | _ ->
            Option.map
              (fun tag -> Seed_mir.Enum (Ids.Variant_index.make tag, ty))
              (variant_tag "" n))
    | Ast.Call (_, callee, _, args, _) -> (
        (* `Vec::new()` (the empty container — the kernel alias
           `Array::new` served by the same qualified static-call path) *)
        match callee with
        | Ast.Name (_, cname, _)
          when (cname = "Vec::new" || cname = "Array::new") && args = [] ->
            Some (Seed_mir.Array ty)
        | _ -> None)
    | Ast.StructLit (_, _, _, [], None, _) ->
        (* an EMPTY struct literal (`SystemAllocator {}`) — the
           non-empty literal forms stay outside the evaluated set (the
           subset keeps rejecting them) *)
        Some (Seed_mir.Struct ty)
    | _ -> None
  in
  (* the const declarations in the closure, keyed by the qualified and
     the flat name (the checker registers the qualified names) *)
  let bare_keys (n : string) : string list =
    match String.rindex_opt n ':' with
    | Some i -> [ n; String.sub n (i + 1) (String.length n - i - 1) ]
    | None -> [ n ]
  in
  let decl_of (n : string) : Ast.const_decl option =
    List.find_map
      (fun (it : Ast.item) ->
        match it.Ast.kind with
        | Ast.ConstDecl d
          when Typecheck.qualified_name it.Ast.module_path d.c_name = n ->
            Some d
        | Ast.StaticDecl d
          when Typecheck.qualified_name it.Ast.module_path d.st_name = n ->
            Some
              {
                Ast.c_name = d.Ast.st_name;
                c_public = d.Ast.st_public;
                c_type = d.Ast.st_type;
                c_value = d.Ast.st_value;
                c_span = d.Ast.st_span;
              }
        | _ -> None)
      items
  in
  List.concat_map
    (fun (n, ty : string * Type_repr.t) ->
      match decl_of n with
      | None -> []
      | Some d -> (
          match lit_constant d ty with
          | None -> []
          | Some c -> List.map (fun k -> (k, (ty, c))) (bare_keys n)))
    env.Typecheck.consts

let closure_statics (env : Typecheck.env) (items : Ast.item list) :
    (string * Type_repr.t * Seed_mir.constant option) array =
  (* the audit (mutable statics, P0): const_values locates each
     declaration by scanning the SUPPLIED item list — the previous
     `const_values env []` could never recover the declarations, so the
     statics table silently lost every initializer *)
  let init_of (n : string) : Seed_mir.constant option =
    match List.assoc_opt n (const_values env items) with
    | Some (_, c) -> Some c
    | None -> None
  in
  Array.of_list
    (List.filter_map
       (fun (n, ty : string * Type_repr.t) ->
         if Type_repr.has_type_param ty then None else Some (n, ty, init_of n))
       env.Typecheck.consts)

let closure_types (env : Typecheck.env) : Seed_mir.type_def array =
  Array.of_list
    (List.filter_map
       (fun (name, nom : string * Typecheck.nominal) ->
         match List.assoc_opt name env.Typecheck.type_ids with
         | None -> None
         | Some tid ->
             if nom.Typecheck.nom_params <> [] then None
             else
               (match nom.Typecheck.nom_kind with
                | `Struct ->
                    let fids =
                      if List.length nom.Typecheck.nom_field_ids
                         = List.length nom.Typecheck.nom_fields
                      then nom.Typecheck.nom_field_ids
                      else
                        List.mapi (fun i _ -> Ids.Field_id.make (i + 1)) nom.Typecheck.nom_fields
                    in
                    Some
                      (Seed_mir.StructDef
                         {
                           sd_id = tid;
                           sd_fields =
                             List.mapi
                               (fun i (_, fty) ->
                                 {
                                   Seed_mir.fd_id = List.nth fids i;
                                   fd_index = Ids.Field_index.make i;
                                   fd_ty = fty;
                                 })
                               nom.Typecheck.nom_fields;
                         })
                | `Enum ->
                    let vids =
                      if List.length nom.Typecheck.nom_variant_ids
                         = List.length nom.Typecheck.nom_variants
                      then nom.Typecheck.nom_variant_ids
                      else
                        List.mapi (fun i _ -> Ids.Variant_id.make (i + 1)) nom.Typecheck.nom_variants
                    in
                    Some
                      (Seed_mir.EnumDef
                         {
                           ed_id = tid;
                           ed_variants =
                             List.mapi
                               (fun i (_, pty) ->
                                 {
                                   Seed_mir.vd_id = List.nth vids i;
                                   vd_index = Ids.Variant_index.make i;
                                   vd_payload =
                                     (if Array.length pty = 0 then Type_repr.Unit
                                      else Type_repr.Tuple pty);
                                 })
                               nom.Typecheck.nom_variants;
                         })))
       env.Typecheck.nominals)

let struct_fields_of (env : Typecheck.env) :
    (Ids.Type_id.t * (string * Ids.Field_id.t * Type_repr.t) list) list =
  List.filter_map
    (fun (name, nom : string * Typecheck.nominal) ->
      match List.assoc_opt name env.Typecheck.type_ids with
      | None -> None
      | Some tid ->
          let nf = List.length nom.Typecheck.nom_fields in
          let fids =
            if List.length nom.Typecheck.nom_field_ids = nf then nom.Typecheck.nom_field_ids
            else List.mapi (fun i _ -> Ids.Field_id.make (i + 1)) nom.Typecheck.nom_fields
          in
          Some
            ( tid,
              List.mapi
                (fun i (fname, fty) -> (fname, List.nth fids i, fty))
                nom.Typecheck.nom_fields ))
    env.Typecheck.nominals

(* ── The persistent typed-node bridge (re-audit: TypedProgram/TypedHIR) ──
   The typechecker's node-keyed map (NodeId -> resolved node) crosses
   into lowering as Mir_lower's typed_nodes channel, threaded alongside
   lowering_env_of into every lower_function_with_variants call.  The
   typed channel is authoritative in lowering when a node-keyed entry is
   present; the cast rule consumes the checker-RESOLVED target
   (declaration-owned GenericParamIds) and never re-derives it from
   syntax positionally; the call rule consumes the checker-RESOLVED
   callee + solved concrete substitution (tn_call). *)
let typed_nodes_of (env : Typecheck.env) : (Ids.Node_id.t * Mir_lower.typed_node) list =
  Hashtbl.fold
    (fun key (node : Typecheck.typed_node) acc ->
      ( key,
        {
          Mir_lower.tn_type = node.Typecheck.tn_type;
          tn_cast_target = node.Typecheck.tn_cast_target;
          tn_call = node.Typecheck.tn_call;
        } )
      :: acc)
    env.Typecheck.typed_nodes []

(* The typed-pattern channel (re-audit P0 #3): (match NodeId, arm index)
   -> the arm's SEMANTIC pattern tree, resolved ONCE by the typechecker.
   The lowerer consumes the semantic identities (VariantId, binding
   names/types, constants, field names) instead of re-interpreting the
   syntactic Ast.pattern. *)
let typed_for_patterns_of (env : Typecheck.env) :
    (Ids.Node_id.t * (Typed_pattern.t * Type_repr.t)) list =
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) env.Typecheck.typed_for_patterns []

let typed_let_patterns_of (env : Typecheck.env) :
    (Ids.Node_id.t * Typed_pattern.t) list =
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) env.Typecheck.typed_let_patterns []

let typed_patterns_of (env : Typecheck.env) :
    ((Ids.Node_id.t * int) * Typed_pattern.t) list =
  Hashtbl.fold (fun key tp acc -> (key, tp) :: acc) env.Typecheck.typed_patterns []

let lowering_env_of ?(items : Ast.item list = []) (env : Typecheck.env) : Mir_lower.func_env =
  (* both the qualified key and the bare name resolve (flat namespace) *)
  let bare_keys (n : string) : string list =
    match String.rindex_opt n ':' with
    | Some i -> [ n; String.sub n (i + 1) (String.length n - i - 1) ]
    | None -> [ n ]
  in
  (* the typed nested-function registry resolves FIRST — the typechecker's
     lookup_function prefers a local helper (nested def) over the
     module-qualified top-level names, so the lowering env mirrors that
     order for both the callable entries and the value (return-type)
     entries *)
  let nested_values =
    List.concat_map
      (fun (qname, ts, _ : string * Typecheck.typed_signature * Ast.function_decl) ->
        List.map (fun k -> (k, ts.Typecheck.ts_return)) (bare_keys qname))
      env.Typecheck.state.nested_functions
  in
  let values =
    nested_values
    @ List.concat_map
        (fun (n, ts : string * Typecheck.typed_signature) ->
          let bare =
            match String.rindex_opt n ':' with
            | Some i -> [ (String.sub n (i + 1) (String.length n - i - 1), ts.Typecheck.ts_return) ]
            | None -> []
          in
          (n, ts.Typecheck.ts_return) :: bare)
        env.Typecheck.functions
    (* enum variant constructors are callable values: their registered
       result type lets lowering build the EnumCtor aggregate *)
    @ List.map (fun (n, ts) -> (n, ts.Typecheck.ts_return)) env.Typecheck.constructors
  in
  let nested_callables =
    List.concat_map
      (fun (qname, ts, _ : string * Typecheck.typed_signature * Ast.function_decl) ->
        List.map
          (fun k ->
            ( k,
              {
                Mir_lower.ce_callable = Ids.Callable_id.to_int ts.Typecheck.ts_callable;
                (* the template instance declares the generic params in
                   declaration order, so the monomorphizer can construct
                   exact substitutions *)
                ce_template_args =
                  Array.of_list
                    (List.map
                       (fun (_, pid) -> Type_repr.Type_param pid)
                       ts.Typecheck.ts_params_decl);
                ce_params = ts.Typecheck.ts_params;
              } ))
          (bare_keys qname))
      env.Typecheck.state.nested_functions
  in
  let callables =
    nested_callables
    @ List.concat_map
        (fun (n, ts : string * Typecheck.typed_signature) ->
          let entry : Mir_lower.callable_entry =
            {
              ce_callable = Ids.Callable_id.to_int ts.Typecheck.ts_callable;
              (* the template instance declares the generic params in
                 declaration order, so the monomorphizer can construct
                 exact substitutions *)
              ce_template_args =
                Array.of_list
                  (List.map
                     (fun (_, pid) -> Type_repr.Type_param pid)
                     ts.Typecheck.ts_params_decl);
              ce_params = ts.Typecheck.ts_params;
            }
          in
          let bare =
            match String.rindex_opt n ':' with
            | Some i -> [ (String.sub n (i + 1) (String.length n - i - 1), entry) ]
            | None -> []
          in
          (n, entry) :: bare)
        env.Typecheck.functions
  in
  let methods =
    List.map
      (fun ((t, m), ts : (string * string) * Typecheck.typed_signature) ->
        ((t, m),
         {
           Mir_lower.me_instance =
             (* the instance identity the method body is lowered under
                (lower_closure lowers methods with the declaration-order
                type params from ts_params_decl) — the call-site instance
                resolves against the callee function exactly *)
             Instance_id.make ~callable:ts.Typecheck.ts_callable
               ~type_args:
                 (Array.of_list
                    (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                       ts.Typecheck.ts_params_decl));
           (* the method's typed signature contracts: self at index 0
              (its convention is the receiver's access effect at the
              call site), then the explicit params in order; me_ret is
              the call's result type *)
           me_params = ts.Typecheck.ts_params;
           me_ret = ts.Typecheck.ts_return;
         }))
      env.Typecheck.methods
  in
  (* the GLOBAL-storage channel (the audit's mutable statics): the
     static name -> (program.statics index, type) — the SAME filtered
     order closure_statics builds (non-generic consts), so -1 - idx
     addresses the VM's statics slot *)
  let statics =
    let bare_of (q : string) : string =
      match List.rev (String.split_on_char ':' q) with
      | x :: _ -> x
      | [] -> q
    in
    List.filter_map
      (fun (n, ty : string * Type_repr.t) ->
        if Type_repr.has_type_param ty then None
        else
          let prefix =
            List.take_while (fun (m, _) -> m <> n) env.Typecheck.consts
          in
          let idx =
            List.length (List.filter (fun (_, t) -> not (Type_repr.has_type_param t)) prefix)
          in
          (* the lowering addresses globals by their BARE name — the
             same single-file module-path convention the checker uses *)
          Some (bare_of n, (idx, ty)))
      env.Typecheck.consts
  in
  {
    Mir_lower.types = env.Typecheck.types;
    values;
    consts = const_values env items;
    statics;
    callables;
    methods;
    fn_ret = Type_repr.Unit;
    struct_fields = struct_fields_of env;
  }

(* ── User-enum variant table (re-audit finding: the closure driver never
      fed lowering the typechecker's enum/VariantId universe) ─────────

   mir_lower's variant_table (vt_enums: enum name -> variant name ->
   {vs_id; vs_index; vs_fields}; vt_ctors: bare ctor name -> (enum name,
   variant name)) is built HERE from the TYPED nominal registry — the
   same semantic registry closure_types reads for the EnumDefs — never
   from re-parsing the AST.  Only concrete (non-generic) enums are
   tabled: generic payloads are deferred to post-mono, and the builtin
   Option/Result go through the SAME registry (the table's vt_builtin
   channel, fed from the nominals' nom_variant_ids — the LangItem
   declarations in the kernel source carry resolver ids), NOT a
   hardcoded position formula (audit P0: the semantic VariantId must
   never be reconstructed from the declaration-order index).  Each
   spec's vs_id is the typed nominal's nom_variant_ids entry at the
   variant's position; vs_index is the declaration-order position (the
   EnumDef variant position — construction sites (EnumCtor tags), match
   arms (SwitchInt targets) and the typed EnumDefs (semantic VariantIds
   from nom_variant_ids) agree; the semantic id and the runtime tag are
   independent coordinates).  The nominal is validated against its
   semantic variant-id registry (fail closed on a length mismatch). *)
let user_variant_table (env : Typecheck.env) : Mir_lower.variant_table =
  let enums =
    List.filter_map
      (fun (name, nom : string * Typecheck.nominal) ->
        match nom.Typecheck.nom_kind with
        | `Struct -> None
        | `Enum ->
            if nom.Typecheck.nom_params <> [] then None
            else begin
              let nvar = List.length nom.Typecheck.nom_variants in
              if List.length nom.Typecheck.nom_variant_ids <> nvar then
                die "enum `%s`: %d variants but %d semantic VariantIds" name nvar
                  (List.length nom.Typecheck.nom_variant_ids);
              Some
                ( name,
                  List.mapi
                    (fun i (vname, pty) ->
                      ( vname,
                        {
                          Mir_lower.vs_id = List.nth nom.Typecheck.nom_variant_ids i;
                          vs_index = i;
                          vs_fields = Array.to_list pty;
                        } ))
                    nom.Typecheck.nom_variants )
            end)
      env.Typecheck.nominals
  in
  (* the builtin Option/Result semantic identities: the SAME typed
     registry channel.  A bare compiler-seeded nominal (no source
     declaration, no resolver handoff) carries no nom_variant_ids — the
     deterministic 1-based minting the typechecker's own fallback
     registration and closure_types' EnumDef materialization use is the
     no-resolver world's canonical identity, so the fallback below is
     the registry's identity, never a lowering-side derivation. *)
  let builtin_ids =
    List.filter_map
      (fun (name, nom : string * Typecheck.nominal) ->
        match (name, nom.Typecheck.nom_kind) with
        | ("Option" | "Result"), `Enum ->
            let ids =
              if List.length nom.Typecheck.nom_variant_ids
                 = List.length nom.Typecheck.nom_variants
              then nom.Typecheck.nom_variant_ids
              else
                List.mapi (fun i _ -> Ids.Variant_id.make (i + 1)) nom.Typecheck.nom_variants
            in
            Some
              (name, List.mapi (fun i (vname, _) -> (vname, List.nth ids i)) nom.Typecheck.nom_variants)
        | _ -> None)
      env.Typecheck.nominals
  in
  let ctors =
    List.concat_map
      (fun (ename, specs) ->
        List.map (fun (vname, _) -> (vname, (ename, vname))) specs)
      enums
  in
  { Mir_lower.vt_enums = enums; vt_ctors = ctors; vt_builtin = builtin_ids }

(* The generic nominal registry for the monomorphizer (re-audit finding:
   "generic nominal type definitions disappear before MIR").  closure_types
   below DROPS nom_params <> [] nominals from the seed types table — but
   the generic TEMPLATES do not disappear: they are handed to Mono.build
   as its generic_types registry, and the post-mono assembly
   (materialize_type_instances) materializes the CONCRETE instances the
   mono queue reaches (Mono.build's on_type_instance channel) as
   concrete StructDef/EnumDef entries carrying the SAME semantic
   FieldIds/VariantIds as the original def.  The builtin Option/Result
   nominals are included: mir_lower's hardcoded fallback mints the same
   1-based semantic VariantIds (vs_index + 1), so the materialized defs
   agree with the lowered projections.  The SAME registry is handed to
   Mir_verify.require_valid_template: program.types is concrete-only
   pre-mono, so the template verifier resolves generic nominal
   identities against this registry. *)
let closure_generic_types (env : Typecheck.env) : Mono.generic_def array =
  Array.of_list
    (List.filter_map
       (fun (name, nom : string * Typecheck.nominal) ->
         match List.assoc_opt name env.Typecheck.type_ids with
         | None -> None
         | Some tid ->
             if nom.Typecheck.nom_params = [] then None
             else
               let params =
                 Array.of_list (List.map snd nom.Typecheck.nom_params)
               in
               (match nom.Typecheck.nom_kind with
                | `Struct ->
                    let fids =
                      if List.length nom.Typecheck.nom_field_ids
                         = List.length nom.Typecheck.nom_fields
                      then nom.Typecheck.nom_field_ids
                      else
                        List.mapi (fun i _ -> Ids.Field_id.make (i + 1)) nom.Typecheck.nom_fields
                    in
                    Some
                      { Mono.gd_tid = tid;
                        gd_params = params;
                        gd_def =
                          Seed_mir.StructDef
                            {
                              sd_id = tid;
                              sd_fields =
                                List.mapi
                                  (fun i (_, fty) ->
                                    {
                                      Seed_mir.fd_id = List.nth fids i;
                                      fd_index = Ids.Field_index.make i;
                                      fd_ty = fty;
                                    })
                                  nom.Typecheck.nom_fields;
                            } }
                | `Enum ->
                    let vids =
                      if List.length nom.Typecheck.nom_variant_ids
                         = List.length nom.Typecheck.nom_variants
                      then nom.Typecheck.nom_variant_ids
                      else
                        List.mapi (fun i _ -> Ids.Variant_id.make (i + 1)) nom.Typecheck.nom_variants
                    in
                    Some
                      { Mono.gd_tid = tid;
                        gd_params = params;
                        gd_def =
                          Seed_mir.EnumDef
                            {
                              ed_id = tid;
                              ed_variants =
                                List.mapi
                                  (fun i (_, pty) ->
                                    {
                                      Seed_mir.vd_id = List.nth vids i;
                                      vd_index = Ids.Variant_index.make i;
                                      vd_payload =
                                        (if Array.length pty = 0 then Type_repr.Unit
                                         else Type_repr.Tuple pty);
                                    })
                                  nom.Typecheck.nom_variants;
                            } }))
       env.Typecheck.nominals)

let lower_and_report (path : string) (env : Typecheck.env) (program : Ast.program) : int =
  let module_path = Parser.module_path_of_file path in
  let funcs =
    List.filter_map
      (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
      program.Ast.items
  in
  Printf.printf "// lower %s (module %s): %d items, %d functions\n" path
    (String.concat "::" module_path)
    (List.length program.Ast.items)
    (List.length funcs);
  let base = lowering_env_of ~items:program.Ast.items env in
  let mir_funcs =
    List.mapi
      (fun i d ->
        let fn_ret, callable, template_args =
          match lookup_typed_fn env d.Ast.fn_sig.Ast.sig_name with
          | Some ts ->
              ( ts.Typecheck.ts_return,
                Ids.Callable_id.to_int ts.Typecheck.ts_callable,
                Array.of_list
                  (List.map
                     (fun (_, pid) -> Type_repr.Type_param pid)
                     ts.Typecheck.ts_params_decl) )
          | None -> (Type_repr.Unit, i, [||])
        in
        let conventions =
          match lookup_typed_fn env d.Ast.fn_sig.Ast.sig_name with
          | Some ts ->
              Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params
          | None -> [||]
        in
        Mir_lower.lower_function_with_variants ~typed_nodes:(typed_nodes_of env)
                    ~typed_patterns:(typed_patterns_of env)
                    ~typed_for_patterns:(typed_for_patterns_of env)
                    ~typed_let_patterns:(typed_let_patterns_of env)
          (user_variant_table env)
          { base with Mir_lower.fn_ret }
          d.Ast.fn_sig.Ast.sig_name callable template_args conventions d)
      funcs
  in
  let prog =
    { Seed_mir.functions = Array.of_list mir_funcs; statics = closure_statics env program.Ast.items; types = closure_types env }
  in
  match Mir_verify.require_valid_template ~generic_types:(closure_generic_types env) prog with
  | Error errs ->
      Printf.printf "// MIR verify FAILED:\n";
      List.iter (fun e -> Printf.printf "//   %s\n" e) errs;
      1
  | Ok () ->
      Printf.printf "// MIR verify PASS (%d functions)\n" (Array.length prog.Seed_mir.functions);
      print_string (Seed_mir.print_program prog);
      (match
         Array.to_list prog.Seed_mir.functions
         |> List.find_opt (fun f -> f.Seed_mir.name = "main")
       with
      | None -> 0
      | Some main ->
          let host = Host.create ~repo_root:"." ~argv:[||] in
          (match Vm.run ~program:prog ~entry:main.Seed_mir.instance ~argv:[||] ~host with
           | Ok _ -> Printf.printf "// VM: exit 0\n"; 0
           | Error e -> Printf.printf "// VM: %s\n" e.Vm.message; 1))



let cmd_lex (args : string list) : int =
  match args with
  | path :: _ ->
      let src = match load_source_or_report path with Some s -> s | None -> exit 1 in
      let sm = Span.create () in
      let file_id = Span.add_file sm src.Source.name src in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      List.iter
        (fun t ->
          match Span.resolve sm t.Token.span with
          | Some (_, line, col) -> Printf.printf "%d:%d  %s\n" line col (Token.display_name t.Token.kind)
          | None -> Printf.printf "?:?  %s\n" (Token.display_name t.Token.kind))
        tokens;
      report_errors diags sm;
      Printf.printf "\n%d tokens, 0 errors\n" (List.length tokens);
      0
  | [] -> die "'lex' requires a file path"

let cmd_parse (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      Printf.printf "Parsed %d top-level items\n" (List.length program.Ast.items);
      List.iter (fun i -> Printf.printf "  %s\n" (Ast.item_summary i.Ast.kind)) program.Ast.items;
      0
  | [] -> die "'parse' requires a file path"

let cmd_check (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      if not (Diagnostic.has_errors diags) then Subset.check diags program;
      report_errors diags sm;
      if Diagnostic.has_errors diags then 1
      else begin
        (* the advertised semantics: parse + profile + resolution + typing *)
        let env = Typecheck.initial_env () in
        match Typecheck.check_program env program with
        | Error m -> die "typecheck failed: %s" m
        | Ok (_, errors) ->
            if errors <> [] then begin
              List.iter (fun e -> Printf.printf "  %s\n" e) (List.rev errors);
              Printf.printf "Checked %d top-level items: %d errors, %d warnings\n"
                (List.length program.Ast.items) (List.length errors)
                (Diagnostic.warning_count diags);
              1
            end
            else begin
              Printf.printf "Checked %d top-level items: 0 errors, %d warnings\n"
                (List.length program.Ast.items)
                (Diagnostic.warning_count diags);
              0
            end
      end
  | [] -> die "'check' requires a file path"

(* interpret: lower a file and run its main through the seed VM, printing
   the return value (audit: the dispatcher advertised interpret but had no
   branch). *)
let cmd_interpret (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      if Diagnostic.has_errors diags then 1
      else begin
        let env = Typecheck.initial_env () in
        match Typecheck.check_program env program with
        | Error m -> die "typecheck failed: %s" m
        | Ok (env, errors) ->
            if errors <> [] then begin
              List.iter (fun e -> Printf.printf "  %s\n" e) (List.rev errors);
              1
            end
            else begin
              let funcs =
                List.filter_map
                  (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
                  program.Ast.items
              in
              let base = lowering_env_of ~items:program.Ast.items env in
              let mir_funcs =
                List.mapi
                  (fun i d ->
                    let fn_ret, callable =
                      match lookup_typed_fn env d.Ast.fn_sig.Ast.sig_name with
                      | Some ts -> (ts.Typecheck.ts_return, Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                      | None -> (Type_repr.Unit, i)
                    in
                    Mir_lower.lower_function_with_variants ~typed_nodes:(typed_nodes_of env)
                    ~typed_patterns:(typed_patterns_of env)
                    ~typed_for_patterns:(typed_for_patterns_of env)
                    ~typed_let_patterns:(typed_let_patterns_of env)
                      (user_variant_table env)
                      { base with Mir_lower.fn_ret }
                      d.Ast.fn_sig.Ast.sig_name callable [||] [||] d)
                  funcs
              in
              let prog =
                { Seed_mir.functions = Array.of_list mir_funcs; statics = closure_statics env program.Ast.items; types = closure_types env }
              in
              (match
                 Mir_verify.require_valid_template
                   ~generic_types:(closure_generic_types env)
                   prog
               with
               | Error errs ->
                   List.iter (fun e -> Printf.printf "  %s\n" e) errs;
                   1
               | Ok () -> (
                   match
                     Array.to_list prog.Seed_mir.functions
                     |> List.find_opt (fun f -> f.Seed_mir.name = "main")
                   with
                   | None -> die "no `main` function to interpret"
                   | Some main -> (
                       match Vm.entry_frame_of ~program:prog ~entry:main.Seed_mir.instance ~argv:[||] with
                       | Error m -> die "interpret: %s" m
                       | Ok (vm, entry_frame) -> (
                           match Vm.run_inspect vm entry_frame with
                           | Ok ret ->
                               Printf.printf "%s\n" ret;
                               0
                           | Error m ->
                               Printf.printf "interpret failed: %s\n" m;
                               1))))
            end
      end
  | [] -> die "'interpret' requires a file path"

let cmd_dump_ast (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      print_string (Dump.dump program);
      print_newline ();
      0
  | [] -> die "'dump-ast' requires a file path"

(* Typecheck modules in import-dependency (topological) order so that
   forward references between kernel modules resolve (the manifest lists
   modules alphabetically, not dependency-ordered). *)
let topological_nodes (graph : Module_graph.t) : Module_graph.module_node list =
  (* Deduplicate by source file: lib_kernel.tg creates re-export subtree
     nodes whose node_path aliases the same file (e.g. lib_kernel::token
     vs token). Prefer the canonical (non-lib_kernel) copy. *)
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
  Array.iteri
    (fun i node ->
      Printf.printf "      topo %d %s deps=%s\n" i (String.concat "::" node.Module_graph.node_path)
        (String.concat "," (List.map string_of_int deps.(i))))
    nodes;
  let queue = Queue.create () in
  Array.iteri (fun i d -> if d = 0 then Queue.push i queue) indeg;
  let order = ref [] in
  while not (Queue.is_empty queue) do
    let i = Queue.pop queue in
    order := i :: !order;
    List.iter (fun j ->
      indeg.(j) <- indeg.(j) - 1;
      if indeg.(j) = 0 then Queue.push j queue) rdeps.(i)
  done;
  let order = List.rev !order in
  Printf.printf "      kahn order: %s\n"
    (String.concat "," (List.map string_of_int order));
  if List.length order <> n then begin
    (* import cycles exist: append the remaining nodes in manifest order;
       cross-module forward references are then resolved by the flat
       global namespace (the resolver's contract). *)
    let in_order = Hashtbl.create 16 in
    List.iter (fun i -> Hashtbl.add in_order i ()) order;
    let rest =
      List.filter (fun i -> not (Hashtbl.mem in_order i)) (List.init n Fun.id)
    in
    List.map (Array.get nodes) (order @ rest)
  end
  else List.map (Array.get nodes) order

(* Build the Mir_lower func_env from the typed environment. *)
let cmd_lower (args : string list) : int =
  match args with
  | path :: _ ->
      let diags, sm, program = front_end path in
      report_errors diags sm;
      Subset.check diags program;
      report_errors diags sm;
      let env = Typecheck.initial_env () in
      (match Typecheck.check_program env program with
       | Error m -> die "typecheck failed: %s" m
       | Ok (env, errors) ->
           List.iter (fun e -> Printf.printf "  type error: %s\n" e) (List.rev errors);
           if errors <> [] then begin
             Printf.printf "lower %s: FAILED (typecheck)\n" path;
             1
           end
           else lower_and_report path env program)
  | [] -> die "'lower' requires a file path"

(* ── bootstrap-check / compile shared machinery ─────────────────── *)

type boot_opts = {
  repo_root : string;
  manifest : string;
  target : string;
  entry : string option;
  (* strict resolver mode (re-audit P0 #1): the future compiler's
     per-module authority — the flat/global unique-name recovery is
     disabled and every wrong-module import stays unresolved.  The
     bootstrap closure always runs the strict audit (separate bag);
     --strict makes the strict run the semantic pipeline, which fails
     closed on any unresolved import. *)
  strict : bool;
  (* audit P0 fix: when set, bootstrap-check writes the structured
     per-diagnostic JSONL (one JSON object per typecheck diagnostic,
     serialized directly from the checker's structured channel) to this
     path instead of the evidence relying on stdout scraping. *)
  diagnostics_jsonl : string option;
}

let default_boot_opts =
  {
    repo_root = ".";
    manifest = "bootstrap/compiler_kernel.manifest";
    target = "aarch64-apple-darwin";
    entry = None;
    strict = false;
    diagnostics_jsonl = None;
  }

let boot_specs =
  [
    { name = "--repo-root"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with repo_root = v } | None -> o) };
    { name = "--manifest"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with manifest = v } | None -> o) };
    { name = "--target"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with target = v } | None -> o) };
    { name = "--entry"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with entry = Some v } | None -> o) };
    { name = "--strict"; takes_value = false; apply = (fun _ o -> { o with strict = true }) };
    { name = "--diagnostics-jsonl"; takes_value = true; apply = (fun v o -> match v with Some v -> { o with diagnostics_jsonl = Some v } | None -> o) };
  ]

(* ── @cfg elimination (audit @cfg P0) ──────────────────────────── *)

(* Cut the eliminated items' byte spans out of a module's source text.
   The spans are the MAXIMAL removed spans returned by the pass (an
   eliminated inline module covers its children), disjoint and sorted by
   start, so the re-parse of the cut text is exactly the kept program. *)
let cut_spans (text : string) (spans : Span.span list) : string =
  let sorted = List.sort (fun a b -> compare a.Span.start b.Span.start) spans in
  let buf = Buffer.create (String.length text) in
  let rec go pos = function
    | [] -> Buffer.add_substring buf text pos (String.length text - pos)
    | (s : Span.span) :: rest ->
        Buffer.add_substring buf text pos (s.Span.start - pos);
        go s.Span.end_ rest
  in
  go 0 sorted;
  Buffer.contents buf

(* Apply @cfg elimination over every module program: AFTER the
   parse/merge (the module graph), BEFORE the resolver's duplicate/name
   registration and the type checker. Each module's target-contradicting
   declarations are physically removed from the source snapshot (the
   eliminated spans are cut out and the graph is re-parsed), so the
   resolver, the typechecker and everything downstream only ever see the
   target's semantic program — an eliminated declaration does not exist
   for this target and cannot be resurrected by any reference. Fail
   closed: an empty @cfg() (E108), a malformed predicate or an unknown
   target key renders its diagnostics and aborts the pipeline BEFORE the
   resolver runs — a bad gate never silently stays active. *)
let apply_cfg_elimination ~(manifest : Bootstrap_manifest.t) ~(graph : Module_graph.t)
    (target : Target.t) : (Module_graph.t * int, string) result =
  let ctx = Target.Cfg_context.of_target target in
  let manifest_ref = ref manifest in
  let total = ref 0 in
  let cfg_errors = ref [] in
  let file_nodes =
    List.filter (fun n -> n.Module_graph.node_parent = None) graph.Module_graph.nodes
  in
  List.iter
    (fun node ->
      let key = String.concat "::" node.Module_graph.node_path in
      match Target.eliminate_program ctx node.Module_graph.node_program with
      | Error ds -> cfg_errors := !cfg_errors @ ds
      | Ok r ->
          if r.Target.elim_removed > 0 then begin
            total := !total + r.Target.elim_removed;
            Printf.printf "  cfg: module %s eliminated %d items\n" key r.Target.elim_removed;
            (match Bootstrap_manifest.find manifest node.Module_graph.node_path with
             | None -> ()
             | Some entry ->
                 let text = cut_spans entry.Bootstrap_manifest.source r.Target.elim_spans in
                 manifest_ref :=
                   Bootstrap_manifest.with_entry_source !manifest_ref node.Module_graph.node_path
                     text)
          end)
    file_nodes;
  if !cfg_errors <> [] then begin
    prerr_string
      (Diagnostic.render (Module_graph.source_map graph)
         { Diagnostic.diagnostics = List.rev !cfg_errors });
    prerr_newline ();
    Error "cfg elimination diagnostics"
  end
  else begin
    let reparse_diags = Diagnostic.create_bag () in
    let graph' = Module_graph.create_with_sources !manifest_ref reparse_diags in
    if Diagnostic.has_errors reparse_diags then begin
      prerr_string (Diagnostic.render (Module_graph.source_map graph') reparse_diags);
      prerr_newline ();
      Error "cfg elimination re-parse diagnostics"
    end
    else begin
      (* Sanity: the re-parse of the cut sources must reproduce exactly the
         filtered programs (an off-by-one span cut is an internal error,
         not a silent semantic change). *)
      List.iter
        (fun node ->
          match Target.eliminate_program ctx node.Module_graph.node_program with
          | Error _ -> ()
          | Ok r ->
              if r.Target.elim_removed > 0 then begin
                match Module_graph.find_module_by_path graph' node.Module_graph.node_path with
                | Some n ->
                    if List.length n.Module_graph.node_items
                       <> List.length r.Target.elim_program.Ast.items
                    then
                      failwith
                        (Printf.sprintf
                           "cfg elimination internal error: module %s re-parse diverged (%d items, expected %d)"
                           (String.concat "::" node.Module_graph.node_path)
                           (List.length n.Module_graph.node_items)
                           (List.length r.Target.elim_program.Ast.items))
                | None ->
                    failwith
                      (Printf.sprintf
                         "cfg elimination internal error: module %s missing from the re-parsed graph"
                         (String.concat "::" node.Module_graph.node_path))
              end)
        file_nodes;
      Printf.printf "  cfg: total eliminated across closure: %d items\n" !total;
      Ok (graph', !total)
    end
  end

(* ── Executable-subset firewall over the manifest closure ─────────
   (re-audit P1 finding 1): the aggregate bootstrap path previously
   never called Subset.check over the actual manifest programs — only
   the standalone check/lower commands and the gate's synthetic
   specimens did.  run_closure_pipeline now runs Subset.check over EVERY
   module program of the cfg-filtered closure, AFTER the module graph +
   @cfg elimination and BEFORE the resolver/typechecker, with a FRESH
   diagnostic bag per module: the findings are a SEPARATE channel and
   can never inflate the resolver diagnostics or the typecheck debt
   (debt_total is a typecheck-only count). *)

type subset_module = {
  ssm_key : string;                   (* module path key *)
  ssm_findings : (string * int) list; (* E-code -> count, sorted by code *)
  ssm_total : int;
}

type subset_result = {
  sr_modules : subset_module list;  (* dedup by source file *)
  sr_accepted : int;
  sr_rejected : int;
  sr_total : int;
}

let subset_firewall_of_graph (graph : Module_graph.t) : subset_result =
  (* Deduplicate by source file: lib_kernel.tg creates re-export subtree
     nodes whose node_file aliases the same file (same rule as
     topological_nodes). *)
  let seen = Hashtbl.create 64 in
  let nodes =
    List.filter
      (fun node ->
        if Hashtbl.mem seen node.Module_graph.node_file then false
        else begin
          Hashtbl.add seen node.Module_graph.node_file ();
          true
        end)
      graph.Module_graph.nodes
  in
  let modules =
    List.map
      (fun node ->
        let diags = Diagnostic.create_bag () in
        Subset.check diags node.Module_graph.node_program;
        let total = Diagnostic.error_count diags in
        let counts =
          List.map
            (fun code ->
              ( code,
                List.length
                  (List.filter
                     (fun d ->
                       d.Diagnostic.severity = Diagnostic.Error && d.Diagnostic.code = code)
                     diags.Diagnostic.diagnostics) ))
            (Diagnostic.codes diags)
        in
        {
          ssm_key = String.concat "::" node.Module_graph.node_path;
          ssm_findings = counts;
          ssm_total = total;
        })
      nodes
  in
  let accepted = List.length (List.filter (fun m -> m.ssm_total = 0) modules) in
  {
    sr_modules = modules;
    sr_accepted = accepted;
    sr_rejected = List.length modules - accepted;
    sr_total = List.fold_left (fun acc m -> acc + m.ssm_total) 0 modules;
  }

let subset_firewall_status (r : subset_result) : string =
  if r.sr_total = 0 then "PASS" else "FAIL"

let print_subset_firewall (r : subset_result) : unit =
  Printf.printf
    "  subset firewall: %d module programs (dedup by source file) — %d accepted, %d rejected, %d findings\n"
    (List.length r.sr_modules) r.sr_accepted r.sr_rejected r.sr_total;
  List.iter
    (fun m ->
      if m.ssm_total > 0 then
        Printf.printf "    %s: %s\n" m.ssm_key
          (String.concat ", "
             (List.map (fun (c, n) -> Printf.sprintf "%s=%d" c n) m.ssm_findings)))
    r.sr_modules;
  List.iter
    (fun m ->
      if m.ssm_total > 0 then begin
        Printf.printf "    module %s: REJECTED (%d findings:" m.ssm_key m.ssm_total;
        List.iter (fun (c, n) -> Printf.printf " %s x%d" c n) m.ssm_findings;
        Printf.printf ")\n"
      end
      else Printf.printf "    module %s: ACCEPTED\n" m.ssm_key)
    r.sr_modules;
  Printf.printf "  SUBSET_FIREWALL = %s (%d findings across %d module(s))\n"
    (subset_firewall_status r) r.sr_total r.sr_rejected

(* ── Declaration-fixpoint fingerprint (re-audit P0 #3) ───────────
   The declaration fixpoint converges when the SEMANTIC state stops
   changing, not when the per-module error COUNT stops decreasing.  The
   fingerprint covers: the registered definition identities
   (env.type_ids), the resolved declaration identities (each nominal's
   registered fields, variants, and their resolver FieldId/VariantId
   identities), the registered function/constructor/const signatures,
   and the pending unresolved declaration set (the per-module error
   reports).  Fully deterministic: every component is sorted before
   serialization, and the canonical string is hashed with Digest. *)
(* error-message normalization: the fresh infer-var ids (?#N) inside
   error strings are per-round artifacts (the var counter grows across
   retries), so the fingerprint must not see them as semantic change *)
let normalize_fp_err (e : string) : string =
  let b = Buffer.create (String.length e) in
  let n = String.length e in
  let i = ref 0 in
  while !i < n do
    if !i + 2 <= n && String.sub e !i 2 = "?#" then begin
      Buffer.add_string b "?#V";
      let j = ref (!i + 2) in
      while !j < n && e.[!j] >= '0' && e.[!j] <= '9' do incr j done;
      i := !j
    end
    else begin
      Buffer.add_char b e.[!i];
      incr i
    end
  done;
  Buffer.contents b

let decl_fingerprint (env : Typecheck.env) (errs_by_mod : (string, string list) Hashtbl.t) : string =
  let buf = Buffer.create 4096 in
  List.iter
    (fun (name, tid) ->
      Buffer.add_string buf (Printf.sprintf "T %s %d\n" name (Ids.Type_id.to_int tid)))
    (List.sort compare env.Typecheck.type_ids);
  List.iter
    (fun (name, nom) ->
      let fields = List.sort compare (List.map fst nom.Typecheck.nom_fields) in
      let variants = List.sort compare (List.map fst nom.Typecheck.nom_variants) in
      let field_ids =
        List.sort compare (List.map Ids.Field_id.to_int nom.Typecheck.nom_field_ids)
      in
      let variant_ids =
        List.sort compare (List.map Ids.Variant_id.to_int nom.Typecheck.nom_variant_ids)
      in
      Buffer.add_string buf
        (Printf.sprintf "N %s f[%s] v[%s] fi[%s] vi[%s]\n" name
           (String.concat "," fields)
           (String.concat "," variants)
           (String.concat "," (List.map string_of_int field_ids))
           (String.concat "," (List.map string_of_int variant_ids))))
    (List.sort compare env.Typecheck.nominals);
  List.iter
    (fun (n, _) -> Buffer.add_string buf ("F " ^ n ^ "\n"))
    (List.sort compare env.Typecheck.functions);
  List.iter
    (fun (n, _) -> Buffer.add_string buf ("C " ^ n ^ "\n"))
    (List.sort compare env.Typecheck.constructors);
  List.iter
    (fun (n, _) -> Buffer.add_string buf ("K " ^ n ^ "\n"))
    (List.sort compare env.Typecheck.consts);
  List.iter
    (fun (k, errs) ->
      Buffer.add_string buf
        (Printf.sprintf "E %s [%s]\n" k
           (String.concat ";"
              (List.sort compare (List.map normalize_fp_err errs)))))
    (List.sort compare (Hashtbl.fold (fun k errs acc -> (k, errs) :: acc) errs_by_mod []));
  Digest.to_hex (Digest.string (Buffer.contents buf))

(* Everything bootstrap-check and compile share: manifest load, module
   graph, resolver, and the typecheck fixpoint (registration is
   non-fatal, so modules with forward/cyclic references retry with the
   growing env until no module makes progress).  The o_calls channel is
   reset per item inside check_program, so the driver's observable typed
   call count is sampled after every module check (a lower bound). *)
type closure_ctx = {
  ctx_repo_root : string;
  ctx_manifest_path : string;
  ctx_target : Target.t;
  ctx_graph : Module_graph.t;
  ctx_resolved : Resolver.resolved_program;
  ctx_env : Typecheck.env;
  ctx_type_errors : string list;
  ctx_items : int;
  ctx_typed_calls_sample : int;
  (* The MEASURED declaration-fixpoint iteration count (re-audit finding
     2): !decl_rounds from the fixpoint loop below — never a hard-coded
     2.  The body pass runs exactly once against the frozen env (audit
     Fix 3 deterministic phase split). *)
  ctx_decl_rounds : int;
  ctx_subset : subset_result;
  ctx_profile_findings : int;
  ctx_strict_fallbacks : int;
  (* audit P0 fix: the strict-mode audit's diagnostic records (the
     future compiler's per-module-authority findings on the separate
     audit bag), so the evidence can persist the strict-resolution
     diagnostics as structured data — never scraped from rendered
     stderr.  Emission order; [] in strict mode (the strict run IS the
     semantic pipeline). *)
  ctx_strict_diags : Diagnostic.diagnostic list;
  mutable lowered_methods : int;
}

(* Everything bootstrap-check and compile share: manifest load, module
   graph, resolver, and the typecheck fixpoint (registration is
   non-fatal, so modules with forward/cyclic references retry with the
   growing env until no module makes progress).  The o_calls channel is
   reset per item inside check_program, so the driver's observable typed
   call count is sampled after every module check (a lower bound).

   strict=false (the bootstrap-closure default): the resolver runs in
   recovery mode AND the strict-mode audit runs unconditionally on a
   separate diagnostic bag; strict=true: the strict run IS the semantic
   pipeline (fails closed on any unresolved import). *)
let run_closure_pipeline_impl ~(repo_root : string) ~(manifest_path : string)
    ~(target : Target.t) ~(strict : bool) : (closure_ctx, string) result =
  match Bootstrap_manifest.load ~repo_root ~manifest_path with
  | Error m -> Error m
  | Ok manifest ->
      let n = List.length (Bootstrap_manifest.entries manifest) in
      Printf.printf "  manifest: %d entries, version %s\n" n
        (match Bootstrap_manifest.version_of manifest with Some v -> v | None -> "(none)");
       Printf.printf "  fingerprint: %s\n" (Bootstrap_manifest.fingerprint manifest);
       let diags = Diagnostic.create_bag () in
       (* audit P0 fix: the strict-mode audit findings are stashed here
          (recovery-mode runs; in strict mode the audit IS the semantic
          pipeline and the ctx never materializes on resolver errors) *)
       let strict_audit_diags = ref [] in
       let graph = Module_graph.create_with_sources manifest diags in
      Printf.printf "  module graph: %d modules, %d items\n" graph.Module_graph.node_count
        graph.Module_graph.item_count;
      (* ── @cfg elimination (audit @cfg P0) ─────────────────────────
         The production compiler applies apply_cfg_elimination after
         parse/dependency merge and BEFORE the resolver/typechecker
         registration. Identical position here: every module program is
         target-filtered before anything registers or typechecks it. *)
      (match apply_cfg_elimination ~manifest ~graph target with
       | Error m -> Error m
       | Ok (graph, _cfg_eliminated) ->
      (* ── executable-subset firewall (re-audit P1 finding 1): run
         Subset.check over EVERY module program of the cfg-filtered
         closure, BEFORE the resolver/typechecker.  Each module gets a
         FRESH diagnostic bag, so the findings are a separate gate line
         and cannot touch the resolver diagnostics or the typecheck
         debt. *)
      let subset_result = subset_firewall_of_graph graph in
      print_subset_firewall subset_result;
      (* ── resolver: strict-mode audit (re-audit P0 #1) ──────────────
         The bootstrap closure runs the resolver under strict mode (the
         future compiler's per-module ModuleId/DefId authority: wrong
         module -> unresolved import; the flat/global unique-name
         recovery is disabled) on a SEPARATE diagnostic bag, and the
         strict findings are reported.  The semantic pipeline then runs
         in recovery mode, whose compatibility-fallback activation
         count must be exactly zero for the closure to be strict-clean
         (the audit's requirement before the seed swap).  With --strict
         the strict run IS the semantic pipeline and fails closed on
         any finding. *)
      let resolved =
        if strict then Resolver.resolve ~strict:true manifest graph diags
        else begin
          let audit_diags = Diagnostic.create_bag () in
          ignore (Resolver.resolve ~strict:true manifest graph audit_diags);
          let audit_findings = List.length audit_diags.Diagnostic.diagnostics in
          if audit_findings > 0 then begin
            Printf.printf
              "  strict-mode audit: %d import(s) stay unresolved under strict mode (the flat unique-name recovery would mask them):\n"
              audit_findings;
            prerr_string (Diagnostic.render (Module_graph.source_map graph) audit_diags);
            prerr_newline ()
          end
          else
            Printf.printf
              "  strict-mode audit: CLEAN — the closure resolves under per-module authority (strict-mode diagnostics: 0)\n";
          strict_audit_diags := List.rev audit_diags.Diagnostic.diagnostics;
          Resolver.resolve manifest graph diags
        end
      in
      Printf.printf "  resolver: %d expr defs, %d type defs, %d field defs, %d variant defs, %d call candidates\n"
        (List.length resolved.Resolver.expr_defs)
        (List.length resolved.Resolver.type_defs)
        (List.length resolved.Resolver.field_defs)
        (List.length resolved.Resolver.variant_defs)
        (List.length resolved.Resolver.call_candidates);
      if Diagnostic.has_errors diags then begin
        prerr_string (Diagnostic.render (Module_graph.source_map graph) diags);
        prerr_newline ();
        Error "resolver diagnostics"
      end
      else begin
        Printf.printf "  diagnostics: 0\n";
        (* identity handoff (audit Fix 2): the typechecker consumes the
           resolver's semantic identities instead of rediscovering them *)
        let env = ref (Typecheck.initial_env ~resolved:(Some resolved) ()) in
        let errs_by_mod : (string, string list) Hashtbl.t = Hashtbl.create 64 in
        let items = ref 0 in
        let typed_calls = ref 0 in
        (* deterministic phase split (audit Fix 3): declare every identity
           over the closure to a fixpoint (registration is idempotent —
           re-runs replace, never append duplicates; the fixpoint only
           resolves what became resolvable as the env grew), then check
           bodies exactly once against the frozen environment *)
        let nodes = topological_nodes graph in
        let with_module env node =
          {
            env with
            Typecheck.module_id = node.Module_graph.node_id;
            module_path = node.Module_graph.node_path;
          }
        in
        let decl_rounds = ref 0 in
        let rec decl_pass env = function
          | [] -> env
          | node :: rest -> (
              match Typecheck.check_declarations (with_module env node) node.Module_graph.node_program with
              | Error m ->
                  let key = String.concat "::" node.Module_graph.node_path in
                  Hashtbl.replace errs_by_mod key [ m ];
                  decl_pass env rest
              | Ok (env', errors) ->
                  let key = String.concat "::" node.Module_graph.node_path in
                  Hashtbl.replace errs_by_mod key errors;
                  decl_pass env' rest)
        in
        let env_after_decls =
          (* convergence = the semantic fingerprint stops changing
             (registered definition identities + resolved declaration
             identities + the pending unresolved set) — NOT the
             per-module error count; capped at 8 rounds *)
          (* re-audit P1 clean fixpoint: `round(env, n)` carries whether
             the LAST attempted transition changed the environment — the
             cap check is `n == MAX` after a CHANGED transition, never a
             post-hoc inference comparing the final state against the
             root *)
          let rec fixpoint env n =
            incr decl_rounds;
            let before = decl_fingerprint env errs_by_mod in
            let env' = decl_pass env nodes in
            let after = decl_fingerprint env' errs_by_mod in
            if after = before then (env', true)
            else if n >= 8 then (env', false)
            else fixpoint env' (n + 1)
          in
          let env_final, converged = fixpoint !env 1 in
          if not converged then
            failwith
              "declaration fixpoint did NOT converge within the 8-round cap — the semantic fingerprint is still changing at the cap boundary (re-audit P1: changed-at-max is a non-convergence error, never an accept)";
          env_final
        in
        Printf.printf
          "  decl fixpoint: %d round(s); converged on a stable semantic fingerprint (registered type identities + resolved nominal declarations + pending unresolved declaration set)\n"
          !decl_rounds;
        let rec body_pass env = function
          | [] -> env
          | node :: rest -> (
              match Typecheck.check_bodies (with_module env node) node.Module_graph.node_program with
              | Error m ->
                  let key = String.concat "::" node.Module_graph.node_path in
                  Hashtbl.replace errs_by_mod key [ m ];
                  body_pass env rest
              | Ok (env', errors) ->
                  let key = String.concat "::" node.Module_graph.node_path in
                  typed_calls := !typed_calls + List.length env.state.oracle.o_calls;
                  Hashtbl.replace errs_by_mod key errors;
                  body_pass env' rest)
        in
        env := body_pass env_after_decls nodes;
        (* final-state report (re-audit P0 #1): the compatibility-fallback
           activation count of the closure's resolution — exactly zero
           means the closure is strict-clean (per-module authority) *)
        let fallback_activations = Resolver.flat_fallback_activations resolved in
        Printf.printf "  strict-mode status: %d compatibility-fallback activation(s) — %s\n"
          fallback_activations
          (if fallback_activations = 0 then
            "closure is strict-clean (per-module authority)"
          else "closure needs kernel-source import repairs (see the fallback sites above)");
        (* identity-handoff invariant: every method the resolver can
           resolve must carry the resolver's CallableId, not a fresh mint *)
        Printf.printf
          "  identity handoff: methods via resolver %d, fallback %d\n"
          (!env).Typecheck.state.o_handoff_resolved (!env).Typecheck.state.o_handoff_fallback;
        List.iter
          (fun node ->
            items := !items + List.length node.Module_graph.node_items)
          (topological_nodes graph);
        let type_errors =
          Hashtbl.fold
            (fun key errs acc -> List.map (fun e -> key ^ ": " ^ e) errs @ acc)
            errs_by_mod []
        in
        (* ── the TYPED-PROFILE firewall (the audit's P0): the
           syntactic subset gate says the parser sees no categorically
           forbidden AST form — it does NOT prove every TYPED use of
           an accepted form is executable.  This check runs after
           typing over the typed closure. *)
        let profile_items =
          List.concat_map (fun node -> node.Module_graph.node_items) (topological_nodes graph)
        in
        let profile_findings = Typed_profile.check !env profile_items in
        Printf.printf "  TYPED_PROFILE = %s (%d findings)\n"
          (if profile_findings = [] then "PASS" else "FAIL")
          (List.length profile_findings);
        List.iter
          (fun f ->
            Printf.printf "    %s: %s\n" f.Typed_profile.f_kind f.Typed_profile.f_message)
          profile_findings;
        Ok
          { ctx_repo_root = repo_root;
            ctx_manifest_path = manifest_path;
            ctx_target = target;
            ctx_graph = graph;
            ctx_resolved = resolved;
            ctx_env = !env;
            ctx_type_errors = type_errors;
            ctx_items = !items;
            ctx_typed_calls_sample = !typed_calls;
            ctx_decl_rounds = !decl_rounds;
            ctx_subset = subset_result;
            ctx_profile_findings = List.length profile_findings;
            ctx_strict_fallbacks = fallback_activations;
            ctx_strict_diags = !strict_audit_diags;
            lowered_methods = 0 }
      end)

(* Public entry: the bootstrap-closure default — recovery-mode semantic
   pipeline plus the unconditional strict-mode audit (selfcheck call
   sites are unchanged). *)
let run_closure_pipeline ~(repo_root : string) ~(manifest_path : string)
    ~(target : Target.t) : (closure_ctx, string) result =
  run_closure_pipeline_impl ~repo_root ~manifest_path ~target ~strict:false

(* Lower every top-level free function of the closure into one Seed MIR
   program (flat namespace; shared by bootstrap-check and compile). *)
(* Materialize program.types from the typed nominal registry (audit P0-8):
   concrete (non-generic) structs/enums become StructDef/EnumDef entries
   with deterministic field/variant identities; generic nominals are
   deferred to post-mono (the seed types table is concrete-only by
   contract). *)
(* Materialize program.statics from the typed const registry: declared
   with their types; initializers arrive with the typed-expression
   channel (the subset firewall rejects const uses until then). *)
let lower_closure (ctx : closure_ctx) : Seed_mir.program =
  let base = lowering_env_of ctx.ctx_env in
  let variants = user_variant_table ctx.ctx_env in
  let mir_funcs = ref [] in
  let lowered_methods = ref 0 in
  List.iter
    (fun node ->
      let funcs =
        List.filter_map
          (fun i -> match i.Ast.kind with Ast.Function fd -> Some fd | _ -> None)
          node.Module_graph.node_items
      in
      List.iter
        (fun fd ->
          let fn_ret, callable =
            match lookup_typed_fn ctx.ctx_env fd.Ast.fn_sig.Ast.sig_name with
            | Some ts -> (ts.Typecheck.ts_return, Ids.Callable_id.to_int ts.Typecheck.ts_callable)
            | None -> (Type_repr.Unit, 0)
          in
          let f =
            Mir_lower.lower_function_with_variants
              ~typed_for_patterns:(typed_for_patterns_of ctx.ctx_env)
              ~typed_let_patterns:(typed_let_patterns_of ctx.ctx_env)
              ~typed_nodes:(typed_nodes_of ctx.ctx_env)
                    ~typed_patterns:(typed_patterns_of ctx.ctx_env)
              variants
              { base with Mir_lower.fn_ret }
              fd.Ast.fn_sig.Ast.sig_name callable [||] [||] fd
          in
          mir_funcs := f :: !mir_funcs)
        funcs;
      (* methods: every callable in the typed universe reaches Seed MIR —
         the impl methods lower with their typed signatures (the audit's
         no-second-AST-scan invariant) *)
      List.iter
        (fun i ->
          match i.Ast.kind with
          | Ast.ImplBlock d -> (
              List.iter
                (fun (m : Ast.function_decl) ->
                  match
                    List.assoc_opt (d.Ast.i_target_type, m.Ast.fn_sig.Ast.sig_name)
                      ctx.ctx_env.Typecheck.methods
                  with
                  | Some ts ->
                      let f =
                        Mir_lower.lower_function_with_variants
                          ~typed_nodes:(typed_nodes_of ctx.ctx_env)
                          ~typed_patterns:(typed_patterns_of ctx.ctx_env)
                          variants
                          { base with Mir_lower.fn_ret = ts.Typecheck.ts_return }
                          m.Ast.fn_sig.Ast.sig_name
                          (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                          (Array.of_list
                             (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                                ts.Typecheck.ts_params_decl))
                          (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
                          ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
                          m
                      in
                      mir_funcs := f :: !mir_funcs;
                      incr lowered_methods
                  | None -> ())
                d.Ast.i_methods)
          | _ -> ())
        node.Module_graph.node_items)
    ctx.ctx_graph.Module_graph.nodes;
  (* nested functions (re-audit: the typed callable universe is the
     lowering source — NOT another AST scan).  Every nested def the
     typechecker registered during the body pass (check_stmt's Item
     Function case) carries its typed signature AND its function_decl:
     each lowers exactly like the methods (typed param types, template
     args from ts_params_decl, conventions from ts_params, the callable
     id), with the nested fn's qname as the seed function's name.  The
     seed is keyed by its callable id (the instance), so the callers'
     calls — which carry that same nested callable id — resolve. *)
  List.iter
    (fun (qname, ts, fd : string * Typecheck.typed_signature * Ast.function_decl) ->
      let f =
        Mir_lower.lower_function_with_variants ~typed_nodes:(typed_nodes_of ctx.ctx_env)
                    ~typed_patterns:(typed_patterns_of ctx.ctx_env)
          variants
          { base with Mir_lower.fn_ret = ts.Typecheck.ts_return }
          qname
          (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
          (Array.of_list
             (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                ts.Typecheck.ts_params_decl))
          (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
          ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
          fd
      in
      mir_funcs := f :: !mir_funcs)
    ctx.ctx_env.Typecheck.state.nested_functions;
  ctx.lowered_methods <- !lowered_methods;
  let all_items =
    List.concat_map (fun node -> node.Module_graph.node_items) ctx.ctx_graph.Module_graph.nodes
  in
  {
    Seed_mir.functions = Array.of_list (List.rev !mir_funcs);
    statics = closure_statics ctx.ctx_env all_items;
    types = closure_types ctx.ctx_env;
  }

(* MIR-side counts for the completeness oracle: calls, callable#0 uses,
   enum variant operations (EnumCtor aggregates, SetDiscriminant,
   Discriminant rvalues, Downcast projections) and closure objects
   (ClosureAgg aggregates and function-pointer constants), plus the
   callable-instance SET (re-audit P0 #2): every `User inst` callee of
   a Call terminator, deduped — the MIR-side identity set the oracle's
   call row compares against the typed accepted instances. *)
type mir_stats = {
  ms_functions : int;
  ms_statics : int;
  ms_types : int;
  ms_calls : int;
  ms_callable_zero : int;
  ms_enum_ops : int;
  ms_closures : int;
  ms_callable_instances : Instance_id.t list;
}

let count_mir_stats (prog : Seed_mir.program) : mir_stats =
  let calls = ref 0 and zeros = ref 0 and enums = ref 0 and closures = ref 0 in
  let instances = ref [] in
  let scan_place (p : Seed_mir.place) =
    List.iter
      (function
        | Seed_mir.Downcast _ -> incr enums
        | _ -> ())
      p.Seed_mir.projections
  in
  let scan_operand (op : Seed_mir.operand) =
    match op with
    | Seed_mir.Copy p | Seed_mir.Move p | Seed_mir.Read p | Seed_mir.Consume p -> scan_place p
    | Seed_mir.Constant (Seed_mir.Function _) -> incr closures
    | Seed_mir.Constant _ -> ()
  in
  let scan_rvalue (rv : Seed_mir.rvalue) =
    match rv with
    | Seed_mir.Discriminant p ->
        scan_place p;
        incr enums
    | Seed_mir.Aggregate (kind, ops) ->
        (match kind with
         | Seed_mir.EnumCtor _ -> incr enums
         | Seed_mir.ClosureAgg _ -> incr closures
         | _ -> ());
        List.iter scan_operand ops
    | Seed_mir.Use op | Seed_mir.Cast (op, _) | Seed_mir.UnaryOp (_, op) -> scan_operand op
    | Seed_mir.BinaryOp (_, l, r) ->
        scan_operand l;
        scan_operand r
    | Seed_mir.Ref p | Seed_mir.RefMut p | Seed_mir.Len p -> scan_place p
  in
  Array.iter
    (fun (f : Seed_mir.function_) ->
      Array.iter
        (fun (b : Seed_mir.block) ->
          List.iter
            (fun st ->
              match st with
              | Seed_mir.Assign (p, rv) ->
                  scan_place p;
                  scan_rvalue rv
              | Seed_mir.SetDiscriminant (p, _) ->
                  scan_place p;
                  incr enums
              | _ -> ())
            b.Seed_mir.statements;
          (match b.Seed_mir.terminator with
           | Seed_mir.Call (dest, callee, args, _, _) ->
               scan_place dest;
               (match callee with
                | Seed_mir.User inst ->
                    incr calls;
                    instances := inst :: !instances;
                    if Ids.Callable_id.to_int (Instance_id.callable inst) = 0 then incr zeros
                | _ -> ());
               Array.iter (fun a -> scan_operand a.Seed_mir.value) args
           | Seed_mir.SwitchInt (op, _, _) | Seed_mir.Assert (op, _, _, _) -> scan_operand op
           | Seed_mir.Drop (p, _, _) | Seed_mir.Deinit (p, _, _) -> scan_place p
           | _ -> ()))
        f.Seed_mir.blocks)
    prog.Seed_mir.functions;
  { ms_functions = Array.length prog.Seed_mir.functions;
    ms_statics = Array.length prog.Seed_mir.statics;
    ms_types = Array.length prog.Seed_mir.types;
    ms_calls = !calls;
    ms_callable_zero = !zeros;
    ms_enum_ops = !enums;
    ms_closures = !closures;
    ms_callable_instances = List.sort_uniq Instance_id.compare !instances }

(* The completeness-oracle rows.  Returns true when the closure is
   INCOMPLETE (any DIFF or any callable#0 use). *)
type oracle_counts = {
  oc_typed_functions : int;
  oc_typed_methods : int;
  oc_typed_consts : int;
  oc_typed_nominals : int;
  oc_typed_calls : int;
  oc_mir_functions : int;
  oc_mir_methods : int;
  oc_mir_statics : int;
  oc_mir_types : int;
  oc_mir_calls : int;
  oc_mir_callable_zero : int;
  oc_mir_enum_ops : int;
  oc_mir_closures : int;
  oc_skipped : bool;
}

(* The oracle's identity-set channel (re-audit P0 #2).  oracle_counts
   is a FROZEN public record — tg_pipeline_smoke constructs it
   literally — so the semantic identity sets ride beside it: each
   oracle_of_ctx call records (typed accepted callable instances, MIR
   callable instances) here, and print_oracle_rows consumes them in
   the same breath.  Single-threaded driver; set immediately before
   every print. *)
let oracle_instance_sets : (Instance_id.t list * Instance_id.t list) ref =
  ref ([], [])

let print_oracle_rows (o : oracle_counts) : bool =
  let diff_count = ref 0 in
  let skipped_note = if o.oc_skipped then " (skipped: typecheck gate failed)" else "" in
  (* ── counter rows: PLACEHOLDERS (re-audit P0 #2) ────────────────
     A counter DIFF cannot prove completeness: a missing call and a
     duplicated different call can have equal counts.  Each row below
     is retained as a labeled placeholder until the semantic identity
     SET for its domain exists; none of them closes completeness. *)
  let counter_row (label : string) (expected : int) (emitted : int) =
    let ok = expected = emitted in
    if not ok then incr diff_count;
    Printf.printf "  oracle %-46s expected %6d  emitted %6d  %s%s\n" label expected emitted
      (if ok then "OK" else "DIFF")
      (if ok then "" else skipped_note)
  in
  counter_row "typed reachable functions (counter placeholder)" o.oc_typed_functions
    o.oc_mir_functions;
  counter_row "typed methods (counter placeholder)" o.oc_typed_methods o.oc_mir_methods;
  counter_row "required static definitions (counter placeholder)" o.oc_typed_consts
    o.oc_mir_statics;
  counter_row "required concrete nominal type defs (counter placeholder)" o.oc_typed_nominals
    o.oc_mir_types;
  counter_row "enum variant ops (counter placeholder)" o.oc_mir_enum_ops o.oc_mir_enum_ops;
  counter_row "closure objects (counter placeholder)" o.oc_mir_closures o.oc_mir_closures;
  (* ── the callable-instance IDENTITY-SET row (re-audit P0 #2): the
     only call row that can close completeness — the typed accepted
     CallableId/InstanceId set (the checker's persistent typed-node
     channel) vs the MIR callable-instance set (the lowered program's
     User callees), with the set-difference sizes (missing/extra)
     reported instead of raw count equality *)
  let typed_set, mir_set = !oracle_instance_sets in
  let missing = List.filter (fun i -> not (List.mem i mir_set)) typed_set in
  let extra = List.filter (fun i -> not (List.mem i typed_set)) mir_set in
  let set_ok = missing = [] && extra = [] in
  if not set_ok then incr diff_count;
  Printf.printf
    "  oracle callable-instance identity set  typed accepted %6d  MIR emitted %6d  %s%s\n"
    (List.length typed_set) (List.length mir_set)
    (if set_ok then "OK" else "DIFF")
    (if set_ok then "" else skipped_note);
  Printf.printf
    "    set difference: %d typed accepted instance(s) missing from MIR, %d MIR instance(s) not typed-accepted (typed-call count sample %d is a lower bound — counts cannot prove completeness, the identity set can)\n"
    (List.length missing) (List.length extra) o.oc_typed_calls;
  if not set_ok && not o.oc_skipped then begin
    let rec take_first n = function
      | [] -> []
      | x :: rest when n > 0 -> x :: take_first (n - 1) rest
      | _ :: _ -> []
    in
    List.iter
      (fun i -> Printf.printf "    missing from MIR: %s\n" (Seed_mir.print_instance i))
      (take_first 10 missing);
    List.iter
      (fun i -> Printf.printf "    extra in MIR: %s\n" (Seed_mir.print_instance i))
      (take_first 10 extra)
  end;
  Printf.printf "  oracle calls with concrete callee InstanceId  emitted %6d  callable#0 uses %d\n"
    o.oc_mir_calls o.oc_mir_callable_zero;
  if o.oc_skipped then
    Printf.printf
      "  oracle note: MIR side emitted as zeros — lowering skipped (typecheck gate failed)\n"
  else
    Printf.printf
      "  oracle note: the counter rows above are PLACEHOLDERS — count equality cannot prove completeness (a missing call and a duplicated different call can have equal counts); the callable-instance identity-set row is the completeness comparison for calls.  The closure row stays a placeholder because typed closures are not recorded (check_closure computes the capture list but records no closure identity/captures) and Mir_lower has no Closure branch (E9040, no closure-CALL path in the VM), so its 0 == 0 is vacuous until the VM's closure model lands\n";
  !diff_count > 0 || o.oc_mir_callable_zero > 0

(* The bootstrap entry: --entry overrides; default is the kernel's
   bootstrap_main (the closure's single `main`), else the first
   function.  Suffix matching allows qualified names. *)
let resolve_bootstrap_entry (prog : Seed_mir.program) (entry_opt : string option) :
    (string * Instance_id.t) option =
  let fns = Array.to_list prog.Seed_mir.functions in
  let find (name : string) =
    List.find_opt
      (fun (f : Seed_mir.function_) ->
        f.Seed_mir.name = name || Util.has_suffix f.Seed_mir.name ("::" ^ name))
      fns
  in
  match entry_opt with
  | Some name -> (
      match find name with
      | Some f -> Some (f.Seed_mir.name, f.Seed_mir.instance)
      | None -> None)
  | None -> (
      match find "bootstrap_main" with
      | Some f -> Some (f.Seed_mir.name, f.Seed_mir.instance)
      | None -> (
          match find "main" with
          | Some f -> Some (f.Seed_mir.name, f.Seed_mir.instance)
          | None -> (
              match fns with
              | f :: _ -> Some (f.Seed_mir.name, f.Seed_mir.instance)
              | [] -> None)))

(* Residual Type_param walk over every rvalue/operand/type position of a
   program: params, locals, instance type args, cast targets, function
   constants, closure aggregates, call callees, static types, type
   defs. *)
let count_residual_type_params (prog : Seed_mir.program) : int =
  let n = ref 0 in
  let tp (ty : Type_repr.t) = if Type_repr.has_type_param ty then incr n in
  let tp_inst (i : Instance_id.t) = Array.iter tp (Instance_id.type_args i) in
  let scan_operand (op : Seed_mir.operand) =
    match op with
    | Seed_mir.Constant (Seed_mir.Function i) -> tp_inst i
    | _ -> ()
  in
  let scan_rvalue (rv : Seed_mir.rvalue) =
    match rv with
    | Seed_mir.Cast (op, ty) ->
        tp ty;
        scan_operand op
    | Seed_mir.Aggregate (kind, ops) ->
        (match kind with
         | Seed_mir.ClosureAgg i -> tp_inst i
         | _ -> ());
        List.iter scan_operand ops
    | Seed_mir.Use op | Seed_mir.UnaryOp (_, op) -> scan_operand op
    | Seed_mir.BinaryOp (_, l, r) ->
        scan_operand l;
        scan_operand r
    | _ -> ()
  in
  Array.iter
    (fun (f : Seed_mir.function_) ->
      Array.iter tp (Instance_id.type_args f.Seed_mir.instance);
      Array.iter (fun p -> tp p.Type_repr.pt_type) f.Seed_mir.params;
      Array.iter tp f.Seed_mir.locals;
      Array.iter
        (fun (b : Seed_mir.block) ->
          List.iter
            (fun st ->
              match st with
              | Seed_mir.Assign (_, rv) -> scan_rvalue rv
              | _ -> ())
            b.Seed_mir.statements;
          (match b.Seed_mir.terminator with
           | Seed_mir.Call (_, callee, args, _, _) ->
               (match callee with
                | Seed_mir.User i -> tp_inst i
                | _ -> ());
               Array.iter (fun a -> scan_operand a.Seed_mir.value) args
           | _ -> ()))
        f.Seed_mir.blocks)
    prog.Seed_mir.functions;
  Array.iter
    (fun (_, ty, init) ->
      tp ty;
      match init with
      | Some (Seed_mir.Function i) -> tp_inst i
      | _ -> ())
    prog.Seed_mir.statics;
  Array.iter (fun d -> tp (Seed_mir.def_repr d)) prog.Seed_mir.types;
  !n

(* ── Static reachable-host closure scan (re-audit: stage 10) ────────

   The post-mono program's calls carry their callees as Seed_mir callee
   forms.  The VM's host dispatch (Vm.call_host) converts
   Seed_mir.Intrinsic i / Seed_mir.Extern i into
   Host.Intrinsic (Intrinsic_registry.Id.make i) / Host.Extern
   (Extern_registry.Id.make i) — the registry-index -> abstract-id
   boundary.  A call in User form maps to a host symbol when the
   callee's instance names one of the program's specialized functions
   and that function's source name is a declared host symbol (extern-
   declared functions reach Seed MIR as User callees; the host
   registries are keyed by those same names, and the binding table
   resolves ids from them).  This scan collects exactly the host ids
   the program can dispatch to — the REACHABLE set. *)
let collect_reachable_host_ids (prog : Seed_mir.program) : Host.host_id list =
  let module IdSet = Set.Make (struct type t = Host.host_id let compare = compare end) in
  let acc = ref IdSet.empty in
  let add (id : Host.host_id) = acc := IdSet.add id !acc in
  (* User callee -> host symbol: the callee instance's callable names
     one of the specialized functions; a function whose name is a
     declared host symbol is a host call in User form. *)
  let fn_by_callable = Hashtbl.create 64 in
  Array.iter
    (fun (f : Seed_mir.function_) ->
      Hashtbl.replace fn_by_callable
        (Ids.Callable_id.to_int (Instance_id.callable f.Seed_mir.instance))
        f.Seed_mir.name)
    prog.Seed_mir.functions;
  let resolve_user (inst : Instance_id.t) =
    match
      Hashtbl.find_opt fn_by_callable (Ids.Callable_id.to_int (Instance_id.callable inst))
    with
    | None -> ()
    | Some name -> (
        match Intrinsic_registry.lookup Intrinsic_registry.manifest ~name with
        | Some (iid, _) -> add (Host.Intrinsic iid)
        | None -> (
            match Extern_registry.lookup Extern_registry.manifest ~name with
            | Some (eid, _) -> add (Host.Extern eid)
            | None -> ()))
  in
  Array.iter
    (fun (f : Seed_mir.function_) ->
      Array.iter
        (fun (b : Seed_mir.block) ->
          match b.Seed_mir.terminator with
          | Seed_mir.Call (_, callee, _, _, _) -> (
              match callee with
              | Seed_mir.Intrinsic i -> add (Host.Intrinsic (Intrinsic_registry.Id.make i))
              | Seed_mir.Extern i -> add (Host.Extern (Extern_registry.Id.make i))
              | Seed_mir.User inst -> resolve_user inst)
          | _ -> ())
        f.Seed_mir.blocks)
    prog.Seed_mir.functions;
  IdSet.elements !acc

type mono_outcome = {
  mo_program : Seed_mir.program;
  mo_entry : Instance_id.t;
  mo_entry_name : string;
  mo_pre_functions : int;
  mo_post_functions : int;
  mo_post_instances : int;
  mo_type_instances : int;
  mo_residual_type_params : int;
}

(* ── Post-mono type materialization (re-audit finding: "generic nominal
      type definitions disappear before MIR") ───────────────────────
   Mono.build's queue (the on_type_instance channel) lists every
   CONCRETE instance of a generic nominal the specialized bodies and
   signatures mention, in first-discovery order.  This assembles the
   final types table: for each queued (tid, args) the generic
   template's fields/variants are substituted under the KParam-keyed
   table (Mono.type_substitution — the same positional machinery as the
   function templates), and the result carries a FRESH TypeId — the
   semantic identity of a concrete instance is (tid, args), so two
   instances (Pair[Int], Pair[String]) must never share one def.  Every
   Named (tid, args) in the program (bodies, statics, defs) is then
   rewritten to the fresh TypeId; StructCtor/EnumCtor aggregate kinds
   are rewritten through their destination's rewritten type.  The
   materialization is a FIXPOINT: the substituted field types can
   reveal further instances (Pair[Vec[Int]], Pair[Pair[Int]], ...),
   queued in materialization order; instances embedded in the pre-mono
   defs/statics (invisible to the body walk) are queued here too.  Fail
   closed: an instance whose tid has no generic template, or an arity
   disagreement, is an internal error.  The materialized defs carry the
   SEMANTIC FieldId/VariantId of the original def (fd_id/vd_id are
   copied, never re-minted); fd_index/vd_index stay the declaration
   order. *)

let array_eq (cmp : 'a -> 'a -> int) (a : 'a array) (b : 'a array) : bool =
  Array.length a = Array.length b
  && Array.for_all2 (fun x y -> cmp x y = 0) a b

let rec rewrite_ty (map : (Ids.Type_id.t * Type_repr.t array * Ids.Type_id.t) list)
    (ty : Type_repr.t) : Type_repr.t =
  match ty with
  | Type_repr.Named (tid, args) ->
      let args' = Array.map (rewrite_ty map) args in
      (match
         List.find_opt
           (fun (t, a, _) -> Ids.Type_id.compare t tid = 0 && array_eq Type_repr.compare a args)
           map
       with
       | Some (_, _, ntid) -> Type_repr.Named (ntid, args')
       | None -> Type_repr.Named (tid, args'))
  | Type_repr.Raw_ptr (m, t) -> Type_repr.Raw_ptr (m, rewrite_ty map t)
  | Type_repr.Ref_internal (m, t) -> Type_repr.Ref_internal (m, rewrite_ty map t)
  | Type_repr.Tuple elems -> Type_repr.Tuple (Array.map (rewrite_ty map) elems)
  | Type_repr.Fixed_array (t, n) -> Type_repr.Fixed_array (rewrite_ty map t, n)
  | Type_repr.Function (params, ret) ->
      Type_repr.Function
        ( Array.map
            (fun p -> { p with Type_repr.pt_type = rewrite_ty map p.Type_repr.pt_type })
            params,
          rewrite_ty map ret )
  | ty -> ty

let rewrite_instance (map) (inst : Instance_id.t) : Instance_id.t =
  Instance_id.make ~callable:(Instance_id.callable inst)
    ~type_args:(Array.map (rewrite_ty map) (Instance_id.type_args inst))

let rewrite_operand map (op : Seed_mir.operand) : Seed_mir.operand =
  match op with
  | Seed_mir.Constant (Seed_mir.Function inst) ->
      Seed_mir.Constant (Seed_mir.Function (rewrite_instance map inst))
  | op -> op

(* Aggregate kinds carry the owner TypeId but not the instance args; the
   instance is the DESTINATION's type.  The verifier requires the kind
   tid to equal the dest's Named tid, so after the dest's type was
   rewritten to its fresh instance tid, the kind follows.  (Aggregates
   target plain locals in valid programs; the root local type is the
   dest type.) *)
let rewrite_rvalue map (dest_ty : Type_repr.t option) (rv : Seed_mir.rvalue) :
    Seed_mir.rvalue =
  match rv with
  | Seed_mir.Use op -> Seed_mir.Use (rewrite_operand map op)
  | Seed_mir.Ref p -> Seed_mir.Ref p
  | Seed_mir.RefMut p -> Seed_mir.RefMut p
  | Seed_mir.Aggregate (kind, ops) ->
      let kind' =
        match kind with
        | Seed_mir.StructCtor (tid, fields) -> (
            match dest_ty with
            | Some (Type_repr.Named (ntid, _)) -> Seed_mir.StructCtor (ntid, fields)
            | _ -> Seed_mir.StructCtor (tid, fields))
        | Seed_mir.EnumCtor (tid, vid) -> (
            match dest_ty with
            | Some (Type_repr.Named (ntid, _)) -> Seed_mir.EnumCtor (ntid, vid)
            | _ -> Seed_mir.EnumCtor (tid, vid))
        | Seed_mir.ClosureAgg inst -> Seed_mir.ClosureAgg (rewrite_instance map inst)
        | k -> k
      in
      Seed_mir.Aggregate (kind', List.map (rewrite_operand map) ops)
  | Seed_mir.BinaryOp (o, l, r) ->
      Seed_mir.BinaryOp (o, rewrite_operand map l, rewrite_operand map r)
  | Seed_mir.UnaryOp (o, op) -> Seed_mir.UnaryOp (o, rewrite_operand map op)
  | Seed_mir.Discriminant p -> Seed_mir.Discriminant p
  | Seed_mir.Len p -> Seed_mir.Len p
  | Seed_mir.Cast (op, ty) -> Seed_mir.Cast (rewrite_operand map op, rewrite_ty map ty)

let rewrite_block map (locals : Type_repr.t array) (b : Seed_mir.block) : Seed_mir.block =
  let dest_ty (p : Seed_mir.place) : Type_repr.t option =
    if p.Seed_mir.local >= 0 && p.Seed_mir.local < Array.length locals then
      Some locals.(p.Seed_mir.local)
    else None
  in
  {
    id = b.id;
    statements =
      List.map
        (function
          | Seed_mir.Assign (p, rv) -> Seed_mir.Assign (p, rewrite_rvalue map (dest_ty p) rv)
          | st -> st)
        b.statements;
    terminator =
      (match b.terminator with
       | Seed_mir.Call (dest, callee, args, next, unwind) ->
           let callee' =
             match callee with
             | Seed_mir.User inst -> Seed_mir.User (rewrite_instance map inst)
             | c -> c
           in
           Seed_mir.Call
             ( dest,
               callee',
               Array.map
                 (fun a -> { a with Seed_mir.value = rewrite_operand map a.Seed_mir.value })
                 args,
               next,
               unwind )
       | Seed_mir.SwitchInt (op, targets, default) ->
           Seed_mir.SwitchInt (rewrite_operand map op, targets, default)
       | Seed_mir.Assert (op, expected, msg, target) ->
           Seed_mir.Assert (rewrite_operand map op, expected, msg, target)
       | t -> t);
  }

let rewrite_function map (fn : Seed_mir.function_) : Seed_mir.function_ =
  let locals' = Array.map (rewrite_ty map) fn.Seed_mir.locals in
  {
    fn with
    instance = rewrite_instance map fn.Seed_mir.instance;
    params =
      Array.map
        (fun p -> { p with Type_repr.pt_type = rewrite_ty map p.Type_repr.pt_type })
        fn.Seed_mir.params;
    locals = locals';
    blocks = Array.map (rewrite_block map locals') fn.Seed_mir.blocks;
  }

let rewrite_static map ((name, ty, init) : string * Type_repr.t * Seed_mir.constant option) :
    string * Type_repr.t * Seed_mir.constant option =
  ( name,
    rewrite_ty map ty,
    match init with
    | Some (Seed_mir.Function inst) ->
        Some (Seed_mir.Function (rewrite_instance map inst))
    | init -> init )

let rewrite_def map (d : Seed_mir.type_def) : Seed_mir.type_def =
  match d with
  | Seed_mir.StructDef { sd_id; sd_fields } ->
      Seed_mir.StructDef
        {
          sd_id;
          sd_fields =
            List.map
              (fun f -> { f with Seed_mir.fd_ty = rewrite_ty map f.Seed_mir.fd_ty })
              sd_fields;
        }
  | Seed_mir.EnumDef { ed_id; ed_variants } ->
      Seed_mir.EnumDef
        {
          ed_id;
          ed_variants =
            List.map
              (fun v -> { v with Seed_mir.vd_payload = rewrite_ty map v.Seed_mir.vd_payload })
              ed_variants;
        }

(* The largest TypeId the program can see: every def id, every generic
   registry tid and every Named mention in bodies/statics/defs.  The
   fresh instance TypeIds are minted above it, so a fresh id can never
   alias an existing identity (a body's unrewritten Named tid must not
   start resolving to a materialized def). *)
let program_max_type_id ~(generic_types : Mono.generic_def array)
    (prog : Seed_mir.program) : int =
  let acc = ref 0 in
  let bump i = if i > !acc then acc := i in
  let rec walk_ty (ty : Type_repr.t) : unit =
    match ty with
    | Type_repr.Named (tid, args) ->
        bump (Ids.Type_id.to_int tid);
        Array.iter walk_ty args
    | Type_repr.Raw_ptr (_, t) | Type_repr.Ref_internal (_, t) | Type_repr.Fixed_array (t, _) ->
        walk_ty t
    | Type_repr.Tuple elems -> Array.iter walk_ty elems
    | Type_repr.Function (params, ret) ->
        Array.iter (fun p -> walk_ty p.Type_repr.pt_type) params;
        walk_ty ret
    | _ -> ()
  in
  let walk_operand (op : Seed_mir.operand) : unit =
    match op with
    | Seed_mir.Constant (Seed_mir.Function inst) ->
        Array.iter walk_ty (Instance_id.type_args inst)
    | _ -> ()
  in
  let walk_rvalue (rv : Seed_mir.rvalue) : unit =
    match rv with
    | Seed_mir.Use op -> walk_operand op
    | Seed_mir.Ref _ | Seed_mir.RefMut _ | Seed_mir.Discriminant _ | Seed_mir.Len _ -> ()
    | Seed_mir.Aggregate (kind, ops) ->
        List.iter walk_operand ops;
        (match kind with
         | Seed_mir.ClosureAgg inst -> Array.iter walk_ty (Instance_id.type_args inst)
         | _ -> ())
    | Seed_mir.BinaryOp (_, l, r) ->
        walk_operand l;
        walk_operand r
    | Seed_mir.UnaryOp (_, op) -> walk_operand op
    | Seed_mir.Cast (op, ty) ->
        walk_operand op;
        walk_ty ty
  in
  Array.iter
    (fun (d : Seed_mir.type_def) -> bump (Ids.Type_id.to_int (Seed_mir.def_id d)))
    prog.Seed_mir.types;
  Array.iter
    (fun (gd : Mono.generic_def) -> bump (Ids.Type_id.to_int gd.Mono.gd_tid))
    generic_types;
  Array.iter
    (fun (f : Seed_mir.function_) ->
      Array.iter walk_ty (Instance_id.type_args f.Seed_mir.instance);
      Array.iter (fun p -> walk_ty p.Type_repr.pt_type) f.Seed_mir.params;
      Array.iter walk_ty f.Seed_mir.locals;
      Array.iter
        (fun (b : Seed_mir.block) ->
          List.iter
            (function
              | Seed_mir.Assign (_, rv) -> walk_rvalue rv
              | _ -> ())
            b.Seed_mir.statements;
          match b.Seed_mir.terminator with
          | Seed_mir.Call (_, callee, args, _, _) ->
              (match callee with
               | Seed_mir.User inst -> Array.iter walk_ty (Instance_id.type_args inst)
               | _ -> ());
              Array.iter (fun a -> walk_operand a.Seed_mir.value) args
          | Seed_mir.SwitchInt (op, _, _) | Seed_mir.Assert (op, _, _, _) -> walk_operand op
          | _ -> ())
        f.Seed_mir.blocks)
    prog.Seed_mir.functions;
  Array.iter
    (fun (_, ty, init) ->
      walk_ty ty;
      match init with
      | Some (Seed_mir.Function inst) -> Array.iter walk_ty (Instance_id.type_args inst)
      | _ -> ())
    prog.Seed_mir.statics;
  Array.iter
    (fun (d : Seed_mir.type_def) ->
      match d with
      | Seed_mir.StructDef { sd_fields; _ } -> List.iter (fun f -> walk_ty f.Seed_mir.fd_ty) sd_fields
      | Seed_mir.EnumDef { ed_variants; _ } ->
          List.iter (fun v -> walk_ty v.Seed_mir.vd_payload) ed_variants)
    prog.Seed_mir.types;
  !acc

let materialize_type_instances ~(generic_types : Mono.generic_def array)
    ~(type_instances : Mono.type_instance list) (prog : Seed_mir.program) :
    (Seed_mir.program, string list) result =
  if Array.length generic_types = 0 then Ok prog
  else begin
    let errors = ref [] in
    let err msg = errors := msg :: !errors in
    let seen : Mono.type_instance list ref = ref [] in
    let queue : Mono.type_instance Queue.t = Queue.create () in
    let enqueue (ti : Mono.type_instance) =
      if not (List.exists (Mono.type_instance_equal ti) !seen) then begin
        seen := ti :: !seen;
        Queue.add ti queue
      end
    in
    (* seed: the mono queue (first-discovery order), then instances
       embedded in the pre-mono defs and statics — those are invisible
       to the body walk (a struct Foo { p: Pair[Int] } field type is
       only reached through Foo's def) *)
    List.iter enqueue type_instances;
    Array.iter
      (fun (d : Seed_mir.type_def) ->
        match d with
        | Seed_mir.StructDef { sd_fields; _ } ->
            List.iter (fun f -> Mono.scan_type generic_types enqueue f.Seed_mir.fd_ty) sd_fields
        | Seed_mir.EnumDef { ed_variants; _ } ->
            List.iter
              (fun v -> Mono.scan_type generic_types enqueue v.Seed_mir.vd_payload)
              ed_variants)
      prog.Seed_mir.types;
    Array.iter
      (fun (_, ty, init) ->
        Mono.scan_type generic_types enqueue ty;
        match init with
        | Some (Seed_mir.Function inst) ->
            Array.iter (Mono.scan_type generic_types enqueue) (Instance_id.type_args inst)
        | _ -> ())
      prog.Seed_mir.statics;
    let next_tid = ref (program_max_type_id ~generic_types prog + 1) in
    let map : (Ids.Type_id.t * Type_repr.t array * Ids.Type_id.t) list ref = ref [] in
    let materialized : Seed_mir.type_def list ref = ref [] in
    (* drain: materialize each queued instance; the substituted field
       types can reveal further instances (the fixpoint), queued in
       materialization order *)
    while not (Queue.is_empty queue) do
      let ti = Queue.pop queue in
      match Mono.find_generic generic_types ti.Mono.ti_tid with
      | None ->
          err
            (Printf.sprintf
               "mono: no generic template def for the required concrete type instance type#%d[%s]"
               (Ids.Type_id.to_int ti.Mono.ti_tid)
               (String.concat ", "
                  (Array.to_list (Array.map Seed_mir.print_type ti.Mono.ti_args))))
      | Some gd -> (
          match Mono.type_substitution gd ti.Mono.ti_args with
          | Error m -> err m
          | Ok subst ->
              let ntid = Ids.Type_id.make !next_tid in
              incr next_tid;
              let def =
                match gd.Mono.gd_def with
                | Seed_mir.StructDef { sd_fields; _ } ->
                    Seed_mir.StructDef
                      {
                        sd_id = ntid;
                        sd_fields =
                          List.map
                            (fun f ->
                              {
                                f with
                                Seed_mir.fd_ty = Type_repr.substitute subst f.Seed_mir.fd_ty;
                              })
                            sd_fields;
                      }
                | Seed_mir.EnumDef { ed_variants; _ } ->
                    Seed_mir.EnumDef
                      {
                        ed_id = ntid;
                        ed_variants =
                          List.map
                            (fun v ->
                              {
                                v with
                                Seed_mir.vd_payload =
                                  Type_repr.substitute subst v.Seed_mir.vd_payload;
                              })
                            ed_variants;
                      }
              in
              map := (ti.Mono.ti_tid, ti.Mono.ti_args, ntid) :: !map;
              materialized := def :: !materialized;
              (match def with
               | Seed_mir.StructDef { sd_fields; _ } ->
                   List.iter (fun f -> Mono.scan_type generic_types enqueue f.Seed_mir.fd_ty)
                     sd_fields
               | Seed_mir.EnumDef { ed_variants; _ } ->
                   List.iter
                     (fun v -> Mono.scan_type generic_types enqueue v.Seed_mir.vd_payload)
                     ed_variants))
    done;
    match !errors with
    | [] ->
        let map = List.rev !map in
        let materialized = List.rev !materialized in
        Ok
          {
            Seed_mir.functions = Array.map (rewrite_function map) prog.Seed_mir.functions;
            statics = Array.map (rewrite_static map) prog.Seed_mir.statics;
            types =
              Array.append
                (Array.map (rewrite_def map) prog.Seed_mir.types)
                (Array.of_list (List.map (rewrite_def map) materialized));
          }
    | errs -> Error (List.rev errs)
  end

(* Mono the lowered closure from the bootstrap entry; report pre/post
   function and instance counts; require zero residual Type_param and a
   clean Mir_verify.require_valid_concrete (post-mono = concrete mode)
   of the mono'd program. *)
let run_mono_phase ~(entry_name : string) ~(entry : Instance_id.t)
    ?(generic_types : Mono.generic_def array = [||])
    (prog : Seed_mir.program) : (mono_outcome, string list) result =
  Printf.printf "  mono: entry '%s' (%s)\n" entry_name (Seed_mir.print_instance entry);
  let type_instances = ref [] in
  match
    Mono.build ~entry ~generic_types
      ~on_type_instance:(fun ti -> type_instances := ti :: !type_instances)
      prog
  with
  | Error errs ->
      Printf.printf "  mono: BUILD FAILED\n";
      List.iter (fun e -> Printf.printf "    %s\n" e) errs;
      Error errs
  | Ok fns ->
      let mono_prog = { prog with Seed_mir.functions = fns } in
      let pre = Array.length prog.Seed_mir.functions in
      let post = Array.length fns in
      let queued = List.rev !type_instances in
      (match materialize_type_instances ~generic_types ~type_instances:queued mono_prog with
       | Error errs ->
           Printf.printf "  mono: TYPE MATERIALIZATION FAILED\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Error errs
       | Ok final_prog ->
           let n_type_instances =
             Array.length final_prog.Seed_mir.types - Array.length prog.Seed_mir.types
           in
           let residual = count_residual_type_params final_prog in
           Printf.printf
             "  mono: build OK — pre %d template function(s) -> post %d specialized instance(s)\n"
             pre post;
           Printf.printf "  mono: queued concrete type instances: %d (%s)\n"
             (List.length queued)
             (String.concat ", "
                (List.map
                   (fun (ti : Mono.type_instance) ->
                     Printf.sprintf "type#%d[%s]"
                       (Ids.Type_id.to_int ti.Mono.ti_tid)
                       (String.concat ", "
                          (Array.to_list (Array.map Seed_mir.print_type ti.Mono.ti_args))))
                   queued));
           Printf.printf
             "  mono: materialized %d concrete type instance def(s); final types table %d entries\n"
             n_type_instances (Array.length final_prog.Seed_mir.types);
           Printf.printf
             "  mono: post-instance count %d; residual Type_param positions %d (walked params/locals/instance args/operands/callees/statics/type defs)\n"
             post residual;
           (match Mir_verify.require_valid_concrete final_prog with
            | Error errs ->
                Printf.printf "  MONO_MIR_STRUCTURAL_GATE = FAIL\n";
                List.iter (fun e -> Printf.printf "    %s\n" e) errs;
                Error errs
            | Ok () ->
                Printf.printf "  MONO_MIR_STRUCTURAL_GATE = PASS (%d functions)\n" post;
                Ok
                  { mo_program = final_prog;
                    mo_entry = entry;
                    mo_entry_name = entry_name;
                    mo_pre_functions = pre;
                    mo_post_functions = post;
                    mo_post_instances = post;
                    mo_type_instances = n_type_instances;
                    mo_residual_type_params = residual }))

let oracle_of_ctx (ctx : closure_ctx) (stats : mir_stats option) : oracle_counts =
  let s =
    match stats with
    | Some s -> s
    | None ->
        {
          ms_functions = 0;
          ms_statics = 0;
          ms_types = 0;
          ms_calls = 0;
          ms_callable_zero = 0;
          ms_enum_ops = 0;
          ms_closures = 0;
          ms_callable_instances = [];
        }
  in
  (* the typed accepted CallableId/InstanceId set (re-audit P0 #2):
     every checker-ACCEPTED call node on the persistent typed channel
     (span -> (callable, solved concrete substitution)).  Enum-variant
     constructors are excluded — they lower to EnumCtor aggregates,
     never to a User callee — and so are the size_of/align_of query
     sigs (a type-argument special form), so the set is exactly the
     typed calls that must appear as MIR User callees. *)
  let env = ctx.ctx_env in
  let excluded_callables =
    List.map (fun (_, ts) -> ts.Typecheck.ts_callable) env.Typecheck.constructors
    @ List.map (fun (_, ts) -> ts.Typecheck.ts_callable) env.Typecheck.state.query_sigs
  in
  let is_user_callable (c : Ids.Callable_id.t) : bool =
    not (List.exists (fun k -> Ids.Callable_id.compare k c = 0) excluded_callables)
  in
  let typed_set =
    Hashtbl.fold
      (fun _ (n : Typecheck.typed_node) acc ->
        match n.Typecheck.tn_call with
        | Some (cid, subst) when is_user_callable cid ->
            Instance_id.make ~callable:cid ~type_args:subst :: acc
        | _ -> acc)
      env.Typecheck.typed_nodes []
    |> List.sort_uniq Instance_id.compare
  in
  oracle_instance_sets := (typed_set, s.ms_callable_instances);
  {
    oc_typed_functions = List.length ctx.ctx_env.Typecheck.functions;
    oc_typed_methods = List.length ctx.ctx_env.Typecheck.methods;
    oc_typed_consts = List.length ctx.ctx_env.Typecheck.consts;
    oc_typed_nominals = List.length ctx.ctx_env.Typecheck.nominals;
    oc_typed_calls = ctx.ctx_typed_calls_sample;
    oc_mir_functions = s.ms_functions;
    oc_mir_methods = ctx.lowered_methods;
    oc_mir_statics = s.ms_statics;
    oc_mir_types = s.ms_types;
    oc_mir_calls = s.ms_calls;
    oc_mir_callable_zero = s.ms_callable_zero;
    oc_mir_enum_ops = s.ms_enum_ops;
    oc_mir_closures = s.ms_closures;
    oc_skipped = stats = None;
  }

(* ── CALL_ARGUMENT_ACCESS_SANITY (re-audit P0-11; re-audit P0 #2 label) ─
   After the typecheck phase, walk the closure env's RECORDED typed
   channels: the typechecker accumulates one Access_check.access per
   checked call argument (place path + callee-side read effect) across
   the whole closure (the channel is not reset per item).  The pass
   (a) feeds the access-effect conflict matrix per statement group (one
   call's argument list) and (b) replays the recorded operations on
   Resource_check's per-local state lattice per item; findings are
   returned, nothing in the typechecker is rewritten.

   HONEST LABEL — THIS IS NOT THE OWNERSHIP PASS.  It is a SANITY
   replay of call-argument accesses recorded during typechecking: the
   roots are the typed LocalIds of the argument bindings (shadowed
   locals are distinct roots), the effects are the callee-side
   conventions, and the replay walks a simplified resource-state
   lattice.  It does NOT perform the native ownership stage: the real
   CFG-based pass (finalize_plan + edge_cleanup consumed by MIR) is
   future work, and nothing about seed equivalence rests on this
   stage's findings.  Additive by construction: it reports findings
   and cannot change the typecheck debt. *)

(* Nominal-definition lookup for the pass's copy query (mirror of
   seed_mir.def_repr / mir_verify.find_type, read-only): a struct
   resolves to its field tuple, an enum to its payload function, so
   Resource_check.is_copy recurses over every field / payload.  A name
   with no nominal (alias/builtin) falls back to the type registry. *)
let nominal_def_of_tid (env : Typecheck.env) (tid : Ids.Type_id.t) : Type_repr.t option =
  match List.assoc_opt tid env.Typecheck.type_names with
  | None -> None
  | Some name -> (
      match List.assoc_opt name env.Typecheck.nominals with
      | Some nom ->
          Some
            (match nom.Typecheck.nom_kind with
             | `Struct ->
                 Type_repr.Tuple (Array.of_list (List.map snd nom.Typecheck.nom_fields))
             | `Enum ->
                 Type_repr.Function
                   ( Array.of_list
                       (List.map
                          (fun (_, pty) ->
                            {
                              Type_repr.pt_convention = Access_effect.Let;
                              pt_type =
                                (if Array.length pty = 0 then Type_repr.Unit
                                 else Type_repr.Tuple pty);
                            })
                          nom.Typecheck.nom_variants),
                      Type_repr.Never ))
      | None -> List.assoc_opt name env.Typecheck.types)

let run_access_resource_pass (ctx : closure_ctx) : Access_check.finding list =
  Access_check.run_closure (nominal_def_of_tid ctx.ctx_env)
    ctx.ctx_env.Typecheck.state.oracle.o_accesses

let report_access_resource_pass (ctx : closure_ctx) : unit =
  let findings = run_access_resource_pass ctx in
  let recorded = List.rev ctx.ctx_env.Typecheck.state.oracle.o_accesses in
  let n_places =
    List.length (List.filter (fun (a : Access_check.access) -> a.a_path <> None) recorded)
  in
  Printf.printf
    "  call-argument access sanity (NOT the ownership pass — the CFG finalize_plan/edge_cleanup cleanup-plan stage is future work; this replay walks the recorded typed channels): %d call-argument accesses (%d place paths, roots keyed by LocalId), %d finding(s)\n"
    (List.length recorded) n_places (List.length findings);
  let status = if findings = [] then "PASS" else "FAIL" in
  Printf.printf "  CALL_ARGUMENT_ACCESS_SANITY = %s (%d finding(s))\n" status
    (List.length findings);
  let printed = ref 0 in
  List.iter
    (fun (f : Access_check.finding) ->
      if !printed < 20 then begin
        Printf.printf "    %s: %s\n" f.Access_check.f_kind f.Access_check.f_message;
        incr printed
      end)
    findings;
  if List.length findings > 20 then
    Printf.printf "    ... (%d more findings suppressed)\n" (List.length findings - 20)

(* ── bootstrap-check (audit §51) ───────────────────────────────── *)
let take_first (n : int) (l : 'a list) : 'a list =
  List.rev (snd (List.fold_left (fun (i, acc) x -> if i < n then (i + 1, x :: acc) else (i, acc)) (0, []) l))

(* ── structured diagnostics JSONL (audit P0 fix) ─────────────────
   Hand-rolled JSON serialization (no external library): the evidence
   needs exactly one object-per-line shape, so a minimal correct
   escape function suffices.  The records come from the typechecker's
   structured channel (Typecheck.state.structured_diags) — original
   spans and raw messages, never re-parsed from rendered text. *)
let json_escape (s : string) : string =
  let b = Buffer.create (String.length s + 16) in
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let json_string (s : string) : string = "\"" ^ json_escape s ^ "\""

let span_to_json (s : Span.span) : string =
  Printf.sprintf "{\"file\":%d,\"start\":%d,\"end\":%d}" s.Span.file_id s.Span.start
    s.Span.end_

let write_diagnostics_jsonl ~(path : string) (ds : Typecheck.structured_diag list) : unit =
  let oc = open_out path in
  (try
     List.iter
       (fun d ->
         Printf.fprintf oc
           "{\"module\":%s,\"item\":%s,\"is_secondary\":%b,\"message\":%s,\"span\":%s,\"category\":%s}\n"
           (json_string d.Typecheck.sd_module)
           (json_string d.Typecheck.sd_item)
           d.Typecheck.sd_secondary
           (json_string d.Typecheck.sd_message)
           (match d.Typecheck.sd_span with Some s -> span_to_json s | None -> "null")
           (json_string (Debt_report.classify d.Typecheck.sd_message)))
       (List.rev ds)
   with e ->
     close_out_noerr oc;
     raise e);
  close_out oc

(* ── EVIDENCE_* fact lines (audit P0 fix) ─────────────────────────
   The script reads the subset / strict-resolution / mir / host facts
   from the bootstrap-check output; each is printed as a stable
   machine-readable line (values JSON-escaped where they are free
   text). *)

let print_subset_evidence (r : subset_result) : unit =
  let counts = Hashtbl.create 16 in
  List.iter
    (fun m ->
      List.iter
        (fun (c, n) ->
          Hashtbl.replace counts c (n + Option.value ~default:0 (Hashtbl.find_opt counts c)))
        m.ssm_findings)
    r.sr_modules;
  Printf.printf "EVIDENCE_SUBSET total_findings=%d accepted=%d rejected=%d modules=%d\n"
    r.sr_total r.sr_accepted r.sr_rejected (List.length r.sr_modules);
  List.iter
    (fun (c, n) -> Printf.printf "EVIDENCE_SUBSET_COUNT code=%s count=%d\n" c n)
    (List.sort compare (Hashtbl.fold (fun c n acc -> (c, n) :: acc) counts []));
  List.iter
    (fun m ->
      if m.ssm_total > 0 then
        Printf.printf "EVIDENCE_SUBSET_MODULE module=%s findings=%d\n"
          (json_escape m.ssm_key) m.ssm_total)
    r.sr_modules

let print_strict_evidence (ds : Diagnostic.diagnostic list) (fallbacks : int) : unit =
  Printf.printf "EVIDENCE_STRICT diagnostics=%d compatibility_fallback_activations=%d\n"
    (List.length ds) fallbacks;
  List.iter
    (fun (d : Diagnostic.diagnostic) ->
      Printf.printf "EVIDENCE_STRICT_DIAG code=%s message=%s span=%d:%d:%d\n"
        (json_escape d.Diagnostic.code)
        (json_escape d.Diagnostic.message)
        d.Diagnostic.span.Span.file_id d.Diagnostic.span.Span.start
        d.Diagnostic.span.Span.end_)
    ds

(* The artifact path the kernel derives from its own argv: the -o/
   --output value, else the input file minus .tg. *)
let kernel_output_path (kernel_args : string list) : string option =
  let rec go = function
    | "-o" :: v :: _ | "--output" :: v :: _ -> Some v
    | _ :: rest -> go rest
    | [] -> None
  in
  match go kernel_args with
  | Some p -> Some p
  | None -> (
      match kernel_args with
      | file :: _ when not (String.length file >= 1 && file.[0] = '-') ->
          if Filename.check_suffix file ".tg" then Some (Filename.chop_suffix file ".tg")
          else Some file
      | _ -> None)

let artifact_exists ~(repo_root : string) (path : string) : bool =
  if Filename.is_relative path then Sys.file_exists (Filename.concat repo_root path)
  else Sys.file_exists path

(* ── the ONE structured bootstrap closure (re-audit P0: the gate must
   not reconstruct the pipeline — every consumer inspects this result) ─ *)
type bootstrap_stages = {
  bs_ctx : closure_ctx;
  bs_debt : Debt_report.t;
  bs_prog : Seed_mir.program option;
  bs_mir_verify_ok : bool;
  bs_mono : mono_outcome option;
  bs_host_report : Host.closure_report option;
  bs_vm_code : int option;
  bs_artifact : string option;
  bs_oracle_incomplete : bool;
}

let run_bootstrap_closure ~(repo_root : string) ~(manifest_path : string)
    ~(target : Target.t) ~(entry : string option) ~(kernel_args : string list) :
    (bootstrap_stages, string) result =
  match run_closure_pipeline_impl ~repo_root ~manifest_path ~target ~strict:true with
  | Error m -> Error m
  | Ok ctx ->
      let measured_debt =
        Debt_report.sum_reports
          (List.map snd ctx.ctx_env.Typecheck.state.debt_by_module)
      in
      if ctx.ctx_type_errors <> [] then
        Ok
          {
            bs_ctx = ctx;
            bs_debt = measured_debt;
            bs_prog = None;
            bs_mir_verify_ok = false;
            bs_mono = None;
            bs_host_report = None;
            bs_vm_code = None;
            bs_artifact = None;
            bs_oracle_incomplete = true;
          }
      else begin
        let prog = lower_closure ctx in
        let tpl_ok =
          match
            Mir_verify.require_valid_template
              ~generic_types:(closure_generic_types ctx.ctx_env)
              prog
          with
          | Ok () -> true
          | Error _ -> false
        in
        let stats = count_mir_stats prog in
        let oracle_incomplete = print_oracle_rows (oracle_of_ctx ctx (Some stats)) in
        match resolve_bootstrap_entry prog entry with
        | None ->
            Ok
              {
                bs_ctx = ctx;
                bs_debt = measured_debt;
                bs_prog = Some prog;
                bs_mir_verify_ok = tpl_ok;
                bs_mono = None;
                bs_host_report = None;
                bs_vm_code = None;
                bs_artifact = None;
                bs_oracle_incomplete = oracle_incomplete;
              }
        | Some (entry_name, entry_id) -> (
            match
              run_mono_phase ~entry_name ~entry:entry_id
                ~generic_types:(closure_generic_types ctx.ctx_env)
                prog
            with
            | Error _ ->
                Ok
                  {
                    bs_ctx = ctx;
                    bs_debt = measured_debt;
                    bs_prog = Some prog;
                    bs_mir_verify_ok = tpl_ok;
                    bs_mono = None;
                    bs_host_report = None;
                    bs_vm_code = None;
                    bs_artifact = None;
                    bs_oracle_incomplete = oracle_incomplete;
                  }
            | Ok mo ->
                if mo.mo_residual_type_params > 0 || oracle_incomplete then
                  Ok
                    {
                      bs_ctx = ctx;
                      bs_debt = measured_debt;
                      bs_prog = Some prog;
                      bs_mir_verify_ok = tpl_ok;
                      bs_mono = Some mo;
                      bs_host_report = None;
                      bs_vm_code = None;
                      bs_artifact = None;
                      bs_oracle_incomplete = oracle_incomplete;
                    }
                else begin
                  let argv = Array.of_list ("tg-bootstrap" :: kernel_args) in
                  let host = Host.create ~repo_root ~argv in
                  let reachable = collect_reachable_host_ids mo.mo_program in
                  match Host.closure_check_reachable host reachable with
                  | Error _ ->
                      Ok
                        {
                          bs_ctx = ctx;
                          bs_debt = measured_debt;
                          bs_prog = Some prog;
                          bs_mir_verify_ok = tpl_ok;
                          bs_mono = Some mo;
                          bs_host_report = None;
                          bs_vm_code = None;
                          bs_artifact = None;
                          bs_oracle_incomplete = oracle_incomplete;
                        }
                  | Ok report -> (
                      match Vm.run ~program:mo.mo_program ~entry:mo.mo_entry ~argv ~host with
                      | Error _ ->
                          Ok
                            {
                              bs_ctx = ctx;
                              bs_debt = measured_debt;
                              bs_prog = Some prog;
                              bs_mir_verify_ok = tpl_ok;
                              bs_mono = Some mo;
                              bs_host_report = Some report;
                              bs_vm_code = None;
                              bs_artifact = None;
                              bs_oracle_incomplete = oracle_incomplete;
                            }
                      | Ok code ->
                          let artifact =
                            match code with
                            | 0 -> (
                                match kernel_output_path kernel_args with
                                | Some p when artifact_exists ~repo_root p -> Some p
                                | _ -> None)
                            | _ -> None
                          in
                          Ok
                            {
                              bs_ctx = ctx;
                              bs_debt = measured_debt;
                              bs_prog = Some prog;
                              bs_mir_verify_ok = tpl_ok;
                              bs_mono = Some mo;
                              bs_host_report = Some report;
                              bs_vm_code = Some code;
                              bs_artifact = artifact;
                              bs_oracle_incomplete = oracle_incomplete;
                            })
        end)
    end

let cmd_bootstrap_check (args : string list) : int =
  let opts, positional = parse_options boot_specs default_boot_opts args in
  if positional <> [] then die "unexpected positional arguments to bootstrap-check";
  let target =
    match Target.unsupported_triple opts.target with
    | Ok t -> t
    | Error m -> die "%s" m
  in
  Printf.printf "TANGERINE OCAML SEED — bootstrap-check\n";
  Printf.printf "  target: %s\n" (Target.to_string target);
  Printf.printf "  resolver mode: %s\n" (if opts.strict then "strict (per-module authority)" else "recovery + strict audit");
  (match run_closure_pipeline_impl ~repo_root:opts.repo_root ~manifest_path:opts.manifest
           ~target ~strict:opts.strict with
   | Error m ->
       prerr_endline ("error: " ^ m);
       Printf.printf "  RESULT: FAIL\n";
       1
   | Ok ctx ->
       (match opts.diagnostics_jsonl with
        | Some p ->
            write_diagnostics_jsonl ~path:p
              ctx.ctx_env.Typecheck.state.structured_diags
        | None -> ());
       print_subset_evidence ctx.ctx_subset;
       print_strict_evidence ctx.ctx_strict_diags ctx.ctx_strict_fallbacks;
       Printf.printf "  typecheck: %d modules, %d items, %d errors (%d rounds)\n"
         ctx.ctx_graph.Module_graph.node_count ctx.ctx_items (List.length ctx.ctx_type_errors)
         ctx.ctx_decl_rounds;
       report_access_resource_pass ctx;
       List.iter (fun e -> Printf.printf "    %s\n" e) (List.sort compare ctx.ctx_type_errors);
       if ctx.ctx_type_errors <> [] then begin
         (* honest: lowering/mono are unreachable — print the oracle rows
            with zeros and the skipped note, then fail the gate *)
         ignore (print_oracle_rows (oracle_of_ctx ctx None));
         Printf.printf "  mono: skipped (typecheck gate failed)\n";
         Printf.printf "  FRONTEND_SEMANTIC_GATE = FAIL\n";
         Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
         Printf.printf "EVIDENCE_MIR template_verify=skipped concrete_verify=skipped\n";
         Printf.printf "EVIDENCE_HOST reachable_closure=skipped\n";
         Printf.printf "  RESULT: FAIL\n";
         1
       end
       else begin
         let prog = lower_closure ctx in
         (match
            Mir_verify.require_valid_template
              ~generic_types:(closure_generic_types ctx.ctx_env)
              prog
          with
          | Error errs ->
              Printf.printf "  SEED_MIR_STRUCTURAL_GATE = FAIL\n";
              List.iter (fun e -> Printf.printf "    %s\n" e) errs;
              Printf.printf "EVIDENCE_MIR template_verify=fail concrete_verify=skipped\n";
              Printf.printf "EVIDENCE_HOST reachable_closure=skipped\n";
              Printf.printf "  RESULT = WIP\n";
              1
          | Ok () ->
              Printf.printf "  SEED_MIR_STRUCTURAL_GATE = PASS (%d functions)\n"
                (Array.length prog.Seed_mir.functions);
              let stats = count_mir_stats prog in
              let incomplete = print_oracle_rows (oracle_of_ctx ctx (Some stats)) in
              Printf.printf "  FRONTEND_SEMANTIC_GATE = PASS\n";
              (match resolve_bootstrap_entry prog opts.entry with
               | None ->
                   Printf.printf "  mono: skipped (no entry function in the closure)\n";
                   Printf.printf "EVIDENCE_MIR template_verify=pass concrete_verify=skipped\n";
                   Printf.printf "EVIDENCE_HOST reachable_closure=skipped\n";
                   Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
                   Printf.printf "  RESULT = WIP\n";
                   1
               | Some (entry_name, entry) -> (
                   match
                     run_mono_phase ~entry_name ~entry
                       ~generic_types:(closure_generic_types ctx.ctx_env)
                       prog
                   with
                   | Error _ ->
                       Printf.printf "EVIDENCE_MIR template_verify=pass concrete_verify=skipped\n";
                       Printf.printf "EVIDENCE_HOST reachable_closure=skipped\n";
                       Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
                       Printf.printf "  RESULT = WIP\n";
                       1
                   | Ok mo ->
                       (* audit P0 fix: the post-mono concrete verification
                          is a recorded fact (same check tg_evidence runs);
                          it does not change the gate's verdicts *)
                       let concrete_ok =
                         match Mir_verify.require_valid mo.mo_program with
                         | Ok () -> true
                         | Error _ -> false
                       in
                       Printf.printf "EVIDENCE_MIR template_verify=pass concrete_verify=%s\n"
                         (if concrete_ok then "pass" else "fail");
                       if mo.mo_residual_type_params > 0 || incomplete then begin
                         Printf.printf "EVIDENCE_HOST reachable_closure=skipped\n";
                         Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
                         Printf.printf "  RESULT = WIP\n";
                         1
                       end
                       else begin
                         (* ── post-mono host section (stage 10) ─────────
                            The STATIC reachable-host closure proof FIRST,
                            then the dynamic VM evidence: every host id the
                            mono'd program can dispatch to must carry an
                            executable binding with the exact typed
                            signature before any host call executes (the
                            re-audit's strongest-solution order).  The VM
                            compiler invocation is dynamic evidence ON TOP
                            of the static proof. *)
                         let kernel_args =
                           [ "compile"; "tests/differential/corpus/01_defs_arith.tg"; "-o";
                             "bootstrap_check.out" ]
                         in
                         let argv = Array.of_list ("tg-bootstrap" :: kernel_args) in
                         let host = Host.create ~repo_root:opts.repo_root ~argv in
                         let reachable = collect_reachable_host_ids mo.mo_program in
                         let reachable_names =
                           List.map
                             (fun id ->
                               match Host.name_of_host_id host id with
                               | Some n -> n
                               | None -> "?")
                             reachable
                         in
                         (match Host.closure_check_reachable host reachable with
                          | Error problems ->
                              Printf.printf
                                "  REACHABLE_HOST_CLOSURE = FAIL (%d reachable host id(s): %s)\n"
                                (List.length reachable) (String.concat ", " reachable_names);
                              List.iter (fun p -> Printf.printf "    %s\n" p) problems;
                              Printf.printf "EVIDENCE_HOST reachable_closure=fail reachable=%d declared=0 implemented=0\n"
                                (List.length reachable);
                              Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = INCOMPLETE\n";
                              Printf.printf "  RESULT: FAIL\n";
                              1
                          | Ok report ->
                              Printf.printf
                                "  REACHABLE_HOST_CLOSURE = PASS (%d reachable host id(s) [%s], %d with executable bindings, all exact typed signatures)\n"
                                report.Host.declared (String.concat ", " reachable_names)
                                report.Host.implemented;
                              Printf.printf "EVIDENCE_HOST reachable_closure=pass reachable=%d declared=%d implemented=%d\n"
                                (List.length reachable) report.Host.declared report.Host.implemented;
                              Printf.printf "  BOOTSTRAP_EXECUTABLE_CLOSURE = PASS\n";
                              (match
                                 Vm.run ~program:mo.mo_program ~entry:mo.mo_entry ~argv ~host
                               with
                               | Error e ->
                                   let out = Host.stdout_contents host in
                                   if out <> "" then
                                     Printf.printf "  kernel stdout:\n%s\n" out;
                                   let err = Host.stderr_contents host in
                                   if err <> "" then
                                     Printf.printf "  kernel stderr:\n%s\n" err;
                                   Printf.printf "  VM bootstrap run TRAPPED: %s\n"
                                     e.Vm.message;
                                   Printf.printf "  RESULT: FAIL\n";
                                   1
                               | Ok code ->
                                   let out = Host.stdout_contents host in
                                   if out <> "" then
                                     Printf.printf "  kernel stdout:\n%s\n" out;
                                   Printf.printf "  VM bootstrap run: exit %d\n" code;
                                   if code <> 0 then begin
                                     Printf.printf
                                       "  VM bootstrap run: FAILED (nonzero exit from the kernel)\n";
                                     Printf.printf "  RESULT: FAIL\n";
                                     1
                                   end
                                   else
                                     (match kernel_output_path kernel_args with
                                     | None ->
                                         Printf.printf
                                           "  artifact: FAILED (no output path derivable from the kernel argv)\n";
                                         Printf.printf "  RESULT: FAIL\n";
                                         1
                                     | Some out_path ->
                                         if
                                           not
                                             (artifact_exists ~repo_root:opts.repo_root
                                                out_path)
                                         then begin
                                           Printf.printf
                                             "  artifact: FAILED (VM exited 0 but produced no artifact at %s)\n"
                                             out_path;
                                           Printf.printf "  RESULT: FAIL\n";
                                           1
                                         end
                                         else begin
                                           Printf.printf "  artifact produced: %s\n" out_path;
                                           Printf.printf "  RESULT = PASS\n";
                                           0
                                         end)))
                       end)))
      end)

(* ── compile (audit §49) ───────────────────────────────────────── *)

let cmd_compile (args : string list) : int =
  let opts, positional = parse_options boot_specs default_boot_opts args in
  let target =
    match Target.unsupported_triple opts.target with
    | Ok t -> t
    | Error m -> die "%s" m
  in
  Printf.printf "TANGERINE OCAML SEED — compile\n";
  Printf.printf "  target: %s\n" (Target.to_string target);
  Printf.printf "  resolver mode: %s\n" (if opts.strict then "strict (per-module authority)" else "recovery + strict audit");
  (match run_closure_pipeline_impl ~repo_root:opts.repo_root ~manifest_path:opts.manifest
           ~target ~strict:opts.strict with
   | Error m ->
       prerr_endline ("error: " ^ m);
       Printf.printf "  RESULT: FAIL\n";
       1
   | Ok ctx ->
       Printf.printf "  typecheck: %d modules, %d items, %d errors (%d rounds)\n"
         ctx.ctx_graph.Module_graph.node_count ctx.ctx_items (List.length ctx.ctx_type_errors)
         ctx.ctx_decl_rounds;
       if ctx.ctx_type_errors <> [] then begin
         Printf.printf "compile: FAILED — closure typecheck gate: %d errors; the VM bootstrap run is NOT attempted\n"
           (List.length ctx.ctx_type_errors);
         List.iter (fun e -> Printf.printf "    %s\n" e)
           (List.sort compare (take_first 20 ctx.ctx_type_errors));
         Printf.printf "  RESULT: FAIL\n";
         1
       end
       else begin
         let prog = lower_closure ctx in
         (match
            Mir_verify.require_valid_template
              ~generic_types:(closure_generic_types ctx.ctx_env)
              prog
          with
          | Error errs ->
              Printf.printf "compile: FAILED — SEED_MIR_STRUCTURAL_GATE: %s\n" (String.concat "; " errs);
              Printf.printf "  RESULT: FAIL\n";
              1
          | Ok () -> (
              match resolve_bootstrap_entry prog opts.entry with
              | None ->
                  Printf.printf "compile: FAILED — no entry function in the closure\n";
                  Printf.printf "  RESULT: FAIL\n";
                  1
              | Some (entry_name, entry) -> (
                  match
                    run_mono_phase ~entry_name ~entry
                      ~generic_types:(closure_generic_types ctx.ctx_env)
                      prog
                  with
                  | Error _ ->
                      Printf.printf "compile: FAILED — mono phase\n";
                      Printf.printf "  RESULT: FAIL\n";
                      1
                  | Ok mo ->
                      if mo.mo_residual_type_params > 0 then begin
                        Printf.printf "compile: FAILED — %d residual Type_param after mono\n"
                          mo.mo_residual_type_params;
                        Printf.printf "  RESULT: FAIL\n";
                        1
                      end
                      else begin
                        (* Real tg compiler argv for the kernel's
                           bootstrap_main: argv[0] is the program name,
                           argv[1] the command.  Positional args past the
                           driver options are passed through verbatim. *)
                        let kernel_args =
                          match positional with
                          | [] -> [ "compile"; "--help" ]
                          | first :: _
                            when List.mem first [ "compile"; "check"; "-h"; "--help"; "-V"; "--version" ] ->
                              positional
                          | _ -> "compile" :: positional
                        in
                        let argv = Array.of_list ("tg-bootstrap" :: kernel_args) in
                        Printf.printf "  compile: kernel argv: %s\n" (String.concat " " (Array.to_list argv));
                        let host = Host.create ~repo_root:opts.repo_root ~argv in
                        (match Vm.run ~program:mo.mo_program ~entry:mo.mo_entry ~argv ~host with
                         | Error e ->
                             Printf.printf "compile: VM bootstrap run TRAPPED: %s\n" e.Vm.message;
                             let out = Host.stdout_contents host in
                             if out <> "" then Printf.printf "compile: kernel stdout:\n%s\n" out;
                             let err = Host.stderr_contents host in
                             if err <> "" then Printf.printf "compile: kernel stderr:\n%s\n" err;
                             Printf.printf "  RESULT: FAIL\n";
                             1
                         | Ok code ->
                             let out = Host.stdout_contents host in
                             if out <> "" then Printf.printf "compile: kernel stdout:\n%s\n" out;
                             Printf.printf "compile: VM bootstrap run exit %d\n" code;
                             (match kernel_output_path kernel_args with
                              | None ->
                                  Printf.printf "compile: FAILED — no output path derivable from the kernel argv\n";
                                  Printf.printf "  RESULT: FAIL\n";
                                  1
                              | Some out_path ->
                                  if code <> 0 then begin
                                    Printf.printf "compile: FAILED — nonzero exit from the kernel\n";
                                    Printf.printf "  RESULT: FAIL\n";
                                    1
                                  end
                                  else if artifact_exists ~repo_root:opts.repo_root out_path then begin
                                    Printf.printf "compile: artifact produced: %s\n" out_path;
                                    Printf.printf "  RESULT: PASS\n";
                                    0
                                  end
                                  else begin
                                    Printf.printf "compile: FAILED — VM exited 0 but produced no artifact at %s\n"
                                      out_path;
                                     Printf.printf "  RESULT: FAIL\n";
                                     1
                                   end))
                       end)))
      end)

let cmd_version () : int =
  print_string (version_string ^ "\n");
  0

let main () : int =
  let args = Array.to_list Sys.argv in
  match args with
  | _ :: cmd :: rest -> (
      match cmd with
      | "lex" -> cmd_lex rest
      | "parse" -> cmd_parse rest
      | "check" -> cmd_check rest
      | "dump-ast" -> cmd_dump_ast rest
      | "lower" -> cmd_lower rest
      | "interpret" -> cmd_interpret rest
      | "bootstrap-check" -> cmd_bootstrap_check rest
      | "compile" -> cmd_compile rest
      | "version" -> cmd_version ()
      | "help" ->
          print_string usage;
          0
      | other -> die "unknown command '%s'" other)
  | _ ->
      print_string usage;
      0
