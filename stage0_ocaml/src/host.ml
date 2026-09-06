(* host.ml — the host aggregate (audit §42, §70).

   The host is everything the stage0 VM talks to: the intrinsic and extern
   registries (declared-host symbols), the virtual filesystem, process
   spawning, the program argument vector, the normalized environment, and
   the output buffers the VM's printf/intrinsic path writes to
   (emit_stdout/emit_stderr — audit §45).

   THE EXECUTABLE CLOSURE (audit §70): a host symbol is *implemented* only
   when the binding table (bindings / binding_manifest) carries an entry
   with an executable `invoke`. A symbol that the registries declare but
   that has no binding is NOT implemented: closure_check fails and names
   it, and the VM's host dispatch traps — fail-closed. There is no
   metadata-only "implementation". *)

(* Host symbol ids: the VM dispatches registry ids (Seed_mir.Intrinsic n
   / Seed_mir.Extern n, converted at the dispatch boundary); the binding
   table is keyed by the same ids, namespaced by kind so the two
   registries cannot collide. The ids are the registries' ABSTRACT id
   types — not raw ints — so an intrinsic id can never be used where an
   extern id belongs, and vice versa. *)
type host_id =
  | Intrinsic of Intrinsic_registry.Id.t
  | Extern of Extern_registry.Id.t

(* One binding table for the whole host surface. A symbol WITHOUT an
   `invoke` is not implemented — the record type requires the function, so
   "bound" and "has an executable invoke" are the same predicate. *)
(* A binding's signature is TYPED (access convention + type per
   parameter, plus the return) and is carried TWICE (audit P0-3): the
   binding record carries THREE signature/execution fields —

     `declared` (the audit's `declared_signature` role): the
     REGISTRY-owned declaration — the language ABI the VM dispatches
     against (its arity is the dispatch arity authority, vm.ml
     call_host) and the declaration the source-derived closure was
     verified against;
     `adapter` (the audit's `adapter_signature` role): the EXECUTABLE
     ADAPTER's OWN independent declaration — the adapter describes its
     ABI itself (the generic schemas below, written once at the
     adapter);
     `invoke`: the executable semantics.

   Host construction compares the two declarations with the SHARED
   signature-identity matcher (alpha-equivalent under one binder
   bijection, exact TypeId equality after canonicalization, conventions
   compared exactly — P0-1/P0-2/P0-4), so a drift between the adapter
   and the registry is a real, caught error, never a self-comparison. *)
type signature = Signature_identity.signature

(* re-audit P0-B: the host-call RESULT separates the language-visible
   value from the mutation writebacks — an inout intrinsic mutates
   through the writeback channel (arg index -> new value) and returns
   the EXACT Tangerine contract (Set::insert -> Bool, Map::insert ->
   Option[old V]) in the value slot.  The old collection-return-as-
   mutation-transport convention is gone. *)
type host_result = {
  value : Vm_value.t;
  writebacks : (int * Vm_value.t) list;
}

let plain_result (v : Vm_value.t) : host_result = { value = v; writebacks = [] }

type binding = {
  id : host_id;
  name : string;
  (* the registry-owned declaration — the P0-3 `declared_signature`
     role (the VM's arity authority, vm.ml call_host) *)
  declared : signature;
  (* the adapter's own independent declaration — the P0-3
     `adapter_signature` role (written at the adapter, never copied
     from the registry) *)
  adapter : signature;
  invoke : t -> Vm_value.t array -> (host_result, string) result;
}

(* The process surface (audit §44): real spawning through
   Host_process, wired into the host aggregate so source-derived process
   symbols have a single place to call. A cwd supplied by Tangerine is a
   VIRTUAL path: it goes through the Host_fs resolver first, and only a
   path that resolves inside the canonical root is handed to the child. *)
and process_api = {
  spawn :
    executable:string -> argv:string array -> env:string array -> cwd:string option
    -> (Host_process.status, string) result;
  spawn_nocapture :
    executable:string -> argv:string array -> env:string array -> (int, string) result;
}

and t = {
  intrinsics : Intrinsic_registry.t;
  externs : Extern_registry.t;
  bindings : binding list;
  fs : Host_fs.t;
  process : process_api;
  argv : string array;
  mutable env : (string * string) list;
  mutable stdout : Buffer.t;
  mutable stderr : Buffer.t;
}

(* Output helpers (the VM's printf/intrinsic path — audit §45). *)
let emit_stdout (t : t) (s : string) : unit = Buffer.add_string t.stdout s
let emit_stderr (t : t) (s : string) : unit = Buffer.add_string t.stderr s
let stdout_contents (t : t) : string = Buffer.contents t.stdout
let stderr_contents (t : t) : string = Buffer.contents t.stderr

(* ── The single binding table (audit §70) ────────────────────────────

   Every entry below carries a REAL executable implementation. Symbols the
   closure declares but that are NOT in this table — the map/set record
   traversal intrinsics, the Ruby C API externs, the dl* loader family,
   the __sync arithmetic primitives — are deliberately unbound: their real
   semantics are not implementable on this seed host, so no stub is
   shipped. closure_check fails on them and the VM traps. *)

(* ── Independent typed binding adapters (host P1, audit P0-3) ──────

   Each executable binding is declared through a typed ADAPTER that
   independently encodes the symbol's signature — written ONCE at the
   adapter (in the registries' OWN generic schema language: Set[P0],
   inout Map[P0, P1], Option[P0] — never a fake concrete shape, and
   never copied from the registry declaration).  The OCaml function
   type the adapter accepts fixes the argument/result conversion.
   `intrinsic_binding`/`extern_binding` then pair the adapter with the
   registry-declared id, and host construction validates the two
   declarations with the SHARED signature-identity matcher
   (alpha_equivalent(canonicalize declared, canonicalize adapter));
   the closure checks re-run the same comparison against the host's
   OWN registries.  A drift between the adapter and the registry is a
   real, caught error, not a self-comparison. *)

(* the adapter's OWN placeholder-binder domain (audit P0-3).  The
   adapters write their generic schemas with their OWN generic
   parameters — P0 for the single-element families (Set/Array/Vec),
   P0/P1 for the map key/value family — never with the registries'
   T/K/V binder ids (Intrinsic_registry.Type_param).  The binder ids
   are chosen OUTSIDE the registry domain (the registries use 0..1), so
   agreement between the adapter's independent declaration and the
   registry's declaration can never be an artifact of shared binder
   identity: it is established only by the shared matcher's binder
   BIJECTION over the whole signature (a first-occurrence pair binds
   both directions; a later occurrence must agree with both maps). *)
let p0 = Intrinsic_registry.param (Ids.Generic_param_id.make 10)
let p1 = Intrinsic_registry.param (Ids.Generic_param_id.make 11)

(* the registry placeholder-domain building blocks the adapters write
   their independent declarations with (the shared schema constructors:
   the named collection forms and the scalar types) *)
let set_of = Intrinsic_registry.set_of
let map_of = Intrinsic_registry.map_of
let vec_of = Intrinsic_registry.vec_of
let option_of = Intrinsic_registry.option_of
let tuple_of = Intrinsic_registry.tuple_of
let ty_int = Intrinsic_registry.ty_int
let ty_bool = Intrinsic_registry.ty_bool
let ty_string = Intrinsic_registry.ty_string

type adapter = {
  signature : signature;
  invoke : t -> Vm_value.t array -> (host_result, string) result;
}

(* ── Host lookup equality (audit P0-11) ─────────────────────────────

   The collection containment ops (set contains/insert/remove, map
   contains-key/get/insert, array contains) compare element/key values
   to decide presence.  Structural equality must NEVER report an
   arbitrary resource-containing aggregate as Eq: the seed's one OWNED
   value shape is a region-backed reference (Ref (Region p) — the value
   the drop glue frees, and a resource can only ever have ONE owner), so
   a purely structural comparison over aggregates that carry such refs
   would equate distinct owners (or alias copies) and let containment
   invent a false positive.  The lookup equality therefore REFUSES —
   returns false — as soon as either side contains a region-backed ref
   anywhere in its tree (fail-closed: no ownership decision is ever made
   through Eq on a resource carrier).  Non-resource values (scalars,
   strings, plain records/enums/arrays/sets/maps of them) compare with
   the plain structural equality. *)
let rec has_owned_ref (v : Vm_value.t) : bool =
  match v with
  | Vm_value.Tuple elems | Vm_value.Struct elems | Vm_value.Array elems
  | Vm_value.Enum (_, elems) ->
      Array.exists has_owned_ref elems
  | Vm_value.Set elems -> List.exists has_owned_ref elems
  | Vm_value.Map pairs -> List.exists (fun (k, v) -> has_owned_ref k || has_owned_ref v) pairs
  | Vm_value.Closure (_, caps) -> Array.exists has_owned_ref caps
  | Vm_value.Ref (Vm_value.Region _) -> true
  | Vm_value.Unit | Vm_value.Bool _ | Vm_value.Int _ | Vm_value.Float32 _
  | Vm_value.Float64 _ | Vm_value.Char _ | Vm_value.String _
  | Vm_value.Function _ | Vm_value.RawPtr _ | Vm_value.Ref (Vm_value.Place _)
  | Vm_value.Null | Vm_value.MovedOut ->
      false

(* the collection-lookup equality (see above). *)
let lookup_eq (a : Vm_value.t) (b : Vm_value.t) : bool =
  not (has_owned_ref a) && not (has_owned_ref b) && Vm_value.equal a b

let arg_mismatch expected : (Vm_value.t, string) result =
  Error ("argument mismatch: expected " ^ expected)

(* the (convention, type) parameter list -> typed signature *)
let mk_sig (params : (Access_effect.t * Type_repr.t) list) (ret : Type_repr.t) : signature =
  {
    Signature_identity.sig_params =
      Array.of_list
        (List.map
           (fun (c, ty) -> { Type_repr.pt_convention = c; pt_type = ty })
           params);
    sig_ret = ret;
  }

(* the by-value (let) parameter list shorthand *)
let lets (tys : Type_repr.t list) : (Access_effect.t * Type_repr.t) list =
  List.map (fun ty -> (Access_effect.Let, ty)) tys

(* the raw adapter: the argument/result conversions are the caller's
   responsibility (used for the runtime Set/Map/Array intrinsics whose
   values are Vm_value.t arrays) — the typed signature is written once
   here (conventions AND generic types) and checked against the
   registry declaration by the closure checks *)
let adapter_raw (params : (Access_effect.t * Type_repr.t) list) (ret : Type_repr.t)
    (invoke : t -> Vm_value.t array -> (Vm_value.t, string) result) : adapter =
  {
    signature = mk_sig params ret;
    invoke =
      (fun t args ->
        match invoke t args with
        | Ok v -> Ok (plain_result v)
        | Error m -> Error m);
  }

(* the writeback-capable raw adapter: the invoke returns the language
   value AND the (arg index -> new value) mutation writebacks *)
let adapter_raw_wb (params : (Access_effect.t * Type_repr.t) list) (ret : Type_repr.t)
    (invoke : t -> Vm_value.t array -> (host_result, string) result) : adapter =
  { signature = mk_sig params ret; invoke }

let adapter_ret_unit (f : t -> unit) : adapter =
  {
    signature = mk_sig [] Type_repr.Unit;
    invoke =
      (fun t args ->
        match args with
        | [||] ->
            f t;
            Ok (plain_result Vm_value.Unit)
        | _ -> Error "argument mismatch: expected no arguments");
  }

(* () -> Never: f produces the deterministic host error message. *)
let adapter_ret_never (f : t -> string) : adapter =
  {
    signature = mk_sig [] Type_repr.Never;
    invoke =
      (fun t args ->
        match args with
        | [||] -> Error (f t)
        | _ -> Error "argument mismatch: expected no arguments");
  }

(* String -> Unit *)
let adapter_string_ret_unit (f : t -> string -> unit) : adapter =
  {
    signature = mk_sig (lets [ Type_repr.String ]) Type_repr.Unit;
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.String s |] ->
            f t s;
            Ok (plain_result Vm_value.Unit)
        | _ -> Error "argument mismatch: expected String");
  }

(* String -> Never: f produces the deterministic host error message. *)
let adapter_string_ret_never (f : t -> string -> string) : adapter =
  {
    signature = mk_sig (lets [ Type_repr.String ]) Type_repr.Never;
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.String s |] -> Error (f t s)
        | _ -> Error "argument mismatch: expected String");
  }

(* Int -> String *)
let adapter_int_ret_string (f : t -> Int_value.t -> string) : adapter =
  {
    signature = mk_sig (lets [ ty_int ]) Type_repr.String;
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.Int i |] -> Ok (plain_result (Vm_value.String (f t i)))
        | _ -> Error "argument mismatch: expected Int");
  }

(* Bool -> String *)
let adapter_bool_ret_string (f : t -> bool -> string) : adapter =
  {
    signature = mk_sig (lets [ Type_repr.Bool ]) Type_repr.String;
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.Bool b |] -> Ok (plain_result (Vm_value.String (f t b)))
        | _ -> Error "argument mismatch: expected Bool");
  }

(* Char -> String *)
let adapter_char_ret_string (f : t -> Uchar.t -> string) : adapter =
  {
    signature = mk_sig (lets [ Type_repr.Char ]) Type_repr.String;
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.Char c |] -> Ok (plain_result (Vm_value.String (f t c)))
        | _ -> Error "argument mismatch: expected Char");
  }

(* String -> Int *)
let adapter_string_ret_int (f : t -> string -> Int_value.t) : adapter =
  {
    signature = mk_sig (lets [ Type_repr.String ]) ty_int;
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.String s |] -> Ok (plain_result (Vm_value.Int (f t s)))
        | _ -> Error "argument mismatch: expected String");
  }

(* the canonicalization every registry-domain declaration goes through
   before identity comparison (alias fold + the single LangItem
   adoption table) *)
let canonicalize_registry (ty : Type_repr.t) : Type_repr.t =
  Signature_identity.canonicalize_registry_placeholder ty

(* a (convention type) parameter rendered for diagnostics *)
let param_contract (p : Type_repr.param_type) : string =
  Access_effect.to_string p.Type_repr.pt_convention
  ^ " "
  ^ Intrinsic_registry.ty_to_string p.Type_repr.pt_type

(* Binding ids are resolved from the declared registries by name, so the
   executable closure and the declarations can never drift apart in
   identity.  Audit P0-3: a binding carries BOTH the registry-owned
   `declared` signature (the VM's dispatch arity authority) AND the
   adapter's independently written `adapter` signature; host
   construction validates alpha_equivalent(canonicalize declared,
   canonicalize adapter) with the correct binder/nominal rules, so the
   adapter is a genuine independent specification, not a
   self-comparison. *)
let intrinsic_binding (name : string) (a : adapter) : binding =
  match Intrinsic_registry.lookup Intrinsic_registry.manifest ~name with
  | Some (id, sig_) ->
      let declared = Signature_identity.of_registry sig_ in
      if
        not
          (Signature_identity.signatures_match
             ~canon_left:canonicalize_registry ~canon_right:canonicalize_registry
             declared a.signature)
      then
        failwith
          (Printf.sprintf
             "host binding '%s': the adapter's independent signature %s does not match \
              the registry declaration %s (identity rules: exact TypeIds after \
              canonicalization, conventions exact, binders alpha-equivalent under one \
              bijection)"
             name (Signature_identity.to_string a.signature)
             (Signature_identity.to_string declared));
      { id = Intrinsic id; name; declared; adapter = a.signature; invoke = a.invoke }
  | None -> failwith (Printf.sprintf "host binding '%s': not a declared intrinsic" name)

let extern_binding (name : string) (a : adapter) : binding =
  match Extern_registry.lookup Extern_registry.manifest ~name with
  | Some (id, sig_) ->
      let declared = Signature_identity.of_registry sig_ in
      if
        not
          (Signature_identity.signatures_match
             ~canon_left:canonicalize_registry ~canon_right:canonicalize_registry
             declared a.signature)
      then
        failwith
          (Printf.sprintf
             "host binding '%s': the adapter's independent signature %s does not match \
              the registry declaration %s (identity rules: exact TypeIds after \
              canonicalization, conventions exact, binders alpha-equivalent under one \
              bijection)"
             name (Signature_identity.to_string a.signature)
             (Signature_identity.to_string declared));
      { id = Extern id; name; declared; adapter = a.signature; invoke = a.invoke }
  | None -> failwith (Printf.sprintf "host binding '%s': not a declared extern" name)

(* ────────────────────────────────────────────────────────────────────
   The collection surface's OWNERSHIP semantics (audit P0-11).
   Vm_value values are immutable trees, and the seed's only OWNED value
   shape is a region-backed reference (Ref (Region p) — the one shape
   the VM's drop glue frees; a live duplicate of an owned value would
   double-free).  The adapters below implement the Tangerine ownership
   contracts on that value model with these rules:

     • a sink parameter's value ARRIVES MOVED (the VM's Consume/Move
       operand left the caller's slot Moved — the caller no longer
       owns it), so the adapter TAKES the exact value object: the
       caller's moved value BECOMES the stored element/key — it is
       placed into the writeback collection and never copied, and
       never appears anywhere else in a live value;
     • the element-returning ops (pop, remove, drain_one) EXTRACT:
       the element appears in the returned Option/value and NOT in the
       writeback collection — ownership transfers exactly once;
     • set(Array)/remove(Array)/insert(Array)/set-insert-REPLACE
       RELINQUISH the displaced old element exactly once: after the
       call the old element is in no live value (neither the writeback
       nor the return) — the writeback is a fresh collection sharing
       only the retained elements, and the caller's moved-in value is
       the one stored;
     • a FAILED bounds check consumes NOTHING: the check runs before
       any mutation, the adapter returns an error, and no writeback is
       produced (the VM traps on the error);
     • the WRITEBACK channel never duplicates an aggregate: each
       element/key object of the old collection either stays (shared
       into the new collection — single live owner, the old collection
       value is dead the moment its slot was moved) or leaves with the
       returned value — never both;
     • containment decisions use lookup_eq (above), which never
       reports a resource-containing aggregate Eq.

   The map insert key path preserves the STORED key on replacement
   (the map keeps its key identity — the incoming sink key is consumed
   by the call and never stored when the key existed; the VALUE is
   always replaced and the old one returned as the language's
   Option[old V]).  The set insert REPLACES the stored element with
   the incoming item (the caller's moved value becomes the stored
   element) and returns the std presence Bool (true = the key already
   existed). *)

let binding_manifest : binding list =
  [
    intrinsic_binding "__intrinsic_set_new"
      (adapter_raw [] (set_of p0) (fun _ args ->
           match args with
           | [||] -> Ok (Vm_value.Set [])
           | _ -> arg_mismatch "no arguments"));
    intrinsic_binding "__intrinsic_map_new"
      (adapter_raw [] (map_of p0 p1) (fun _ args ->
           match args with
           | [||] -> Ok (Vm_value.Map [])
           | _ -> arg_mismatch "no arguments"));
    intrinsic_binding "__intrinsic_set_contains"
      (adapter_raw (lets [ set_of p0; p0 ]) ty_bool (fun _ args ->
           (* pure read: the containment decision uses lookup_eq — a
              resource-containing aggregate is never reported Eq *)
           match args with
           | [| Vm_value.Set elems; item |] ->
               Ok (Vm_value.Bool (List.exists (fun e -> lookup_eq e item) elems))
           | _ -> arg_mismatch "(Set, item)"));
    intrinsic_binding "__intrinsic_set_remove"
      (adapter_raw_wb
         [ (Access_effect.Inout, set_of p0); (Access_effect.Let, p0) ]
         ty_bool (fun _ args ->
           (* the exact Tangerine contract: the language value is Bool
              (whether the element was present and removed) and the
              mutation travels through the explicit writeback channel.
              The item is a read-only key (Let — never consumed); the
              REMOVED element is relinquished exactly once: it appears
              in no live value after the call (not in the writeback,
              not in the return).  An element is only ever removed when
              lookup_eq matched it — no removal decision is made
              through equality on resource carriers. *)
           match args with
           | [| Vm_value.Set elems; item |] ->
               let rec remove acc = function
                 | [] -> (false, List.rev acc)
                 | x :: rest when lookup_eq x item ->
                     (true, List.rev_append acc rest)
                 | x :: rest -> remove (x :: acc) rest
               in
               let removed, new_elems = remove [] elems in
               Ok
                 { value = Vm_value.Bool removed;
                   writebacks = [ (0, Vm_value.Set new_elems) ] }
           | _ -> Error "argument mismatch: expected (Set, item)"));
    intrinsic_binding "__intrinsic_set_insert"
      (adapter_raw_wb
         [ (Access_effect.Inout, set_of p0); (Access_effect.Sink, p0) ]
         ty_bool (fun _ args ->
           (* the exact Tangerine contract (std REPLACEMENT contract):
              the sink item arrives MOVED and the caller no longer owns
              it — the adapter TAKES the exact value object and it
              BECOMES the stored element.  On the fresh path it is
              appended; on the found path the FIRST lookup_eq-equal
              stored element is REPLACED by the incoming item (the
              displaced old element is relinquished exactly once — it
              is in no live value afterward, and the old set value is
              dead).  The language value is the presence Bool: `true`
              when the key already existed (its slot was replaced),
              `false` when a fresh slot was created. *)
           match args with
           | [| Vm_value.Set elems; item |] ->
               let rec insert acc = function
                 | [] -> (false, List.rev_append acc [ item ])
                 | x :: rest when lookup_eq x item ->
                     (true, List.rev_append acc (item :: rest))
                 | x :: rest -> insert (x :: acc) rest
               in
               let existed, new_elems = insert [] elems in
               Ok { value = Vm_value.Bool existed;
                    writebacks = [ (0, Vm_value.Set new_elems) ] }
           | _ -> Error "argument mismatch: expected (Set, item)"));
    intrinsic_binding "__intrinsic_set_len"
      (adapter_raw (lets [ set_of p0 ]) ty_int (fun _ args ->
           match args with
           | [| Vm_value.Set elems |] ->
               Ok
                 (Vm_value.Int
                    (Int_value.of_int64 ~width:64 ~signed:true
                       (Int64.of_int (List.length elems))))
           | _ -> arg_mismatch "(Set)"));
    intrinsic_binding "__intrinsic_set_entries"
      (adapter_raw (lets [ set_of p0 ]) (vec_of p0) (fun _ args ->
           match args with
           | [| Vm_value.Set elems |] ->
               Ok (Vm_value.Array (Array.of_list elems))
           | _ -> arg_mismatch "(Set)"));
    intrinsic_binding "__intrinsic_set_drain_one"
      (adapter_raw_wb [ (Access_effect.Inout, set_of p0) ] (option_of p0)
         (fun _ args ->
           (* the drain contract: extract an arbitrary element as an
              owned Option[T] and shrink the set through the writeback
              channel (the seed set is unordered, so the head is the
              deterministic pick) *)
           match args with
           | [| Vm_value.Set elems |] -> (
               match elems with
               | [] -> Ok { value = Vm_value.Enum (1, [||]);
                            writebacks = [ (0, Vm_value.Set []) ] }
               | x :: rest ->
                   Ok { value = Vm_value.Enum (0, [| x |]);
                        writebacks = [ (0, Vm_value.Set rest) ] })
           | _ -> Error "argument mismatch: expected (Set)"));
    intrinsic_binding "__intrinsic_set_clear"
      (adapter_raw_wb [ (Access_effect.Inout, set_of p0) ] Type_repr.Unit (fun _ args ->
           match args with
           | [| Vm_value.Set _ |] ->
               Ok { value = Vm_value.Unit;
                    writebacks = [ (0, Vm_value.Set []) ] }
           | _ -> Error "argument mismatch: expected (Set)"));
    intrinsic_binding "__intrinsic_map_contains_key"
      (adapter_raw (lets [ map_of p0 p1; p0 ]) ty_bool (fun _ args ->
           (* pure read; the key decision uses lookup_eq — a
              resource-containing key aggregate is never reported Eq *)
           match args with
           | [| Vm_value.Map pairs; key |] ->
               Ok
                 (Vm_value.Bool
                    (List.exists (fun (k, _) -> lookup_eq k key) pairs))
           | _ -> arg_mismatch "(Map, key)"));
    intrinsic_binding "__intrinsic_map_get"
      (adapter_raw (lets [ map_of p0 p1; p0 ]) (option_of p1) (fun _ args ->
           (* pure read (surface-bound V: Copy — the returned value
              aliases the map's stored value only for copy payloads;
              containment/lookup never compares resource carriers) *)
           match args with
           | [| Vm_value.Map pairs; key |] -> (
               match List.find_opt (fun (k, _) -> lookup_eq k key) pairs with
               | Some (_, v) ->
                   Ok (Vm_value.Enum (0, [| v |]))
               | None -> Ok (Vm_value.Enum (1, [||])))
           | _ -> arg_mismatch "(Map, key)"));
    intrinsic_binding "__intrinsic_map_insert"
      (adapter_raw_wb
         [
           (Access_effect.Inout, map_of p0 p1);
           (Access_effect.Sink, p0);
           (Access_effect.Sink, p1);
         ]
         (option_of p1) (fun _ args ->
          (* the exact Tangerine contract (audit P0-B / P0-11): the
             language value is Option[old V] — the displaced old value,
             returned OWNED (it appears in no live value but the
             Option) — and the mutation travels through the explicit
             writeback channel.  The sink key and sink value arrive
             MOVED and are TAKEN by the adapter (never copied):
             • key ABSENT: both the incoming key and the incoming
               value become the stored pair;
             • key PRESENT (first lookup_eq match): the STORED key is
               PRESERVED (the map keeps its key identity — the
               incoming sink key is consumed by the call and stored
               nowhere), the incoming sink VALUE becomes the stored
               value, and the OLD value is relinquished into the
               returned Option exactly once.  The writeback is a fresh
               pair list sharing only the retained pairs/keys. *)
          match args with
          | [| Vm_value.Map pairs; key; value |] -> (
              match List.find_opt (fun (k, _) -> lookup_eq k key) pairs with
              | Some (_, old) ->
                  let new_pairs =
                    List.map
                      (fun (k, v) -> if lookup_eq k key then (k, value) else (k, v))
                      pairs
                  in
                  Ok
                    { value = Vm_value.Enum (0, [| old |]);
                      writebacks = [ (0, Vm_value.Map new_pairs) ] }
              | None ->
                  Ok
                    { value = Vm_value.Enum (1, [||]);
                      writebacks = [ (0, Vm_value.Map (pairs @ [ (key, value) ])) ] })
          | _ -> Error "argument mismatch: expected (Map, key, value)"));
    intrinsic_binding "__intrinsic_map_len"
      (adapter_raw (lets [ map_of p0 p1 ]) ty_int (fun _ args ->
           match args with
           | [| Vm_value.Map pairs |] ->
               Ok
                 (Vm_value.Int
                    (Int_value.of_int64 ~width:64 ~signed:true
                       (Int64.of_int (List.length pairs))))
           | _ -> arg_mismatch "(Map)"));
    intrinsic_binding "__intrinsic_map_entries"
      (adapter_raw (lets [ map_of p0 p1 ])
         (vec_of (tuple_of [| p0; p1 |])) (fun _ args ->
           match args with
           | [| Vm_value.Map pairs |] ->
               Ok
                 (Vm_value.Array
                    (Array.of_list
                       (List.map (fun (k, v) -> Vm_value.Tuple [| k; v |]) pairs)))
           | _ -> arg_mismatch "(Map)"));
    (* ── The Vec/Array host surface (the growable-array family) ──────
       The seed's runtime Vec/Array form is Vm_value.Array (the
       element tree).  Growth is implicit: a push extends the OCaml
       array and the mutation travels through the writeback channel
       (the same inout convention the Set/Map adapters use), so
       len == capacity always holds — the capacity queries only feed
       the kernel's geometric-growth decisions, which the implicit
       growth makes moot.  The VALUE ABIs transcribe the kernel
       contracts: pop -> Option[T] (Some payload / None on empty),
       get/remove are the CHECKED reads — out-of-range is the std's
       OOB panic, enforced as a deterministic host error (the VM
       traps).  Ownership (audit P0-11): the sink item of push/set/
       insert arrives MOVED and is TAKEN — the exact value object
       becomes the stored element; the displaced element of set is
       relinquished exactly once; pop/remove EXTRACT the element into
       the return so it leaves the collection exactly once; a failed
       bounds check consumes NOTHING (error before any writeback). *)
    intrinsic_binding "__intrinsic_array_new"
      (adapter_raw [] (vec_of p0) (fun _ args ->
           match args with
           | [||] -> Ok (Vm_value.Array [||])
           | _ -> arg_mismatch "no arguments"));
    intrinsic_binding "__intrinsic_array_with_capacity"
      (adapter_raw (lets [ ty_int ]) (vec_of p0) (fun _ args ->
           (* the preallocation hint is advisory: the seed's implicit
              growth makes capacity a query-only quantity, so the
              empty result is the full semantic *)
           match args with
           | [| Vm_value.Int _ |] -> Ok (Vm_value.Array [||])
           | _ -> arg_mismatch "(Int)"));
    intrinsic_binding "__intrinsic_array_len"
      (adapter_raw (lets [ vec_of p0 ]) ty_int (fun _ args ->
           match args with
           | [| Vm_value.Array elems |] ->
               Ok
                 (Vm_value.Int
                    (Int_value.of_int64 ~width:64 ~signed:true
                       (Int64.of_int (Array.length elems))))
           | _ -> arg_mismatch "(Array)"));
    intrinsic_binding "__intrinsic_array_capacity"
      (adapter_raw (lets [ vec_of p0 ]) ty_int (fun _ args ->
           (* len == capacity on the implicit-growth seed representation *)
           match args with
           | [| Vm_value.Array elems |] ->
               Ok
                 (Vm_value.Int
                    (Int_value.of_int64 ~width:64 ~signed:true
                       (Int64.of_int (Array.length elems))))
           | _ -> arg_mismatch "(Array)"));
    intrinsic_binding "__intrinsic_array_push"
      (adapter_raw_wb
         [ (Access_effect.Inout, vec_of p0); (Access_effect.Sink, p0) ]
         Type_repr.Unit (fun _ args ->
          (* take-not-copy: the sink item arrives MOVED (the caller's
             slot is already consumed) — the exact value object is
             appended and becomes the new last element; the writeback
             array shares the retained elements with the (now dead)
             old array value, so no element is ever held by two live
             values.  Nothing here copies the item. *)
          match args with
          | [| Vm_value.Array elems; item |] ->
              Ok
                { value = Vm_value.Unit;
                  writebacks = [ (0, Vm_value.Array (Array.append elems [| item |])) ] }
          | _ -> Error "argument mismatch: expected (Array, item)"));
    intrinsic_binding "__intrinsic_array_pop"
      (adapter_raw_wb [ (Access_effect.Inout, vec_of p0) ] (option_of p0)
         (fun _ args ->
           (* the exact Tangerine contract: the language value is
              Option[T] — Some(the last element) or None on empty —
              and the shrink travels through the writeback channel.
              Element ownership TRANSFERS to the caller exactly once:
              on the Some path the last element appears ONLY in the
              returned Option — the writeback array (a sub-array
              sharing the remaining elements) never contains it. *)
           match args with
           | [| Vm_value.Array elems |] ->
               let n = Array.length elems in
               if n = 0 then
                 Ok
                   { value = Vm_value.Enum (1, [||]);
                     writebacks = [ (0, Vm_value.Array elems) ] }
               else
                 Ok
                   { value = Vm_value.Enum (0, [| elems.(n - 1) |]);
                     writebacks = [ (0, Vm_value.Array (Array.sub elems 0 (n - 1))) ] }
           | _ -> Error "argument mismatch: expected (Array)"));
    intrinsic_binding "__intrinsic_array_get"
      (adapter_raw (lets [ vec_of p0; ty_int ]) p0 (fun _ args ->
           (* VALUE ABI, CHECKED: out-of-range is the std's defined OOB
              panic — a deterministic host error the VM traps on; a
              failed check consumes NOTHING.  A successful get is a
              pure READ (surface-bound T: Copy — the value aliases the
              array's stored element only for copy payloads). *)
           match args with
           | [| Vm_value.Array elems; Vm_value.Int i |] ->
               let idx = Int64.to_int (Int_value.to_int64 i) in
               if idx < 0 || idx >= Array.length elems then
                 Error
                   (Printf.sprintf
                      "__intrinsic_array_get: index %d out of bounds (len %d)" idx
                      (Array.length elems))
               else Ok elems.(idx)
           | _ -> arg_mismatch "(Array, Int)"));
    intrinsic_binding "__intrinsic_array_set"
      (adapter_raw_wb
         [ (Access_effect.Inout, vec_of p0); (Access_effect.Let, ty_int);
           (Access_effect.Sink, p0) ]
         Type_repr.Unit (fun _ args ->
          (* ownership semantics: the bounds check runs FIRST — a
             failed check consumes NOTHING (an error, no writeback).
             On success the sink value arrives MOVED and is TAKEN —
             the exact value object becomes the stored element at the
             index — and the OLD element is relinquished exactly once
             (it appears in no live value afterward: the writeback
             array is a shallow copy sharing only the retained
             elements, and the old array value is dead). *)
          match args with
          | [| Vm_value.Array elems; Vm_value.Int i; value |] ->
              let idx = Int64.to_int (Int_value.to_int64 i) in
              if idx < 0 || idx >= Array.length elems then
                Error
                  (Printf.sprintf
                     "__intrinsic_array_set: index %d out of bounds (len %d)" idx
                     (Array.length elems))
              else begin
                let new_elems = Array.copy elems in
                new_elems.(idx) <- value;
                Ok { value = Vm_value.Unit;
                     writebacks = [ (0, Vm_value.Array new_elems) ] }
              end
          | _ -> Error "argument mismatch: expected (Array, Int, value)"));
    intrinsic_binding "__intrinsic_array_remove"
      (adapter_raw_wb
         [ (Access_effect.Inout, vec_of p0); (Access_effect.Let, ty_int) ]
         p0 (fun _ args ->
           (* VALUE ABI, CHECKED: the removed element is the language
              value and the shifted remainder travels through the
              writeback channel.  Element ownership TRANSFERS to the
              caller exactly once: the removed element appears ONLY in
              the returned value — the writeback shares only the
              retained prefix/suffix.  The bounds check runs FIRST — a
              failed check consumes NOTHING. *)
           match args with
           | [| Vm_value.Array elems; Vm_value.Int i |] ->
               let idx = Int64.to_int (Int_value.to_int64 i) in
               let n = Array.length elems in
               if idx < 0 || idx >= n then
                 Error
                   (Printf.sprintf
                      "__intrinsic_array_remove: index %d out of bounds (len %d)" idx n)
               else
                 Ok
                   { value = elems.(idx);
                     writebacks =
                       [ (0,
                          Vm_value.Array
                            (Array.append (Array.sub elems 0 idx)
                               (Array.sub elems (idx + 1) (n - idx - 1)))) ] }
           | _ -> Error "argument mismatch: expected (Array, Int)"));
    intrinsic_binding "__intrinsic_array_insert"
      (adapter_raw_wb
         [ (Access_effect.Inout, vec_of p0); (Access_effect.Let, ty_int);
           (Access_effect.Sink, p0) ]
         Type_repr.Unit (fun _ args ->
          (* the bounds check runs FIRST — a failed check consumes
             NOTHING (an error, no writeback).  On success the sink
             item arrives MOVED and is TAKEN: the exact value object
             is placed at the index and the writeback shares only the
             retained elements. *)
          match args with
          | [| Vm_value.Array elems; Vm_value.Int i; item |] ->
              let idx = Int64.to_int (Int_value.to_int64 i) in
              let n = Array.length elems in
              if idx < 0 || idx > n then
                Error
                  (Printf.sprintf
                     "__intrinsic_array_insert: index %d out of bounds (len %d)" idx n)
              else
                Ok
                  { value = Vm_value.Unit;
                    writebacks =
                      [ (0,
                         Vm_value.Array
                           (Array.append (Array.sub elems 0 idx)
                              (Array.append [| item |] (Array.sub elems idx (n - idx))))) ] }
          | _ -> Error "argument mismatch: expected (Array, Int, item)"));
    intrinsic_binding "__intrinsic_array_clear"
      (adapter_raw_wb [ (Access_effect.Inout, vec_of p0) ] Type_repr.Unit (fun _ args ->
           (* every element is relinquished: the writeback is empty and
              none of the old elements appears in any live value *)
           match args with
           | [| Vm_value.Array _ |] ->
               Ok { value = Vm_value.Unit;
                    writebacks = [ (0, Vm_value.Array [||]) ] }
           | _ -> Error "argument mismatch: expected (Array)"));
    intrinsic_binding "__intrinsic_array_contains"
      (adapter_raw (lets [ vec_of p0; p0 ]) ty_bool (fun _ args ->
           (* pure read; the containment decision uses lookup_eq — a
              resource-containing element is never reported Eq *)
           match args with
           | [| Vm_value.Array elems; item |] ->
               Ok (Vm_value.Bool (Array.exists (fun e -> lookup_eq e item) elems))
           | _ -> arg_mismatch "(Array, item)"));
    intrinsic_binding "print"
      (adapter_string_ret_unit (fun t s -> emit_stdout t s));
    intrinsic_binding "println"
      (adapter_string_ret_unit (fun t s ->
           emit_stdout t s;
           emit_stdout t "\n"));
    intrinsic_binding "panic"
      (adapter_string_ret_never (fun _ s -> Printf.sprintf "panic: %s" s));
    intrinsic_binding "__intrinsic_abort"
      (adapter_raw [] Type_repr.Unit (fun _ _ ->
           (* the std declares () -> Unit (std/core.tg); the seed host
              semantics are the deterministic abort error, which traps
              the VM before any value materializes *)
           Error "__intrinsic_abort: process aborted"));
    intrinsic_binding "__intrinsic_int_to_string"
      (adapter_int_ret_string (fun _ i -> Int_value.to_string i));
    intrinsic_binding "__intrinsic_bool_to_string"
      (adapter_bool_ret_string (fun _ b -> if b then "true" else "false"));
    intrinsic_binding "__intrinsic_char_to_string"
      (adapter_char_ret_string (fun _ c -> Bytes.to_string (Utf8.encode_scalar c)));
    intrinsic_binding "__intrinsic_string_len"
      (adapter_string_ret_int (fun _ s ->
           Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (String.length s))));
    (* __sync_synchronize is a full memory barrier; on the single-threaded
       seed host there is nothing to order, so the correct implementation
       is a no-op. This is the real semantic, not a fabricated value. *)
    extern_binding "__sync_synchronize"
      (adapter_ret_unit (fun _ -> ()));
    (* std/args.tg — the kernel argv channel (the same argv Vm.run
       received): tg_get_argc returns the argv length and _tg_arg_copy
       the i-th argv string (the kernel's raw_arg_count/raw_arg_copy). *)
    extern_binding "tg_get_argc"
      (adapter_raw [] ty_int (fun t args ->
           match args with
           | [||] ->
               Ok
                 (Vm_value.Int
                    (Int_value.of_int64 ~width:64 ~signed:true
                       (Int64.of_int (Array.length t.argv))))
           | _ -> arg_mismatch "no arguments"));
    extern_binding "_tg_arg_copy"
      (adapter_raw (lets [ ty_int ]) ty_string (fun t args ->
           match args with
           | [| Vm_value.Int i |] ->
               let n = Int64.to_int (Int_value.to_int64 i) in
               if n < 0 || n >= Array.length t.argv then
                 Error "argument mismatch: argv index out of range"
               else Ok (Vm_value.String t.argv.(n))
           | _ -> arg_mismatch "Int"));
  ]

let binding_of_manifest (name : string) : binding option =
  List.find_opt (fun b -> b.name = name) binding_manifest

(* ── Construction ─────────────────────────────────────────────────── *)

(* The process capability is built ONCE per host from Host_process,
   bound to the host's virtual filesystem: a Tangerine-supplied cwd is a
   virtual path, resolved through Host_fs (canonicalized + containment)
   before a child is chdir'd onto it. *)
let default_process_api (fs : Host_fs.t) : process_api =
  let resolve_virtual_cwd (cwd : string option) : (string option, string) result =
    match cwd with
    | None -> Ok None
    | Some dir ->
        let segs =
          String.split_on_char '/' dir |> List.filter (fun s -> s <> "")
        in
        (match Host_fs.resolve fs segs with
        | Ok real -> Ok (Some real)
        | Error e -> Error e)
  in
  {
    spawn =
      (fun ~executable ~argv ~env ~cwd ->
        match resolve_virtual_cwd cwd with
        | Error e -> Error e
        | Ok cwd' -> Host_process.spawn ~executable ~argv ~env ~cwd:cwd');
    spawn_nocapture = Host_process.spawn_nocapture;
  }

(* Build a host from explicit registries (declared surface) and an
   explicit binding table (executable closure). *)
let create_with ~repo_root ~(argv : string array) ~(intrinsics : Intrinsic_registry.t)
    ~(externs : Extern_registry.t) ~(bindings : binding list) : t =
  let fs = Host_fs.create ~repo_root in
  {
    intrinsics;
    externs;
    bindings;
    fs;
    process = default_process_api fs;
    argv;
    env = [];
    stdout = Buffer.create 4096;
    stderr = Buffer.create 4096;
  }

(* The default host: manifest registries and the manifest binding table. *)
let create ~repo_root ~(argv : string array) : t =
  create_with ~repo_root ~argv ~intrinsics:Intrinsic_registry.manifest
    ~externs:Extern_registry.manifest ~bindings:binding_manifest

(* Normalize the process environment for spawned children: LC_ALL=C and
   TZ=UTC are forced through Unix.putenv, then the recorded environment is
   captured and sorted by key for determinism. *)
let with_normalized_env (t : t) : t =
  Unix.putenv "LC_ALL" "C";
  Unix.putenv "TZ" "UTC";
  let env =
    Unix.environment ()
    |> Array.to_list
    |> List.map (fun entry ->
           match String.index_opt entry '=' with
           | Some i ->
               ( String.sub entry 0 i,
                 String.sub entry (i + 1) (String.length entry - i - 1) )
           | None -> (entry, ""))
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  t.env <- env;
  t

(* ── Binding lookup (the VM's dispatch path) ───────────────────────── *)

let lookup_binding (t : t) (id : host_id) : binding option =
  List.find_opt (fun b -> b.id = id) t.bindings

let lookup_binding_by_name (t : t) (name : string) : binding option =
  List.find_opt (fun b -> b.name = name) t.bindings

(* Resolve a dispatch id back to its declared name (for diagnostics). *)
let name_of_host_id (t : t) (id : host_id) : string option =
  match id with
  | Intrinsic i ->
      List.find_map
        (fun (name, (iid, _)) -> if iid = i then Some name else None)
        t.intrinsics.Intrinsic_registry.by_name
  | Extern i ->
      List.find_map
        (fun (name, (eid, _)) -> if eid = i then Some name else None)
        t.externs.Extern_registry.by_name

(* ────────────────────────────────────────────────────────────────────
   Closure check (audit §70). The declared surface (the registries) is
   compared against the EXACT SAME binding table the VM dispatches
   through (t.bindings). PASS requires every declared symbol to carry a
   binding — an executable invoke. Any declared-but-unbound symbol FAILS
   the check and is named; a signature disagreement between the
   binding's INDEPENDENT adapter declaration and the registry's
   source-derived declaration also fails; bound-but-undeclared extras
   fail. The report carries the implemented-vs-declared counts. *)

type closure_report = {
  declared : int;
  implemented : int;
  bound : string list;
}

(* The registry's declaration vs the binding's INDEPENDENT adapter
   declaration, compared with the SHARED signature-identity matcher
   (audit P0-3/P0-4): arity, every parameter's convention and type
   (alpha-equivalent under one binder bijection), and the return —
   exact TypeIds after each side's registry-domain canonicalization
   (canonicalize_registry — defined with the adapters above).  Returns
   the rendered problem, or None when the signatures are identical. *)
let check_binding_signature (reachable : bool) (name : string)
    (dsig : Intrinsic_registry.signature) (b : binding) : string option =
  let prefix = if reachable then " for reachable" else "" in
  let declared = Signature_identity.of_registry dsig in
  let canon_left = canonicalize_registry and canon_right = canonicalize_registry in
  if
    not
      (Signature_identity.signatures_match ~canon_left ~canon_right declared
         b.adapter)
  then
    match
      Signature_identity.first_mismatch ~canon_left ~canon_right declared b.adapter
    with
    | Some (Signature_identity.Mismatch_arity (nd, na)) ->
        Some
          (Printf.sprintf "signature mismatch%s for %s: declared arity %d, binding arity %d"
             prefix name nd na)
    | Some (Signature_identity.Mismatch_param i) ->
        Some
          (Printf.sprintf
             "signature mismatch%s for %s: parameter %d disagrees (declared %s; binding %s)"
             prefix name (i + 1)
             (param_contract declared.Signature_identity.sig_params.(i))
             (param_contract b.adapter.Signature_identity.sig_params.(i)))
    | Some Signature_identity.Mismatch_return ->
        Some
          (Printf.sprintf "return mismatch%s for %s: declared %s, binding %s" prefix name
             (Intrinsic_registry.ty_to_string declared.Signature_identity.sig_ret)
             (Intrinsic_registry.ty_to_string b.adapter.Signature_identity.sig_ret))
    | None -> None
  else None

let closure_check (t : t) : (closure_report, string list) result =
  let module SS = Set.Make (String) in
  let problems = ref [] in
  let problem fmt = Printf.ksprintf (fun s -> problems := s :: !problems) fmt in
  let declared =
    List.map
      (fun name -> (name, snd (Option.get (Intrinsic_registry.lookup t.intrinsics ~name))))
      (Intrinsic_registry.names t.intrinsics)
    @ List.map
        (fun name ->
          (name, snd (Option.get (Extern_registry.lookup t.externs ~name))))
        (Extern_registry.names t.externs)
  in
  let decl_names = SS.of_list (List.map fst declared) in
  let impl_names = SS.of_list (List.map (fun b -> b.name) t.bindings) in
  let missing = SS.diff decl_names impl_names in
  if not (SS.is_empty missing) then
    problem "declared but not bound (no invoke): %s" (String.concat ", " (SS.elements missing));
  List.iter
    (fun (name, dsig) ->
      match List.find_opt (fun b -> b.name = name) t.bindings with
      | None -> ()
      | Some b -> (
          match check_binding_signature false name dsig b with
          | Some p -> problem "%s" p
          | None -> ()))
    declared;
  let extras = SS.diff impl_names decl_names in
  if not (SS.is_empty extras) then
    problem "bound but not declared: %s" (String.concat ", " (SS.elements extras));
  match List.rev !problems with
  | [] ->
      Ok
        { declared = SS.cardinal decl_names;
          implemented = SS.cardinal impl_names;
          bound = List.sort compare (List.map (fun b -> b.name) t.bindings) }
  | ps -> Error ps

(* ────────────────────────────────────────────────────────────────────
   Reachable-host closure check (re-audit: stage 10).  closure_check
   compares the WHOLE declared surface against the binding table; the
   reachable-host proof needs the narrower boundary: only the host ids
   a post-mono program's calls actually REACH must carry an executable
   binding with the exact typed signature.  A declared-but-unreachable
   symbol needs no binding — that is the documented distinction (the
   host is a declared surface; the executable closure is the bound
   subset the VM may dispatch).  PASS requires every reachable id to be
   declared AND bound with matching signatures; any problem names the
   symbol, mirroring closure_check's failure report. *)

let closure_check_reachable (t : t) (reachable : host_id list) :
    (closure_report, string list) result =
  let problems = ref [] in
  let problem fmt = Printf.ksprintf (fun s -> problems := s :: !problems) fmt in
  let seen = Hashtbl.create 16 in
  let declared = ref 0 in
  let implemented = ref 0 in
  let bound_names = ref [] in
  List.iter
    (fun id ->
      if not (Hashtbl.mem seen id) then begin
        Hashtbl.add seen id ();
        incr declared;
        let decl =
          match id with
          | Intrinsic i ->
              List.find_map
                (fun (name, (iid, sig_)) -> if iid = i then Some (name, sig_) else None)
                t.intrinsics.Intrinsic_registry.by_name
          | Extern i ->
              List.find_map
                (fun (name, (eid, sig_)) -> if eid = i then Some (name, sig_) else None)
                t.externs.Extern_registry.by_name
        in
        match decl with
        | None ->
            problem "reachable host id #%d is not declared in the host registries"
              (match id with
              | Intrinsic i -> Intrinsic_registry.Id.to_int i
              | Extern i -> Extern_registry.Id.to_int i)
        | Some (name, dsig) -> (
            match List.find_opt (fun b -> b.id = id) t.bindings with
            | None -> problem "reachable but not bound (no invoke): %s" name
            | Some b ->
                incr implemented;
                bound_names := name :: !bound_names;
                (match check_binding_signature true name dsig b with
                 | Some p -> problem "%s" p
                 | None -> ()))
      end)
    reachable;
  match List.rev !problems with
  | [] ->
      Ok
        { declared = !declared;
          implemented = !implemented;
          bound = List.sort compare (List.rev !bound_names) }
  | ps -> Error ps
