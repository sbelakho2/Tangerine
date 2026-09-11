(* lang_items.ml — The compilation's LangItems record (audit P0-2).

   The well-known OWNED-HANDLE and raw-POINTER nominal identities of ONE
   compilation, carried explicitly as a record — never re-derived from
   numeric builtin-id knowledge inside a consumer.  The consumers that
   must classify the builtin compound nominals (Type_properties'
   resolver, Drop_plan, Mir_verify.is_copy, Mir_lower's copyability and
   owned-value rules) all select through this record, mirroring the
   reference model's LangItems snapshot (the tg_compiler's
   `lang_items: LangItems` on the typed program / MIR program — the
   checker-populated id-indexed table carried on every builder).

   ── The classification (the native representation authority) ────────
   The values of the OWNING-HANDLE nominals (Vec/Array/List — one shared
   nominal — Map/HashMap, Set/HashSet, Box, Rc, ArcStrong/Arc, the weak
   handle families, UniquePtr and the owned-String nominal when a
   compilation registers one) own memory: they move + clone, never
   bit-Copy; their direct property answer is
   { copy = false; drop = true }.  The raw-pointer nominals
   (Ptr/PtrMut — address handles) are { copy = true; drop = false }.
   Option/Result are deliberately NOT classified here: they are enums
   whose copyability is their def's recursive payload rule (Option[Int]
   is Copy, Option[String] is not), resolved structurally through their
   defs; their ids are carried so identity-keyed consumers (the
   verifier's def-less arity/payload fallbacks) never key on numeric
   knowledge either.

   The seed checker mints the shared-LangItem nominal ids at fixed
   positions (Array/Vec/List = 0, Map/HashMap = 1, Set/HashSet = 2,
   Option = 3, Result = 4, Ptr = 5, PtrMut = 6 — Typecheck's builtin
   registrations, adopted by any source declaration of the same name);
   Box/Rc/Arc/UniquePtr/... are per-compilation declarations whose ids
   this record carries.  A field is None when the compilation never
   registered the nominal (String: the seed's owned String is the
   Type_repr.String PRIMITIVE — never a nominal — so `string` stays None
   in every seed compilation and the engine classifies the primitive
   directly). *)

type t = {
  vec : Ids.Type_id.t option;      (* Vec / Array / List — the shared nominal *)
  map : Ids.Type_id.t option;      (* Map / HashMap *)
  set : Ids.Type_id.t option;      (* Set / HashSet *)
  option : Ids.Type_id.t option;   (* Option *)
  result : Ids.Type_id.t option;   (* Result *)
  box_ : Ids.Type_id.t option;     (* Box *)
  rc : Ids.Type_id.t option;       (* Rc *)
  arc : Ids.Type_id.t option;      (* ArcStrong / Arc *)
  weak_rc : Ids.Type_id.t option;  (* WeakRc — a weak handle, still an owning handle *)
  weak_arc : Ids.Type_id.t option; (* WeakArc *)
  unique_ptr : Ids.Type_id.t option; (* UniquePtr *)
  string : Ids.Type_id.t option;   (* an owned-String nominal, when one is declared *)
  ptr : Ids.Type_id.t option;      (* Ptr — the raw address handle *)
  ptr_mut : Ids.Type_id.t option;  (* PtrMut *)
}

(* The canonical seed default: the checker-minted shared-LangItem ids
   (Typecheck's builtin registrations).  This is the ONLY place the
   seed's fixed id constants are embodied — the mirror of
   Canonical_type_instance.default_materializable.  The per-compilation
   owning nominals (Box/Rc/Arc/...) start unknown (None); the driver
   rebuilds the record from the checked environment's name tables. *)
let seed_defaults : t =
  {
    vec = Some (Ids.Type_id.make 0);
    map = Some (Ids.Type_id.make 1);
    set = Some (Ids.Type_id.make 2);
    option = Some (Ids.Type_id.make 3);
    result = Some (Ids.Type_id.make 4);
    box_ = None;
    rc = None;
    arc = None;
    weak_rc = None;
    weak_arc = None;
    unique_ptr = None;
    string = None;
    ptr = Some (Ids.Type_id.make 5);
    ptr_mut = Some (Ids.Type_id.make 6);
  }

let empty : t =
  {
    vec = None; map = None; set = None; option = None; result = None;
    box_ = None; rc = None; arc = None; weak_rc = None; weak_arc = None;
    unique_ptr = None; string = None; ptr = None; ptr_mut = None;
  }

let tid_eq (a : Ids.Type_id.t option) (b : Ids.Type_id.t) : bool =
  match a with Some a' -> Ids.Type_id.compare a' b = 0 | None -> false

(* The OWNING-HANDLE membership: { copy = false; drop = true }. *)
let is_owning_handle (li : t) (tid : Ids.Type_id.t) : bool =
  tid_eq li.vec tid || tid_eq li.map tid || tid_eq li.set tid
  || tid_eq li.box_ tid || tid_eq li.rc tid || tid_eq li.arc tid
  || tid_eq li.weak_rc tid || tid_eq li.weak_arc tid || tid_eq li.unique_ptr tid
  || tid_eq li.string tid

(* The raw-POINTER membership: { copy = true; drop = false }. *)
let is_raw_pointer (li : t) (tid : Ids.Type_id.t) : bool =
  tid_eq li.ptr tid || tid_eq li.ptr_mut tid

(* The enum LangItems (Option/Result) — identity lookups for the
   def-less fallbacks (never a property answer). *)
let is_option (li : t) (tid : Ids.Type_id.t) : bool = tid_eq li.option tid
let is_result (li : t) (tid : Ids.Type_id.t) : bool = tid_eq li.result tid
let is_enum_langitem (li : t) (tid : Ids.Type_id.t) : bool =
  is_option li tid || is_result li tid

(* ── Builders ────────────────────────────────────────────────────────
   of_types: from the checker's name -> type table (Typecheck.env.types
   — the builtin registrations plus every source-declared nominal, the
   same name-anchored table the checker itself uses for adoption): a
   name whose repr is a Named(tid, _) fills its record field; missing
   names stay None.  of_types only identifies — the answer it implies
   for a tid is the classification above, never a def shape. *)

let tid_of_named (ty : Type_repr.t) : Ids.Type_id.t option =
  match ty with Type_repr.Named (tid, _) -> Some tid | _ -> None

let first_tid_of (types : (string * Type_repr.t) list) (names : string list) :
    Ids.Type_id.t option =
  List.find_map
    (fun n -> match List.assoc_opt n types with Some ty -> tid_of_named ty | None -> None)
    names

(* The same identification through a caller-supplied name lookup (the
   checker's cached O(1) name table): of_lookup find == of_types types
   whenever find n == List.assoc_opt n types for every queried name. *)
let first_tid_of_lookup (find : string -> Type_repr.t option) (names : string list) :
    Ids.Type_id.t option =
  List.find_map
    (fun n -> match find n with Some ty -> tid_of_named ty | None -> None)
    names

let of_lookup (find : string -> Type_repr.t option) : t =
  {
    vec = first_tid_of_lookup find [ "Vec"; "Array"; "List" ];
    map = first_tid_of_lookup find [ "Map"; "HashMap" ];
    set = first_tid_of_lookup find [ "Set"; "HashSet" ];
    option = first_tid_of_lookup find [ "Option" ];
    result = first_tid_of_lookup find [ "Result" ];
    box_ = first_tid_of_lookup find [ "Box" ];
    rc = first_tid_of_lookup find [ "Rc" ];
    arc = first_tid_of_lookup find [ "ArcStrong"; "Arc" ];
    weak_rc = first_tid_of_lookup find [ "WeakRc" ];
    weak_arc = first_tid_of_lookup find [ "WeakArc" ];
    unique_ptr = first_tid_of_lookup find [ "UniquePtr" ];
    string = first_tid_of_lookup find [ "String" ];
    ptr = first_tid_of_lookup find [ "Ptr" ];
    ptr_mut = first_tid_of_lookup find [ "PtrMut" ];
  }

let of_types (types : (string * Type_repr.t) list) : t =
  of_lookup (fun n -> List.assoc_opt n types)
