(* vm.ml — The Seed VM interpreter loop (audit §37, §39, §41, §45, §46).

   Executes pre-indexed, monomorphized Seed MIR: functions/block ids/
   locals are arrays; calls go through callee = User InstanceId |
   Intrinsic id | Extern id — never name dispatch. Slot-state ownership
   is enforced on every local access.

   ── Semantic projection execution (re-audit) ────────────────────────

   The Field and Downcast projections carry SEMANTIC ids (FieldId /
   VariantId); the positional index/tag is NOT in the projection.  At
   execution the VM derives the position from the program's
   type-definition table: the static type of the base value (from the
   frame's locals, threaded through the projection walk) names the
   owner def, and the def's fd_index/vd_index metadata gives the
   position.  The aggregate value itself is positional (Struct fields
   arrays, Enum (tag, payload)); the id is the compile-time identity
   that the verifier ties to the owner.  A Downcast additionally
   checks the runtime tag equals the VariantId's declaration-order tag.

   ── Kernel-closure primitives (the audit's remaining items) ─────────

   1. DYNAMIC INDEX PROJECTIONS.  The Seed MIR dynamic-index projection
      is `Seed_mir.Index local` (seed_mir.ml): the payload is a LOCAL
      whose value is the runtime index — the seed's dynamic-index
      convention (the "index operand" is read from the current frame's
      locals through the slot machine).  The index is bounds-checked
      deterministically (traps: "index out of bounds" for arrays,
      "tuple index out of bounds", "string index out of bounds"; a
      non-integer or 128-bit index traps).  Reads project the element
      and continue the remaining projections; writes update the element
      in place — the updated aggregate is written back to the slot
      (Array/Tuple elements; a String write replaces the byte at the
      index with the char's UTF-8 bytes — String indices are BYTE
      indices, consistent with Len's String.length and the
      ConstantIndex projection).
      NOTE: mir_lower.ml today emits ConstantIndex for literal `arr[i]`
      (already executed here) and unrolls for-loops with ConstantIndex
      reads; it never emits the dynamic Index form — the VM executes it
      for hand-written/kernel MIR.

   2. POINTER DEREFERENCE (`Seed_mir.Deref`).  A RawPtr (or a
      region-backed Ref) dereferences through the simulated memory: the
      region at (region, offset) holds a self-describing byte
      serialization (Vm_value.serialize/deserialize — see vm_value.ml
      for the exact format; integers little-endian by width, Bool 1
      byte, Char 4-byte utf-32, String 8-byte length prefix + utf-8,
      aggregates recursively; it round-trips).  Null pointers, dead
      regions, out-of-bounds offsets and invalid payloads are
      deterministic traps.  A deref WRITE serializes the value into the
      region (in place, never a copy).

   3. REF / REFMUT WRITEBACK.  `Ref p`/`RefMut p` with a place source
      (no Deref in p's projections) produces a REAL reference:
      `Vm_value.Ref (Place (frame, local, projections))` — the target
      frame RECORD is captured, so reads resolve to the target place
      and writes through the ref update the target IN PLACE, even when
      the ref crosses a call boundary.  `Ref p` whose source has a Deref
      projection (a computed value, e.g. `&*ptr`) keeps a serialized
      copy in a fresh region (`Ref (Region ptr)`): reads load the copy
      back, and WRITES THROUGH IT ARE A DETERMINISTIC TRAP (no silent
      divergence).

   4. RECURSIVE DROP.  `Drop`/`Deinit` run the recursive drop glue
      (Vm_value.drop_glue) over the place's value first: aggregates are
      visited depth-first and every region-backed ref inside is
      deterministically freed, then the outer slot transitions per the
      slot machine (Live -> Dropped; Moved/Uninitialized are no-ops; a
      second drop of a Dropped slot traps). *)

(* Frame identity — the type lives in vm_value.ml so that reference
   targets can record a frame; the equation re-declares it here so the
   record fields are in scope in this module. *)
type frame = Vm_value.frame = {
  fn : int;
  locals : Vm_value.slot array;
  statics : Vm_value.slot array;
  mutable block : int;
  mutable stmt : int;
}

type error_kind = Panic | Trap of string | LimitExceeded of string | HostError of string | Unreachable

type vm_error = {
  kind : error_kind;
  message : string;
  trace : string list;
}

type limits = {
  max_steps : int;
  max_depth : int;
  max_alloc_bytes : int;
  max_host_calls : int;
}

let default_limits =
  { max_steps = 100_000_000; max_depth = 10_000; max_alloc_bytes = 1_073_741_824; max_host_calls = 1_000_000 }

type t = {
  program : Seed_mir.program;
  fn_index : (Instance_id.t, int) Hashtbl.t;  (* lookup only; iteration is never semantic *)
  memory : Vm_memory.t;
  (* The P1-26 canonical drop-plan table: per concrete TypeId the
     ordered (field/payload path, needs_drop) plan derived ONCE from
     program.types; the destruction sites (do_drop, the assign-overwrite
     drop) consult it by the local/place TYPE and fall back to the
     structural value glue only for types whose plan is not
     materialized. *)
  drop_plans : Drop_plan.table;
  mutable host : Host.t;
  limits : limits;
  mutable steps : int;
  mutable host_calls : int;
  mutable alloc_bytes : int;
  mutable stdout : Buffer.t;
  mutable stderr : Buffer.t;
  mutable frames : frame list;
  mutable trace : string list;
}

let find_fn (vm : t) (inst : Instance_id.t) : int option =
  Hashtbl.find_opt vm.fn_index inst

let mk_error vm kind message =
  { kind; message; trace = List.rev (List.map (fun f -> Printf.sprintf "_%d bb%d" f.fn f.block) vm.frames) }

let step_limit (vm : t) : unit =
  vm.steps <- vm.steps + 1;
  if vm.steps > vm.limits.max_steps then
    raise (Failure "vm: step limit exceeded")

let err_trap vm msg =
  let where =
    match vm.frames with
    | f :: _ ->
        let caller =
          if f.fn >= 0 && f.fn < Array.length vm.program.Seed_mir.functions then
            vm.program.Seed_mir.functions.(f.fn).Seed_mir.name
          else "?"
        in
        Printf.sprintf " (in %s: fn %d bb%d stmt %d)" caller f.fn f.block f.stmt
    | [] -> " (entry frame)"
  in
  raise (Failure ("vm trap: " ^ msg ^ where))

(* The static type of a local in a frame's function (the locals array
   carries the concrete types). *)
let type_of_local (vm : t) (fn_idx : int) (local : int) : Type_repr.t =
  let fn = vm.program.Seed_mir.functions.(fn_idx) in
  if local < 0 then begin
    (* the GLOBAL root: the type comes from the program.statics table *)
    let sidx = -1 - local in
    if sidx >= 0 && sidx < Array.length vm.program.Seed_mir.statics then
      let (_, ty, _, _) = vm.program.Seed_mir.statics.(sidx) in
      ty
    else err_trap vm (Printf.sprintf "static slot out of range: %d" sidx)
  end
  else if local >= Array.length fn.Seed_mir.locals then
    err_trap vm (Printf.sprintf "local _%d out of range" local)
  else fn.Seed_mir.locals.(local)

(* ── Semantic projection resolution (re-audit) ────────────────────
   The Field/Downcast projections carry SEMANTIC ids; the positional
   index/tag is metadata in the program's type-definition table
   (fd_index/vd_index) and is derived HERE at execution.  The verifier
   has already established the owner identity, so a miss at runtime is
   an invariant failure (deterministic trap). *)

let find_def (vm : t) (tid : Ids.Type_id.t) : Seed_mir.type_def option =
  let found = ref None in
  Array.iter
    (fun d -> if Seed_mir.def_id d = tid && !found = None then found := Some d)
    vm.program.Seed_mir.types;
  !found

(* FieldId -> positional index within the owner StructDef. *)
let field_index_of (vm : t) (ty : Type_repr.t) (fid : Ids.Field_id.t) : int =
  match ty with
  | Type_repr.Named (tid, _) -> (
      match find_def vm tid with
      | Some (Seed_mir.StructDef { sd_fields; _ }) -> (
          match
            List.find_opt
              (fun f -> Ids.Field_id.compare f.Seed_mir.fd_id fid = 0)
              sd_fields
          with
          | Some f -> Ids.Field_index.to_int f.Seed_mir.fd_index
          | None -> err_trap vm "field identity not found in the owner struct def")
      | _ -> err_trap vm "field projection on a non-struct value")
  | _ -> err_trap vm "field projection on a non-struct value"

(* VariantId -> declaration-order tag (vd_index) within the owner
   EnumDef. *)
let variant_index_of (vm : t) (ty : Type_repr.t) (vid : Ids.Variant_id.t) : int =
  match ty with
  | Type_repr.Named (tid, _) -> (
      match find_def vm tid with
      | Some (Seed_mir.EnumDef { ed_variants; _ }) -> (
          match
            List.find_opt
              (fun v -> Ids.Variant_id.compare v.Seed_mir.vd_id vid = 0)
              ed_variants
          with
          | Some v -> Ids.Variant_index.to_int v.Seed_mir.vd_index
          | None -> err_trap vm "variant identity not found in the owner enum def")
      | _ -> err_trap vm "variant projection on a non-enum value")
  | _ -> err_trap vm "variant projection on a non-enum value"

(* The static type produced by one projection: the VM mirrors the
   verifier's project_type with the program's def table, so the static
   type stays in sync with the value walk (a FieldId resolves its owner
   def's fd_ty, a VariantId its owner def's vd_payload, a tuple
   ConstantIndex its element).  Field/Downcast are SEMANTIC and need
   the static type to resolve their ids — a mismatch traps.  The
   positional forms (Deref/Index/ConstantIndex) are value-driven: when
   the static type does not match their expected shape (hand-written
   MIR with imprecise locals — the verifier rejects such chains, so no
   verified program reaches the fallback), the static type is carried
   through unchanged and the value-side case still bounds-checks. *)
let proj_type_of (vm : t) (ty : Type_repr.t) (proj : Seed_mir.projection) : Type_repr.t =
  match proj with
  | Seed_mir.Deref -> (
      match ty with
      | Type_repr.Ref_internal (_, t) | Type_repr.Raw_ptr (_, t) -> t
      | _ -> ty)
  | Seed_mir.Field fid -> (
      match ty with
      | Type_repr.Named (tid, _) -> (
          match find_def vm tid with
          | Some (Seed_mir.StructDef { sd_fields; _ }) -> (
              match
                List.find_opt
                  (fun f -> Ids.Field_id.compare f.Seed_mir.fd_id fid = 0)
                  sd_fields
              with
              | Some f -> f.Seed_mir.fd_ty
              | None -> err_trap vm "field identity not found in the owner struct def")
          | _ -> err_trap vm "field projection on a non-struct static type")
      | _ -> err_trap vm "field projection on a non-struct static type")
  | Seed_mir.ConstantIndex i -> (
      match ty with
      | Type_repr.Fixed_array (elem, n) ->
          if i < 0 || i >= n then err_trap vm "constant index out of bounds (static)"
          else elem
      | Type_repr.Tuple elems ->
          if i < 0 || i >= Array.length elems then
            err_trap vm "tuple index out of bounds (static)"
          else elems.(i)
      | Type_repr.String -> Type_repr.Char
      | _ -> ty)
  | Seed_mir.Index _ -> (
      match ty with
      | Type_repr.Fixed_array (elem, _) -> elem
      | Type_repr.Tuple elems when Array.length elems > 0 -> elems.(0)
      | Type_repr.Tuple _ -> err_trap vm "dynamic index on an empty tuple (static)"
      | Type_repr.String -> Type_repr.Char
      | _ -> ty)
  | Seed_mir.Downcast vid -> (
      match ty with
      | Type_repr.Named (tid, _) -> (
          match find_def vm tid with
          | Some (Seed_mir.EnumDef { ed_variants; _ }) -> (
              match
                List.find_opt
                  (fun v -> Ids.Variant_id.compare v.Seed_mir.vd_id vid = 0)
                  ed_variants
              with
              | Some v -> v.Seed_mir.vd_payload
              | None -> err_trap vm "variant identity not found in the owner enum def")
          | _ -> err_trap vm "variant projection on a non-enum static type")
      | _ -> err_trap vm "variant projection on a non-enum static type")

(* Evaluate an operand to a value (with slot-state checks). *)
let rec eval_operand (vm : t) (frame : frame) (op : Seed_mir.operand) : Vm_value.t =
  step_limit vm;
  match op with
  | Seed_mir.Constant c -> (
      match c with
      | Seed_mir.Unit -> Vm_value.Unit
      | Seed_mir.Bool b -> Vm_value.Bool b
      | Seed_mir.Integer i -> Vm_value.Int i
      | Seed_mir.Float32 f -> Vm_value.Float32 f
      | Seed_mir.Float64 f -> Vm_value.Float64 f
      | Seed_mir.Char c -> Vm_value.Char c
      | Seed_mir.String s -> Vm_value.String s
      | Seed_mir.Function inst -> Vm_value.Function inst
      (* the ctor constants: the runtime shapes of a nullary enum-variant
         value (the tag is the EnumCtor convention's vs_index), an empty
         struct literal and the empty Vec::new() container — a static
         read lowering to these constants executes as the aggregate *)
      | Seed_mir.Enum (vi, _) ->
          Vm_value.Enum (Ids.Variant_index.to_int vi, [||])
      | Seed_mir.Struct _ -> Vm_value.Struct [||]
      | Seed_mir.Array _ -> Vm_value.Array [||]
      | Seed_mir.Map _ -> Vm_value.Map []
      | Seed_mir.Set _ -> Vm_value.Set [])
  | Seed_mir.Copy p | Seed_mir.Read p -> (
      match read_place vm frame p with
      | Ok v -> v
      | Error e -> err_trap vm (Vm_value.slot_error_string e))
  | Seed_mir.Move p | Seed_mir.Consume p ->
      (* re-audit P12: the partial-move representation — a projected
         Move/Consume reads the projected COMPONENT (never the whole
         root) and writes the Moved hole marker into the component; the
         root slot stays Live with the hole and the drop glue skips the
         Moved components.  The verifier's moved lattice tracks the
         same per-path keys, so the dataflow and the executor agree. *)
      if p.Seed_mir.projections <> [] then begin
        let v =
          match read_place vm frame p with
          | Ok v -> v
          | Error e -> err_trap vm (Vm_value.slot_error_string e)
        in
        write_place vm frame p Vm_value.MovedOut;
        v
      end
      else begin
      let slot =
        if Seed_mir.root_is_static p.Seed_mir.root then
          let sidx = Seed_mir.root_static_index p.Seed_mir.root in
          if sidx >= Array.length frame.statics then
            err_trap vm ("static slot out of bounds: " ^ string_of_int sidx)
          else frame.statics.(sidx)
        else frame.locals.((Seed_mir.root_key p.Seed_mir.root))
      in
      (match Vm_value.move_slot slot with
       | Ok (v, s) ->
           (if Seed_mir.root_is_static p.Seed_mir.root then
              let sidx = Seed_mir.root_static_index p.Seed_mir.root in
              frame.statics.(sidx) <- s
            else frame.locals.((Seed_mir.root_key p.Seed_mir.root)) <- s);
           v
       | Error e -> err_trap vm (Vm_value.slot_error_string e))
      end

(* Read a place: project through the value.  A Deref projection resolves
   through memory (RawPtr) or through the reference target (Ref).  The
   static type of the base (from the frame's locals) is threaded through
   the walk so Field/Downcast can resolve their semantic ids against the
   program's type-definition table (fd_index/vd_index metadata). *)
and read_place (vm : t) (frame : frame) (p : Seed_mir.place) :
    (Vm_value.t, Vm_value.slot_error) result =
  step_limit vm;
  let base =
    if Seed_mir.root_is_static p.Seed_mir.root then
      let sidx = Seed_mir.root_static_index p.Seed_mir.root in
      if sidx >= Array.length frame.statics then
        Error (Vm_value.SlotOob sidx)
      else Vm_value.read_slot frame.statics.(sidx)
    else Vm_value.read_slot frame.locals.((Seed_mir.root_key p.Seed_mir.root))
  in
  match base with
  | Ok b ->
      let base_ty = type_of_local vm frame.fn (Seed_mir.root_key p.Seed_mir.root) in
      Ok (project_read vm frame b base_ty p.Seed_mir.projections)
  | Error e -> Error e

and project_read (vm : t) (frame : frame) (base : Vm_value.t) (base_ty : Type_repr.t)
    (projs : Seed_mir.projection list) : Vm_value.t =
  match base with
  | Vm_value.MovedOut ->
      (* re-audit P12: reading through a partial-move hole is an
         invariant break — the verifier's moved lattice blocks the path
         before execution; the VM traps as defense-in-depth *)
      err_trap vm "read through a moved-out (partial-move) component"
  | _ -> (
  match projs with
  | [] -> base
  | proj :: rest ->
      let next_ty = proj_type_of vm base_ty proj in
      let recurse v = project_read vm frame v next_ty rest in
      (match proj with
       | Seed_mir.Field fid -> (
           (* the semantic id resolves to the positional index through
              the owner def (the verifier has checked the owner
              identity) *)
           let i = field_index_of vm base_ty fid in
           match base with
           | Vm_value.Struct fields | Vm_value.Tuple fields ->
               if i < 0 || i >= Array.length fields then err_trap vm "field index out of bounds"
               else recurse fields.(i)
           | Vm_value.Enum (_, fields) ->
               if i < 0 || i >= Array.length fields then err_trap vm "enum field index out of bounds"
               else recurse fields.(i)
           | _ -> err_trap vm "field projection on non-aggregate")
       | Seed_mir.ConstantIndex i -> (
           match base with
           | Vm_value.Array elems ->
               if i < 0 || i >= Array.length elems then err_trap vm "index out of bounds"
               else recurse elems.(i)
           | Vm_value.Tuple elems ->
               if i < 0 || i >= Array.length elems then err_trap vm "tuple index out of bounds"
               else recurse elems.(i)
           | Vm_value.Struct elems ->
               if i < 0 || i >= Array.length elems then err_trap vm "struct index out of bounds"
               else recurse elems.(i)
           | Vm_value.String str ->
               if i < 0 || i >= String.length str then err_trap vm "string index out of bounds"
               else recurse (Vm_value.Char (Uchar.of_char str.[i]))
           | _ -> err_trap vm "index projection on non-array")
       | Seed_mir.Index li -> (
           let i = index_of_local vm frame li in
           match base with
           | Vm_value.Array elems ->
               if i < 0 || i >= Array.length elems then err_trap vm "index out of bounds"
               else recurse elems.(i)
           | Vm_value.Tuple elems ->
               if i < 0 || i >= Array.length elems then err_trap vm "tuple index out of bounds"
               else recurse elems.(i)
           | Vm_value.String str ->
               if i < 0 || i >= String.length str then err_trap vm "string index out of bounds"
               else recurse (Vm_value.Char (Uchar.of_char str.[i]))
           | _ -> err_trap vm "index projection on non-array")
       | Seed_mir.Downcast vid -> (
           (* the semantic id resolves to the declaration-order tag
              through the owner enum def; the runtime tag must equal it
              (a wrong-tag downcast is an invariant failure) *)
           let expect = variant_index_of vm base_ty vid in
           match base with
           | Vm_value.Enum (tag, fields) ->
               if tag <> expect then
                 err_trap vm
                   (Printf.sprintf
                      "variant downcast: runtime tag %d does not match VariantId %d's declaration-order tag %d"
                      tag (Ids.Variant_id.to_int vid) expect)
               else recurse (Vm_value.Struct fields)
           | _ -> err_trap vm "downcast on non-enum")
       | Seed_mir.Deref -> (
           match base with
           | Vm_value.Ref (Vm_value.Place (tf, l, projs)) ->
               (* a real reference: resolve the target place, then
                  continue the remaining projections on the target value *)
               let tv =
                 match read_place vm tf { Seed_mir.root = Seed_mir.Local l; projections = projs } with
                 | Ok v -> v
                 | Error e -> err_trap vm (Vm_value.slot_error_string e)
               in
               recurse tv
           | Vm_value.Ref (Vm_value.Region ptr) -> recurse (memory_load vm ptr)
           | Vm_value.RawPtr ptr -> recurse (memory_load vm ptr)
           | _ -> err_trap vm "deref on non-pointer")))

(* The dynamic-index form: the payload is a LOCAL whose value is the
   runtime index (the seed's dynamic-index convention).  The local is
   read through the slot machine; a non-integer or 128-bit index is a
   deterministic trap. *)
and index_of_local (vm : t) (frame : frame) (li : int) : int =
  if li < 0 || li >= Array.length frame.locals then
    err_trap vm "dynamic index local out of range";
  match Vm_value.read_slot frame.locals.(li) with
  | Error e -> err_trap vm (Vm_value.slot_error_string e)
  | Ok (Vm_value.Int i) ->
      if i.Int_value.width > 64 then err_trap vm "dynamic index is a 128-bit value";
      let n =
        if i.Int_value.width > 64 then
          err_trap vm "128-bit value used as an index (not representable in the seed)"
        else Int_value.to_int64 i
      in
      if n < 0L then err_trap vm "index out of bounds (negative)";
      if Int64.compare n (Int64.of_int max_int) > 0 then err_trap vm "index out of bounds";
      Int64.to_int n
  | Ok _ -> err_trap vm "dynamic index is not an integer"

(* Deref read: the region at the pointer holds a self-describing
   serialized value (Vm_value.serialize).  Null pointers, dead regions,
   out-of-bounds offsets and invalid payloads are deterministic traps. *)
and memory_load (vm : t) (ptr : Vm_memory.pointer) : Vm_value.t =
  if ptr.Vm_memory.region < 0 then err_trap vm "deref of null pointer";
  match Vm_memory.region_of vm.memory ptr with
  | Error e -> err_trap vm ("deref read: " ^ Vm_memory.mem_error_string e)
  | Ok r ->
      let len = Bytes.length r.Vm_memory.bytes in
      if ptr.Vm_memory.offset < 0 || ptr.Vm_memory.offset > len then
        err_trap vm "deref read: out-of-bounds";
      let sub = Bytes.sub r.Vm_memory.bytes ptr.Vm_memory.offset (len - ptr.Vm_memory.offset) in
      Vm_value.deserialize sub

(* Deref write: serialize the value into the region (in place, never a
   copy). *)
and memory_store (vm : t) (ptr : Vm_memory.pointer) (v : Vm_value.t) : unit =
  if ptr.Vm_memory.region < 0 then err_trap vm "deref of null pointer";
  let bytes = Vm_value.serialize v in
  match Vm_memory.region_of vm.memory ptr with
  | Error e -> err_trap vm ("deref write: " ^ Vm_memory.mem_error_string e)
  | Ok r ->
      let blen = Bytes.length bytes in
      let rlen = Bytes.length r.Vm_memory.bytes in
      if ptr.Vm_memory.offset < 0 || ptr.Vm_memory.offset > rlen - blen then
        err_trap vm "deref write: out-of-bounds";
      Bytes.blit bytes 0 r.Vm_memory.bytes ptr.Vm_memory.offset blen

(* Write a value into a place (assign). *)
and write_place (vm : t) (frame : frame) (p : Seed_mir.place) (v : Vm_value.t) : unit =
  step_limit vm;
  let statics_slot () =
    let sidx = Seed_mir.root_static_index p.Seed_mir.root in
    if sidx >= Array.length frame.statics then
      err_trap vm ("static slot out of bounds: " ^ string_of_int sidx)
    else frame.statics.(sidx)
  in
  match p.Seed_mir.projections with
  | [] -> (
      if Seed_mir.root_is_static p.Seed_mir.root then
        match Vm_value.write_slot (statics_slot ()) v with
        | Ok s -> frame.statics.(Seed_mir.root_static_index p.Seed_mir.root) <- s
        | Error e -> err_trap vm (Vm_value.slot_error_string e)
      else
        match Vm_value.write_slot frame.locals.((Seed_mir.root_key p.Seed_mir.root)) v with
        | Ok s -> frame.locals.((Seed_mir.root_key p.Seed_mir.root)) <- s
        | Error e -> err_trap vm (Vm_value.slot_error_string e))
  | projs -> (
      let base =
        if Seed_mir.root_is_static p.Seed_mir.root then Vm_value.read_slot (statics_slot ())
        else Vm_value.read_slot frame.locals.((Seed_mir.root_key p.Seed_mir.root))
      in
      let base =
        match base with
        | Ok b -> b
        | Error e -> err_trap vm (Vm_value.slot_error_string e)
      in
      let base_ty = type_of_local vm frame.fn (Seed_mir.root_key p.Seed_mir.root) in
      let updated = update_place vm frame base base_ty projs v in
      if Seed_mir.root_is_static p.Seed_mir.root then
        match Vm_value.write_slot (statics_slot ()) updated with
        | Ok s -> frame.statics.(Seed_mir.root_static_index p.Seed_mir.root) <- s
        | Error e -> err_trap vm (Vm_value.slot_error_string e)
      else
        match Vm_value.write_slot frame.locals.((Seed_mir.root_key p.Seed_mir.root)) updated with
        | Ok s -> frame.locals.((Seed_mir.root_key p.Seed_mir.root)) <- s
      | Error e -> err_trap vm (Vm_value.slot_error_string e))

and update_place (vm : t) (frame : frame) (base : Vm_value.t) (base_ty : Type_repr.t)
    (projs : Seed_mir.projection list) (v : Vm_value.t) : Vm_value.t =
  match projs with
  | [] -> v
  | proj :: rest -> (
      let next_ty = proj_type_of vm base_ty proj in
      match proj with
      | Seed_mir.Field fid -> (
          let i = field_index_of vm base_ty fid in
          match base with
          | Vm_value.Struct fields ->
              if i < 0 || i >= Array.length fields then err_trap vm "field index out of bounds";
              let copy = Array.copy fields in
              copy.(i) <- update_place vm frame fields.(i) next_ty rest v;
              Vm_value.Struct copy
          | Vm_value.Tuple fields ->
              if i < 0 || i >= Array.length fields then err_trap vm "field index out of bounds";
              let copy = Array.copy fields in
              copy.(i) <- update_place vm frame fields.(i) next_ty rest v;
              Vm_value.Tuple copy
          | _ -> err_trap vm "field write on non-aggregate")
      | Seed_mir.ConstantIndex i -> (
          match base with
          | Vm_value.Array elems ->
              if i < 0 || i >= Array.length elems then err_trap vm "index out of bounds";
              let copy = Array.copy elems in
              copy.(i) <- update_place vm frame elems.(i) next_ty rest v;
              Vm_value.Array copy
          | Vm_value.Tuple elems ->
              if i < 0 || i >= Array.length elems then err_trap vm "tuple index out of bounds";
              let copy = Array.copy elems in
              copy.(i) <- update_place vm frame elems.(i) next_ty rest v;
              Vm_value.Tuple copy
          | Vm_value.Struct elems ->
              if i < 0 || i >= Array.length elems then err_trap vm "struct index out of bounds";
              let copy = Array.copy elems in
              copy.(i) <- update_place vm frame elems.(i) next_ty rest v;
              Vm_value.Struct copy
          | Vm_value.String str ->
              if i < 0 || i >= String.length str then err_trap vm "string index out of bounds";
              let c =
                match update_place vm frame (Vm_value.Char (Uchar.of_char str.[i])) next_ty rest v with
                | Vm_value.Char c -> c
                | _ -> err_trap vm "string index write with non-char value"
              in
              Vm_value.String (string_with_char_at str i c)
          | _ -> err_trap vm "index write on non-array")
      | Seed_mir.Index li -> (
          let i = index_of_local vm frame li in
          match base with
          | Vm_value.Array elems ->
              if i < 0 || i >= Array.length elems then err_trap vm "index out of bounds";
              let copy = Array.copy elems in
              copy.(i) <- update_place vm frame elems.(i) next_ty rest v;
              Vm_value.Array copy
          | Vm_value.Tuple elems ->
              if i < 0 || i >= Array.length elems then err_trap vm "tuple index out of bounds";
              let copy = Array.copy elems in
              copy.(i) <- update_place vm frame elems.(i) next_ty rest v;
              Vm_value.Tuple copy
          | Vm_value.String str ->
              if i < 0 || i >= String.length str then err_trap vm "string index out of bounds";
              let c =
                match update_place vm frame (Vm_value.Char (Uchar.of_char str.[i])) next_ty rest v with
                | Vm_value.Char c -> c
                | _ -> err_trap vm "string index write with non-char value"
              in
              Vm_value.String (string_with_char_at str i c)
          | _ -> err_trap vm "index write on non-array")
      | Seed_mir.Downcast _ -> base
      | Seed_mir.Deref -> (
          match base with
          | Vm_value.Ref (Vm_value.Place (tf, l, projs)) ->
              (* a real reference: write through to the target place; the
                 remaining projections extend the target path; the ref
                 value itself is unchanged *)
              write_place vm tf
                { Seed_mir.root = Seed_mir.Local l; projections = projs @ rest }
                v;
              base
          | Vm_value.Ref (Vm_value.Region _) ->
              err_trap vm "write through a region-backed ref (computed-value ref) is a deterministic trap"
          | Vm_value.RawPtr ptr -> (
              match rest with
              | [] -> memory_store vm ptr v
              | _ ->
                  (* projected write through the pointee: load, update, store *)
                  let cur = memory_load vm ptr in
                  memory_store vm ptr (update_place vm frame cur next_ty rest v));
              base
          | _ -> err_trap vm "deref write on non-pointer"))

(* Replace the byte at index i with the char's UTF-8 encoding (the byte
   index is the seed String convention — see the header).  The char's
   encoding may be multi-byte, so the result string's length changes. *)
and string_with_char_at (str : string) (i : int) (c : Uchar.t) : string =
  let encoded = uchar_utf8_encode c in
  let prefix = String.sub str 0 i in
  let suffix = String.sub str (i + 1) (String.length str - i - 1) in
  prefix ^ encoded ^ suffix

(* UTF-8 encode a code point (deterministic; the input Uchar is always
   valid). *)
and uchar_utf8_encode (c : Uchar.t) : string =
  let cp = Uchar.to_int c in
  if cp <= 0x7F then String.make 1 (Char.chr cp)
  else if cp <= 0x7FF then
    String.init 2 (fun j ->
        if j = 0 then Char.chr (0xC0 lor (cp lsr 6))
        else Char.chr (0x80 lor (cp land 0x3F)))
  else if cp <= 0xFFFF then
    String.init 3 (fun j ->
        match j with
        | 0 -> Char.chr (0xE0 lor (cp lsr 12))
        | 1 -> Char.chr (0x80 lor ((cp lsr 6) land 0x3F))
        | _ -> Char.chr (0x80 lor (cp land 0x3F)))
  else
    String.init 4 (fun j ->
        match j with
        | 0 -> Char.chr (0xF0 lor (cp lsr 18))
        | 1 -> Char.chr (0x80 lor ((cp lsr 12) land 0x3F))
        | 2 -> Char.chr (0x80 lor ((cp lsr 6) land 0x3F))
        | _ -> Char.chr (0x80 lor (cp land 0x3F)))

(* ── The P1-26 typed drop ──────────────────────────────────────────
   The canonical per-concrete-TypeId drop plans (drop_plan.ml, built
   once per program) drive every destruction site where the type is
   known.  drop_value_typed consults the plan of the value's TYPE: a
   materialized plan enumerates the def's components (declaration
   order; the runtime enum tag selects the live variant), and each
   component's value is dropped recursively under its own type — the
   recursion is derived ONCE per type (the plan table), never re-derived
   per value.  A type with no materialized plan (String, the container/
   pointer handle nominals, tuples, references, ...) falls back to the
   structural value glue — exactly the sanctioned fallback.  The
   traversal order equals the glue's (depth-first, declaration order),
   so a plan-driven drop frees exactly what the glue frees, in the same
   order; a shape/type mismatch (defensive; verified programs cannot
   produce one) falls back to the glue on the whole value. *)
let rec drop_value_typed (vm : t) (ty : Type_repr.t) (v : Vm_value.t) : unit =
  match Drop_plan.plan_of_type vm.drop_plans ty with
  | None -> Vm_value.drop_glue vm.memory v
  | Some plan -> (
      match v with
      | Vm_value.Struct elems ->
          List.iter
            (fun (c : Drop_plan.component) ->
              match c.Drop_plan.variant with
              | Some _ -> ()
              | None ->
                  if c.Drop_plan.index >= 0 && c.Drop_plan.index < Array.length elems then
                    drop_value_typed vm c.Drop_plan.ty elems.(c.Drop_plan.index))
            plan.Drop_plan.components
      | Vm_value.Enum (tag, payload) ->
          List.iter
            (fun (c : Drop_plan.component) ->
              match c.Drop_plan.variant with
              | Some t when t = tag ->
                  if c.Drop_plan.index >= 0 && c.Drop_plan.index < Array.length payload then
                    drop_value_typed vm c.Drop_plan.ty payload.(c.Drop_plan.index)
              | _ -> ())
            plan.Drop_plan.components
      | _ -> Vm_value.drop_glue vm.memory v)

(* re-audit P0-9 / P1-26: drop the old value at a place about to be
   OVERWRITTEN by an assignment — resolve the current component value
   WITHOUT trapping on a MovedOut hole and run the typed drop over it
   (the plan-driven recursion frees region-backed refs and is a no-op
   for everything else; plan-less values fall back to the structural
   glue). *)
let drop_old_value_at (vm : t) (frame : frame) (p : Seed_mir.place) : unit =
  let ty_of_place () : Type_repr.t =
    let root_ty = type_of_local vm frame.fn (Seed_mir.root_key p.Seed_mir.root) in
    List.fold_left (fun ty proj -> proj_type_of vm ty proj) root_ty p.Seed_mir.projections
  in
  let drop_slot s =
    match s with
    | Vm_value.Live v -> drop_value_typed vm (ty_of_place ()) v
    | Vm_value.Uninitialized | Vm_value.Moved | Vm_value.Dropped -> ()
  in
  if Seed_mir.root_is_static p.Seed_mir.root then
    let sidx = Seed_mir.root_static_index p.Seed_mir.root in
    if sidx < Array.length frame.statics then drop_slot frame.statics.(sidx)
  else begin
    let local = Seed_mir.root_key p.Seed_mir.root in
    if local >= 0 && local < Array.length frame.locals then
      match p.Seed_mir.projections with
      | [] -> drop_slot frame.locals.(local)
      | _projs -> (
          (* the projected overwrite: only the exact leaf component's
             old value is replaced — walk the aggregate tree without
             trapping on MovedOut holes *)
          let rec leaf_value (v : Vm_value.t) (projs : Seed_mir.projection list) :
              Vm_value.t option =
            match projs with
            | [] -> Some v
            | proj :: rest -> (
                match proj, v with
                | Seed_mir.Field fid, Vm_value.Struct fields -> (
                    let i = field_index_of vm (type_of_local vm frame.fn local) fid in
                    if i >= 0 && i < Array.length fields then
                      match fields.(i) with
                      | Vm_value.MovedOut -> None
                      | fv -> leaf_value fv rest
                    else None)
                | Seed_mir.ConstantIndex k, (Vm_value.Tuple elems | Vm_value.Array elems)
                  when k >= 0 && k < Array.length elems -> (
                    match elems.(k) with
                    | Vm_value.MovedOut -> None
                    | ev -> leaf_value ev rest)
                | Seed_mir.Downcast _, Vm_value.Enum (_, payload) ->
                    if Array.length payload > 0 then leaf_value payload.(0) rest else None
                | _ -> None)
          in
          match frame.locals.(local) with
          | Vm_value.Live v -> (
              match leaf_value v p.Seed_mir.projections with
              | Some old -> drop_value_typed vm (ty_of_place ()) old
              | None -> ())
          | _ -> ())
  end

(* A needs_drop value requires a Drop terminator; the verifier has already
   checked the plan.  The drop is RECURSIVE: the value's contained
   components run their drop glue first (aggregates depth-first; every
   region-backed ref inside is freed), then the outer slot transitions.
   The VM knows the local's TYPE (fn.locals), so the drop runs through
   the local's canonical drop plan (P1-26) instead of re-deriving the
   recursion per value; values whose plan is not materialized fall back
   to the structural glue.  Moved/Uninitialized slots are no-ops and a
   second drop of a Dropped slot traps — exactly the slot machine in
   vm_value.ml. *)
let do_drop (vm : t) (frame : frame) (local : int) : unit =
  match frame.locals.(local) with
  | Vm_value.Live v ->
      drop_value_typed vm (type_of_local vm frame.fn local) v;
      frame.locals.(local) <- Vm_value.Dropped
  | Vm_value.Moved | Vm_value.Uninitialized -> ()
  | Vm_value.Dropped -> err_trap vm (Vm_value.slot_error_string Vm_value.DropDropped)

(* Frame-shape invariant, enforced at frame creation (the VM boundary):
   the block array must be indexed by block id — blocks.(i).id = i for
   every i — and the function must declare at least one local (local _0
   is the return slot).  Mis-shaped MIR traps deterministically instead
   of indexing out of bounds. *)
let check_fn_shape (vm : t) (fn_idx : int) : unit =
  let fn = vm.program.Seed_mir.functions.(fn_idx) in
  let nblocks = Array.length fn.Seed_mir.blocks in
  if nblocks > 0 then begin
    Array.iteri
      (fun i b ->
        if b.Seed_mir.id <> i then
          err_trap vm
            (Printf.sprintf
               "function %s: block array must be indexed by block id: blocks.(%d).id = %d (expected %d)"
               fn.Seed_mir.name i b.Seed_mir.id i))
      fn.Seed_mir.blocks;
    if fn.Seed_mir.entry < 0 || fn.Seed_mir.entry >= nblocks then
      err_trap vm
        (Printf.sprintf "function %s: entry block %d out of range 0..%d"
           fn.Seed_mir.name fn.Seed_mir.entry (nblocks - 1))
  end;
  if Array.length fn.Seed_mir.locals < 1 then
    err_trap vm
      (Printf.sprintf "function %s: must declare at least one local (local _0 is the return slot)"
         fn.Seed_mir.name)

(* True when v is the signed minimum of its width: the unique non-zero
   value whose two's-complement negation wraps to itself (the 128-bit
   pattern is explicit: hi = min_int, lo = 0).  Representation-robust:
   it does not depend on how Int_value stores sign-extended low words. *)
let is_signed_min (v : Int_value.t) : bool =
  let open Int_value in
  v.signed
  && if v.width = 128 then v.bits_hi = Int64.min_int && v.bits_lo = 0L
     else not (is_zero v) && compare_vals v (neg v) = 0

(* The signed value -1 of the value's width. *)
let is_neg_one (v : Int_value.t) : bool =
  let open Int_value in
  v.signed
  && if v.width = 128 then v.bits_lo = -1L && v.bits_hi = -1L else v.bits_lo = -1L

(* Signed division overflows exactly when min / -1 is evaluated: the true
   quotient 2^(w-1) does not fit the width, so no deterministic exact
   value exists. Trap instead of inventing one. *)
let int_div_overflow (a : Int_value.t) (b : Int_value.t) : bool =
  is_signed_min a && is_neg_one b

let binop_int (vm : t) (op : Seed_mir.bin_op) (a : Int_value.t) (b : Int_value.t) : Vm_value.t =
  let open Int_value in
  match op with
  | Seed_mir.Add -> Vm_value.Int (add a b)
  | Seed_mir.Sub -> Vm_value.Int (sub a b)
  | Seed_mir.Mul -> Vm_value.Int (mul a b)
  | Seed_mir.Div | Seed_mir.Rem ->
      if int_div_overflow a b then err_trap vm "signed division overflow"
      else
        (try
           Vm_value.Int (if op = Seed_mir.Div then div a b else rem a b)
         with Division_by_zero -> err_trap vm "division by zero")
  | Seed_mir.Eq -> Vm_value.Bool (compare_vals a b = 0)
  | Seed_mir.Ne -> Vm_value.Bool (compare_vals a b <> 0)
  | Seed_mir.Lt -> Vm_value.Bool (compare_vals a b < 0)
  | Seed_mir.Le -> Vm_value.Bool (compare_vals a b <= 0)
  | Seed_mir.Gt -> Vm_value.Bool (compare_vals a b > 0)
  | Seed_mir.Ge -> Vm_value.Bool (compare_vals a b >= 0)
  | Seed_mir.BitAnd -> Vm_value.Int (logand a b)
  | Seed_mir.BitOr -> Vm_value.Int (logor a b)
  | Seed_mir.BitXor -> Vm_value.Int (logxor a b)
  | Seed_mir.Shl -> Vm_value.Int (shift_left a b)
  | Seed_mir.Shr -> Vm_value.Int (shift_right a b)
  | Seed_mir.And -> Vm_value.Bool (not (is_zero a) && not (is_zero b))
  | Seed_mir.Or -> Vm_value.Bool (not (is_zero a) || not (is_zero b))

let rec eval_rvalue (vm : t) (frame : frame) (rv : Seed_mir.rvalue) : Vm_value.t =
  step_limit vm;
  match rv with
  | Seed_mir.Use op -> eval_operand vm frame op
  | Seed_mir.Ref p | Seed_mir.RefMut p ->
      if Seed_mir.root_is_static p.Seed_mir.root || (Seed_mir.root_key p.Seed_mir.root) >= Array.length frame.locals then
        err_trap vm "ref of out-of-range local";
      if List.exists (function Seed_mir.Deref -> true | _ -> false) p.Seed_mir.projections then
        (* computed-value source (e.g. `&*ptr`): the target is not a
           local subplace; keep a serialized copy in a fresh region;
           writes through this ref are a deterministic trap *)
        (match read_place vm frame p with
         | Ok v -> Vm_value.Ref (Vm_value.Region (vm_alloc_scalar vm v))
         | Error e -> err_trap vm (Vm_value.slot_error_string e))
      else
        (* real reference: record the target (frame, local, projections) *)
        Vm_value.Ref (Vm_value.Place (frame, (Seed_mir.root_key p.Seed_mir.root), p.Seed_mir.projections))
  | Seed_mir.Aggregate (kind, ops) ->
      let vals = Array.of_list (List.map (eval_operand vm frame) ops) in
      (match kind with
       | Seed_mir.TupleAgg -> Vm_value.Tuple vals
       | Seed_mir.ArrayAgg -> Vm_value.Array vals
       | Seed_mir.StructCtor _ -> Vm_value.Struct vals
       | Seed_mir.EnumCtor (_, vid) -> Vm_value.Enum (Ids.Variant_index.to_int vid, vals)
       | Seed_mir.ClosureAgg inst -> Vm_value.Closure (inst, vals))
  | Seed_mir.BinaryOp (op, l, r) ->
      let lv = eval_operand vm frame l in
      let rv = eval_operand vm frame r in
      (match lv, rv with
       | Vm_value.Int a, Vm_value.Int b -> binop_int vm op a b
       | Vm_value.Bool a, Vm_value.Bool b -> (
           match op with
           | Seed_mir.And -> Vm_value.Bool (a && b)
           | Seed_mir.Or -> Vm_value.Bool (a || b)
           | Seed_mir.Eq -> Vm_value.Bool (a = b)
           | Seed_mir.Ne -> Vm_value.Bool (a <> b)
           | _ -> err_trap vm "invalid bool binary op")
       | Vm_value.String a, Vm_value.String b -> (
           match op with
           | Seed_mir.Add -> Vm_value.String (a ^ b)
           | Seed_mir.Eq -> Vm_value.Bool (a = b)
           | Seed_mir.Ne -> Vm_value.Bool (a <> b)
           | Seed_mir.Lt -> Vm_value.Bool (a < b)
           | Seed_mir.Le -> Vm_value.Bool (a <= b)
           | Seed_mir.Gt -> Vm_value.Bool (a > b)
           | Seed_mir.Ge -> Vm_value.Bool (a >= b)
           | _ -> err_trap vm "invalid string binary op")
        | Vm_value.Float64 a, Vm_value.Float64 b -> (
            let fa = Int64.float_of_bits a and fb = Int64.float_of_bits b in
            match op with
            | Seed_mir.Add -> Vm_value.Float64 (Int64.bits_of_float (fa +. fb))
            | Seed_mir.Sub -> Vm_value.Float64 (Int64.bits_of_float (fa -. fb))
            | Seed_mir.Mul -> Vm_value.Float64 (Int64.bits_of_float (fa *. fb))
            | Seed_mir.Div -> Vm_value.Float64 (Int64.bits_of_float (fa /. fb))
            | Seed_mir.Eq -> Vm_value.Bool (fa = fb)
            | Seed_mir.Ne -> Vm_value.Bool (fa <> fb)
            | Seed_mir.Lt -> Vm_value.Bool (fa < fb)
            | Seed_mir.Le -> Vm_value.Bool (fa <= fb)
            | Seed_mir.Gt -> Vm_value.Bool (fa > fb)
            | Seed_mir.Ge -> Vm_value.Bool (fa >= fb)
            | _ -> err_trap vm "invalid float binary op")
        | ( Vm_value.Enum _, Vm_value.Enum _
          | Vm_value.Tuple _, Vm_value.Tuple _
          | Vm_value.Struct _, Vm_value.Struct _
          | Vm_value.Array _, Vm_value.Array _
          | Vm_value.Char _, Vm_value.Char _
          | Vm_value.Float32 _, Vm_value.Float32 _ ) -> (
            (* aggregate/scalar equality beyond the int/bool/string
               primitives — the checker's fundamental equality accepts
               whole-enum/struct/tuple operands (`tok.kind == kind`, the
               parser's token-kind dispatch), so the runtime compares the
               values structurally (Vm_value.equal: tags + payloads) *)
            match op with
            | Seed_mir.Eq -> Vm_value.Bool (Vm_value.equal lv rv)
            | Seed_mir.Ne -> Vm_value.Bool (not (Vm_value.equal lv rv))
            | _ -> err_trap vm "ordering on aggregate operands")
        | _ -> err_trap vm "binary op on unsupported value pair")
  | Seed_mir.UnaryOp (op, v) -> (
      let vv = eval_operand vm frame v in
      match op, vv with
      | Seed_mir.Neg, Vm_value.Int i -> Vm_value.Int (Int_value.neg i)
      | Seed_mir.Neg, Vm_value.Float64 f -> Vm_value.Float64 (Int64.bits_of_float (-. Int64.float_of_bits f))
      | Seed_mir.Not, Vm_value.Bool b -> Vm_value.Bool (not b)
      | Seed_mir.Not, Vm_value.Int i -> Vm_value.Bool (Int_value.is_zero i)
      | _ -> err_trap vm "invalid unary op")
  | Seed_mir.Discriminant p -> (
      match read_place vm frame p with
      | Ok (Vm_value.Enum (i, _)) -> Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int i))
      | _ -> err_trap vm "discriminant on non-enum")
  | Seed_mir.Len p -> (
      match read_place vm frame p with
      | Ok (Vm_value.Array a) -> Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (Array.length a)))
      | Ok (Vm_value.String s) -> Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (String.length s)))
      | Ok (Vm_value.Tuple t) -> Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (Array.length t)))
      | _ -> err_trap vm "len on unsupported value")
  | Seed_mir.Cast (op, ty) -> (
      let vv = eval_operand vm frame op in
      match ty with
      | Type_repr.Int kind -> (
          match vv with
          | Vm_value.Int i -> Vm_value.Int (int_cast i kind)
          | Vm_value.Float64 f -> Vm_value.Int (Int_value.of_int64 ~width:(int_width kind) ~signed:(int_signed kind) (Int64.of_float (Int64.float_of_bits f)))
          | Vm_value.Bool b -> Vm_value.Int (Int_value.of_int64 ~width:(int_width kind) ~signed:(int_signed kind) (if b then 1L else 0L))
          | _ -> err_trap vm "invalid cast to int")
      | Type_repr.Float Type_repr.F64 -> (
          match vv with
          | Vm_value.Int i ->
              if i.Int_value.width > 64 then
                err_trap vm "128-bit value cast to f64 (not representable in the seed)"
              else Vm_value.Float64 (Int64.bits_of_float (Int64.to_float (Int_value.to_int64 i)))
          | Vm_value.Float32 f -> Vm_value.Float64 (Int64.bits_of_float (Int32.float_of_bits f))
          | Vm_value.Float64 f -> Vm_value.Float64 f
          | _ -> err_trap vm "invalid cast to f64")
      | Type_repr.Float Type_repr.F32 -> (
          match vv with
          | Vm_value.Int i ->
              if i.Int_value.width > 64 then
                err_trap vm "128-bit value cast to f32 (not representable in the seed)"
              else Vm_value.Float32 (Int32.bits_of_float (Int64.to_float (Int_value.to_int64 i)))
          | Vm_value.Float64 f -> Vm_value.Float32 (Int32.bits_of_float (Int64.float_of_bits f))
          | _ -> err_trap vm "invalid cast to f32")
      | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> (
          match vv with
          | Vm_value.Int i ->
              if i.Int_value.width > 64 then
                err_trap vm "128-bit value cast to a pointer (not representable in the seed)"
              else Vm_value.RawPtr { Vm_memory.region = Int64.to_int (Int_value.to_int64 i); offset = 0 }
          | Vm_value.RawPtr _ -> vv
          | _ -> err_trap vm "invalid cast to pointer")
      | Type_repr.Unit -> Vm_value.Unit
      | Type_repr.Bool -> (
          match vv with
          | Vm_value.Int i -> Vm_value.Bool (not (Int_value.is_zero i))
          | Vm_value.Bool _ -> vv
          | _ -> err_trap vm "invalid cast to bool")
      | Type_repr.Char -> (
          match vv with
          | Vm_value.Int i ->
              if i.Int_value.width > 64 then
                err_trap vm "128-bit value cast to char (not representable in the seed)"
              else Vm_value.Char (Uchar.of_int (Int64.to_int (Int_value.to_int64 i)))
          | Vm_value.Char _ -> vv
          | _ -> err_trap vm "invalid cast to char")
      | Type_repr.Named _ | Type_repr.Tuple _ | Type_repr.Fixed_array _ ->
          (* re-audit P12: the enum-rebrand cast — the `?` failure path
             moves the WHOLE subject (Result[Int, E] -> Result[String,
             E]) when the two instantiate the same enum: the runtime
             value (tag + payload slots) is already the identical
             Err(E), so the cast passes the value through.  Anything
             that is not already the runtime shape of the target is an
             invariant break. *)
          (match vv with
           | Vm_value.Enum _ | Vm_value.Struct _ | Vm_value.Array _ | Vm_value.Tuple _ ->
               vv
           | _ -> err_trap vm "enum-rebrand cast of a non-aggregate value")
      | _ -> err_trap vm "cast to unsupported type")

and int_width = function
  | Type_repr.I8 | Type_repr.U8 -> 8
  | Type_repr.I16 | Type_repr.U16 -> 16
  | Type_repr.I32 | Type_repr.U32 -> 32
  | Type_repr.I64 | Type_repr.U64 | Type_repr.Int | Type_repr.UInt -> 64
  | Type_repr.I128 | Type_repr.U128 -> 128

and int_signed = function
  | Type_repr.I8 | Type_repr.I16 | Type_repr.I32 | Type_repr.I64 | Type_repr.I128 | Type_repr.Int -> true
  | _ -> false

and int_cast (i : Int_value.t) (kind : Type_repr.int_kind) : Int_value.t =
  Int_value.of_int64 ~width:(int_width kind) ~signed:(int_signed kind) (Int_value.to_int64 i)

(* Allocate a region holding the serialized bytes of a value (the
   computed-value refs).  An allocation failure is a deterministic trap,
   never a silent fallback. *)
and vm_alloc_scalar (vm : t) (v : Vm_value.t) : Vm_memory.pointer =
  let bytes = Vm_value.serialize v in
  let size = Bytes.length bytes in
  vm.alloc_bytes <- vm.alloc_bytes + size;
  if vm.alloc_bytes > vm.limits.max_alloc_bytes then err_trap vm "allocation limit exceeded";
  match Vm_memory.alloc vm.memory size 8 with
  | Error e -> err_trap vm ("allocation failed: " ^ Vm_memory.mem_error_string e)
  | Ok ptr -> (
      match Vm_memory.region_of vm.memory ptr with
      | Error e -> err_trap vm ("allocation failed: " ^ Vm_memory.mem_error_string e)
      | Ok r -> Bytes.blit bytes 0 r.Vm_memory.bytes 0 size);
      ptr

let rec exec_terminator (vm : t) (frame : frame) (term : Seed_mir.terminator) : unit =
  step_limit vm;
  match term with
  | Seed_mir.Goto b ->
      frame.block <- b;
      frame.stmt <- 0
  | Seed_mir.Ret -> raise Exit
  | Seed_mir.SwitchInt (op, targets, otherwise) -> (
      let v = eval_operand vm frame op in
      let tag =
        match v with
        | Vm_value.Int i ->
            if i.Int_value.width > 64 then
              err_trap vm "128-bit switch value (not representable in the seed)"
            else Int_value.to_int64 i
        | Vm_value.Bool b -> if b then 1L else 0L
        | Vm_value.Char c -> Int64.of_int (Uchar.to_int c)
        | _ -> err_trap vm "switchInt on non-tag value"
      in
      let rec find = function
        | [] -> otherwise
        | (t, b) :: rest -> if t = tag then b else find rest
      in
      frame.block <- find targets;
      frame.stmt <- 0)
  | Seed_mir.Call (dest, callee, args, next, _unwind) ->
      (* re-audit P0-A (the four-effect ABI): an Initialize argument is
         writable storage that does not need to contain a readable value
         yet — it is NOT read before the call (the old pre-eval trapped
         on an uninitialized caller place before the callee could
         initialize it) *)
      let arg_vals =
        Array.map
          (fun a ->
            match a.Seed_mir.effect_ with
            | Access_effect.Initialize -> Vm_value.Unit
            | _ -> eval_operand vm frame a.Seed_mir.value)
          args
      in
      (* re-audit P12: the closure-VALUE call — the FnValue callee is a
         RUNTIME fn value: `Vm_value.Function inst` (a plain
         named-function pointer — the kernel's fn-typed params/fields)
         or `Vm_value.Closure (inst, caps)` (a closure object; the
         capture tuple binds the callee's trailing env parameters, the
         Swift reference's convention).  Both execute the same
         user-call machinery below. *)
      let inst, caps =
        match callee with
        | Seed_mir.User inst -> (inst, [||])
        | Seed_mir.Derived (c, args) ->
            (* audit P0-5: the compiler-synthesized derived contract
               class — the callee names the derived function under the
               SAME callable identity its emitted (specialized) body
               carries, so the dispatch is exactly the user-call
               machinery *)
            (Instance_id.make ~callable:c ~type_args:args, [||])
        | Seed_mir.FnValue op -> (
            match eval_operand vm frame op with
            | Vm_value.Function inst -> (inst, [||])
            | Vm_value.Closure (inst, caps) -> (inst, caps)
            | _ ->
                err_trap vm
                  "fn-value call: callee operand is not a function value")
        | Seed_mir.TypeQuery (k, _) ->
            err_trap vm
              (Printf.sprintf
                 "type-query call `%s` reached the VM: the seed has no layout authority to fold the query (audit P0-5 — the TypeQuery callee must be resolved by layout folding or a precise host channel, never a body-less User callee; deterministic trap)"
                 (Seed_mir.type_query_name k))
        | Seed_mir.Intrinsic _ | Seed_mir.Extern _ ->
            ( Instance_id.make ~callable:(Ids.Callable_id.make (-1)) ~type_args:[||],
              [||] )
      in
      (match callee with
       | Seed_mir.User _ | Seed_mir.FnValue _ | Seed_mir.Derived _ ->
           let fn_idx =
             match find_fn vm inst with
             | Some idx -> idx
             | None ->
                 let caller_name =
                   if frame.fn >= 0 && frame.fn < Array.length vm.program.Seed_mir.functions
                   then vm.program.Seed_mir.functions.(frame.fn).Seed_mir.name
                   else "?"
                 in
                 err_trap vm
                   (Printf.sprintf "call to unknown instance %s (in %s)"
                      (Seed_mir.print_instance inst) caller_name)
           in
           vm.frames <- frame :: vm.frames;
           if List.length vm.frames > vm.limits.max_depth then
             err_trap vm "call depth exceeded";
           let fn = vm.program.Seed_mir.functions.(fn_idx) in
           check_fn_shape vm fn_idx;
           let callee_frame =
             { fn = fn_idx;
               locals = Array.make (Array.length fn.Seed_mir.locals) Vm_value.Uninitialized;
               statics = frame.statics;
               block = fn.Seed_mir.entry;
               stmt = 0 }
           in
           (try
              (* params occupy locals _1 .. _n (local _0 is the return
                 slot).  A Set (Initialize) parameter enters the callee
                 as an UNINITIALIZED output place — the callee must
                 initialize it before returning; every other convention
                 enters as the copied Live value. *)
              let all_args = Array.append arg_vals caps in
              Array.iteri
                (fun i _slot ->
                  if i < Array.length args
                     && args.(i).Seed_mir.effect_ = Access_effect.Initialize
                  then callee_frame.locals.(i + 1) <- Vm_value.Uninitialized
                  else callee_frame.locals.(i + 1) <- Vm_value.Live all_args.(i))
                (Array.sub all_args 0 (Array.length fn.Seed_mir.params));
              run_frame vm callee_frame
            with Exit -> ());

           (* The return slot is the callee's declared return value.  For a
              Unit-typed return it may legitimately be left Uninitialized
              (return Unit then); for any other declared return type an
              uninitialized or moved/dropped slot at return is an invariant
              failure and traps — the VM never fabricates a value. *)
           let ret =
             match callee_frame.locals.(0) with
             | Vm_value.Live v -> v
             | Vm_value.Uninitialized ->
                 if fn.Seed_mir.locals.(0) = Type_repr.Unit then Vm_value.Unit
                 else
                   err_trap vm
                     (Printf.sprintf
                        "callee %s returned with an uninitialized return slot (declared return type %s is not unit)"
                        fn.Seed_mir.name (Seed_mir.print_type fn.Seed_mir.locals.(0)))
             | Vm_value.Moved | Vm_value.Dropped ->
                 err_trap vm
                   (Printf.sprintf "callee %s returned with a non-live return slot"
                      fn.Seed_mir.name)
           in
           (* re-audit P0 (the inout calling convention): a
              Modify/Initialize argument is a PLACE channel — the
              callee's parameter local aliases the caller's storage via
              explicit deterministic copy-in/copy-out.  The callee runs
              on the copied value; after it returns, the (possibly
              modified) parameter local copies back into the caller's
              place.  Without this, `def mutate(inout x: Int) ...;
              mutate(a)` would silently discard the mutation. *)
           Array.iteri
             (fun i a ->
               match a.Seed_mir.effect_ with
               | Access_effect.Modify -> (
                   match a.Seed_mir.value with
                   | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p -> (
                       match callee_frame.locals.(i + 1) with
                       | Vm_value.Live v -> write_place vm frame p v
                       | _ -> ())
                   | Seed_mir.Constant _ | Seed_mir.Consume _ ->
                       err_trap vm
                         "inout argument is not a place (a Modify call argument must be a place channel)")
               | Access_effect.Initialize -> (
                   (* re-audit P0-A: a Set parameter must be definitely
                      initialized on every successful return — an
                      uninitialized Set parameter at return is an
                      invariant failure; the initialized value copies
                      back into the caller's place *)
                   match a.Seed_mir.value with
                   | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p -> (
                       match callee_frame.locals.(i + 1) with
                       | Vm_value.Live v -> write_place vm frame p v
                       | _ ->
                           err_trap vm
                             "callee returned with an uninitialized Set (Initialize) parameter")
                   | _ -> ())
               | _ -> ())
             args;
           vm.frames <- List.tl vm.frames;
           write_place vm frame dest ret;
           frame.block <- next;
           frame.stmt <- 0
       | Seed_mir.TypeQuery _ -> assert false (* trapped above, before dispatch *)
       | Seed_mir.Intrinsic _ | Seed_mir.Extern _ as host_callee ->
           vm.host_calls <- vm.host_calls + 1;
           if vm.host_calls > vm.limits.max_host_calls then
             err_trap vm "host call limit exceeded";
           let hr = call_host vm host_callee arg_vals in
           (* re-audit P0-B: the intrinsic's mutation writebacks are
              explicit (arg index -> new value) — each writeback copies
              into the argument's caller place *)
           List.iter
             (fun (i, v) ->
               if i >= 0 && i < Array.length args then
                 match args.(i).Seed_mir.value with
                 | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p ->
                     write_place vm frame p v
                 | _ -> ())
             hr.Host.writebacks;
           write_place vm frame dest hr.Host.value;
           frame.block <- next;
           frame.stmt <- 0)
  | Seed_mir.Drop (p, next, _) ->
      do_drop vm frame (Seed_mir.root_key p.Seed_mir.root);
      frame.block <- next;
      frame.stmt <- 0
  | Seed_mir.Deinit (p, next, _) ->
      do_drop vm frame (Seed_mir.root_key p.Seed_mir.root);
      frame.block <- next;
      frame.stmt <- 0
  | Seed_mir.Assert (op, expected, msg, target) -> (
      let v = eval_operand vm frame op in
      let ok =
        match v with
        | Vm_value.Bool b -> b = expected
        | Vm_value.Int i -> (not (Int_value.is_zero i)) = expected
        | _ -> false
      in
      if ok then begin
        frame.block <- target;
        frame.stmt <- 0
      end
      else err_trap vm ("assertion failed: " ^ msg))
  | Seed_mir.Unreachable -> raise (Failure "vm: reached Unreachable")
  | Seed_mir.Abort -> raise (Failure "vm: abort")

(* Host boundary: the executable closure is the Host binding table
   (audit §70). Dispatch resolves the registry index to a binding id and
   invokes the binding's `invoke`; a declared symbol without a binding
   fails closed, and an invoke error becomes a deterministic trap. *)
and call_host (vm : t) (callee : Seed_mir.callee) (args : Vm_value.t array) : Host.host_result =
  let id =
    match callee with
    | Seed_mir.Intrinsic (i, _) -> Host.Intrinsic (Intrinsic_registry.Id.make i)
    | Seed_mir.Extern (i, _) -> Host.Extern (Extern_registry.Id.make i)
    | Seed_mir.User _ | Seed_mir.FnValue _ | Seed_mir.Derived _
    | Seed_mir.TypeQuery _ ->
        err_trap vm "internal: user/fn-value/derived/type-query call routed to host dispatch"
  in
  match Host.lookup_binding vm.host id with
  | None ->
      let label =
        match Host.name_of_host_id vm.host id with
        | Some name -> name
        | None -> (
            match callee with
            | Seed_mir.Intrinsic (i, _) ->
                Printf.sprintf "intrinsic#%d" (Intrinsic_registry.Id.to_int i)
            | Seed_mir.Extern (i, _) ->
                Printf.sprintf "extern#%d" (Extern_registry.Id.to_int i)
            | Seed_mir.User _ | Seed_mir.FnValue _ | Seed_mir.Derived _
            | Seed_mir.TypeQuery _ ->
                "?")
      in
      err_trap vm (Printf.sprintf "host call %s has no binding (fail-closed)" label)
  | Some b ->
      if
        Array.length args
        <> Array.length b.Host.declared.Signature_identity.sig_params
      then
        err_trap vm
          (Printf.sprintf "host call %s: arity mismatch (binding arity %d, got %d)"
             b.Host.name
             (Array.length b.Host.declared.Signature_identity.sig_params)
             (Array.length args));
      (match b.Host.invoke vm.host args with
       | Ok r -> r
       | Error msg -> err_trap vm (Printf.sprintf "host call %s: %s" b.Host.name msg))

and run_frame (vm : t) (frame : frame) : unit =
  let fn = vm.program.Seed_mir.functions.(frame.fn) in
  let fn_tag () =
    Printf.sprintf "%s(inst %s)" fn.Seed_mir.name (Seed_mir.print_instance fn.Seed_mir.instance)
  in
  let rec go () =
    let block = fn.Seed_mir.blocks.(frame.block) in
    if frame.stmt < List.length block.Seed_mir.statements then begin
      let st = List.nth block.Seed_mir.statements frame.stmt in
      (try
         exec_statement vm frame st;
         frame.stmt <- frame.stmt + 1;
         go ()
       with Failure msg ->
         raise
           (Failure
              (Printf.sprintf "%s [fn %d %s bb%d id=%d stmts=%d]"
                 msg frame.fn (fn_tag ()) frame.block
                 (if frame.block < Array.length fn.Seed_mir.blocks then fn.Seed_mir.blocks.(frame.block).Seed_mir.id else -1)
                 (if frame.block < Array.length fn.Seed_mir.blocks then List.length fn.Seed_mir.blocks.(frame.block).Seed_mir.statements else -1))))
    end
    else
      (try
         exec_terminator vm frame block.Seed_mir.terminator;
         go ()
       with Failure msg ->
         raise
           (Failure
              (Printf.sprintf "%s [fn %d %s bb%d term]" msg frame.fn (fn_tag ())
                 frame.block)))
  in
  go ()

and exec_statement (vm : t) (frame : frame) (st : Seed_mir.statement) : unit =
  step_limit vm;
  match st with
  | Seed_mir.Assign (dest, rv) ->
      (* re-audit P0-9: an assignment over a LIVE owning place drops the
         old exact value FIRST (drop_glue frees region-backed refs;
         scalars/strings/aggregates-without-regions and MovedOut holes
         are no-ops), so an overwrite can never leak the replaced
         value's resources.  The lowering still emits explicit Drop
         terminators for the scope-end glue; this is the overwrite
         boundary the verifier's destroyed-lattice models as
         destroyed-by-assignment. *)
      drop_old_value_at vm frame dest;
      let v = eval_rvalue vm frame rv in
      write_place vm frame dest v
  | Seed_mir.StorageLive l ->
      if l >= 0 && l < Array.length frame.locals then frame.locals.(l) <- Vm_value.Uninitialized
  | Seed_mir.StorageDead l ->
      if l >= 0 && l < Array.length frame.locals then frame.locals.(l) <- Vm_value.Uninitialized
  | Seed_mir.SetDiscriminant (p, vid) -> (
      match read_place vm frame p with
      | Ok (Vm_value.Enum (_, payload)) ->
          write_place vm frame p (Vm_value.Enum (Ids.Variant_index.to_int vid, payload))
      | _ -> err_trap vm "SetDiscriminant on non-enum")
  | Seed_mir.Nop -> ()

(* Re-run the entry frame and return the entry return slot as text
   (self-check/inspection helper). *)
let rec run_inspect (vm : t) (entry_frame : frame) : (string, string) result =
  (try
     run_frame vm entry_frame;
     Ok "unit"
   with
  | Failure msg -> Error msg
  | Exit -> (
      match entry_frame.locals.(0) with
      | Vm_value.Live v -> (
          match v with
          | Vm_value.Int i -> Ok (Int_value.to_string i)
          | Vm_value.Bool b -> Ok (if b then "true" else "false")
          | Vm_value.String s -> Ok s
          | Vm_value.Unit -> Ok "()"
          | other -> Ok (Printf.sprintf "<%s>" (value_kind other)))
      | Vm_value.Uninitialized -> Ok "<uninitialized>"
      | Vm_value.Moved -> Ok "<moved>"
      | Vm_value.Dropped -> Ok "<dropped>"))

and value_kind (v : Vm_value.t) : string =
  match v with
  | Vm_value.Unit -> "unit"
  | Vm_value.Bool _ -> "bool"
  | Vm_value.Int _ -> "int"
  | Vm_value.Float32 _ -> "f32"
  | Vm_value.Float64 _ -> "f64"
  | Vm_value.Char _ -> "char"
  | Vm_value.String _ -> "string"
  | Vm_value.Tuple _ -> "tuple"
  | Vm_value.Struct _ -> "struct"
  | Vm_value.Enum _ -> "enum"
  | Vm_value.Array _ -> "array"
  | Vm_value.Set _ -> "set"
  | Vm_value.Map _ -> "map"
  | Vm_value.Function _ -> "fn"
  | Vm_value.Closure _ -> "closure"
  | Vm_value.RawPtr _ -> "ptr"
  | Vm_value.Ref _ -> "ref"
  | Vm_value.Null -> "null"
  | Vm_value.MovedOut -> "moved-out-hole"

(* ── the GLOBAL storage ──────────────────────────────── *)
let statics_initial_values (program : Seed_mir.program) : Vm_value.slot array =
  Array.map
    (fun (_, _ty, _, c) ->
      match c with
      | None -> Vm_value.Uninitialized
      | Some c -> (
          match c with
          | Seed_mir.Unit -> Vm_value.Live Vm_value.Unit
          | Seed_mir.Bool b -> Vm_value.Live (Vm_value.Bool b)
          | Seed_mir.Integer i -> Vm_value.Live (Vm_value.Int i)
          | Seed_mir.Float32 f -> Vm_value.Live (Vm_value.Float32 f)
          | Seed_mir.Float64 f -> Vm_value.Live (Vm_value.Float64 f)
          | Seed_mir.Char ch -> Vm_value.Live (Vm_value.Char ch)
          | Seed_mir.String str -> Vm_value.Live (Vm_value.String str)
          | Seed_mir.Function inst -> Vm_value.Live (Vm_value.Function inst)
          | Seed_mir.Enum (vi, _) ->
              Vm_value.Live (Vm_value.Enum (Ids.Variant_index.to_int vi, [||]))
          | Seed_mir.Struct _ -> Vm_value.Live (Vm_value.Struct [||])
          | Seed_mir.Array _ -> Vm_value.Live (Vm_value.Array [||])
          | Seed_mir.Map _ -> Vm_value.Live (Vm_value.Map [])
          | Seed_mir.Set _ -> Vm_value.Live (Vm_value.Set [])))
    program.Seed_mir.statics

(* Build an entry frame without running (inspection). *)
let entry_frame_of ~(program : Seed_mir.program) ~(entry : Instance_id.t) ~(argv : string array) :
    (t * frame, string) result =
  let fn_index = Hashtbl.create 64 in
  Array.iteri (fun i fn -> Hashtbl.replace fn_index fn.Seed_mir.instance i) program.Seed_mir.functions;
  match Hashtbl.find_opt fn_index entry with
  | None -> Error "entry instance not found"
  | Some fn_idx ->
      (try
         let vm =
           {
             program;
             fn_index;
             memory = Vm_memory.create ();
             drop_plans = Drop_plan.of_program program;
             host = Host.create ~repo_root:"." ~argv:[||];
             limits = default_limits;
             steps = 0;
             host_calls = 0;
             alloc_bytes = 0;
             stdout = Buffer.create 256;
             stderr = Buffer.create 256;
             frames = [];
             trace = [];
           }
         in
         check_fn_shape vm fn_idx;
         let fn = program.Seed_mir.functions.(fn_idx) in
         let entry_frame =
           { fn = fn_idx;
             locals = Array.make (Array.length fn.Seed_mir.locals) Vm_value.Uninitialized;
             statics = statics_initial_values program;
             block = fn.Seed_mir.entry;
             stmt = 0 }
         in
         (* The legacy argv-in-locals handoff fills the entry frame's
            EXISTING local slots only — a small entry function (fewer
            locals than argv entries) must not index out of bounds (the
            kernel reads its argv through the host's argv externs
            tg_get_argc/_tg_arg_copy, never through these slots). *)
         Array.iteri
           (fun i s ->
             if i < Array.length entry_frame.locals then
               entry_frame.locals.(i) <- Vm_value.Live (Vm_value.String s))
           argv;
         Ok (vm, entry_frame)
       with
      | Failure msg -> Error msg)

let run ~(program : Seed_mir.program) ~(entry : Instance_id.t) ~(argv : string array)
    ~(host : Host.t) : (int, vm_error) result =
  match entry_frame_of ~program ~entry ~argv with
  | Error m -> Error { kind = Trap "entry instance not found"; message = m; trace = [] }
  | Ok (vm, entry_frame) ->
      vm.host <- host;
      (try
         run_frame vm entry_frame;
         Ok 0
       with
      | Failure msg -> Error { kind = Trap msg; message = msg; trace = List.rev vm.trace }
      | Exit -> Ok 0)
