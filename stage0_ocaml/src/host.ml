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

(* re-audit P0-B / P0-3: the host-call RESULT separates the language-
   visible value from the mutation writebacks — an inout intrinsic
   mutates through the writeback channel and returns the EXACT
   Tangerine contract (Set::insert -> Bool, Map::insert -> Option[old
   V]) in the value slot.  The old collection-return-as-mutation-
   transport convention is gone.

   Audit P0-3 (the collection writeback OWNERSHIP model): a writeback
   is an ownership-explicit record — the arg index whose caller value
   is replaced, the replacement value, and the list of values that
   LEFT the caller's container (the displaced/removed members).  The
   copy-on-write collection adapters build the replacement as a fresh
   collection SHARING only the retained members, so the old container
   value is dead the moment the writeback lands and can never be
   dropped as a whole (a whole drop would double-destroy the shared
   retained members); the members that left (the array_set displaced
   element, the clear/remove casualties, ...) are enumerated in
   `removed`, and the VM's writeback application drops exactly those,
   exactly once, with the canonical per-type drop (vm.ml).  A value
   TRANSFERRED to the return (pop/remove/drain_one payloads,
   map_insert's Option[old V]) is never in `removed`. *)
type host_writeback = {
  arg_index : int;
  replacement : Vm_value.t;
  removed : Vm_value.t list;
}

type host_result = {
  value : Vm_value.t;
  writebacks : host_writeback list;
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
  (* The RAW-MEMORY ARENA: the one region table both the VM (raw-pointer
     deref, computed-value refs) and the host adapters (as_ptr views,
     mem_alloc blocks, libc buffers, environment entries) index.  The VM
     adopts this table as vm.memory, so a host-materialized region and a
     VM Deref of the same pointer agree byte-for-byte. *)
  memory : Vm_memory.t;
  (* The array-view links: region id -> the OCaml element array the region
     was materialized from.  A byte written through a raw pointer into a
     linked region is mirrored into the element array in place, so the
     guest's own Vec value observes the C-ABI write (the seed value model
     has no addressable Vec storage; the link is the materialization). *)
  array_links : (int, Vm_value.t array) Hashtbl.t;
  (* True in an OS child process created by the guest's own c_fork.  The
     direct kernel's `_exit` terminates the process; the seed host may
     perform exactly that in a guest-created child (the child is the VM
     process, the parent keeps the driver's report), never in the parent
     where it would kill the seed host running the VM. *)
  mutable in_fork_child : bool;
}

(* Output helpers (the VM's printf/intrinsic path — audit §45). *)
let emit_stdout (t : t) (s : string) : unit = Buffer.add_string t.stdout s
let emit_stderr (t : t) (s : string) : unit = Buffer.add_string t.stderr s
let stdout_contents (t : t) : string = Buffer.contents t.stdout
let stderr_contents (t : t) : string = Buffer.contents t.stderr

(* ── The single binding table (audit §70) ────────────────────────────

   Every entry below carries a REAL executable implementation. Symbols the
   closure declares but that are NOT in this table — the Ruby C API
   externs, the dl* loader family, the __sync arithmetic primitives —
   are deliberately unbound: their real semantics are not implementable
   on this seed host, so no stub is shipped. closure_check fails on
   them and the VM traps. The five map/set record-visit traversal
   intrinsics ARE implemented (the value-model borrow/index adapters
   below — see the visit protocol note before binding_manifest). *)

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
   value AND the ownership-explicit mutation writebacks (replacement +
   the removed members, audit P0-3) *)
let adapter_raw_wb (params : (Access_effect.t * Type_repr.t) list) (ret : Type_repr.t)
    (invoke : t -> Vm_value.t array -> (host_result, string) result) : adapter =
  { signature = mk_sig params ret; invoke }

(* The remaining deterministic traps are written inline at their
   adapters (a direct `Error`): the unwind/function-value intrinsics
   (__intrinsic_try_invoke, __intrinsic_longjmp), panic/abort, the
   Option::expect None case and the checked-access errors (out-of-bounds
   array/region access, invalid free).  They fire only on guest misuse or
   on the program's own abort semantics — never on a valid host call the
   executable closure reaches. *)
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

(* ── The kernel wrapper surface's value helpers (audit §70) ─────────
   The called __intrinsic_* wrappers (the std str/String/array/map/set
   and scalar-conversion surface) operate on the seed's immutable value
   model: the String value, the Array element tree, the Map pair list
   and the Set element list.  The helpers below implement the exact
   semantics the native runtime helpers (_tg_string_*, _tg_str_*,
   _tg_regex_match) define — the seed host and the native runtime must
   agree on the observable result — and are shared by the adapters. *)

let ty_u64 = Intrinsic_registry.ty_u64
let ty_uint = Intrinsic_registry.ty_uint
let ty_i32 = Intrinsic_registry.ty_i32
let ty_char = Type_repr.Char
let result_of = Intrinsic_registry.result_of
let ptr_named = Intrinsic_registry.ptr_named
let ptrmut_named = Intrinsic_registry.ptrmut_named
let fn0 = Intrinsic_registry.fn0
(* the internal address/reference ABI type of the five record-visit
   declarations (Ref_internal Immutable — the checker's `&T`) *)
let ref_ = Intrinsic_registry.ref_

let vm_int (n : int) : Vm_value.t =
  Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int n))

let vm_i32 (n : int) : Vm_value.t =
  Vm_value.Int (Int_value.of_int64 ~width:32 ~signed:true (Int64.of_int n))

(* The seed host's STANDARD descriptors keep their process meaning (the
   captured stdout/stderr paths below); every OTHER descriptor number is
   resolved through the host's own descriptor table, into which
   libc_open/pipe install the OS descriptors they open.  The guest sees
   stable host descriptor numbers; the OS file_descr never crosses the
   boundary. *)
let std_fd_of (fd : int) : Unix.file_descr option =
  if fd = 0 then Some Unix.stdin
  else if fd = 1 then Some Unix.stdout
  else if fd = 2 then Some Unix.stderr
  else None

(* ── The raw-memory arena adapters ───────────────────────────────────
   The host owns the SAME Vm_memory region table the VM dereferences
   through (the VM adopts Host.memory as vm.memory), so a region a host
   adapter materializes is addressable by the VM's own raw-pointer deref
   and vice versa.  The adapters below are the C-ABI face of that table:
   pointer arguments are decoded, bytes are copied with bounds checks,
   and every byte written into a region linked to an array view is
   mirrored back into the guest's element array (the seed value model has
   no addressable Vec storage). *)

let mem_error (e : Vm_memory.mem_error) : string = Vm_memory.mem_error_string e

(* The value's runtime shape, for boundary diagnostics. *)
let value_kind_name (v : Vm_value.t) : string =
  match v with
  | Vm_value.Unit -> "Unit"
  | Vm_value.Bool _ -> "Bool"
  | Vm_value.Int _ -> "Int"
  | Vm_value.Float32 _ -> "Float32"
  | Vm_value.Float64 _ -> "Float64"
  | Vm_value.Char _ -> "Char"
  | Vm_value.String _ -> "String"
  | Vm_value.Tuple _ -> "Tuple"
  | Vm_value.Struct _ -> "Struct"
  | Vm_value.Enum _ -> "Enum"
  | Vm_value.Array _ -> "Array"
  | Vm_value.Set _ -> "Set"
  | Vm_value.Map _ -> "Map"
  | Vm_value.Function _ -> "Function"
  | Vm_value.Closure _ -> "Closure"
  | Vm_value.RawPtr _ -> "RawPtr"
  | Vm_value.Ref _ -> "Ref"
  | Vm_value.Null -> "Null"
  | Vm_value.MovedOut -> "MovedOut"

(* The address-bearing pointer shapes the value model uses: the host's
   RawPtr/Null, the Int address codec (the language's `p as Int`
   spellings), the source `Ptr { address }` handle struct, and a handle
   over a handle (the Box/Ptr wrapper shape).  None when the value is not
   a pointer at all. *)
let pointer_value_to_pointer (v : Vm_value.t) : Vm_memory.pointer option =
  match v with
  | Vm_value.RawPtr p -> Some p
  | Vm_value.Null -> Some (Vm_memory.pointer_of_int64 0L)
  | Vm_value.Int i -> Some (Vm_memory.pointer_of_int64 (Int_value.to_int64 i))
  | Vm_value.Struct [| Vm_value.Int i |] ->
      Some (Vm_memory.pointer_of_int64 (Int_value.to_int64 i))
  | Vm_value.Struct [| Vm_value.Struct [| Vm_value.Int i |] |] ->
      Some (Vm_memory.pointer_of_int64 (Int_value.to_int64 i))
  | _ -> None

let ptr_arg (v : Vm_value.t) : (Vm_memory.pointer, string) result =
  match pointer_value_to_pointer v with
  | Some p ->
      if p.Vm_memory.region < 0 then
        Error
          (Printf.sprintf
             "argument mismatch: expected Ptr (found %s, which is not an arena \
              address — a null/foreign address)"
             (value_kind_name v))
      else Ok p
  | None -> Error ("argument mismatch: expected Ptr (found " ^ value_kind_name v ^ ")")

let arena_alloc (t : t) (size : int) (align : int) : (Vm_memory.pointer, string) result =
  match Vm_memory.alloc ~kind:Vm_memory.Raw t.memory size align with
  | Ok p -> Ok p
  | Error e -> Error (mem_error e)

let arena_load (t : t) (p : Vm_memory.pointer) (len : int) : (Bytes.t, string) result =
  match Vm_memory.load_bytes t.memory p len with
  | Ok b -> Ok b
  | Error e -> Error (mem_error e)

(* The scalar classification of a runtime value (the array-view link's
   stride authority; None for values with no scalar raw image). *)
let scalar_of_value (v : Vm_value.t) : Raw_memory.scalar option =
  match v with
  | Vm_value.Int i -> Some (Raw_memory.SInt (i.Int_value.width, i.Int_value.signed))
  | Vm_value.Bool _ -> Some Raw_memory.SBool
  | Vm_value.Char _ -> Some Raw_memory.SChar
  | Vm_value.Float32 _ -> Some Raw_memory.SF32
  | Vm_value.Float64 _ -> Some Raw_memory.SF64
  | Vm_value.RawPtr _ | Vm_value.Null -> Some Raw_memory.SPtr
  | _ -> None

(* Write `b` at the pointer, then mirror every byte into any linked array
   view so the guest's own Vec value observes the C-ABI write. *)
let arena_link_mirror (t : t) (p : Vm_memory.pointer) (b : Bytes.t) : unit =
  match Hashtbl.find_opt t.array_links p.Vm_memory.region with
  | None -> ()
  | Some elems ->
      let n = Array.length elems in
      if n = 0 then ()
      else (
        match scalar_of_value elems.(0) with
        | None -> ()
        | Some s ->
            if
              not
                (Array.for_all
                   (fun e -> scalar_of_value e = Some s)
                   elems)
            then ()
            else begin
              let w = Raw_memory.scalar_size s in
              for i = 0 to Bytes.length b - 1 do
                let abs = p.Vm_memory.offset + i in
                let idx = abs / w in
                if idx >= 0 && idx < n then begin
                  let within = abs mod w in
                  match Raw_memory.encode_with s elems.(idx) with
                  | Some img when Bytes.length img = w && within < w ->
                      Bytes.set img within (Bytes.get b i);
                      (match Raw_memory.decode_with s img 0 with
                       | Some (v, _) -> elems.(idx) <- v
                       | None -> ())
                  | _ -> ()
                end
              done
            end)

let arena_store (t : t) (p : Vm_memory.pointer) (b : Bytes.t) : (unit, string) result =
  match Vm_memory.store_bytes t.memory p b with
  | Ok () ->
      arena_link_mirror t p b;
      Ok ()
  | Error e -> Error (mem_error e)

(* The growing variant for the value-model images (__intrinsic_ptr_write):
   a self-describing serialized image's length is value-dependent, so a
   region sized from a layout query can be smaller; growing keeps the
   image intact.  The strict machine-image stores stay on arena_store. *)
let arena_store_grow (t : t) (p : Vm_memory.pointer) (b : Bytes.t) : (unit, string) result =
  match Vm_memory.store_bytes_grow t.memory p b with
  | Ok () ->
      arena_link_mirror t p b;
      Ok ()
  | Error e -> Error (mem_error e)

(* The linked-array mirror hook the VM calls after a raw Deref store into
   a region (the VM writes through the same table). *)
let region_write_hook (t : t) (p : Vm_memory.pointer) (b : Bytes.t) : unit =
  arena_link_mirror t p b

(* A C string: the bytes from the pointer to the first NUL (the region
   must contain one — an unterminated buffer is a deterministic host
   error, never a fabricated path). *)
let arena_cstring (t : t) (p : Vm_memory.pointer) : (string, string) result =
  match Vm_memory.region_length t.memory p with
  | Error e -> Error (mem_error e)
  | Ok rlen ->
      if p.Vm_memory.offset < 0 || p.Vm_memory.offset > rlen then
        Error "pointer offset outside the region"
      else begin
        let maxn = rlen - p.Vm_memory.offset in
        match arena_load t p maxn with
        | Error e -> Error e
        | Ok src ->
            let n = ref 0 in
            while !n < maxn && Bytes.get src !n <> '\000' do
              incr n
            done;
            if !n >= maxn then Error "unterminated C string (no NUL in the region)"
            else Ok (Bytes.to_string (Bytes.sub src 0 !n))
      end

(* The pointer-typed view of an Int argument: the language's `p as Int`
   spellings pass the address codec value through Int space. *)
let ptr_of_int_arg (v : Vm_value.t) : Vm_memory.pointer =
  match v with
  | Vm_value.Int i -> Vm_memory.pointer_of_int64 (Int_value.to_int64 i)
  | Vm_value.RawPtr p -> p
  | Vm_value.Null -> { Vm_memory.region = -1; offset = 0 }
  | _ -> { Vm_memory.region = -1; offset = 0 }

(* Materialize a Vec/Array as raw storage: every element's scalar raw
   image, packed at the scalar stride (the C-ABI view of the collection).
   A non-scalar element image has no flat machine layout in the value
   model — the adapter reports the boundary, never a fabricated block
   layout. *)
let array_raw_image (elems : Vm_value.t array) : (Bytes.t, string) result =
  if Array.length elems = 0 then Ok Bytes.empty
  else
    match scalar_of_value elems.(0) with
    | None ->
        Error
          "collection as_ptr: the element image has no flat raw layout in the seed \
           value model"
    | Some s ->
        if not (Array.for_all (fun e -> scalar_of_value e = Some s) elems) then
          Error
            "collection as_ptr: heterogeneous element widths have no uniform stride in \
             the seed value model"
        else begin
          let w = Raw_memory.scalar_size s in
          let buf = Bytes.make (Array.length elems * w) '\000' in
          let ok = ref true in
          Array.iteri
            (fun i e ->
              match Raw_memory.encode_with s e with
              | Some img when Bytes.length img = w -> Bytes.blit img 0 buf (i * w) w
              | _ -> ok := false)
            elems;
          if !ok then Ok buf else Error "collection as_ptr: element image encode failed"
        end

let array_link_register (t : t) (p : Vm_memory.pointer) (elems : Vm_value.t array) : unit =
  Hashtbl.replace t.array_links p.Vm_memory.region elems

(* ── The host descriptor table ──────────────────────────────────────
   Open descriptors the guest created through libc_open/pipe/dup2 live
   here under stable guest numbers (0..2 are the process standards). *)
let fd_table : (int, Unix.file_descr) Hashtbl.t = Hashtbl.create 16
let next_guest_fd = ref 3

let guest_fd (fd : int) : Unix.file_descr option =
  match std_fd_of fd with
  | Some d -> Some d
  | None -> Hashtbl.find_opt fd_table fd

let register_guest_fd (d : Unix.file_descr) : int =
  let fd = !next_guest_fd in
  incr next_guest_fd;
  Hashtbl.replace fd_table fd d;
  fd

let unregister_guest_fd (fd : int) : bool =
  match Hashtbl.find_opt fd_table fd with
  | None -> false
  | Some d ->
      Hashtbl.remove fd_table fd;
      (try Unix.close d with _ -> ());
      true

(* errno numbers (the BSD/macOS values the kernel's is_macos() target and
   the direct kernel's syscall path produce). *)
let errno_of_unix_error (e : Unix.error) : int =
  match e with
  | Unix.EPERM -> 1
  | Unix.ENOENT -> 2
  | Unix.ESRCH -> 3
  | Unix.EINTR -> 4
  | Unix.EIO -> 5
  | Unix.ENXIO -> 6
  | Unix.E2BIG -> 7
  | Unix.ENOEXEC -> 8
  | Unix.EBADF -> 9
  | Unix.ECHILD -> 10
  | Unix.EAGAIN -> 35
  | Unix.ENOMEM -> 12
  | Unix.EACCES -> 13
  | Unix.EFAULT -> 14
  | Unix.EBUSY -> 16
  | Unix.EEXIST -> 17
  | Unix.EXDEV -> 18
  | Unix.ENODEV -> 19
  | Unix.ENOTDIR -> 20
  | Unix.EISDIR -> 21
  | Unix.EINVAL -> 22
  | Unix.ENFILE -> 23
  | Unix.EMFILE -> 24
  | Unix.ENOTTY -> 25
  | Unix.EFBIG -> 27
  | Unix.ENOSPC -> 28
  | Unix.ESPIPE -> 29
  | Unix.EROFS -> 30
  | Unix.EPIPE -> 32
  | Unix.EDOM -> 33
  | Unix.ERANGE -> 34
  | Unix.EWOULDBLOCK -> 35
  | Unix.EINPROGRESS -> 36
  | Unix.EALREADY -> 37
  | Unix.ENOTEMPTY -> 66
  | Unix.ELOOP -> 62
  | Unix.ENAMETOOLONG -> 63
  | Unix.ENOSYS -> 78
  | Unix.EOPNOTSUPP -> 102
  | Unix.EOVERFLOW -> 84
  | Unix.ETIMEDOUT -> 60
  | Unix.EUNKNOWNERR n -> n
  | _ -> 22

(* ── The descriptor I/O helpers (libc_read/write, syscall read/write) ──
   All buffer traffic goes through the arena: bytes are bounds-checked
   into/out of a region, and a write into a linked array view is mirrored
   into the guest's element array.  The std descriptors 1/2 stay captured
   in the host output buffers (the same contract as _tg_write_vec_u8). *)

let errno_badf = 9
let errno_fault = 14

let host_read_into (t : t) (fd : int) (p : Vm_memory.pointer) (count : int) : int =
  if count <= 0 then 0
  else
    match guest_fd fd with
    | None -> -errno_badf
    | Some d -> (
        let count = min count 0x1000000 in
        let b = Bytes.create count in
        try
          let n = Unix.read d b 0 count in
          match arena_store t p (Bytes.sub b 0 n) with
          | Ok () -> n
          | Error _ -> -errno_fault
        with Unix.Unix_error (e, _, _) -> -errno_of_unix_error e)

let host_write_from (t : t) (fd : int) (p : Vm_memory.pointer) (count : int) : int =
  if count <= 0 then 0
  else
    match arena_load t p count with
    | Error _ -> -errno_fault
    | Ok b ->
        let s = Bytes.to_string b in
        if fd = 1 then begin
          emit_stdout t s;
          String.length s
        end
        else if fd = 2 then begin
          emit_stderr t s;
          String.length s
        end
        else (
          match guest_fd fd with
          | None -> -errno_badf
          | Some d -> (
              try Unix.write_substring d s 0 (String.length s)
              with Unix.Unix_error (e, _, _) -> -errno_of_unix_error e))

(* The raw open flags of a kernel call (the is_macos()-selected BSD
   layout; the Linux layout is honored when the host kernel is Linux).
   The seed host maps them onto the OCaml Unix flag set — the same
   observable descriptor contract the direct kernel's syscall path
   provides.  O_DIRECTORY/O_NOFOLLOW have no OCaml Unix spelling; a
   directory still opens read-only, and a symlink is followed (the host
   boundary's documented descriptor semantics). *)
let host_is_darwin : bool =
  Sys.file_exists "/System/Library/CoreServices"
  || Sys.file_exists "/usr/lib/libSystem.B.dylib"

(* A kernel path argument -> the host path the OS call runs on.  Relative
   paths are the host's VIRTUAL filesystem paths (Host_fs, rooted at
   repo_root): the harness runs the kernel with the repository root as
   its working directory, so a repo-relative kernel path resolves to the
   same file while staying contained in the sandbox.  Absolute paths
   (/dev/null, /tmp, ...) keep their OS meaning.  When virtual resolution
   cannot produce a path (e.g. a not-yet-existing write target), the
   lexical repo-root join is used so the OS produces the real errno. *)
let host_real_path (t : t) (path : string) ~(for_create : bool) : string =
  if String.length path > 0 && path.[0] = '/' then path
  else
    let segs =
      String.split_on_char '/' path |> List.filter (fun s -> s <> "")
    in
    let via_fs =
      if for_create then Host_fs.resolve_write_target t.fs segs
      else Host_fs.resolve_existing t.fs segs
    in
    match via_fs with
    | Ok real -> real
    | Error _ -> Filename.concat t.fs.Host_fs.repo_root path

let open_flags_of_raw (flags : int) : Unix.open_flag list =
  let acc = ref [] in
  (match flags land 0x3 with
   | 1 -> acc := Unix.O_WRONLY :: !acc
   | 2 -> acc := Unix.O_RDWR :: !acc
   | _ -> acc := Unix.O_RDONLY :: !acc);
  let has bit = flags land bit <> 0 in
  if host_is_darwin then begin
    if has 0x8 then acc := Unix.O_APPEND :: !acc;
    if has 0x200 then acc := Unix.O_CREAT :: !acc;
    if has 0x400 then acc := Unix.O_TRUNC :: !acc;
    if has 0x800 then acc := Unix.O_EXCL :: !acc;
    if has 0x1000000 then acc := Unix.O_CLOEXEC :: !acc
  end
  else begin
    if has 0x400 then acc := Unix.O_APPEND :: !acc;
    if has 0x40 then acc := Unix.O_CREAT :: !acc;
    if has 0x200 then acc := Unix.O_TRUNC :: !acc;
    if has 0x80 then acc := Unix.O_EXCL :: !acc;
    if has 0x80000 then acc := Unix.O_CLOEXEC :: !acc
  end;
  !acc

let host_open (t : t) (path : string) (flags : int) (mode : int) : int =
  let create_bit = if host_is_darwin then 0x200 else 0x40 in
  let for_create = flags land create_bit <> 0 in
  let real = host_real_path t path ~for_create in
  try register_guest_fd (Unix.openfile real (open_flags_of_raw flags) mode)
  with Unix.Unix_error (e, _, _) -> -errno_of_unix_error e

let host_close_fd (fd : int) : int =
  if fd >= 0 && fd <= 2 then 0
  else if unregister_guest_fd fd then 0
  else -errno_badf

let host_lseek (fd : int) (off : int64) (whence : int) : int64 =
  match guest_fd fd with
  | None -> Int64.of_int (-errno_badf)
  | Some d -> (
      let cmd =
        match whence with
        | 0 -> Unix.SEEK_SET
        | 1 -> Unix.SEEK_CUR
        | _ -> Unix.SEEK_END
      in
      try Unix.LargeFile.lseek d off cmd
      with Unix.Unix_error (e, _, _) -> Int64.of_int (-errno_of_unix_error e))

let host_dup2 (oldfd : int) (newfd : int) : int =
  match guest_fd oldfd with
  | None -> -errno_badf
  | Some od -> (
      match guest_fd newfd with
      | Some nd -> (
          try
            if oldfd = newfd then newfd
            else begin
              Unix.dup2 ~cloexec:false od nd;
              newfd
            end
          with Unix.Unix_error (e, _, _) -> -errno_of_unix_error e)
      | None ->
          (* dup2 onto an unopened high descriptor: install a duplicate
             under that guest number *)
          (try
             let nd = Unix.dup ~cloexec:false od in
             Hashtbl.replace fd_table newfd nd;
             newfd
           with Unix.Unix_error (e, _, _) -> -errno_of_unix_error e))

let host_chmod (t : t) (path : string) (mode : int) : int =
  let real = host_real_path t path ~for_create:false in
  try
    Unix.chmod real mode;
    0
  with Unix.Unix_error (e, _, _) -> -errno_of_unix_error e

(* ── poll(2) over the guest descriptor table ─────────────────────────
   The guest's pollfd array is a Raw arena region of 8-byte records

     { int fd; short events; short revents; }   (little-endian)

   (std/process.tg _poll_fd_append).  The seed host maps readiness onto
   Unix.select: POLLIN and POLLOUT are the selectable events the closure
   watches (Command::output interleaves its two stdio pipes), a guest fd
   with no host descriptor reports POLLNVAL, and negative entries are
   ignored (POSIX).  revents is written back through arena_store, so a
   linked guest byte Vec observes it.  The result is the number of
   entries with a nonzero revents, or a negative errno on failure —
   exactly poll(2)'s return contract. *)
let poll_in = 0x001
let poll_out = 0x004
let poll_nval = 0x020

let poll_fd_at (b : Bytes.t) (i : int) : int =
  let raw = Raw_memory.u64_le b (i * 8) 4 in
  let raw =
    if Int64.logand raw 0x80000000L <> 0L then Int64.sub raw 0x100000000L
    else raw
  in
  Int64.to_int raw

let poll_events_at (b : Bytes.t) (i : int) : int =
  Int64.to_int (Raw_memory.u64_le b ((i * 8) + 4) 2)

let host_poll (t : t) (p : Vm_memory.pointer) (b : Bytes.t) (nfds : int)
    (timeout_ms : int) : (int, string) result =
  let entries =
    Array.init nfds (fun i -> (poll_fd_at b i, poll_events_at b i))
  in
  let read_fds = ref [] and write_fds = ref [] in
  Array.iter
    (fun (fd, events) ->
      if fd >= 0 then
        match guest_fd fd with
        | None -> ()
        | Some d ->
            if events land poll_in <> 0 && not (List.mem d !read_fds) then
              read_fds := d :: !read_fds;
            if events land poll_out <> 0 && not (List.mem d !write_fds) then
              write_fds := d :: !write_fds)
    entries;
  let timeout =
    if timeout_ms < 0 then -1.0 else float_of_int timeout_ms /. 1000.0
  in
  let select_result =
    if !read_fds = [] && !write_fds = [] then begin
      (* nothing selectable (all entries negative/unknown): a pure
         timeout wait, never an indefinite block on an empty set *)
      if timeout > 0.0 then
        (try ignore (Unix.select [] [] [] timeout)
         with Unix.Unix_error _ -> ());
      Ok ([], [], [])
    end
    else
      try Ok (Unix.select !read_fds !write_fds [] timeout)
      with Unix.Unix_error (e, _, _) -> Error (-errno_of_unix_error e)
  in
  match select_result with
  | Error code -> Ok code
  | Ok (ready_r, ready_w, _) ->
      let ready = ref 0 in
      for i = 0 to nfds - 1 do
        let fd, events = entries.(i) in
        let revents =
          if fd < 0 then 0
          else
            match guest_fd fd with
            | None -> poll_nval
            | Some d ->
                let r = events land poll_in <> 0 && List.mem d ready_r in
                let w = events land poll_out <> 0 && List.mem d ready_w in
                (if r then poll_in else 0) lor (if w then poll_out else 0)
        in
        if revents <> 0 then incr ready;
        Raw_memory.put_u64_le b ((i * 8) + 6) 2 (Int64.of_int revents)
      done;
      if nfds = 0 then Ok !ready
      else (
        match arena_store t p b with
        | Ok () -> Ok !ready
        | Error e -> Error ("poll: " ^ e))

(* ── the stat family (raw_stat/raw_lstat/raw_fstat) ──────────────────
   The kernel's stdout/stat_buffer_size is 160 bytes and its stat_layout
   reads the Darwin stat layout: st_dev@0(u64), st_mode@4(u16),
   st_nlink@6(u16), st_ino@8(u64), st_uid@16(u32), st_gid@20(u32),
   st_rdev@24(u64), st_atime@32(i64), st_mtime@48, st_ctime@64,
   st_birthtime@80, st_blocks@104, st_blksize@112, st_size@96(i64).
   The host fills the same layout from the OCaml Unix stat record. *)
let file_perm_bits (p : Unix.file_perm) : int = Obj.magic p

let mode_kind_bits (k : Unix.file_kind) : int =
  match k with
  | Unix.S_REG -> 0x8000
  | Unix.S_DIR -> 0x4000
  | Unix.S_CHR -> 0x2000
  | Unix.S_BLK -> 0x6000
  | Unix.S_LNK -> 0xA000
  | Unix.S_FIFO -> 0x1000
  | Unix.S_SOCK -> 0xC000

let host_stat_bytes (st : Unix.LargeFile.stats) : Bytes.t =
  let open Unix.LargeFile in
  let b = Bytes.make 160 '\000' in
  let put64 off v = Raw_memory.put_u64_le b off 8 v in
  let put32 off v = Raw_memory.put_u64_le b off 4 (Int64.of_int v) in
  let put16 off v = Raw_memory.put_u64_le b off 2 (Int64.of_int v) in
  let secs (f : float) : int64 = Int64.of_float (Float.trunc f) in
  put64 0 (Int64.of_int st.st_dev);
  put16 4 (mode_kind_bits st.st_kind lor file_perm_bits st.st_perm);
  put16 6 st.st_nlink;
  put64 8 (Int64.of_int st.st_ino);
  put32 16 st.st_uid;
  put32 20 st.st_gid;
  put64 24 (Int64.of_int st.st_rdev);
  put64 32 (secs st.st_atime);
  put64 48 (secs st.st_mtime);
  put64 64 (secs st.st_ctime);
  put64 80 (secs st.st_mtime) (* birthtime: OCaml exposes none; mirror mtime *);
  put64 96 st.st_size;
  put64 104 0L (* st_blocks: not exposed *);
  put64 112 4096L (* st_blksize: not exposed; the conventional page size *);
  b

let host_stat (t : t) (path : string) (kind : [ `Stat | `Lstat ]) :
    (Unix.LargeFile.stats, int) result =
  let real = host_real_path t path ~for_create:false in
  try
    Ok
      (match kind with
       | `Stat -> Unix.LargeFile.stat real
       | `Lstat -> Unix.LargeFile.lstat real)
  with Unix.Unix_error (e, _, _) -> Error (-errno_of_unix_error e)

let host_fstat (fd : int) : (Unix.LargeFile.stats, int) result =
  match guest_fd fd with
  | None -> Error (-errno_badf)
  | Some d -> (
      try Ok (Unix.LargeFile.fstat d)
      with Unix.Unix_error (e, _, _) -> Error (-errno_of_unix_error e))

(* The raw syscall surface (__intrinsic_syscall1..6) ────────────────
   The direct kernel passes the standard library's canonical numbers to
   the target ABI (codegen adds 3 on macOS: read 0->3, write 1->4, open
   2->5, close 3->6, lseek 196->199, chmod 12->15, ...).  The seed host
   performs the same translation and maps the translated BSD operation
   onto the equivalent OCaml Unix primitive — the observable descriptor
   and buffer contract is the runtime's, and the buffer arguments are
   arena pointers.  A number the host has no implementation for is a
   deterministic boundary error (never a fabricated byte count). *)
let host_syscall (t : t) (n : int) (args : int array) : (int, string) result =
  let so = n + 3 in
  let arg i = if i < Array.length args then args.(i) else 0 in
  let ptr i = Vm_memory.pointer_of_int64 (Int64.of_int (arg i)) in
  let path_at i =
    match arena_cstring t (ptr i) with
    | Ok s -> Ok s
    | Error e -> Error (Printf.sprintf "syscall %d: %s" n e)
  in
  match so with
  | 3 -> Ok (host_read_into t (arg 0) (ptr 1) (arg 2))
  | 4 -> Ok (host_write_from t (arg 0) (ptr 1) (arg 2))
  | 5 -> (
      match path_at 0 with
      | Error e -> Error e
      | Ok path -> Ok (host_open t path (arg 1) (arg 2)))
  | 6 -> Ok (host_close_fd (arg 0))
  | 10 -> (
      match path_at 0 with
      | Error e -> Error e
      | Ok path -> (
          try
            Unix.unlink (host_real_path t path ~for_create:false);
            Ok 0
          with Unix.Unix_error (e, _, _) -> Ok (-errno_of_unix_error e)))
  | 12 -> (
      match path_at 0 with
      | Error e -> Error e
      | Ok path -> (
          (* the guest's chdir moves the VIRTUAL cwd (Host_fs), never the
             seed process's own directory *)
          let segs =
            String.split_on_char '/' path |> List.filter (fun s -> s <> "")
          in
          match Host_fs.lexical_resolve t.fs segs with
          | Error _ -> Ok (-2)
          | Ok resolved -> (
              match Host_fs.resolve_existing t.fs segs with
              | Error _ -> Ok (-2)
              | Ok _ ->
                  Host_fs.set_cwd t.fs resolved;
                  Ok 0)))
  | 15 -> (
      match path_at 0 with
      | Error e -> Error e
      | Ok path -> Ok (host_chmod t path (arg 1)))
  | 57 -> (
      match (path_at 0, path_at 1) with
      | Error e, _ | _, Error e -> Error e
      | Ok target, Ok link -> (
          try
            Unix.symlink target (host_real_path t link ~for_create:true);
            Ok 0
          with Unix.Unix_error (e, _, _) -> Ok (-errno_of_unix_error e)))
  | 58 -> (
      match path_at 0 with
      | Error e -> Error e
      | Ok path -> (
          try
            let target = Unix.readlink (host_real_path t path ~for_create:false) in
            let n = min (String.length target) (arg 2) in
            let b = Bytes.of_string (String.sub target 0 n) in
            match arena_store t (ptr 1) b with
            | Ok () -> Ok n
            | Error _ -> Ok (-errno_fault)
          with Unix.Unix_error (e, _, _) -> Ok (-errno_of_unix_error e)))
  | 128 -> (
      match (path_at 0, path_at 1) with
      | Error e, _ | _, Error e -> Error e
      | Ok from_, Ok to_ -> (
          try
            Unix.rename (host_real_path t from_ ~for_create:false)
              (host_real_path t to_ ~for_create:true);
            Ok 0
          with Unix.Unix_error (e, _, _) -> Ok (-errno_of_unix_error e)))
  | 136 -> (
      match path_at 0 with
      | Error e -> Error e
      | Ok path -> (
          try
            Unix.mkdir (host_real_path t path ~for_create:true) (arg 1);
            Ok 0
          with Unix.Unix_error (e, _, _) -> Ok (-errno_of_unix_error e)))
  | 137 -> (
      match path_at 0 with
      | Error e -> Error e
      | Ok path -> (
          try
            Unix.rmdir (host_real_path t path ~for_create:false);
            Ok 0
          with Unix.Unix_error (e, _, _) -> Ok (-errno_of_unix_error e)))
  | 189 | 190 | 191 ->
      (* fstat/lstat/stat (the kernel's SYS_*_MAC values + the codegen
         offset): fill the 160-byte stat buffer at the pointer argument *)
      if so = 189 then (
        match host_fstat (arg 0) with
        | Error code -> Ok code
        | Ok st -> (
            match arena_store t (ptr 1) (host_stat_bytes st) with
            | Ok () -> Ok 0
            | Error _ -> Ok (-errno_fault)))
      else (
        match path_at 0 with
        | Error e -> Error e
        | Ok path -> (
            match host_stat t path (if so = 190 then `Lstat else `Stat) with
            | Error code -> Ok code
            | Ok st -> (
                match arena_store t (ptr 1) (host_stat_bytes st) with
                | Ok () -> Ok 0
                | Error _ -> Ok (-errno_fault))))
  | 199 -> Ok (Int64.to_int (host_lseek (arg 0) (Int64.of_int (arg (1))) (arg 2)))
  | _ ->
      Error
        (Printf.sprintf
           "__intrinsic_syscall: number %d (BSD %d) has no seed host implementation \
            (deterministic boundary trap)"
           n so)

let vm_string (s : string) : Vm_value.t = Vm_value.String s

(* the printed 64-bit value of an Int argument (the host adapters accept
   any integer width the checker's int-kind adoption passes through) *)
let int_arg (v : Vm_value.t) : int =
  match v with
  | Vm_value.Int i -> Int64.to_int (Int_value.to_int64 i)
  | _ -> 0

let float_arg (v : Vm_value.t) : float =
  match v with
  | Vm_value.Float64 bits -> Int64.float_of_bits bits
  | Vm_value.Float32 bits -> Int32.float_of_bits bits
  | Vm_value.Int i -> Int64.to_float (Int_value.to_int64 i)
  | _ -> 0.0

(* the first byte occurrence of `sub` in `s`; the empty needle matches at
   0 (the runtime's _tg_str_find inner-loop contract). *)
let string_find (s : string) (sub : string) : int option =
  let n = String.length s and m = String.length sub in
  if m = 0 then Some 0
  else if m > n then None
  else
    let rec go i =
      if i > n - m then None
      else if String.sub s i m = sub then Some i
      else go (i + 1)
    in
    go 0

(* the owned slice span: start/end clamp into the string (start > end is
   the empty slice — the runtime's negative-span clamp). *)
let string_slice (s : string) (start : int) (stop : int) : string =
  let n = String.length s in
  let start = if start < 0 then 0 else if start > n then n else start in
  let stop = if stop < start then start else if stop > n then n else stop in
  String.sub s start (stop - start)

(* the ASCII decimal integer parse: optional sign, then digits; the
   result is the language's Result[Int, String] (Ok value / Err
   message). *)
let string_parse_int (s : string) : (int64, string) result =
  let n = String.length s in
  let i = ref 0 in
  let neg = ref false in
  if n > 0 && (s.[0] = '+' || s.[0] = '-') then begin
    neg := s.[0] = '-';
    incr i
  end;
  if !i >= n then Error "invalid integer"
  else begin
    let acc = ref 0L in
    let ok = ref true in
    while !ok && !i < n do
      let c = s.[!i] in
      if c >= '0' && c <= '9' then begin
        acc := Int64.add (Int64.mul !acc 10L) (Int64.of_int (Char.code c - 48));
        incr i
      end
      else ok := false
    done;
    if !ok then Ok (if !neg then Int64.neg !acc else !acc)
    else Error "invalid integer"
  end

let string_replace_all (s : string) (from_ : string) (to_ : string) : string =
  if from_ = "" then s
  else begin
    let n = String.length s and m = String.length from_ in
    let b = Buffer.create n in
    let i = ref 0 in
    while !i < n do
      if !i + m <= n && String.sub s !i m = from_ then begin
        Buffer.add_string b to_;
        i := !i + m
      end
      else begin
        Buffer.add_char b s.[!i];
        incr i
      end
    done;
    Buffer.contents b
  end

(* the separator split: non-overlapping matches, the trailing segment
   always present; the empty separator splits into single bytes (the
   runtime's _tg_string_split contract). *)
let string_split (s : string) (sep : string) : string list =
  if sep = "" then List.init (String.length s) (fun i -> String.make 1 s.[i])
  else begin
    let n = String.length s and m = String.length sep in
    let out = ref [] in
    let start = ref 0 in
    let i = ref 0 in
    while !i <= n - m do
      if String.sub s !i m = sep then begin
        out := String.sub s !start (!i - !start) :: !out;
        i := !i + m;
        start := !i
      end
      else incr i
    done;
    out := String.sub s !start (n - !start) :: !out;
    List.rev !out
  end

let string_trim_ascii (s : string) : string =
  let is_ws = function ' ' | '\t' | '\r' | '\n' -> true | _ -> false in
  let n = String.length s in
  let i = ref 0 in
  while !i < n && is_ws s.[!i] do incr i done;
  let j = ref (n - 1) in
  while !j >= !i && is_ws s.[!j] do decr j done;
  String.sub s !i (!j - !i + 1)

let string_trim_matches (s : string) (set : string) : string =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && String.contains set s.[!i] do incr i done;
  let j = ref (n - 1) in
  while !j >= !i && String.contains set s.[!j] do decr j done;
  String.sub s !i (!j - !i + 1)

(* the f64 renderer: sign + integer part + '.' + EXACTLY six truncated
   fraction digits — the runtime's _tg_float_to_str contract. *)
let float_to_string (f : float) : string =
  if f <> f then "nan"
  else if f = infinity then "inf"
  else if f = neg_infinity then "-inf"
  else begin
    let neg = f < 0.0 || (f = 0.0 && 1.0 /. f = neg_infinity) in
    let a = abs_float f in
    let ipf = Int64.of_float a in
    let ip = Int64.to_int ipf in
    let ip = if ip < 0 then 0 else ip in
    let frac = ref (a -. Int64.to_float (Int64.of_int ip)) in
    let b = Buffer.create 32 in
    if neg then Buffer.add_char b '-';
    Buffer.add_string b (string_of_int ip);
    Buffer.add_char b '.';
    for _ = 1 to 6 do
      let d = !frac *. 10.0 in
      let digit = int_of_float d in
      let digit = if digit < 0 then 0 else if digit > 9 then 9 else digit in
      Buffer.add_char b (Char.chr (48 + digit));
      frac := d -. float_of_int digit
    done;
    Buffer.contents b
  end

let int_to_float (i : Int_value.t) : float =
  if i.Int_value.width <= 64 then Int64.to_float (Int_value.to_int64 i)
  else begin
    let hi, lo = Int_value.magnitude_words i in
    let magnitude =
      (Int64.to_float hi *. 18446744073709551616.0) +. Int64.to_float lo
    in
    if Int_value.is_neg i then -.magnitude else magnitude
  end

(* the kernel regex subset: a literal substring search (the runtime's
   _tg_regex_match); the empty pattern matches. *)
let regex_match_subset (text : string) (pattern : string) : bool =
  match string_find text pattern with Some _ -> true | None -> false

(* ── The builtin-method class' value helpers ────────────────────────
   The checker's builtin method tables (Vec/Array/String/Char/Option and
   the integer to_string surface) and the compiler-registered free
   builtins (string_new/from_bytes/from_chars/clone, vec_filled,
   a64_cc_hi) operate directly on the seed's immutable value model.  The
   helpers below mirror the direct kernel's runtime semantics
   (_tg_str_chars byte-per-char, _tg_string_from_bytes raw bytes,
   UTF-8 encoded from_chars, the ASCII predicates); every registry
   declaration is matched by an adapter built from these. *)

(* the integer-kind to_string adapter: the declared width is part of the
   registry signature (u32/u64/... are distinct types), so the adapter
   must declare the EXACT kind — a generic Int-typed adapter would fail
   the adapter/declaration identity check. *)
let adapter_int_kind_ret_string (kind : Type_repr.int_kind) : adapter =
  {
    signature = mk_sig (lets [ Type_repr.Int kind ]) Type_repr.String;
    invoke =
      (fun _ args ->
        match args with
        | [| Vm_value.Int i |] ->
            Ok (plain_result (Vm_value.String (Int_value.to_string i)))
        | _ -> Error "argument mismatch: expected integer");
  }

(* the byte-derived Char value: `chars()`/`char_at` expose the String's
   BYTES as Chars (zero-extended), exactly the native `_tg_str_chars`
   contract. *)
let vm_char_of_byte (b : int) : Vm_value.t =
  Vm_value.Char (Uchar.of_int (b land 0xFF))

(* UTF-8-compose a Vec[Char] into a String (the inverse of the source's
   scalar processing — the native from_chars contract; ASCII chars
   encode to their byte). *)
let vm_string_of_chars (elems : Vm_value.t array) :
    (Vm_value.t, string) result =
  let b = Buffer.create (Array.length elems) in
  let ok = ref true in
  Array.iter
    (fun v ->
      match v with
      | Vm_value.Char c -> Buffer.add_bytes b (Utf8.encode_scalar c)
      | _ -> ok := false)
    elems;
  if !ok then Ok (vm_string (Buffer.contents b))
  else Error "argument mismatch: expected Array[Char]"

(* the raw-byte String constructor (the native _tg_string_from_bytes
   copies the Vec[u8] bytes). *)
let vm_string_of_bytes (elems : Vm_value.t array) :
    (Vm_value.t, string) result =
  let n = Array.length elems in
  let b = Bytes.create n in
  let ok = ref true in
  Array.iteri
    (fun i v ->
      match v with
      | Vm_value.Int i8 ->
          Bytes.set b i
            (Char.chr (Int64.to_int (Int_value.to_int64 i8) land 0xFF))
      | _ -> ok := false)
    elems;
  if !ok then Ok (vm_string (Bytes.to_string b))
  else Error "argument mismatch: expected Array[U8]"

(* the deterministic total order `Vec::sort` uses on the value model: a
   structural ascending order over the scalar/string/aggregate forms.
   None for values with no deterministic order (raw pointers, refs,
   closures) — the adapter then traps instead of inventing one.  The
   direct kernel's native `_tg_array_sort` label exists only as an
   unresolved stub, so this is the seed's own defined sort semantics. *)
let rec vm_sort_compare (a : Vm_value.t) (b : Vm_value.t) : int option =
  match a, b with
  | Vm_value.Int x, Vm_value.Int y -> Some (Int_value.compare_vals x y)
  | Vm_value.Float64 x, Vm_value.Float64 y ->
      Some (compare (Int64.float_of_bits x) (Int64.float_of_bits y))
  | Vm_value.Float32 x, Vm_value.Float32 y ->
      Some (compare (Int32.float_of_bits x) (Int32.float_of_bits y))
  | Vm_value.Bool x, Vm_value.Bool y -> Some (compare x y)
  | Vm_value.Char x, Vm_value.Char y -> Some (Uchar.compare x y)
  | Vm_value.String x, Vm_value.String y -> Some (String.compare x y)
  | Vm_value.Tuple xs, Vm_value.Tuple ys
  | Vm_value.Struct xs, Vm_value.Struct ys
  | Vm_value.Array xs, Vm_value.Array ys ->
      vm_sort_compare_seq (Array.to_list xs) (Array.to_list ys)
  | Vm_value.Enum (i, xs), Vm_value.Enum (j, ys) ->
      if i <> j then Some (compare i j)
      else vm_sort_compare_seq (Array.to_list xs) (Array.to_list ys)
  | _ -> None

and vm_sort_compare_seq (xs : Vm_value.t list) (ys : Vm_value.t list) : int option =
  match xs, ys with
  | [], [] -> Some 0
  | [], _ -> Some (-1)
  | _, [] -> Some 1
  | x :: xr, y :: yr -> (
      match vm_sort_compare x y with
      | None -> None
      | Some 0 -> vm_sort_compare_seq xr yr
      | Some c -> Some c)

(* stable insertion sort over a copy; a comparison failure aborts the
   whole operation BEFORE any writeback (the caller's array is never
   partially rearranged). *)
let vm_sort_elems (elems : Vm_value.t array) :
    (Vm_value.t array, string) result =
  let n = Array.length elems in
  let out = Array.copy elems in
  let ok = ref true in
  let i = ref 1 in
  while !ok && !i < n do
    let v = out.(!i) in
    let j = ref (!i - 1) in
    let stop = ref false in
    while (not !stop) && !j >= 0 do
      match vm_sort_compare out.(!j) v with
      | Some c when c > 0 ->
          out.(!j + 1) <- out.(!j);
          decr j
      | Some _ -> stop := true
      | None ->
          ok := false;
          stop := true
    done;
    if !ok then out.(!j + 1) <- v;
    incr i
  done;
  if !ok then Ok out
  else Error "sort: the element values have no deterministic order"


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
   The collection surface's OWNERSHIP semantics (audit P0-11 / P0-3).
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
     • the element-returning ops (pop, remove, drain_one, map_insert)
       EXTRACT: the element appears in the returned Option/value and
       NOT in the writeback collection and NOT in the writeback's
       `removed` — ownership transfers exactly once;
     • the REPLACEMENT/clear ops (array_set, array_clear, set_clear,
       set_remove's matched element, set-insert-REPLACE's displaced
       element) enumerate the member that left the caller's container
       in the writeback's `removed` list: the writeback is a fresh
       collection sharing ONLY the retained members, and the VM's
       writeback application drops exactly the `removed` values,
       exactly once, after installing the replacement — the old
       container value is dead the moment the writeback lands, and it
       is NEVER dropped as a whole (its retained members are
       structurally shared with the replacement — a whole drop would
       double-destroy them);
     • a FAILED bounds check consumes NOTHING: the check runs before
       any mutation, the adapter returns an error, and no writeback is
       produced (the VM traps on the error);
     • the WRITEBACK channel never duplicates an aggregate: each
       element/key object of the old collection either stays (shared
       into the new collection — single live owner, the old collection
       value is dead the moment its slot was replaced) or leaves with
       the returned value — never both;
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

(* the small-integer to_string surface: one binding per declared width —
   each adapter declares its EXACT integer kind, since the registry
   signatures are kind-specific. *)
let int_to_string_bindings : binding list =
  List.map
    (fun (owner, kind) ->
      intrinsic_binding ("__intrinsic_" ^ owner ^ "_to_string")
        (adapter_int_kind_ret_string kind))
    [
      ("i8", Type_repr.I8);
      ("i16", Type_repr.I16);
      ("i32", Type_repr.I32);
      ("i64", Type_repr.I64);
      ("i128", Type_repr.I128);
      ("u8", Type_repr.U8);
      ("u16", Type_repr.U16);
      ("u32", Type_repr.U32);
      ("u64", Type_repr.U64);
      ("u128", Type_repr.U128);
    ]

(* ── The record-visit traversal surface (std/collections.tg) ──────────
   The five `__intrinsic_{map,set}_visit_{begin,next,value}` declarations
   are the checker's internal address/reference ABI (the only `&T` /
   `Option[&K]` positions in the tree; docs/current/language.md §Types,
   memory_model.md §The Access Marker).  The direct kernel implements
   them as the NON-DESTRUCTIVE record walk (tg_compiler/runtime.tg
   emit_tg_map_visit_* family): begin yields the address of the first LIVE
   entry's key, next(m, key_addr) yields the address of the entry after
   the one the cursor names, value(m, key_addr) projects the value
   address from the key address, and Set is the Map[T, Unit] alias of
   the same walk.

   THE SEED PROTOCOL (the value model has no addresses): a borrowed read
   of a live entry IS the entry's own value object — Vm_value trees are
   immutable, so the adapter returning the stored subtree is a read,
   never a copy, and the VM's Copy/Read operands both evaluate to the
   SAME object (vm.ml eval_operand).  The visit handle is therefore the
   entry's borrowed KEY (Map) / ELEMENT (Set); the entry INDEX is
   recovered by PHYSICAL identity (`==`) of the stored object, which is
   exact because the consumer passes back the very subtree begin/next
   returned.  A structural lookup_eq fallback covers a handle that
   reached the adapter through an equal-but-distinct value; like every
   other host containment decision it refuses resource carriers
   (fail-closed).  The consumer's `key_ref.clone()` and the opaque
   `key_ref: K` parameters read the borrowed value exactly as the direct
   kernel reads through the projected address (the checker's deref-first
   call boundary and Mir_verify.deref_arg_ok document the same shape).

   MUTATION DURING ITERATION mirrors the direct kernel's contract: the
   walk is a pure non-destructive read — it never mutates, never
   unlinks, never produces writebacks; every call resolves the CURRENT
   collection value it is handed, and a handle whose entry no longer
   exists terminates the walk with None (deterministic, fail-closed —
   never a fabricated successor; the direct kernel's behavior under
   mutation is implementation-defined, exactly like the raw entries
   snapshot). *)

let vm_option_none : Vm_value.t = Vm_value.Enum (1, [||])
let vm_option_some (v : Vm_value.t) : Vm_value.t = Vm_value.Enum (0, [| v |])

(* the map entry a visit handle names: physical identity of the stored
   key first (the adapter's own returned object), then the structural
   lookup_eq fallback.  Returns the pair and the pairs AFTER it. *)
let rec map_visit_pair_phys (handle : Vm_value.t)
    (pairs : (Vm_value.t * Vm_value.t) list) :
    ((Vm_value.t * Vm_value.t) * (Vm_value.t * Vm_value.t) list) option =
  match pairs with
  | [] -> None
  | ((k, _) as pair) :: rest ->
      if k == handle then Some (pair, rest) else map_visit_pair_phys handle rest

let rec map_visit_pair_eq (handle : Vm_value.t)
    (pairs : (Vm_value.t * Vm_value.t) list) :
    ((Vm_value.t * Vm_value.t) * (Vm_value.t * Vm_value.t) list) option =
  match pairs with
  | [] -> None
  | ((k, _) as pair) :: rest ->
      if lookup_eq k handle then Some (pair, rest) else map_visit_pair_eq handle rest

let map_visit_pair (pairs : (Vm_value.t * Vm_value.t) list) (handle : Vm_value.t) :
    ((Vm_value.t * Vm_value.t) * (Vm_value.t * Vm_value.t) list) option =
  match map_visit_pair_phys handle pairs with
  | Some r -> Some r
  | None -> map_visit_pair_eq handle pairs

(* the set element a visit handle names: physical identity, then the
   structural lookup_eq fallback (same policy as the map side). *)
let rec set_visit_phys (handle : Vm_value.t) (elems : Vm_value.t list) :
    Vm_value.t list option =
  match elems with
  | [] -> None
  | x :: rest -> if x == handle then Some rest else set_visit_phys handle rest

let rec set_visit_eq (handle : Vm_value.t) (elems : Vm_value.t list) :
    Vm_value.t list option =
  match elems with
  | [] -> None
  | x :: rest -> if lookup_eq x handle then Some rest else set_visit_eq handle rest

let set_visit_after (elems : Vm_value.t list) (handle : Vm_value.t) :
    Vm_value.t list option =
  match set_visit_phys handle elems with
  | Some r -> Some r
  | None -> set_visit_eq handle elems

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
              REMOVED element leaves the caller's container exactly
              once — it appears in no live value after the call (not
              in the writeback, not in the return) and is enumerated
              in the writeback's `removed` list so the VM's writeback
              application drops it exactly once (audit P0-3).  An
              element is only ever removed when lookup_eq matched it —
              no removal decision is made through equality on resource
              carriers. *)
           match args with
           | [| Vm_value.Set elems; item |] ->
               let rec remove acc = function
                 | [] -> (None, List.rev acc)
                 | x :: rest when lookup_eq x item ->
                     (Some x, List.rev_append acc rest)
                 | x :: rest -> remove (x :: acc) rest
               in
               let removed_el, new_elems = remove [] elems in
               let removed = match removed_el with Some x -> [ x ] | None -> [] in
               Ok
                 { value = Vm_value.Bool (removed_el <> None);
                   writebacks =
                     [ { arg_index = 0; replacement = Vm_value.Set new_elems;
                         removed } ] }
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
              stored element is REPLACED by the incoming item — the
              displaced old element leaves the caller's container
              exactly once: it is in no live value afterward (not the
              writeback, not the return) and is enumerated in the
              writeback's `removed` list so the VM's writeback
              application drops it exactly once (audit P0-3).  The
              language value is the presence Bool: `true` when the key
              already existed (its slot was replaced), `false` when a
              fresh slot was created. *)
           match args with
           | [| Vm_value.Set elems; item |] ->
               let rec insert acc = function
                 | [] -> (false, [], List.rev_append acc [ item ])
                 | x :: rest when lookup_eq x item ->
                     (true, [ x ], List.rev_append acc (item :: rest))
                 | x :: rest -> insert (x :: acc) rest
               in
               let existed, displaced, new_elems = insert [] elems in
               Ok
                 { value = Vm_value.Bool existed;
                   writebacks =
                     [ { arg_index = 0; replacement = Vm_value.Set new_elems;
                         removed = displaced } ] }
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
              deterministic pick).  Element ownership TRANSFERS to the
              caller exactly once: the extracted element appears ONLY
              in the returned Option — it is in neither the writeback
              replacement nor the writeback's `removed` list (audit
              P0-3). *)
           match args with
           | [| Vm_value.Set elems |] -> (
               match elems with
               | [] ->
                   Ok
                     { value = Vm_value.Enum (1, [||]);
                       writebacks =
                         [ { arg_index = 0; replacement = Vm_value.Set [];
                             removed = [] } ] }
               | x :: rest ->
                   Ok
                     { value = Vm_value.Enum (0, [| x |]);
                       writebacks =
                         [ { arg_index = 0; replacement = Vm_value.Set rest;
                             removed = [] } ] })
           | _ -> Error "argument mismatch: expected (Set)"));
    intrinsic_binding "__intrinsic_set_clear"
      (adapter_raw_wb [ (Access_effect.Inout, set_of p0) ] Type_repr.Unit (fun _ args ->
           (* every prior member leaves the caller's container exactly
              once: the writeback is empty and every old element is
              enumerated in the writeback's `removed` list — the VM's
              writeback application drops each exactly once (audit
              P0-3) *)
           match args with
           | [| Vm_value.Set elems |] ->
               Ok
                 { value = Vm_value.Unit;
                   writebacks =
                     [ { arg_index = 0; replacement = Vm_value.Set [];
                         removed = elems } ] }
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
          (* the exact Tangerine contract (audit P0-B / P0-11 /
             P0-3): the language value is Option[old V] — the displaced
             old value, returned OWNED (it appears in no live value but
             the Option) — and the mutation travels through the
             explicit writeback channel.  The sink key and sink value
             arrive MOVED and are TAKEN by the adapter (never copied):
             • key ABSENT: both the incoming key and the incoming
               value become the stored pair;
             • key PRESENT (first lookup_eq match): the STORED key is
               PRESERVED (the map keeps its key identity — the
               incoming sink key is consumed by the call and stored
               nowhere), the incoming sink VALUE becomes the stored
               value, and the OLD value is relinquished into the
               returned Option exactly once — it is the language value
               and is therefore NEVER in the writeback's `removed` list
               (audit P0-3: a value transferred to the return must not
               be dropped by the writeback application).  The writeback
               is a fresh pair list sharing only the retained
               pairs/keys; nothing left the caller's container except
               the returned old value, so `removed` is empty on both
               paths (a replacement can only match a key that
               lookup_eq found equal, and lookup_eq refuses resource
               carriers — the discarded sink key can never own a
               drop). *)
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
                      writebacks =
                        [ { arg_index = 0; replacement = Vm_value.Map new_pairs;
                            removed = [] } ] }
              | None ->
                  Ok
                    { value = Vm_value.Enum (1, [||]);
                      writebacks =
                        [ { arg_index = 0;
                            replacement = Vm_value.Map (pairs @ [ (key, value) ]);
                            removed = [] } ] })
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
       traps).  Ownership (audit P0-11 / P0-3): the sink item of
       push/set/insert arrives MOVED and is TAKEN — the exact value
       object becomes the stored element; the displaced element of set
       and the cleared members are enumerated in the writeback's
       `removed` list (the VM drops each exactly once — the old array
       value itself is never dropped: its retained members are
       structurally shared with the replacement, so a whole drop would
       double-destroy them); pop/remove EXTRACT the element into the
       return so it leaves the collection exactly once and is never in
       `removed`; a failed bounds check consumes NOTHING (error before
       any writeback). *)
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
                   writebacks =
                     [ { arg_index = 0;
                         replacement =
                           Vm_value.Array (Array.append elems [| item |]);
                         removed = [] } ] }
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
              sharing the remaining elements) never contains it and
              the writeback's `removed` list never lists it (audit
              P0-3). *)
           match args with
           | [| Vm_value.Array elems |] ->
               let n = Array.length elems in
               if n = 0 then
                 Ok
                   { value = Vm_value.Enum (1, [||]);
                     writebacks =
                       [ { arg_index = 0; replacement = Vm_value.Array elems;
                           removed = [] } ] }
               else
                 Ok
                   { value = Vm_value.Enum (0, [| elems.(n - 1) |]);
                     writebacks =
                       [ { arg_index = 0;
                           replacement =
                             Vm_value.Array (Array.sub elems 0 (n - 1));
                           removed = [] } ] }
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
          (* ownership semantics (audit P0-3): the bounds check runs
             FIRST — a failed check consumes NOTHING (an error, no
             writeback).  On success the sink value arrives MOVED and
             is TAKEN — the exact value object becomes the stored
             element at the index — and the OLD element is enumerated
             in the writeback's `removed` list so the VM's writeback
             application drops it exactly once.  The writeback array is
             a shallow copy sharing ONLY the retained elements: the old
             array value is dead the moment the writeback lands and is
             never dropped as a whole — a whole drop would
             double-destroy the retained elements it shares with the
             replacement (the exact leak/double-drop the removed
             channel closes). *)
          match args with
          | [| Vm_value.Array elems; Vm_value.Int i; value |] ->
              let idx = Int64.to_int (Int_value.to_int64 i) in
              if idx < 0 || idx >= Array.length elems then
                Error
                  (Printf.sprintf
                     "__intrinsic_array_set: index %d out of bounds (len %d)" idx
                     (Array.length elems))
              else begin
                let old = elems.(idx) in
                let new_elems = Array.copy elems in
                new_elems.(idx) <- value;
                Ok
                  { value = Vm_value.Unit;
                    writebacks =
                      [ { arg_index = 0; replacement = Vm_value.Array new_elems;
                          removed = [ old ] } ] }
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
              retained prefix/suffix and the writeback's `removed`
              list never lists it (audit P0-3).  The bounds check runs
              FIRST — a failed check consumes NOTHING. *)
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
                       [ { arg_index = 0;
                           replacement =
                             Vm_value.Array
                               (Array.append (Array.sub elems 0 idx)
                                  (Array.sub elems (idx + 1) (n - idx - 1)));
                           removed = [] } ] }
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
             retained elements (nothing left the container — the
             writeback's `removed` list is empty). *)
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
                      [ { arg_index = 0;
                          replacement =
                            Vm_value.Array
                              (Array.append (Array.sub elems 0 idx)
                                 (Array.append [| item |]
                                    (Array.sub elems idx (n - idx))));
                          removed = [] } ] }
          | _ -> Error "argument mismatch: expected (Array, Int, item)"));
    intrinsic_binding "__intrinsic_array_clear"
      (adapter_raw_wb [ (Access_effect.Inout, vec_of p0) ] Type_repr.Unit (fun _ args ->
           (* every prior member leaves the caller's container exactly
              once: the writeback is empty and every old element is
              enumerated in the writeback's `removed` list — the VM's
              writeback application drops each exactly once (audit
              P0-3) *)
           match args with
           | [| Vm_value.Array elems |] ->
               Ok
                 { value = Vm_value.Unit;
                   writebacks =
                     [ { arg_index = 0; replacement = Vm_value.Array [||];
                         removed = Array.to_list elems } ] }
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
    (* str::to_string (std/core.tg:240) — the owned String from the
       borrowed `str` view.  On the seed value model `str` and String
       are the ONE String value (`Type_repr.String` /
       `Vm_value.String`), so the owned conversion is the identity; the
       value is immutable, so the conversion can never alias a mutable
       buffer. *)
    intrinsic_binding "__intrinsic_str_to_string"
      (adapter_raw (lets [ Type_repr.String ]) Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.String _ as s |] -> Ok s
           | _ -> arg_mismatch "String"));
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
    (* ── The called kernel wrapper surface (audit §70; std/core.tg,
       std/alloc.tg, std/collections.tg, std/taint.tg declarations).
       Every wrapper below carries a REAL executable adapter on the
       seed's value model, implementing the same observable semantics as
       the native runtime helpers (_tg_string_* / _tg_str_* /
       _tg_regex_match / _tg_float_to_str); where the seed host has no
       executable semantics (raw memory, raw syscalls, VM function-value
       invocation, unwinding) the adapter is the honest deterministic
       trap — never a fabricated value. *)

    (* the borrowed `str` view (str and String are the ONE String value
       on the seed's value model). *)
    intrinsic_binding "__intrinsic_str_len"
      (adapter_string_ret_int (fun _ s ->
           Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (String.length s))));
    intrinsic_binding "__intrinsic_str_find"
      (adapter_raw (lets [ Type_repr.String; Type_repr.String ]) (option_of ty_int)
         (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.String sub |] -> (
               match string_find s sub with
               | Some i -> Ok (Vm_value.Enum (0, [| vm_int i |]))
               | None -> Ok (Vm_value.Enum (1, [||])))
           | _ -> arg_mismatch "(String, String)"));
    intrinsic_binding "__intrinsic_str_slice"
      (adapter_raw
         (lets [ Type_repr.String; ty_int; ty_int ])
         Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.Int a; Vm_value.Int b |] ->
               Ok
                 (vm_string
                    (string_slice s (Int64.to_int (Int_value.to_int64 a))
                       (Int64.to_int (Int_value.to_int64 b))))
           | _ -> arg_mismatch "(String, Int, Int)"));
    intrinsic_binding "__intrinsic_str_parse_int"
      (adapter_raw (lets [ Type_repr.String ]) (result_of ty_int Type_repr.String)
         (fun _ args ->
           match args with
           | [| Vm_value.String s |] -> (
               match string_parse_int s with
               | Ok i ->
                   Ok
                     (Vm_value.Enum
                        ( 0,
                          [| Vm_value.Int
                               (Int_value.of_int64 ~width:64 ~signed:true i) |] ))
               | Error m -> Ok (Vm_value.Enum (1, [| vm_string m |])))
           | _ -> arg_mismatch "String"));
    intrinsic_binding "__intrinsic_string_as_str"
      (adapter_raw (lets [ Type_repr.String ]) Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.String _ as s |] -> Ok s
           | _ -> arg_mismatch "String"));
    intrinsic_binding "__intrinsic_string_from_static"
      (adapter_raw (lets [ Type_repr.String ]) Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.String _ as s |] -> Ok s
           | _ -> arg_mismatch "String"));
    intrinsic_binding "__intrinsic_string_find"
      (adapter_raw (lets [ Type_repr.String; Type_repr.String ]) (option_of ty_int)
         (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.String sub |] -> (
               match string_find s sub with
               | Some i -> Ok (Vm_value.Enum (0, [| vm_int i |]))
               | None -> Ok (Vm_value.Enum (1, [||])))
           | _ -> arg_mismatch "(String, String)"));
    intrinsic_binding "__intrinsic_string_slice"
      (adapter_raw
         (lets [ Type_repr.String; ty_int; ty_int ])
         Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.Int a; Vm_value.Int b |] ->
               Ok
                 (vm_string
                    (string_slice s (Int64.to_int (Int_value.to_int64 a))
                       (Int64.to_int (Int_value.to_int64 b))))
           | _ -> arg_mismatch "(String, Int, Int)"));
    intrinsic_binding "__intrinsic_string_parse_int"
      (adapter_raw (lets [ Type_repr.String ]) (result_of ty_int Type_repr.String)
         (fun _ args ->
           match args with
           | [| Vm_value.String s |] -> (
               match string_parse_int s with
               | Ok i ->
                   Ok
                     (Vm_value.Enum
                        ( 0,
                          [| Vm_value.Int
                               (Int_value.of_int64 ~width:64 ~signed:true i) |] ))
               | Error m -> Ok (Vm_value.Enum (1, [| vm_string m |])))
           | _ -> arg_mismatch "String"));
    intrinsic_binding "__intrinsic_string_parse_float"
      (adapter_raw (lets [ Type_repr.String ]) (option_of Intrinsic_registry.ty_float)
         (fun _ args ->
           match args with
           | [| Vm_value.String s |] -> (
               match float_of_string_opt s with
               | Some f ->
                   Ok
                     (Vm_value.Enum
                        (0, [| Vm_value.Float64 (Int64.bits_of_float f) |]))
               | None -> Ok (Vm_value.Enum (1, [||])))
           | _ -> arg_mismatch "String"));
    intrinsic_binding "__intrinsic_string_reserve"
      (adapter_raw
         [ (Access_effect.Inout, Type_repr.String); (Access_effect.Let, ty_int) ]
         Type_repr.Unit (fun _ args ->
           (* the capacity hint is advisory on the immutable value
              model: len == capacity always, so the reserve is the
              documented no-op (nothing is consumed or written) *)
           match args with
           | [| Vm_value.String _; Vm_value.Int _ |] -> Ok Vm_value.Unit
           | _ -> arg_mismatch "(String, Int)"));
    intrinsic_binding "__intrinsic_string_push"
      (adapter_raw_wb
         [ (Access_effect.Inout, Type_repr.String); (Access_effect.Let, ty_char) ]
         Type_repr.Unit (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.Char c |] ->
               let ch = Bytes.to_string (Utf8.encode_scalar c) in
               Ok
                 { value = Vm_value.Unit;
                   writebacks =
                     [ { arg_index = 0; replacement = vm_string (s ^ ch);
                         removed = [] } ] }
           | _ -> Error "argument mismatch: expected (String, Char)"));
    intrinsic_binding "__intrinsic_string_push_str"
      (adapter_raw_wb
         [ (Access_effect.Inout, Type_repr.String); (Access_effect.Let, Type_repr.String) ]
         Type_repr.Unit (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.String other |] ->
               Ok
                 { value = Vm_value.Unit;
                   writebacks =
                     [ { arg_index = 0; replacement = vm_string (s ^ other);
                         removed = [] } ] }
           | _ -> Error "argument mismatch: expected (String, String)"));
    intrinsic_binding "__intrinsic_string_replace"
      (adapter_raw
         (lets [ Type_repr.String; Type_repr.String; Type_repr.String ])
         Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.String from_; Vm_value.String to_ |] ->
               Ok (vm_string (string_replace_all s from_ to_))
           | _ -> arg_mismatch "(String, String, String)"));
    intrinsic_binding "__intrinsic_string_trim"
      (adapter_raw (lets [ Type_repr.String ]) Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.String s |] -> Ok (vm_string (string_trim_ascii s))
           | _ -> arg_mismatch "String"));
    intrinsic_binding "__intrinsic_string_trim_matches"
      (adapter_raw (lets [ Type_repr.String; Type_repr.String ]) Type_repr.String
         (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.String set |] ->
               Ok (vm_string (string_trim_matches s set))
           | _ -> arg_mismatch "(String, String)"));
    intrinsic_binding "__intrinsic_string_to_lowercase"
      (adapter_raw (lets [ Type_repr.String ]) Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.String s |] -> Ok (vm_string (String.lowercase_ascii s))
           | _ -> arg_mismatch "String"));
    intrinsic_binding "__intrinsic_string_to_uppercase"
      (adapter_raw (lets [ Type_repr.String ]) Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.String s |] -> Ok (vm_string (String.uppercase_ascii s))
           | _ -> arg_mismatch "String"));
    intrinsic_binding "__intrinsic_string_split"
      (adapter_raw (lets [ Type_repr.String; Type_repr.String ]) (vec_of ty_string)
         (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.String sep |] ->
               Ok
                 (Vm_value.Array
                    (Array.of_list
                       (List.map vm_string (string_split s sep))))
           | _ -> arg_mismatch "(String, String)"));
    intrinsic_binding "__intrinsic_string_lines"
      (adapter_raw (lets [ Type_repr.String ]) (vec_of ty_string) (fun _ args ->
           match args with
           | [| Vm_value.String s |] ->
               Ok
                 (Vm_value.Array
                    (Array.of_list
                       (List.map vm_string (string_split s "\n"))))
           | _ -> arg_mismatch "String"));
    intrinsic_binding "__intrinsic_string_as_bytes"
      (adapter_raw (lets [ Type_repr.String ]) (vec_of Intrinsic_registry.ty_u8)
         (fun _ args ->
           match args with
           | [| Vm_value.String s |] ->
               Ok
                 (Vm_value.Array
                    (Array.init (String.length s) (fun i ->
                         Vm_value.Int
                           (Int_value.of_int64 ~width:8 ~signed:false
                              (Int64.of_int (Char.code s.[i]))))))
           | _ -> arg_mismatch "String"));
    (* The raw-pointer wrappers: materialize the value's bytes as a stable
       Raw arena region and hand the guest its (region, offset) handle.
       The String view is a BORROWED C-string image (the bytes + a NUL):
       the value model never transfers String ownership through a raw
       pointer, and the region stays live for the VM run (the arena owns
       it, exactly like the direct kernel's String buffer outlives the
       borrow). *)
    intrinsic_binding "__intrinsic_string_as_ptr"
      (adapter_raw (lets [ Type_repr.String ]) (ptr_named Intrinsic_registry.ty_u8)
         (fun t args ->
           match args with
           | [| Vm_value.String s |] ->
               let n = String.length s in
               (match arena_alloc t (n + 1) 1 with
                | Error e -> Error e
                | Ok p ->
                    let full = Bytes.make (n + 1) '\000' in
                    Bytes.blit_string s 0 full 0 n;
                    (match arena_store t p full with
                     | Ok () -> Ok (Vm_value.RawPtr p)
                     | Error e -> Error e))
           | _ -> arg_mismatch "String"));
    (* ── the Float conversion/formatting surface. *)
    intrinsic_binding "__intrinsic_float_to_string"
      (adapter_raw (lets [ Intrinsic_registry.ty_float ]) Type_repr.String
         (fun _ args ->
           match args with
           | [| (Vm_value.Float64 _ | Vm_value.Float32 _) as f |] ->
               Ok (vm_string (float_to_string (float_arg f)))
           | _ -> arg_mismatch "Float"));
    intrinsic_binding "__intrinsic_float_to_bits"
      (adapter_raw (lets [ Intrinsic_registry.ty_float ]) ty_u64 (fun _ args ->
           match args with
           | [| f |] when (match f with Vm_value.Float64 _ | Vm_value.Float32 _ -> true | _ -> false) ->
               let bits =
                 match f with
                 | Vm_value.Float64 b -> b
                 | Vm_value.Float32 b ->
                     Int64.logand (Int64.of_int32 b) 0xFFFFFFFFL
                 | _ -> 0L
               in
               Ok (Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:false bits))
           | _ -> arg_mismatch "Float"));
    intrinsic_binding "__intrinsic_int_to_float"
      (adapter_raw (lets [ ty_int ]) Intrinsic_registry.ty_float (fun _ args ->
           match args with
           | [| Vm_value.Int i |] ->
               Ok (Vm_value.Float64 (Int64.bits_of_float (int_to_float i)))
           | _ -> arg_mismatch "Int"));
    intrinsic_binding "__intrinsic_float_to_int"
      (adapter_raw (lets [ Intrinsic_registry.ty_float ]) ty_int (fun _ args ->
           match args with
           | [| f |] when (match f with Vm_value.Float64 _ | Vm_value.Float32 _ -> true | _ -> false) ->
               Ok
                 (Vm_value.Int
                    (Int_value.of_int64 ~width:64 ~signed:true
                       (Int64.of_float (float_arg f))))
           | _ -> arg_mismatch "Float"));
    intrinsic_binding "__intrinsic_pow"
      (adapter_raw (lets [ Intrinsic_registry.ty_float; Intrinsic_registry.ty_float ])
         Intrinsic_registry.ty_float (fun _ args ->
           match args with
           | [| a; b |] -> Ok (Vm_value.Float64 (Int64.bits_of_float (float_arg a ** float_arg b)))
           | _ -> arg_mismatch "(Float, Float)"));
    intrinsic_binding "__intrinsic_exp"
      (adapter_raw (lets [ Intrinsic_registry.ty_float ]) Intrinsic_registry.ty_float
         (fun _ args ->
           match args with
           | [| x |] -> Ok (Vm_value.Float64 (Int64.bits_of_float (exp (float_arg x))))
           | _ -> arg_mismatch "Float"));
    (* ── the growable-array family's remaining operations. *)
    intrinsic_binding "__intrinsic_array_destroy"
      (adapter_raw_wb [ (Access_effect.Inout, vec_of p0) ] Type_repr.Unit
         (fun _ args ->
           (* every member leaves the container exactly once: the
              writeback is empty and every old element is enumerated in
              `removed` so the VM drops each exactly once (P0-3) *)
           match args with
           | [| Vm_value.Array elems |] ->
               Ok
                 { value = Vm_value.Unit;
                   writebacks =
                     [ { arg_index = 0; replacement = Vm_value.Array [||];
                         removed = Array.to_list elems } ] }
           | _ -> Error "argument mismatch: expected (Array)"));
    intrinsic_binding "__intrinsic_array_extend"
      (adapter_raw_wb
         [ (Access_effect.Inout, vec_of p0); (Access_effect.Let, vec_of p0) ]
         Type_repr.Unit (fun _ args ->
           (* append the borrowed other's elements; the replacement
              shares only retained members (nothing left the caller's
              container, so `removed` is empty) *)
           match args with
           | [| Vm_value.Array elems; Vm_value.Array other |] ->
               Ok
                 { value = Vm_value.Unit;
                   writebacks =
                     [ { arg_index = 0;
                         replacement = Vm_value.Array (Array.append elems other);
                         removed = [] } ] }
           | _ -> Error "argument mismatch: expected (Array, Array)"));
    intrinsic_binding "__intrinsic_array_from_list"
      (adapter_raw (lets [ vec_of p0 ]) (vec_of p0) (fun _ args ->
           match args with
           | [| Vm_value.Array _ as a |] -> Ok a
           | _ -> arg_mismatch "Array"));
    intrinsic_binding "__intrinsic_array_slice"
      (adapter_raw (lets [ vec_of p0; ty_int; ty_int ]) (vec_of p0)
         (fun _ args ->
           match args with
           | [| Vm_value.Array elems; Vm_value.Int a; Vm_value.Int b |] ->
               let n = Array.length elems in
               let start = Int64.to_int (Int_value.to_int64 a) in
               let stop = Int64.to_int (Int_value.to_int64 b) in
               let start = if start < 0 then 0 else if start > n then n else start in
               let stop = if stop < start then start else if stop > n then n else stop in
               Ok (Vm_value.Array (Array.sub elems start (stop - start)))
           | _ -> arg_mismatch "(Array, Int, Int)"));
    (* The collection views: every element's scalar raw image is packed
       at its stride into a fresh Raw region; the region is LINKED to the
       element array so every later byte write through the returned
       pointer (a libc_read fill, a ptr_write, a VM Deref store) mirrors
       into the guest's own Vec value.  A non-scalar element image has no
       flat layout in the value model; the adapter reports that boundary
       deterministically. *)
    intrinsic_binding "__intrinsic_array_as_ptr"
      (adapter_raw (lets [ vec_of p0 ]) (ptr_named p0) (fun t args ->
           match args with
           | [| Vm_value.Array elems |] -> (
               match array_raw_image elems with
               | Error e -> Error ("__intrinsic_array_as_ptr: " ^ e)
               | Ok img ->
                   (match arena_alloc t (max 1 (Bytes.length img)) 8 with
                    | Error e -> Error e
                    | Ok p ->
                        (match arena_store t p img with
                         | Error e -> Error e
                         | Ok () ->
                             array_link_register t p elems;
                             Ok (Vm_value.RawPtr p))))
           | _ -> arg_mismatch "(Array)"));
    intrinsic_binding "__intrinsic_array_as_mut_ptr"
      (adapter_raw [ (Access_effect.Inout, vec_of p0) ] (ptrmut_named p0)
         (fun t args ->
           match args with
           | [| Vm_value.Array elems |] -> (
               match array_raw_image elems with
               | Error e -> Error ("__intrinsic_array_as_mut_ptr: " ^ e)
               | Ok img ->
                   (match arena_alloc t (max 1 (Bytes.length img)) 8 with
                    | Error e -> Error e
                    | Ok p ->
                        (match arena_store t p img with
                         | Error e -> Error e
                         | Ok () ->
                             array_link_register t p elems;
                             Ok (Vm_value.RawPtr p))))
           | _ -> arg_mismatch "(Array)"));
    (* ── the Map removal/drain/destroy surface. *)
    intrinsic_binding "__intrinsic_map_remove"
      (adapter_raw_wb
         [ (Access_effect.Inout, map_of p0 p1); (Access_effect.Let, p0) ]
         (option_of p1) (fun _ args ->
           match args with
           | [| Vm_value.Map pairs; key |] ->
               let rec go acc = function
                 | [] -> (None, List.rev acc)
                 | (k, v) :: rest when lookup_eq k key ->
                     (Some (k, v), List.rev_append acc rest)
                 | pair :: rest -> go (pair :: acc) rest
               in
               let found, new_pairs = go [] pairs in
               (match found with
                | Some (k, v) ->
                    (* the old value transfers to the Option return; the
                       discarded stored key leaves the container and is
                       enumerated in `removed` for the single drop *)
                    Ok
                      { value = Vm_value.Enum (0, [| v |]);
                        writebacks =
                          [ { arg_index = 0; replacement = Vm_value.Map new_pairs;
                              removed = [ k ] } ] }
                | None ->
                    Ok
                      { value = Vm_value.Enum (1, [||]);
                        writebacks =
                          [ { arg_index = 0; replacement = Vm_value.Map pairs;
                              removed = [] } ] })
           | _ -> Error "argument mismatch: expected (Map, key)"));
    intrinsic_binding "__intrinsic_map_clear"
      (adapter_raw_wb [ (Access_effect.Inout, map_of p0 p1) ] Type_repr.Unit
         (fun _ args ->
           match args with
           | [| Vm_value.Map pairs |] ->
               Ok
                 { value = Vm_value.Unit;
                   writebacks =
                     [ { arg_index = 0; replacement = Vm_value.Map [];
                         removed =
                           List.concat_map (fun (k, v) -> [ k; v ]) pairs } ] }
           | _ -> Error "argument mismatch: expected (Map)"));
    intrinsic_binding "__intrinsic_map_drain_one"
      (adapter_raw_wb [ (Access_effect.Inout, map_of p0 p1) ]
         (option_of (tuple_of [| p0; p1 |])) (fun _ args ->
           (* the head pair transfers OWNED into the Option tuple return;
              it is never in the writeback's `removed` list (P0-3) *)
           match args with
           | [| Vm_value.Map pairs |] -> (
               match pairs with
               | [] ->
                   Ok
                     { value = Vm_value.Enum (1, [||]);
                       writebacks =
                         [ { arg_index = 0; replacement = Vm_value.Map [];
                             removed = [] } ] }
               | (k, v) :: rest ->
                   Ok
                     { value = Vm_value.Enum (0, [| Vm_value.Tuple [| k; v |] |]);
                       writebacks =
                         [ { arg_index = 0; replacement = Vm_value.Map rest;
                             removed = [] } ] })
           | _ -> Error "argument mismatch: expected (Map)"));
    intrinsic_binding "__intrinsic_map_destroy"
      (adapter_raw_wb [ (Access_effect.Inout, map_of p0 p1) ] Type_repr.Unit
         (fun _ args ->
           match args with
           | [| Vm_value.Map pairs |] ->
               Ok
                 { value = Vm_value.Unit;
                   writebacks =
                     [ { arg_index = 0; replacement = Vm_value.Map [];
                         removed =
                           List.concat_map (fun (k, v) -> [ k; v ]) pairs } ] }
           | _ -> Error "argument mismatch: expected (Map)"));
    intrinsic_binding "__intrinsic_set_destroy"
      (adapter_raw_wb [ (Access_effect.Inout, set_of p0) ] Type_repr.Unit
         (fun _ args ->
           match args with
           | [| Vm_value.Set elems |] ->
               Ok
                 { value = Vm_value.Unit;
                   writebacks =
                     [ { arg_index = 0; replacement = Vm_value.Set [];
                         removed = elems } ] }
           | _ -> Error "argument mismatch: expected (Set)"));
    (* ── the record-visit traversal (see the protocol note above): pure
       non-destructive reads; begin -> Some(first key/element) or None;
       next -> Some(the entry after the handle) or None at the end;
       value -> the borrowed value of the pair the handle names. *)
    intrinsic_binding "__intrinsic_map_visit_begin"
      (adapter_raw (lets [ map_of p0 p1 ]) (option_of (ref_ p0))
         (fun _ args ->
           match args with
           | [| Vm_value.Map pairs |] -> (
               match pairs with
               | [] -> Ok vm_option_none
               | (k, _) :: _ -> Ok (vm_option_some k))
           | _ -> arg_mismatch "Map"));
    intrinsic_binding "__intrinsic_map_visit_next"
      (adapter_raw (lets [ map_of p0 p1; p0 ]) (option_of (ref_ p0))
         (fun _ args ->
           match args with
           | [| Vm_value.Map pairs; handle |] -> (
               match map_visit_pair pairs handle with
               | Some (_, (k, _) :: _) -> Ok (vm_option_some k)
               | Some (_, []) | None -> Ok vm_option_none)
           | _ -> arg_mismatch "(Map, key)"));
    intrinsic_binding "__intrinsic_map_visit_value"
      (adapter_raw (lets [ map_of p0 p1; p0 ]) (ref_ p1)
         (fun _ args ->
           match args with
           | [| Vm_value.Map pairs; handle |] -> (
               match map_visit_pair pairs handle with
               | Some ((_, v), _) -> Ok v
               | None ->
                   Error
                     "stale record-visit handle: the entry is no longer in the \
                      map (the traversal never fabricates a successor)")
           | _ -> arg_mismatch "(Map, key)"));
    intrinsic_binding "__intrinsic_set_visit_begin"
      (adapter_raw (lets [ set_of p0 ]) (option_of (ref_ p0))
         (fun _ args ->
           match args with
           | [| Vm_value.Set elems |] -> (
               match elems with
               | [] -> Ok vm_option_none
               | x :: _ -> Ok (vm_option_some x))
           | _ -> arg_mismatch "Set"));
    intrinsic_binding "__intrinsic_set_visit_next"
      (adapter_raw (lets [ set_of p0; p0 ]) (option_of (ref_ p0))
         (fun _ args ->
           match args with
           | [| Vm_value.Set elems; handle |] -> (
               match set_visit_after elems handle with
               | Some (x :: _) -> Ok (vm_option_some x)
               | Some [] | None -> Ok vm_option_none)
           | _ -> arg_mismatch "(Set, item)"));
    (* ── raw memory / syscalls / control flow.  The arena makes the raw
       memory surface executable; the control-flow wrappers that the
       value model genuinely cannot host (function-value invocation, the
       unwinder) stay deterministic traps. *)
    intrinsic_binding "__intrinsic_mem_alloc"
      (adapter_raw (lets [ Intrinsic_registry.ty_uint ]) (ptr_named Intrinsic_registry.ty_u8)
         (fun t args ->
           match args with
           | [| Vm_value.Int n |] ->
               let size = Int64.to_int (Int_value.to_int64 n) in
               (* the direct kernel's allocator clamps the request to 16
                  bytes and returns a 16-byte aligned block *)
               let size = if size <= 0 then 16 else size in
               (match arena_alloc t size 16 with
                | Ok p -> Ok (Vm_value.RawPtr p)
                | Error e -> Error ("__intrinsic_mem_alloc: " ^ e))
           | _ -> arg_mismatch "UInt"));
    intrinsic_binding "__intrinsic_mem_free"
      (adapter_raw
         (lets [ ptr_named Intrinsic_registry.ty_u8; Intrinsic_registry.ty_uint ])
         Type_repr.Unit (fun t args ->
           (* the arena's strict free: an exact live base pointer frees
              its region; a foreign/dead/offset pointer is a
              deterministic trap (the seed memory model is strict where
              the raw machine is UB). *)
           match args with
           | [| ptrv; Vm_value.Int _ |] -> (
               match pointer_value_to_pointer ptrv with
               | Some p when p.Vm_memory.region >= 0 -> (
                   match Vm_memory.free t.memory p with
                   | Ok () -> Ok Vm_value.Unit
                   | Error e -> Error ("__intrinsic_mem_free: " ^ mem_error e))
               | Some _ -> Ok Vm_value.Unit
               | None -> arg_mismatch "(Ptr[u8], UInt)")
           | _ -> arg_mismatch "(Ptr[u8], UInt)"));
    intrinsic_binding "__intrinsic_syscall1"
      (adapter_raw (lets [ ty_int; ty_int ]) ty_int (fun t args ->
           match args with
           | [| Vm_value.Int n; Vm_value.Int a0 |] ->
               (match host_syscall t (Int64.to_int (Int_value.to_int64 n)) [| int_arg (Vm_value.Int a0) |] with
                | Ok r -> Ok (vm_int r)
                | Error e -> Error e)
           | _ -> arg_mismatch "(Int, Int)"));
    intrinsic_binding "__intrinsic_syscall2"
      (adapter_raw (lets [ ty_int; ty_int; ty_int ]) ty_int (fun t args ->
           match args with
           | [| Vm_value.Int n; a0; a1 |] ->
               (match
                  host_syscall t (Int64.to_int (Int_value.to_int64 n))
                    [| int_arg a0; int_arg a1 |]
                with
                | Ok r -> Ok (vm_int r)
                | Error e -> Error e)
           | _ -> arg_mismatch "(Int, Int, Int)"));
    intrinsic_binding "__intrinsic_syscall3"
      (adapter_raw (lets [ ty_int; ty_int; ty_int; ty_int ]) ty_int (fun t args ->
           match args with
           | [| Vm_value.Int n; a0; a1; a2 |] ->
               (match
                  host_syscall t (Int64.to_int (Int_value.to_int64 n))
                    [| int_arg a0; int_arg a1; int_arg a2 |]
                with
                | Ok r -> Ok (vm_int r)
                | Error e -> Error e)
           | _ -> arg_mismatch "(Int, Int, Int, Int)"));
    intrinsic_binding "__intrinsic_syscall4"
      (adapter_raw (lets [ ty_int; ty_int; ty_int; ty_int; ty_int ]) ty_int
         (fun t args ->
           match args with
           | [| Vm_value.Int n; a0; a1; a2; a3 |] ->
               (match
                  host_syscall t (Int64.to_int (Int_value.to_int64 n))
                    [| int_arg a0; int_arg a1; int_arg a2; int_arg a3 |]
                with
                | Ok r -> Ok (vm_int r)
                | Error e -> Error e)
           | _ -> arg_mismatch "(Int, Int, Int, Int, Int)"));
    intrinsic_binding "__intrinsic_syscall5"
      (adapter_raw (lets [ ty_int; ty_int; ty_int; ty_int; ty_int; ty_int ]) ty_int
         (fun t args ->
           match args with
           | [| Vm_value.Int n; a0; a1; a2; a3; a4 |] ->
               (match
                  host_syscall t (Int64.to_int (Int_value.to_int64 n))
                    [| int_arg a0; int_arg a1; int_arg a2; int_arg a3; int_arg a4 |]
                with
                | Ok r -> Ok (vm_int r)
                | Error e -> Error e)
           | _ -> arg_mismatch "(Int, Int, Int, Int, Int, Int)"));
    intrinsic_binding "__intrinsic_syscall6"
      (adapter_raw
         (lets [ ty_int; ty_int; ty_int; ty_int; ty_int; ty_int; ty_int ])
         ty_int (fun t args ->
           match args with
           | [| Vm_value.Int n; a0; a1; a2; a3; a4; a5 |] ->
               (match
                  host_syscall t (Int64.to_int (Int_value.to_int64 n))
                    [|
                      int_arg a0; int_arg a1; int_arg a2; int_arg a3; int_arg a4;
                      int_arg a5;
                    |]
                with
                | Ok r -> Ok (vm_int r)
                | Error e -> Error e)
           | _ -> arg_mismatch "(Int, Int, Int, Int, Int, Int, Int)"));
    intrinsic_binding "__intrinsic_try_invoke"
      (adapter_raw (lets [ fn0 p0 ]) (option_of p0) (fun _ _ ->
           Error
             "__intrinsic_try_invoke: function-value invocation is not available at the \
              seed host boundary"));
    intrinsic_binding "__intrinsic_longjmp"
      (adapter_raw (lets [ ty_int ]) Type_repr.Unit (fun _ _ ->
           Error "__intrinsic_longjmp: no active try frame in the seed host"));
    intrinsic_binding "__intrinsic_regex_match"
      (adapter_raw (lets [ Type_repr.String; Type_repr.String ]) ty_bool
         (fun _ args ->
           match args with
           | [| Vm_value.String text; Vm_value.String pattern |] ->
               Ok (Vm_value.Bool (regex_match_subset text pattern))
           | _ -> arg_mismatch "(String, String)"));

    (* ── The builtin-method class (the checker's builtin method tables
       and compiler-registered free builtins that had no host binding).
       Every adapter below implements the same observable semantics as
       the direct kernel's codegen arm/runtime helper where one exists;
       the raw-pointer dereference ops trap deterministically (the seed
       host has no VM memory handle — exactly like the as_ptr wrappers
       above) and Ptr::as_mut is the address-preserving cast. *)

    (* Vec/Array receiver methods. *)
    intrinsic_binding "__intrinsic_array_is_empty"
      (adapter_raw (lets [ vec_of p0 ]) ty_bool (fun _ args ->
           match args with
           | [| Vm_value.Array elems |] ->
               Ok (Vm_value.Bool (Array.length elems = 0))
           | _ -> arg_mismatch "(Array)"));
    intrinsic_binding "__intrinsic_array_first"
      (adapter_raw (lets [ vec_of p0 ]) (option_of p0) (fun _ args ->
           match args with
           | [| Vm_value.Array elems |] ->
               if Array.length elems = 0 then Ok (Vm_value.Enum (1, [||]))
               else Ok (Vm_value.Enum (0, [| elems.(0) |]))
           | _ -> arg_mismatch "(Array)"));
    intrinsic_binding "__intrinsic_array_last"
      (adapter_raw (lets [ vec_of p0 ]) (option_of p0) (fun _ args ->
           match args with
           | [| Vm_value.Array elems |] ->
               let n = Array.length elems in
               if n = 0 then Ok (Vm_value.Enum (1, [||]))
               else Ok (Vm_value.Enum (0, [| elems.(n - 1) |]))
           | _ -> arg_mismatch "(Array)"));
    intrinsic_binding "__intrinsic_array_resize"
      (adapter_raw_wb
         [ (Access_effect.Inout, vec_of p0); (Access_effect.Let, ty_int);
           (Access_effect.Sink, p0) ]
         Type_repr.Unit (fun _ args ->
           (* the runtime's _tg_array_resize contract: new_len <= len
              truncates; new_len > len fills the new slots with the
              (moved-in) fill value.  The shrink path enumerates the
              dropped elements in `removed` so the VM drops each exactly
              once (P0-3); the grow path shares the fill value
              structurally, like every value-model aggregate. *)
           match args with
           | [| Vm_value.Array elems; Vm_value.Int n; value |] ->
               let new_len = Int64.to_int (Int_value.to_int64 n) in
               let cur = Array.length elems in
               if new_len < 0 then
                 Error
                   (Printf.sprintf
                      "__intrinsic_array_resize: negative new_len %d" new_len)
               else if new_len <= cur then
                 Ok
                   { value = Vm_value.Unit;
                     writebacks =
                       [ { arg_index = 0;
                           replacement =
                             Vm_value.Array (Array.sub elems 0 new_len);
                           removed =
                             Array.to_list
                               (Array.sub elems new_len (cur - new_len)) } ] }
               else
                 Ok
                   { value = Vm_value.Unit;
                     writebacks =
                       [ { arg_index = 0;
                           replacement =
                             Vm_value.Array
                               (Array.append elems
                                  (Array.make (new_len - cur) value));
                           removed = [] } ] }
           | _ -> Error "argument mismatch: expected (Array, Int, value)"));
    intrinsic_binding "__intrinsic_array_sort"
      (adapter_raw_wb [ (Access_effect.Inout, vec_of p0) ] Type_repr.Unit
         (fun _ args ->
           match args with
           | [| Vm_value.Array elems |] -> (
               match vm_sort_elems elems with
               | Ok sorted ->
                   Ok
                     { value = Vm_value.Unit;
                       writebacks =
                         [ { arg_index = 0;
                             replacement = Vm_value.Array sorted;
                             removed = [] } ] }
               | Error m -> Error ("__intrinsic_array_sort: " ^ m))
           | _ -> Error "argument mismatch: expected (Array)"));
    intrinsic_binding "__intrinsic_array_truncate"
      (adapter_raw_wb
         [ (Access_effect.Inout, vec_of p0); (Access_effect.Let, ty_int) ]
         Type_repr.Unit (fun _ args ->
           (* the std truncate contract (new_len >= len is a no-op);
              the dropped elements are enumerated in `removed` so the VM
              drops each exactly once (P0-3) *)
           match args with
           | [| Vm_value.Array elems; Vm_value.Int n |] ->
               let new_len = Int64.to_int (Int_value.to_int64 n) in
               let cur = Array.length elems in
               if new_len < 0 then
                 Error
                   (Printf.sprintf
                      "__intrinsic_array_truncate: negative new_len %d" new_len)
               else if new_len >= cur then
                 Ok
                   { value = Vm_value.Unit;
                     writebacks =
                       [ { arg_index = 0; replacement = Vm_value.Array elems;
                           removed = [] } ] }
               else
                 Ok
                   { value = Vm_value.Unit;
                     writebacks =
                       [ { arg_index = 0;
                           replacement =
                             Vm_value.Array (Array.sub elems 0 new_len);
                           removed =
                             Array.to_list
                               (Array.sub elems new_len (cur - new_len)) } ] }
           | _ -> Error "argument mismatch: expected (Array, Int)"));

    (* String char/iteration/construction surface. *)
    intrinsic_binding "__intrinsic_string_char_at"
      (adapter_raw (lets [ Type_repr.String; ty_int ]) Type_repr.Char
         (fun _ args ->
           match args with
           | [| Vm_value.String s; Vm_value.Int i |] ->
               let idx = Int64.to_int (Int_value.to_int64 i) in
               if idx < 0 || idx >= String.length s then
                 Error
                   (Printf.sprintf
                      "__intrinsic_string_char_at: index %d out of bounds (len %d)"
                      idx (String.length s))
               else Ok (vm_char_of_byte (Char.code s.[idx]))
           | _ -> arg_mismatch "(String, Int)"));
    intrinsic_binding "__intrinsic_string_chars"
      (adapter_raw (lets [ Type_repr.String ]) (vec_of ty_char) (fun _ args ->
           match args with
           | [| Vm_value.String s |] ->
               Ok
                 (Vm_value.Array
                    (Array.init (String.length s) (fun i ->
                         vm_char_of_byte (Char.code s.[i]))))
           | _ -> arg_mismatch "String"));
    intrinsic_binding "string_new"
      (adapter_raw [] Type_repr.String (fun _ args ->
           match args with
           | [||] -> Ok (vm_string "")
           | _ -> arg_mismatch "no arguments"));
    intrinsic_binding "__intrinsic_string_from_chars"
      (adapter_raw (lets [ vec_of ty_char ]) Type_repr.String (fun _ args ->
           match args with
           | [| Vm_value.Array elems |] -> vm_string_of_chars elems
           | _ -> arg_mismatch "(Array[Char])"));
    intrinsic_binding "__intrinsic_string_from_bytes"
      (adapter_raw (lets [ vec_of Intrinsic_registry.ty_u8 ]) Type_repr.String
         (fun _ args ->
           match args with
           | [| Vm_value.Array elems |] -> vm_string_of_bytes elems
           | _ -> arg_mismatch "(Array[U8])"));
    intrinsic_binding "string_clone"
      (adapter_raw (lets [ Type_repr.String ]) Type_repr.String (fun _ args ->
           (* the value model's String is immutable, so the deep copy is
              the identity (identical to __intrinsic_str_to_string) *)
           match args with
           | [| Vm_value.String _ as s |] -> Ok s
           | _ -> arg_mismatch "String"));

    (* the integer to_string surface (Int/UInt here; the width-specific
       small-int bindings are appended from int_to_string_bindings). *)
    intrinsic_binding "__intrinsic_uint_to_string"
      (adapter_int_kind_ret_string Type_repr.UInt);

    (* Char predicates/conversions. *)
    intrinsic_binding "__intrinsic_char_is_digit"
      (adapter_raw (lets [ ty_char ]) ty_bool (fun _ args ->
           match args with
           | [| Vm_value.Char c |] ->
               let cp = Uchar.to_int c in
               Ok (Vm_value.Bool (cp >= 48 && cp <= 57))
           | _ -> arg_mismatch "Char"));
    intrinsic_binding "__intrinsic_char_to_int"
      (adapter_raw (lets [ ty_char ]) ty_int (fun _ args ->
           match args with
           | [| Vm_value.Char c |] ->
               Ok
                 (Vm_value.Int
                    (Int_value.of_int64 ~width:64 ~signed:true
                       (Int64.of_int (Uchar.to_int c))))
           | _ -> arg_mismatch "Char"));

    (* the raw-pointer receiver methods.  ptr_write/ptr_read have no
       static pointee type at the host boundary, so they speak the
       self-describing value image (the same channel the VM's computed
       refs use); the bytes live in the shared arena. *)
    intrinsic_binding "__intrinsic_ptr_write"
      (adapter_raw
         [ (Access_effect.Let, ptr_named p0); (Access_effect.Sink, p0) ]
         Type_repr.Unit (fun t args ->
           match args with
           | [| ptrv; value |] -> (
               match ptr_arg ptrv with
               | Error e -> Error e
                | Ok p -> (
                    let b = Vm_value.serialize value in
                    match arena_store_grow t p b with
                    | Ok () -> Ok Vm_value.Unit
                    | Error e -> Error ("__intrinsic_ptr_write: " ^ e)))
           | _ -> arg_mismatch "(Ptr, value)"));
    intrinsic_binding "__intrinsic_ptr_read"
      (adapter_raw (lets [ ptr_named p0 ]) p0 (fun t args ->
           match args with
           | [| ptrv |] -> (
               match ptr_arg ptrv with
               | Error e -> Error e
               | Ok p -> (
                   match Vm_memory.region_length t.memory p with
                   | Error e -> Error ("__intrinsic_ptr_read: " ^ mem_error e)
                   | Ok rlen ->
                       let len = rlen - p.Vm_memory.offset in
                       (match arena_load t p len with
                        | Error e -> Error ("__intrinsic_ptr_read: " ^ e)
                        | Ok b -> (
                            try Ok (Vm_value.deserialize b)
                            with Failure m ->
                              Error ("__intrinsic_ptr_read: " ^ m)))))
           | _ -> arg_mismatch "Ptr"));
    intrinsic_binding "__intrinsic_ptr_as_mut"
      (adapter_raw (lets [ ptr_named p0 ]) (ptrmut_named p0) (fun _ args ->
           (* the address-preserving cast: on the value model the
              mutability tag lives in the checker's type, not the value.
              Every address-bearing pointer shape passes through
              unchanged (RawPtr/Null, the `Ptr { address }` handle
              struct, and the handle over a handle). *)
           match args with
           | [| ( Vm_value.RawPtr _ | Vm_value.Null | Vm_value.Int _
                | Vm_value.Struct [| Vm_value.Int _ |]
                | Vm_value.Struct [| Vm_value.Struct [| Vm_value.Int _ |] |] ) as p |] ->
               Ok p
           | _ -> arg_mismatch "Ptr"));

    (* Option::expect (the None case is the std's defined panic — a
       deterministic host error the VM traps on). *)
    intrinsic_binding "__intrinsic_option_expect"
      (adapter_raw
         [ (Access_effect.Sink, option_of p0); (Access_effect.Let, ty_string) ]
         p0 (fun _ args ->
           match args with
           | [| Vm_value.Enum (0, [| v |]); Vm_value.String _ |] -> Ok v
           | [| Vm_value.Enum (1, [||]); Vm_value.String msg |] ->
               Error (Printf.sprintf "Option::expect: %s" msg)
           | _ -> arg_mismatch "(Option[T], String)"));

    (* compiler-registered free builtins. *)
    intrinsic_binding "__intrinsic_a64_cc_hi"
      (adapter_raw [] (Type_repr.Int Type_repr.U32) (fun _ args ->
           (* the AArch64 condition-code constant: HI = 0b1000 (asm.tg) *)
           match args with
           | [||] ->
               Ok
                 (Vm_value.Int
                    (Int_value.of_int64 ~width:32 ~signed:false 8L))
           | _ -> arg_mismatch "no arguments"));
    intrinsic_binding "__intrinsic_vec_filled"
      (adapter_raw (lets [ ty_int; p0 ]) (vec_of p0) (fun _ args ->
           match args with
           | [| Vm_value.Int n; value |] ->
               let count = Int64.to_int (Int_value.to_int64 n) in
               if count < 0 then
                 Error
                   (Printf.sprintf
                      "__intrinsic_vec_filled: negative count %d" count)
               else Ok (Vm_value.Array (Array.make count value))
           | _ -> arg_mismatch "(Int, value)"));

    (* the source `extern` declarations of the allocator/atomic surface. *)
    extern_binding "memcpy"
      (adapter_raw
         [ (Access_effect.Let, ptr_named Intrinsic_registry.ty_u8);
           (Access_effect.Let, ptr_named Intrinsic_registry.ty_u8);
           (Access_effect.Let, ty_uint) ]
         (ptr_named Intrinsic_registry.ty_u8) (fun t args ->
           match args with
           | [| dstv; srcv; n |] -> (
               match (ptr_arg dstv, ptr_arg srcv) with
               | Error e, _ | _, Error e -> Error e
               | Ok dst, Ok src ->
                   let len = int_arg n in
                   (match Vm_memory.memcpy t.memory dst src len with
                    | Error e -> Error ("memcpy: " ^ mem_error e)
                    | Ok () -> (
                        (* mirror the destination bytes into any linked
                           array view *)
                        match arena_load t dst len with
                        | Ok b ->
                            arena_link_mirror t dst b;
                            Ok (Vm_value.RawPtr dst)
                        | Error e -> Error ("memcpy: " ^ e))))
           | _ -> arg_mismatch "(Ptr, Ptr, UInt)"));
    extern_binding "sched_yield"
      (adapter_raw [] (Type_repr.Int Type_repr.I32) (fun _ args ->
           (* single-threaded seed host: yielding the scheduler quantum is
              the defined, immediately-satisfied operation (returns 0) —
              the same honest no-op rationale as __sync_synchronize *)
           match args with
           | [||] ->
               Ok
                 (Vm_value.Int
                    (Int_value.of_int64 ~width:32 ~signed:true 0L))
           | _ -> arg_mismatch "no arguments"));
    extern_binding "__sync_bool_compare_and_swap_1"
      (adapter_raw
         [ (Access_effect.Let, ptr_named Intrinsic_registry.ty_u8);
           (Access_effect.Let, Intrinsic_registry.ty_u8);
           (Access_effect.Let, Intrinsic_registry.ty_u8) ]
         ty_bool (fun t args ->
           match args with
           | [| ptrv; expected; desired |] -> (
               match ptr_arg ptrv with
               | Error e -> Error e
               | Ok p -> (
                   let ev = int_arg expected land 0xFF in
                   let dv = int_arg desired land 0xFF in
                   match Vm_memory.load_u8 t.memory p with
                   | Error e -> Error ("__sync_bool_compare_and_swap_1: " ^ mem_error e)
                   | Ok old ->
                       if old <> ev then Ok (Vm_value.Bool false)
                       else (
                         match arena_store t p (Bytes.make 1 (Char.chr dv)) with
                         | Ok () -> Ok (Vm_value.Bool true)
                         | Error e ->
                             Error ("__sync_bool_compare_and_swap_1: " ^ e))))
           | _ -> arg_mismatch "(Ptr, u8, u8)"));

    (* ── The process / descriptor / environment extern surface (audit
       §70; the `extern def` declarations of std/process.tg, std/fs.tg,
       std/env.tg and the linker/compiler_core io externs, transcribed
       into Extern_registry.manifest).  With the arena in place every
       raw-pointer ABI here is decodable: borrowed C strings, PtrMut out
       parameters and byte buffers all address regions of the same table
       the VM dereferences through.  `poll` remains a deterministic trap:
       the direct kernel's runtime closure emits no poll helper either
       (the boundary has no implementation to mirror). *)
    extern_binding "_tg_write_vec_u8"
      (adapter_raw (lets [ ty_int; vec_of Intrinsic_registry.ty_u8; ty_uint ]) ty_int
          (fun t args ->
            (* the runtime's _tg_write_vec_u8 contract: clamp the count to
               the Vec length, pack each element's low byte, then the
               write-all loop (EINTR retried).  The seed host's captured
               channels are fds 1/2 (audit §45); other descriptors go
               through the host descriptor table. *)
            match args with
            | [| Vm_value.Int fd; Vm_value.Array elems; Vm_value.Int count |] ->
                let n = Int64.to_int (Int_value.to_int64 count) in
                let n =
                  if n <= 0 then 0
                  else if n > Array.length elems then Array.length elems
                  else n
                in
                let bytes = Bytes.create n in
                for i = 0 to n - 1 do
                  let b =
                    match elems.(i) with
                    | Vm_value.Int v ->
                        Int64.to_int (Int64.logand (Int_value.to_int64 v) 0xFFL)
                    | _ -> 0
                  in
                  Bytes.set bytes i (Char.chr b)
                done;
                let fd = Int64.to_int (Int_value.to_int64 fd) in
                if fd = 1 || fd = 2 then begin
                  let s = Bytes.to_string bytes in
                  if fd = 1 then emit_stdout t s else emit_stderr t s;
                  Ok (vm_int n)
                end
                else (
                  match guest_fd fd with
                  | None -> Ok (vm_int 0)
                  | Some d -> (
                      try Ok (vm_int (Unix.write d bytes 0 n))
                      with Unix.Unix_error _ -> Ok (vm_int (-1))))
            | _ -> arg_mismatch "(Int, Vec[u8], UInt)"));

    (* std/env.tg — the process environment channel.  The direct kernel
       returns borrowed pointers into the OS envp block; the host
       materializes each entry as a fresh NUL-terminated Raw region
       (stable for the VM run), so the guest's byte-wise dereferences and
       _tg_str_skip arithmetic observe the same bytes. *)
    extern_binding "_tg_env_count"
      (adapter_raw [] ty_int (fun _ args ->
           match args with
           | [||] -> Ok (vm_int (Array.length (Unix.environment ())))
           | _ -> arg_mismatch "no arguments"));
    extern_binding "_tg_env_entry"
      (adapter_raw (lets [ ty_int ]) (ptr_named Intrinsic_registry.ty_u8)
         (fun t args ->
           match args with
           | [| Vm_value.Int i |] ->
               let idx = Int64.to_int (Int_value.to_int64 i) in
               let env = Unix.environment () in
               if idx < 0 || idx >= Array.length env then Ok Vm_value.Null
               else begin
                 let s = env.(idx) in
                 match arena_alloc t (String.length s + 1) 1 with
                 | Error e -> Error e
                 | Ok p ->
                     let b = Bytes.make (String.length s + 1) '\000' in
                     Bytes.blit_string s 0 b 0 (String.length s);
                     (match arena_store t p b with
                      | Ok () -> Ok (Vm_value.RawPtr p)
                      | Error e -> Error e)
               end
           | _ -> arg_mismatch "Int"));
    extern_binding "_tg_str_skip"
      (adapter_raw
         (lets [ ptr_named Intrinsic_registry.ty_u8; ty_int ])
         (ptr_named Intrinsic_registry.ty_u8) (fun _ args ->
           (* the runtime's str + offset pointer arithmetic — a pure
              value operation on the seed's (region, offset) pointer model,
              no dereference involved. *)
           match args with
           | [| ptrv; Vm_value.Int d |] -> (
               match pointer_value_to_pointer ptrv with
               | Some p when p.Vm_memory.region >= 0 ->
                   Ok
                     (Vm_value.RawPtr
                        { p with
                          Vm_memory.offset =
                            p.Vm_memory.offset + Int64.to_int (Int_value.to_int64 d) })
               | Some _ -> Ok Vm_value.Null
               | None -> arg_mismatch "(Ptr[u8], Int)")
           | _ -> arg_mismatch "(Ptr[u8], Int)"));

    (* the POSIX process surface: fork/dup2/close are descriptor- or
       pid-valued and map onto the host's OCaml Unix calls; the
       raw-pointer-carrying members decode their arena arguments. *)
    extern_binding "c_fork"
      (adapter_raw [] ty_i32 (fun t args ->
           match args with
           | [||] -> (
               try
                 let pid = Unix.fork () in
                 (* the child continues the SAME VM with the forked host
                    state; record its identity so `_exit` can terminate
                    the child (the direct kernel's process) while the
                    parent keeps executing the driver *)
                 if pid = 0 then t.in_fork_child <- true;
                 Ok (vm_i32 pid)
               with Unix.Unix_error _ -> Ok (vm_i32 (-1)))
           | _ -> arg_mismatch "no arguments"));
    extern_binding "dup2"
      (adapter_raw (lets [ ty_int; ty_int ]) ty_i32 (fun _ args ->
           match args with
           | [| Vm_value.Int oldfd; Vm_value.Int newfd |] ->
               let oldfd = Int64.to_int (Int_value.to_int64 oldfd) in
               let newfd = Int64.to_int (Int_value.to_int64 newfd) in
               Ok (vm_i32 (host_dup2 oldfd newfd))
           | _ -> arg_mismatch "(Int, Int)"));
    extern_binding "libc_close"
      (adapter_raw (lets [ ty_int ]) ty_i32 (fun _ args ->
           (* the ONE registry entry serves both closure declarations of
              the name (std/process.tg `-> i32` and tg_compiler/linker.tg
              `-> Int`; the checker's C-integer-kind adoption reconciles
              the two spellings). *)
           match args with
           | [| Vm_value.Int fd |] -> Ok (vm_i32 (host_close_fd (int_arg (Vm_value.Int fd))))
           | _ -> arg_mismatch "Int"));
    extern_binding "execvp"
      (adapter_raw
         (lets
            [ ptr_named Intrinsic_registry.ty_u8;
              ptr_named (ptr_named Intrinsic_registry.ty_u8) ])
         ty_i32 (fun t args ->
           (* decode the NUL-terminated path and the NULL-terminated
              argv vector of C strings, then execute — the direct
              kernel's execvp contract.  On success this process is
              replaced (the call never returns); only a failure returns
              the negative errno. *)
           match args with
           | [| pathv; argvv |] -> (
               match (ptr_arg pathv, ptr_arg argvv) with
               | Error e, _ | _, Error e -> Error e
               | Ok pathp, Ok argvp -> (
                   match arena_cstring t pathp with
                   | Error e -> Error ("execvp: " ^ e)
                   | Ok path -> (
                       let rec gather i acc =
                         if i > 65536 then Error "execvp: argv vector is unterminated"
                         else
                           let slot =
                             { Vm_memory.region = argvp.Vm_memory.region;
                               offset = argvp.Vm_memory.offset + (8 * i) }
                           in
                           match Vm_memory.load_bytes t.memory slot 8 with
                           | Error e -> Error ("execvp: " ^ mem_error e)
                           | Ok b ->
                               let addr = Raw_memory.u64_le b 0 8 in
                               let p = Vm_memory.pointer_of_int64 addr in
                               if Vm_memory.is_null_pointer p then Ok (List.rev acc)
                               else (
                                 match arena_cstring t p with
                                 | Error e -> Error ("execvp: " ^ e)
                                 | Ok s -> gather (i + 1) (s :: acc))
                       in
                       match gather 0 [] with
                       | Error e -> Error e
                       | Ok argv -> (
                           match argv with
                           | [] -> Error "execvp: empty argv vector"
                           | _ -> (
                               try Unix.execvp path (Array.of_list argv)
                               with
                               | Unix.Unix_error (e, _, _) ->
                                   Ok (vm_i32 (-errno_of_unix_error e))
                               | Failure m -> Error ("execvp: " ^ m))))))
           | _ -> arg_mismatch "(Ptr[u8], Ptr[Ptr[u8]])"));
    extern_binding "c_waitpid"
      (adapter_raw (lets [ ty_i32; ptrmut_named ty_int; ty_i32 ]) ty_i32
         (fun t args ->
           match args with
           | [| pidv; statusv; optionsv |] -> (
               match ptr_arg statusv with
               | Error e -> Error e
               | Ok sp ->
                   let pid = int_arg pidv in
                   let options = int_arg optionsv in
                   let flags =
                     if options land 1 <> 0 then [ Unix.WNOHANG ] else []
                   in
                   (* the POSIX wait-status word: exit code << 8, the
                      signal number for a signal death, the stop encoding
                      for a stop *)
                   let status_word status =
                     match status with
                     | Unix.WEXITED n -> n lsl 8
                     | Unix.WSIGNALED n -> n
                     | Unix.WSTOPPED n -> (n lsl 8) lor 0x7f
                   in
                   (try
                      match Unix.waitpid flags pid with
                      | 0, _ -> Ok (vm_i32 0)
                      | p, status ->
                          let b = Bytes.make 8 '\000' in
                          Raw_memory.put_u64_le b 0 8
                            (Int64.of_int (status_word status));
                          (match arena_store t sp b with
                           | Ok () -> Ok (vm_i32 (p land 0x7FFFFFFF))
                           | Error e -> Error ("c_waitpid: " ^ e))
                    with Unix.Unix_error (e, _, _) ->
                      Ok (vm_i32 (-errno_of_unix_error e))))
           | _ -> arg_mismatch "(i32, PtrMut[Int], i32)"));
    extern_binding "_exit"
      (adapter_raw (lets [ ty_int ]) Type_repr.Never (fun t args ->
           (* the direct kernel's `_exit` terminates the process without
              any cleanup.  The VM runs inside the seed host, so the only
              process a guest exit may terminate is an OS child the GUEST
              itself forked (Command::spawn's child arms — the pid == 0
              branch runs in that child); there `Unix._exit` is the exact
              POSIX semantics.  In the parent the call traps instead of
              killing the seed host and the driver alongside it. *)
           match args with
           | [| Vm_value.Int code |] ->
               if t.in_fork_child then
                 Unix._exit (Int64.to_int (Int_value.to_int64 code))
               else
                 Error
                   "_exit: the in-process VM must not terminate the seed host; \
                    a guest exit is executable only in an OS child created by \
                    the guest's own fork()"
           | _ -> arg_mismatch "Int"));
    extern_binding "pipe"
      (adapter_raw (lets [ ptrmut_named ty_int ]) ty_i32 (fun t args ->
           match args with
           | [| pv |] -> (
               match ptr_arg pv with
               | Error e -> Error e
               | Ok p -> (
                   try
                     let r, w = Unix.pipe ~cloexec:false () in
                     let fr = register_guest_fd r in
                     let fw = register_guest_fd w in
                     let b = Bytes.make 16 '\000' in
                     Raw_memory.put_u64_le b 0 8 (Int64.of_int fr);
                     Raw_memory.put_u64_le b 8 8 (Int64.of_int fw);
                     (match arena_store t p b with
                      | Ok () -> Ok (vm_i32 0)
                      | Error e -> Error ("pipe: " ^ e))
                   with Unix.Unix_error (e, _, _) ->
                     Ok (vm_i32 (-errno_of_unix_error e))))
           | _ -> arg_mismatch "PtrMut[Int]"));
    extern_binding "libc_read"
      (adapter_raw (lets [ ty_int; ptrmut_named Intrinsic_registry.ty_u8; ty_uint ]) ty_int
         (fun t args ->
           match args with
           | [| fd; pv; count |] -> (
               match ptr_arg pv with
               | Error e -> Error e
               | Ok p -> Ok (vm_int (host_read_into t (int_arg fd) p (int_arg count))))
           | _ -> arg_mismatch "(Int, PtrMut[u8], UInt)"));
    extern_binding "libc_write"
      (adapter_raw (lets [ ty_int; ptr_named Intrinsic_registry.ty_u8; ty_uint ]) ty_int
         (fun t args ->
           match args with
           | [| fd; pv; count |] -> (
               match ptr_arg pv with
               | Error e -> Error e
               | Ok p -> Ok (vm_int (host_write_from t (int_arg fd) p (int_arg count))))
           | _ -> arg_mismatch "(Int, Ptr[u8], UInt)"));
    extern_binding "libc_open"
      (adapter_raw (lets [ ptr_named Intrinsic_registry.ty_u8; ty_int ]) ty_i32
         (fun t args ->
           match args with
           | [| pathv; flagsv |] -> (
               match ptr_arg pathv with
               | Error e -> Error e
               | Ok p -> (
                   match arena_cstring t p with
                   | Error e -> Error ("libc_open: " ^ e)
                   | Ok path ->
                       let flags = int_arg flagsv in
                       let mode =
                         if host_is_darwin then (if flags land 0x200 <> 0 then 0o644 else 0)
                         else if flags land 0x40 <> 0 then 0o644
                         else 0
                       in
                       Ok (vm_i32 (host_open t path flags mode))))
           | _ -> arg_mismatch "(Ptr[u8], Int)"));
    (* poll(2): the pollfd array is a Raw arena region — decodable now
       that the arena landed (the old trap's stated blocker is gone).
       The direct kernel's Command::output (the linker's macOS ad-hoc
       codesign step) interleaves its two stdio pipes through this call,
       so the executable path requires the real adapter. *)
    extern_binding "poll"
      (adapter_raw (lets [ ptr_named Intrinsic_registry.ty_u8; ty_uint; ty_int ]) ty_i32
         (fun t args ->
           match args with
           | [| fdsv; nfdsv; timeoutv |] -> (
               let nfds = int_arg nfdsv in
               let timeout_ms = int_arg timeoutv in
               if nfds < 0 then Ok (vm_i32 (-errno_of_unix_error Unix.EINVAL))
               else if nfds = 0 then (
                 match
                   host_poll t (Vm_memory.pointer_of_int64 0L) Bytes.empty 0 timeout_ms
                 with
                 | Ok n -> Ok (vm_i32 n)
                 | Error e -> Error e)
               else (
                 match ptr_arg fdsv with
                 | Error e -> Error e
                 | Ok p -> (
                     match arena_load t p (nfds * 8) with
                     | Error e -> Error ("poll: " ^ e)
                     | Ok b -> (
                         match host_poll t p b nfds timeout_ms with
                         | Ok n -> Ok (vm_i32 n)
                         | Error e -> Error e))))
           | _ -> arg_mismatch "(Ptr[u8], UInt, Int)"));
    extern_binding "libc_open_path"
      (adapter_raw (lets [ ptr_named Intrinsic_registry.ty_u8; ty_int; ty_int ]) ty_int
         (fun t args ->
           match args with
           | [| pathv; flagsv; modev |] -> (
               match ptr_arg pathv with
               | Error e -> Error e
               | Ok p -> (
                   match arena_cstring t p with
                   | Error e -> Error ("libc_open_path: " ^ e)
                   | Ok path ->
                       Ok (vm_int (host_open t path (int_arg flagsv) (int_arg modev)))))
           | _ -> arg_mismatch "(Ptr[u8], Int, Int)"));
    extern_binding "libc_chmod"
      (adapter_raw (lets [ ptr_named Intrinsic_registry.ty_u8; ty_int ]) ty_int
         (fun t args ->
           match args with
           | [| pathv; modev |] -> (
               match ptr_arg pathv with
               | Error e -> Error e
               | Ok p -> (
                   match arena_cstring t p with
                   | Error e -> Error ("libc_chmod: " ^ e)
                   | Ok path -> Ok (vm_int (host_chmod t path (int_arg modev)))))
           | _ -> arg_mismatch "(Ptr[u8], Int)"));
  ] @ int_to_string_bindings

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
    memory = Vm_memory.create ();
    array_links = Hashtbl.create 16;
    in_fork_child = false;
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
