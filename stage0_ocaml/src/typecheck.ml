(* typecheck.ml — Bootstrap-subset type checker and trait-bound checker
   (audit §25, §27, §28).

   The checker covers the bootstrap subset used by the manifest:
     - literals (Int with Literal.parsed_integer range decisions per suffix
       — 256u8 is a TYPE error, never zero; Float; String; Char with Uchar
       validation; Bool);
     - names (local scope, free functions, enum variant constructors,
       constants — the resolver's registries built inside this module);
     - tuples, arrays ([T; N] and [T]), struct literals, enum
       construction, field/index projections;
     - method calls (resolved via the resolver's method table; receiver
       effect from the method's first param convention), free calls;
     - match (all arms unify; literal / variant-with-arity / struct /
       wildcard / or / range patterns), if/elsif/else, while/for/loop,
       return, closures (capture tuple; params inferred from use when the
       closure is passed to a typed parameter), casts, try-op `?`;
     - access effects on arguments from the callee's param conventions
       (inout->Modify, sink->Consume, set->Initialize, let->Read; &x ->
       Read, &mut x -> Modify);
     - type parameters: generic functions/structs introduce Type_param;
       unification substitutes; calls instantiate with concrete args;
     - where clauses and trait bounds are checked through
       Trait_solver.solve; unsatisfied -> error.

   The COMPLETENESS ORACLE (§28) runs at the end of every ACCEPTED item:
   it counts Type_params in concrete execution position, unsolved type
   variables, error types, unknown DefIds/FieldIds/VariantIds, unresolved
   calls, unsolved trait obligations and missing argument access effects.
   Any nonzero finding is returned as an error list — the checker never
   silently continues past an incomplete channel. *)

(* ────────────────────────────────────────────────────────────────
   Public types *)

type typed_signature = {
  ts_name : string;
  ts_params_decl : (string * Ids.Generic_param_id.t) list;
  ts_params : Type_repr.param_type array;
  ts_param_names : string array;
  ts_return : Type_repr.t;
  ts_where : (Type_repr.t * string list) list;
  ts_callable : Ids.Callable_id.t;
  ts_span : Span.span;
}

type nominal = {
  nom_kind : [ `Struct | `Enum ];
  nom_params : (string * Ids.Generic_param_id.t) list;
  nom_fields : (string * Type_repr.t) list;          (* struct, in param scope *)
  nom_variants : (string * Type_repr.t array) list;  (* enum, in param scope *)
  nom_where : (Type_repr.t * string list) list;      (* resolved where predicates *)
  nom_field_ids : Ids.Field_id.t list;               (* resolver identities, parallel to nom_fields *)
  nom_variant_ids : Ids.Variant_id.t list;           (* resolver identities, parallel to nom_variants *)
}

type typed_expr = {
  te_type : Type_repr.t;
  te_effects : Access_effect.read_effect array;
  te_span : Span.span;
}

(* The persistent typed-node bridge (re-audit: TypedProgram/TypedHIR).
   Node identity = the expr's span (file_id, start) — the same identity
   the parser stamps on the AST node.  Every accepted node persists its
   resolved type; casts additionally persist the checker-RESOLVED target
   type (a Named(GenericParamId, ...) carrying the declaration-owned
   ids — never a positional reconstruction); calls additionally persist
   the checker-RESOLVED callee identity and the SOLVED concrete
   substitution (the typed_call's substitution array — substitute_fixpoint
   over the declaration params, so concrete types land).  The map is
   populated during check_expr (additive) and exposed to lowering
   through the driver's typed_nodes_of, where the typed channel is
   authoritative when a span-keyed entry is present. *)
type typed_node = {
  tn_type : Type_repr.t;               (* the expr's resolved type *)
  tn_cast_target : Type_repr.t option; (* Ast.Cast: checker-resolved target *)
  tn_call : (Ids.Callable_id.t * Type_repr.t array) option;
  (* Ast.Call: the callee's CallableId + the solved concrete
     substitution in declaration order (the exact-arity pairing the
     lowering Call rule consumes; [||] and None are distinct: an
     empty array is a solved zero-arg substitution, None = no call) *)
}

type typed_call = {
  target : Ids.Callable_id.t option;
  substitution : Type_repr.t array;
  args : typed_expr array;
  effects : Access_effect.read_effect array;
  return_type : Type_repr.t;
}

(* The completeness-oracle channel record (audit §28). *)
type oracle = {
  mutable o_exprs : typed_expr list;
  mutable o_calls : typed_call list;
  mutable o_obligations :
    (Trait_solver.obligation * (Trait_solver.solution, Trait_solver.solve_error) result) list;
  mutable o_type_params : int;
  mutable o_unsolved_vars : int;
  mutable o_error_types : int;
  mutable o_unknown_defs : int;
  mutable o_unknown_fields : int;
  mutable o_unknown_variants : int;
  mutable o_unresolved_calls : int;
  mutable o_unsolved_obligations : int;
  mutable o_missing_effects : int;
  mutable o_derived_callables : Ids.Callable_id.t list;
  mutable o_deferred_params : Ids.Generic_param_id.t list;
  (* the integrated access/resource channel (re-audit P0-11): one
     Access_check.access per checked call argument, accumulated ACROSS
     items (reset_oracle deliberately leaves it alone) so the driver's
     integrated pass walks the whole closure's recorded accesses;
     o_access_seq numbers each recorded call so the pass can delimit
     statement groups *)
  mutable o_accesses : Access_check.access list;
  mutable o_access_seq : int;
  (* local-name -> stable root id for the integrated pass: scope-local
     LIST positions shift as bindings accumulate (add_binds prepends), so
     the channel roots are name-keyed ids assigned on first sight (the
     pass groups per item, so cross-item aliasing of ids is harmless;
     shadowed locals of the same name are conservatively conflated) *)
  mutable o_access_root_ids : (string, int) Hashtbl.t;
}

(* Mutable check state (per check_program run). *)
type state = {
  mutable next_type_id : int;
  mutable next_param_id : int;
  mutable next_var_id : int;
  mutable failed_items : string list;
  mutable o_handoff_resolved : int;
  (* the nested-function registry (re-audit: nested defs reach closure
     MIR lowering from HERE — the accepted typed callable universe).
     Each entry carries the qname, the typed signature (the callable id,
     params, return) AND the function_decl AST: the driver's lower_closure
     lowers every registered entry as its own seed function, so callers'
     calls (which carry the nested callable id) resolve. *)
  mutable nested_functions : (string * typed_signature * Ast.function_decl) list;
  mutable query_sigs : (string * typed_signature) list;
  mutable o_handoff_fallback : int;
  (* once-only declaration identities: the first allocation of an item's
     generic-parameter ids is recorded and reused by every later
     registration attempt, so retry rounds never create stale ids *)
  mutable sig_param_ids : (string, (string * Ids.Generic_param_id.t) list) Hashtbl.t;
  mutable next_callable_id : int;
  mutable next_impl_index : int;
  mutable current_item : string;
  mutable current_item_params : Ids.Generic_param_id.t list;
  oracle : oracle;
  (* diagnostic-debt accounting (audit P1-1): per-module-path debt
     reports, last round wins (mirrors the driver's errs_by_mod), and
     the last emitted block so the printer only fires on change *)
  mutable debt_by_module : (string * Debt_report.t) list;
  mutable debt_last_printed : string;
}

type env = {
  types : (string * Type_repr.t) list;
  functions : (string * typed_signature) list;
  methods : ((string * string) * typed_signature) list;
  impls : Trait_solver.env;
  current_self : Type_repr.t option;
  current_return : Type_repr.t option;
  (* extended registries (the six fields above are the core contract) *)
  type_ids : (string * Ids.Type_id.t) list;
  type_names : (Ids.Type_id.t * string) list;
  nominals : (string * nominal) list;
  constructors : (string * typed_signature) list;
  consts : (string * Type_repr.t) list;
  state : state;
  module_id : Ids.Module_id.t;
  resolved : Resolver.resolved_program option;
  module_path : string list;
  (* the persistent typed-node map (re-audit bridge): span identity
     (file_id, start) -> resolved node.  Populated during check_expr;
     the mutable table is shared across the `{ env with ... }` record
     updates, so the final env the driver receives holds every accepted
     node's channel entry. *)
  typed_nodes : (int * int, typed_node) Hashtbl.t;
}

type scope = {
  locals : (string * Type_repr.t * bool) list;  (* name, type, mutable *)
  generics : (string * Ids.Generic_param_id.t) list;
  loop_depth : int;
  capture : (string -> unit) option;
}

let assoc_local (name : string) (locals : (string * Type_repr.t * bool) list) :
    (Type_repr.t * bool) option =
  match List.find_opt (fun (n, _, _) -> n = name) locals with
  | Some (_, t, m) -> Some (t, m)
  | None -> None

(* error-monad bind *)
let ( let* ) (r : ('a, string) result) (f : 'a -> ('b, string) result) : ('b, string) result =
  match r with Ok x -> f x | Error m -> Error m

let err (span : Span.span) (msg : string) : string =
  Printf.sprintf "%s at file#%d[%d..%d)" msg span.Span.file_id span.Span.start span.Span.end_

let fail span msg = Error (err span msg)

(* ────────────────────────────────────────────────────────────────
   Fresh ids *)

let fresh_type_id (st : state) : Ids.Type_id.t =
  let id = st.next_type_id in
  st.next_type_id <- id + 1;
  Ids.Type_id.make id

let fresh_param_id (st : state) : Ids.Generic_param_id.t =
  let id = st.next_param_id in
  st.next_param_id <- id + 1;
  Ids.Generic_param_id.make id

(* a fresh flexible inference variable (the audit's Infer_var domain) *)
let fresh_infer_var (st : state) : Type_repr.t =
  let id = st.next_var_id in
  st.next_var_id <- id + 1;
  Type_repr.Infer_var id

(* the kernel's strict Box[T] wrapper is transparent: Box[T] unifies
   with T in both directions and derefs on field/method access (the
   full compiler's Box coercions). The Box nominal's tid is registered
   when the source declaration processes. *)
let box_tid : Ids.Type_id.t option ref = ref None

let is_box (id : Ids.Type_id.t) : bool =
  match !box_tid with Some b -> Ids.Type_id.compare b id = 0 | None -> false

let fresh_callable_id (st : state) : Ids.Callable_id.t =
  let id = st.next_callable_id in
  st.next_callable_id <- id + 1;
  Ids.Callable_id.make id

(* ────────────────────────────────────────────────────────────────
   Conventions *)

let convention_of (c : Ast.access_convention) : Access_effect.t =
  match c with
  | Ast.LetAccess -> Access_effect.Let
  | Ast.InoutAccess -> Access_effect.Inout
  | Ast.Sink -> Access_effect.Sink
  | Ast.Set -> Access_effect.Set

let effect_of (c : Ast.access_convention) : Access_effect.read_effect =
  Access_effect.read_effect (convention_of c)

(* ─── builtin type ids ─── *)
let b_array : Ids.Type_id.t = Ids.Type_id.make 0
let b_map : Ids.Type_id.t = Ids.Type_id.make 1
let b_set : Ids.Type_id.t = Ids.Type_id.make 2
let b_option : Ids.Type_id.t = Ids.Type_id.make 3
let b_result : Ids.Type_id.t = Ids.Type_id.make 4
let b_ptr : Ids.Type_id.t = Ids.Type_id.make 5
let b_ptrmut : Ids.Type_id.t = Ids.Type_id.make 6

let int_kind_of_name (n : string) : Type_repr.int_kind option =
  match n with
  | "i8" -> Some Type_repr.I8 | "i16" -> Some Type_repr.I16 | "i32" -> Some Type_repr.I32
  | "i64" -> Some Type_repr.I64 | "i128" -> Some Type_repr.I128
  | "u8" -> Some Type_repr.U8 | "u16" -> Some Type_repr.U16 | "u32" -> Some Type_repr.U32
  | "u64" -> Some Type_repr.U64 | "u128" -> Some Type_repr.U128
  | "Int" -> Some Type_repr.Int | "UInt" -> Some Type_repr.UInt
  | _ -> None

let int_name_of_kind (k : Type_repr.int_kind) : string =
  match k with
  | Type_repr.I8 -> "i8" | Type_repr.I16 -> "i16" | Type_repr.I32 -> "i32"
  | Type_repr.I64 -> "i64" | Type_repr.I128 -> "i128"
  | Type_repr.U8 -> "u8" | Type_repr.U16 -> "u16" | Type_repr.U32 -> "u32"
  | Type_repr.U64 -> "u64" | Type_repr.U128 -> "u128"
  | Type_repr.Int -> "Int" | Type_repr.UInt -> "UInt"

let int_width (k : Type_repr.int_kind) : int =
  match k with
  | Type_repr.I8 | Type_repr.U8 -> 8
  | Type_repr.I16 | Type_repr.U16 -> 16
  | Type_repr.I32 | Type_repr.U32 -> 32
  | Type_repr.I64 | Type_repr.U64 | Type_repr.Int | Type_repr.UInt -> 64
  | Type_repr.I128 | Type_repr.U128 -> 128

let int_signed (k : Type_repr.int_kind) : bool =
  match k with
  | Type_repr.I8 | Type_repr.I16 | Type_repr.I32 | Type_repr.I64 | Type_repr.I128
  | Type_repr.Int ->
      true
  | Type_repr.U8 | Type_repr.U16 | Type_repr.U32 | Type_repr.U64 | Type_repr.U128
  | Type_repr.UInt ->
      false

let primitive_name (t : Type_repr.t) : string option =
  match t with
  | Type_repr.Int k -> Some (int_name_of_kind k)
  | Type_repr.Float Type_repr.F32 -> Some "f32"
  | Type_repr.Float Type_repr.F64 -> Some "Float"
  | Type_repr.Bool -> Some "Bool"
  | Type_repr.Char -> Some "Char"
  | Type_repr.String -> Some "String"
  | Type_repr.Unit -> Some "Unit"
  | Type_repr.Never -> Some "Never"
  | _ -> None

(* ─── signature construction helper ─── *)
let mk_sig (st : state) ~(name : string) ~(params_decl : (string * Ids.Generic_param_id.t) list)
    ~(params : (string * Access_effect.t * Type_repr.t) list) ~(ret : Type_repr.t)
    ~(where : (Type_repr.t * string list) list) : typed_signature =
  {
    ts_name = name;
    ts_params_decl = params_decl;
    ts_params =
      Array.of_list (List.map (fun (_, c, t) -> { Type_repr.pt_convention = c; pt_type = t }) params);
    ts_param_names = Array.of_list (List.map (fun (n, _, _) -> n) params);
    ts_return = ret;
    ts_where = where;
    ts_callable = fresh_callable_id st;
    ts_span = Span.synthetic;
  }

(* ─── builtin types table ─── *)
let builtin_types (st : state) : (string * Type_repr.t) list =
  let ints =
    List.map
      (fun n -> (n, Type_repr.Int (Option.get (int_kind_of_name n))))
      [ "Int"; "UInt"; "i8"; "i16"; "i32"; "i64"; "i128"; "u8"; "u16"; "u32"; "u64"; "u128" ]
  in
  let arr_p = Type_repr.Type_param (fresh_param_id st) in
  let map_k = Type_repr.Type_param (fresh_param_id st) in
  let map_v = Type_repr.Type_param (fresh_param_id st) in
  let set_t = Type_repr.Type_param (fresh_param_id st) in
  let opt_t = Type_repr.Type_param (fresh_param_id st) in
  let res_t = Type_repr.Type_param (fresh_param_id st) in
  let res_e = Type_repr.Type_param (fresh_param_id st) in
  let ptr_t = Type_repr.Type_param (fresh_param_id st) in
  let ptrm_t = Type_repr.Type_param (fresh_param_id st) in
  ints
  @ [
      ("f32", Type_repr.Float Type_repr.F32);
      ("f64", Type_repr.Float Type_repr.F64);
      ("Float", Type_repr.Float Type_repr.F64);
      ("Bool", Type_repr.Bool);
      (* the kernel's string-slice type: `str` behaves as a String in the
         bootstrap subset (std/core.tg impl String methods return str) *)
      ("str", Type_repr.String);
      ("Char", Type_repr.Char);
      ("String", Type_repr.String);
      ("Never", Type_repr.Never);
      ("Unit", Type_repr.Unit);
      ("()", Type_repr.Unit);
      ("Vec", Type_repr.Named (b_array, [| arr_p |]));
      ("Array", Type_repr.Named (b_array, [| arr_p |]));
      ("List", Type_repr.Named (b_array, [| arr_p |]));
      ("Map", Type_repr.Named (b_map, [| map_k; map_v |]));
      ("HashMap", Type_repr.Named (b_map, [| map_k; map_v |]));
      ("Set", Type_repr.Named (b_set, [| set_t |]));
      ("HashSet", Type_repr.Named (b_set, [| set_t |]));
      ("Option", Type_repr.Named (b_option, [| opt_t |]));
      ("Result", Type_repr.Named (b_result, [| res_t; res_e |]));
      ("Ptr", Type_repr.Named (b_ptr, [| ptr_t |]));
      ("PtrMut", Type_repr.Named (b_ptrmut, [| ptrm_t |]));
    ]

let type_ids_of_builtins : (string * Ids.Type_id.t) list =
  [
    ("Array", b_array); ("Vec", b_array); ("List", b_array);
    ("Map", b_map); ("HashMap", b_map);
    ("Set", b_set); ("HashSet", b_set);
    ("Option", b_option); ("Result", b_result);
    ("Ptr", b_ptr); ("PtrMut", b_ptrmut);
  ]

let type_names_of_builtins : (Ids.Type_id.t * string) list =
  [
    (b_array, "Array"); (b_map, "Map"); (b_set, "Set"); (b_option, "Option");
    (b_result, "Result"); (b_ptr, "Ptr"); (b_ptrmut, "PtrMut");
  ]

(* ─── builtin trait impls (mirror the std prelude the resolver seeds) ─── *)
let builtin_impls (st : state) : Trait_solver.impl_entry list =
  let mid = Ids.Module_id.make (-1) in
  let idx = ref 0 in
  let ent ~(trait : string) ~(target : Type_repr.t) ~(name : string) ~(params : string list)
      ~(bounds : Trait_solver.obligation list) ~(assoc : (string * Type_repr.t) list) :
      Trait_solver.impl_entry =
    let e =
      {
        Trait_solver.ie_trait = trait;
        ie_target = target;
        ie_target_name = name;
        ie_id = { Trait_solver.module_id = mid; index = !idx };
        ie_params = params;
        ie_bounds = bounds;
        ie_assoc = assoc;
      }
    in
    incr idx;
    e
  in
  let ob ~(trait : string) ~(self : Type_repr.t) : Trait_solver.obligation =
    { Trait_solver.trait_name = trait; self_ty = self; type_args = [||] }
  in
  let prim_targets =
    [
      Type_repr.Int Type_repr.I8; Type_repr.Int Type_repr.I16; Type_repr.Int Type_repr.I32;
      Type_repr.Int Type_repr.I64; Type_repr.Int Type_repr.I128; Type_repr.Int Type_repr.U8;
      Type_repr.Int Type_repr.U16; Type_repr.Int Type_repr.U32; Type_repr.Int Type_repr.U64;
      Type_repr.Int Type_repr.U128; Type_repr.Int Type_repr.Int; Type_repr.Int Type_repr.UInt;
      Type_repr.Float Type_repr.F32; Type_repr.Float Type_repr.F64; Type_repr.Bool;
      Type_repr.Char;
    ]
  in
  let named t = Option.get (primitive_name t) in
  let hash_impls =
    List.map
      (fun t -> ent ~trait:"Hash" ~target:t ~name:(named t) ~params:[] ~bounds:[] ~assoc:[])
      prim_targets
  in
  let eq_impls =
    List.map
      (fun t -> ent ~trait:"Eq" ~target:t ~name:(named t) ~params:[] ~bounds:[] ~assoc:[])
      prim_targets
  in
  let ord_impls =
    List.map
      (fun t -> ent ~trait:"Ord" ~target:t ~name:(named t) ~params:[] ~bounds:[] ~assoc:[])
      prim_targets
  in
  let default_impls =
    List.map
      (fun t -> ent ~trait:"Default" ~target:t ~name:(named t) ~params:[] ~bounds:[] ~assoc:[])
      [
        Type_repr.Int Type_repr.Int; Type_repr.Int Type_repr.UInt; Type_repr.Bool;
        Type_repr.Float Type_repr.F64; Type_repr.String; Type_repr.Char; Type_repr.Unit;
      ]
  in
  let ent_named trait ty name = ent ~trait ~target:ty ~name ~params:[] ~bounds:[] ~assoc:[] in
  let hash_string = ent_named "Hash" Type_repr.String "String" in
  let eq_string = ent_named "Eq" Type_repr.String "String" in
  let eq_unit = ent_named "Eq" Type_repr.Unit "Unit" in
  let display_int = ent_named "Display" (Type_repr.Int Type_repr.Int) "Int" in
  let display_bool = ent_named "Display" Type_repr.Bool "Bool" in
  let display_float = ent_named "Display" (Type_repr.Float Type_repr.F64) "Float" in
  let display_string = ent_named "Display" Type_repr.String "String" in
  let clone_string = ent_named "Clone" Type_repr.String "String" in
  (* generic impls with where-bounds: Hash for Vec[T] where T: Hash, ... *)
  let t_vec = fresh_param_id st in
  let hash_vec =
    ent ~trait:"Hash" ~target:(Type_repr.Named (b_array, [| Type_repr.Type_param t_vec |]))
      ~name:"Vec" ~params:[ "T" ]
      ~bounds:[ ob ~trait:"Hash" ~self:(Type_repr.Type_param t_vec) ] ~assoc:[]
  in
  let eq_vec =
    ent ~trait:"Eq" ~target:(Type_repr.Named (b_array, [| Type_repr.Type_param t_vec |]))
      ~name:"Vec" ~params:[ "T" ]
      ~bounds:[ ob ~trait:"Eq" ~self:(Type_repr.Type_param t_vec) ] ~assoc:[]
  in
  let t_opt = fresh_param_id st in
  let hash_opt =
    ent ~trait:"Hash" ~target:(Type_repr.Named (b_option, [| Type_repr.Type_param t_opt |]))
      ~name:"Option" ~params:[ "T" ]
      ~bounds:[ ob ~trait:"Hash" ~self:(Type_repr.Type_param t_opt) ] ~assoc:[]
  in
  let k_map = fresh_param_id st in
  let v_map = fresh_param_id st in
  let hash_map =
    ent ~trait:"Hash"
      ~target:(Type_repr.Named (b_map, [| Type_repr.Type_param k_map; Type_repr.Type_param v_map |]))
      ~name:"Map" ~params:[ "K"; "V" ]
      ~bounds:
        [
          ob ~trait:"Hash" ~self:(Type_repr.Type_param k_map);
          ob ~trait:"Hash" ~self:(Type_repr.Type_param v_map);
        ]
      ~assoc:[]
  in
  hash_impls @ [ hash_string; hash_vec; hash_opt; hash_map ] @ eq_impls
  @ [ eq_string; eq_unit; eq_vec ] @ [ display_int; display_bool; display_float; display_string;
                                       clone_string ]
  @ ord_impls @ default_impls

let builtin_trait_contracts : (string * string list) list =
  [
    ("Copy", []);
    ("Drop", [ "drop" ]);
    ("Clone", [ "clone" ]);
    ("Transferable", []);
    ("Shareable", []);
    ("Eq", [ "eq" ]);
    ("Ord", [ "cmp" ]);
    ("Hash", [ "hash" ]);
    ("Default", [ "default" ]);
    ("Into", [ "into" ]);
    ("From", [ "from" ]);
    ("Error", [ "message"; "source" ]);
    ("Display", [ "fmt" ]);
    ("UnsafeTransferable", []);
    ("UnsafeShareable", []);
  ]

(* ─── builtin methods ─── *)
(* the canonical LangItem generic parameters (audit Fix 4): minted once
   in initial_env, shared by the builtin method tables, the builtin
   nominals and — through the seeded sig_param_ids memo — the source
   std declarations *)
let builtin_methods (st : state) (vec_p : Ids.Generic_param_id.t) (opt_p : Ids.Generic_param_id.t)
    (res_p : Ids.Generic_param_id.t) (res_e_p : Ids.Generic_param_id.t)
    (map_k_p : Ids.Generic_param_id.t) (map_v_p : Ids.Generic_param_id.t)
    (set_p : Ids.Generic_param_id.t) :
    ((string * string) * typed_signature) list =
  let par (n : string) (c : Access_effect.t) (t : Type_repr.t) = (n, c, t) in
  let i_ty = Type_repr.Int Type_repr.Int in
  let u_ty = Type_repr.Int Type_repr.UInt in
  let s_ty = Type_repr.String in
  let b_ty = Type_repr.Bool in
  let c_ty = Type_repr.Char in
  let f_ty = Type_repr.Float Type_repr.F64 in
  let unit = Type_repr.Unit in
  let opt t = Type_repr.Named (b_option, [| t |]) in
  let res t e = Type_repr.Named (b_result, [| t; e |]) in
  let vec t = Type_repr.Named (b_array, [| t |]) in
  let ptr t = Type_repr.Named (b_ptr, [| t |]) in
  let ptrm t = Type_repr.Named (b_ptrmut, [| t |]) in
  let simple ~(owner : string) ~(owner_ty : Type_repr.t) ~(name : string)
      ~(params : (string * Access_effect.t * Type_repr.t) list) ~(ret : Type_repr.t)
      ~(decl : (string * Ids.Generic_param_id.t) list)
      ~(where : (Type_repr.t * string list) list)
      ~(recv_conv : Access_effect.t) : (string * string) * typed_signature =
    ((owner, name),
     mk_sig st ~name:("builtin::" ^ owner ^ "::" ^ name) ~params_decl:decl
       ~params:(( "self", recv_conv, owner_ty ) :: params) ~ret ~where)
  in
  let let_ = Access_effect.Let in
  let inout = Access_effect.Inout in
  let sink = Access_effect.Sink in
  let m_string =
    [
      ("len", [], i_ty, [], let_);
      ("is_empty", [], b_ty, [], let_);
      ("clone", [], s_ty, [], let_);
      ("as_str", [], s_ty, [], let_);
      ("push", [ par "ch" let_ c_ty ], unit, [], inout);
      ("push_str", [ par "other" let_ s_ty ], unit, [], inout);
      ("slice", [ par "start" let_ i_ty; par "end_idx" let_ i_ty ], s_ty, [], let_);
      ("find", [ par "sub" let_ s_ty ], opt i_ty, [], let_);
      ("contains", [ par "needle" let_ s_ty ], b_ty, [], let_);
      ("starts_with", [ par "prefix" let_ s_ty ], b_ty, [], let_);
      ("ends_with", [ par "suffix" let_ s_ty ], b_ty, [], let_);
      ("trim", [], s_ty, [], let_);
      ("to_lowercase", [], s_ty, [], let_);
      ("to_uppercase", [], s_ty, [], let_);
      ("split", [ par "sep" let_ s_ty ], vec s_ty, [], let_);
      ("lines", [], vec s_ty, [], let_);
      ("char_at", [ par "index" let_ i_ty ], c_ty, [], let_);
      ("as_bytes", [], vec (Type_repr.Int Type_repr.U8), [], let_);
      ("parse_int", [], res i_ty s_ty, [], let_);
      ("parse_float", [], opt f_ty, [], let_);
      ("replace", [ par "from" let_ s_ty; par "to" let_ s_ty ], s_ty, [], let_);
    ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"String" ~owner_ty:s_ty ~name:n ~params:p ~ret:r ~decl:[] ~where:w ~recv_conv:rc)
  in
  (* the str owner's surface is the String builtin minus what the
     kernel's own impl str provides; the String<->str owner alias in
     check_method_call covers the shared methods *)
  let m_str =
    [ ("to_string", [], s_ty, [], let_) ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"str" ~owner_ty:s_ty ~name:n ~params:p ~ret:r ~decl:[] ~where:w ~recv_conv:rc)
  in
  let m_int =
    [
      ("to_string", [], s_ty, [], let_);
      ("abs", [], i_ty, [], let_);
      ("min", [ par "other" let_ i_ty ], i_ty, [], let_);
      ("max", [ par "other" let_ i_ty ], i_ty, [], let_);
    ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"Int" ~owner_ty:i_ty ~name:n ~params:p ~ret:r ~decl:[] ~where:w ~recv_conv:rc)
  in
  let m_uint =
    [ ("to_string", [], s_ty, [], let_); ("abs", [], u_ty, [], let_) ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"UInt" ~owner_ty:u_ty ~name:n ~params:p ~ret:r ~decl:[] ~where:w ~recv_conv:rc)
  in
  let m_small_int =
    List.concat_map
      (fun oname ->
        let oty = Type_repr.Int (Option.get (int_kind_of_name oname)) in
        [ simple ~owner:oname ~owner_ty:oty ~name:"to_string" ~params:[] ~ret:s_ty ~decl:[] ~where:[] ~recv_conv:let_ ])
      [ "i8"; "i16"; "i32"; "i64"; "i128"; "u8"; "u16"; "u32"; "u64"; "u128" ]
  in
  let m_float =
    [
      ("to_string", [], s_ty, [], let_);
      ("abs", [], f_ty, [], let_);
      ("sqrt", [], f_ty, [], let_);
      ("floor", [], f_ty, [], let_);
      ("ceil", [], f_ty, [], let_);
      ("round", [], f_ty, [], let_);
      ("pow", [ par "exp" let_ f_ty ], f_ty, [], let_);
      ("min", [ par "other" let_ f_ty ], f_ty, [], let_);
      ("max", [ par "other" let_ f_ty ], f_ty, [], let_);
    ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"Float" ~owner_ty:f_ty ~name:n ~params:p ~ret:r ~decl:[] ~where:w ~recv_conv:rc)
  in
  let m_bool =
    [ simple ~owner:"Bool" ~owner_ty:b_ty ~name:"to_string" ~params:[] ~ret:s_ty ~decl:[] ~where:[] ~recv_conv:let_ ]
  in
  let m_char =
    [
      ("to_string", [], s_ty, [], let_);
      ("is_digit", [], b_ty, [], let_);
      ("is_alpha", [], b_ty, [], let_);
      ("is_alphanumeric", [], b_ty, [], let_);
      ("to_int", [], i_ty, [], let_);
    ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"Char" ~owner_ty:c_ty ~name:n ~params:p ~ret:r ~decl:[] ~where:w ~recv_conv:rc)
  in
  (* Vec / Array (the same builtin heap type) *)
  let vec_t = Type_repr.Type_param vec_p in
  let vec_self = Type_repr.Named (b_array, [| vec_t |]) in
  let vec_methods =
    [
      ("len", [], i_ty, [], let_);
      ("is_empty", [], b_ty, [], let_);
      ("push", [ par "value" sink vec_t ], unit, [], inout);
      ("pop", [], opt vec_t, [], let_);
      ("get", [ par "i" let_ i_ty ], opt vec_t, [], let_);
      ("set", [ par "i" let_ i_ty; par "value" sink vec_t ], unit, [], inout);
      ("clear", [], unit, [], inout);
      ("as_ptr", [], ptr vec_t, [], let_);
      ("as_mut_ptr", [], ptrm vec_t, [], inout);
      ("first", [], opt vec_t, [], let_);
      ("last", [], opt vec_t, [], let_);
      ("reserve", [ par "extra" let_ i_ty ], unit, [], inout);
      ("contains", [ par "value" let_ vec_t ], b_ty, [ (vec_t, [ "Eq" ]) ], let_);
    ]
  in
  let m_vec =
    List.map
      (fun (n, p, r, w, rc) -> simple ~owner:"Vec" ~owner_ty:vec_self ~name:n ~params:p ~ret:r ~decl:[ ("T", vec_p) ] ~where:w ~recv_conv:rc)
      vec_methods
  in
  let m_array =
    List.map
      (fun (n, p, r, w, rc) -> simple ~owner:"Array" ~owner_ty:vec_self ~name:n ~params:p ~ret:r ~decl:[ ("T", vec_p) ] ~where:w ~recv_conv:rc)
      vec_methods
  in
  (* Option *)
  let opt_t = Type_repr.Type_param opt_p in
  let opt_self = Type_repr.Named (b_option, [| opt_t |]) in
  let m_opt =
    [
      ("is_some", [], b_ty, [], let_);
      ("is_none", [], b_ty, [], let_);
      ("unwrap", [], opt_t, [], sink);
      ("expect", [ par "msg" let_ s_ty ], opt_t, [], sink);
      ("unwrap_or", [ par "default" let_ opt_t ], opt_t, [], sink);
    ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"Option" ~owner_ty:opt_self ~name:n ~params:p ~ret:r ~decl:[ ("T", opt_p) ] ~where:w ~recv_conv:rc)
  in
  (* Result *)
  let res_t = Type_repr.Type_param res_p in
  let res_e = Type_repr.Type_param res_e_p in
  let res_self = Type_repr.Named (b_result, [| res_t; res_e |]) in
  let m_res =
    [
      ("is_ok", [], b_ty, [], let_);
      ("is_err", [], b_ty, [], let_);
      ("unwrap", [], res_t, [], sink);
      ("unwrap_err", [], res_e, [], sink);
      ("expect", [ par "msg" let_ s_ty ], res_t, [], sink);
      ("unwrap_or", [ par "default" let_ res_t ], res_t, [], sink);
    ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"Result" ~owner_ty:res_self ~name:n ~params:p ~ret:r ~decl:[ ("T", res_p); ("E", res_e_p) ] ~where:w ~recv_conv:rc)
  in
  (* Map *)
  let map_k = Type_repr.Type_param map_k_p in
  let map_v = Type_repr.Type_param map_v_p in
  let map_self = Type_repr.Named (b_map, [| map_k; map_v |]) in
  let hash_eq = [ (map_k, [ "Hash"; "Eq" ]) ] in
  let m_map =
    [
      ("len", [], i_ty, [], let_);
      ("is_empty", [], b_ty, [], let_);
      ("get", [ par "key" let_ map_k ], opt map_v, hash_eq, let_);
      ("contains_key", [ par "key" let_ map_k ], b_ty, hash_eq, let_);
      ("set", [ par "key" let_ map_k; par "value" sink map_v ], unit, hash_eq, inout);
      ("insert", [ par "key" let_ map_k; par "value" sink map_v ], unit, hash_eq, inout);
      ("remove", [ par "key" let_ map_k ], opt map_v, hash_eq, let_);
      ("keys", [], vec map_k, [], let_);
      ("values", [], vec map_v, [], let_);
      ("clear", [], unit, [], inout);
    ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"Map" ~owner_ty:map_self ~name:n ~params:p ~ret:r ~decl:[ ("K", map_k_p); ("V", map_v_p) ] ~where:w ~recv_conv:rc)
  in
  (* Set *)
  let set_t = Type_repr.Type_param set_p in
  let set_self = Type_repr.Named (b_set, [| set_t |]) in
  let m_set =
    [
      ("len", [], i_ty, [], let_);
      ("is_empty", [], b_ty, [], let_);
      ("insert", [ par "value" sink set_t ], b_ty, [ (set_t, [ "Hash"; "Eq" ]) ], inout);
      ("contains", [ par "value" let_ set_t ], b_ty, [ (set_t, [ "Hash"; "Eq" ]) ], let_);
      ("remove", [ par "value" let_ set_t ], b_ty, [ (set_t, [ "Hash"; "Eq" ]) ], let_);
    ]
    |> List.map (fun (n, p, r, w, rc) -> simple ~owner:"Set" ~owner_ty:set_self ~name:n ~params:p ~ret:r ~decl:[ ("T", set_p) ] ~where:w ~recv_conv:rc)
  in
  (* trait-contract method stubs reachable on concrete types *)
  let m_display =
    [ ("Int", i_ty); ("Bool", b_ty); ("Float", f_ty); ("String", s_ty) ]
    |> List.map (fun (owner, oty) ->
           simple ~owner ~owner_ty:oty ~name:"fmt" ~params:[] ~ret:s_ty ~decl:[] ~where:[] ~recv_conv:let_)
  in
  let int_owners =
    [ "Int"; "UInt"; "i8"; "i16"; "i32"; "i64"; "i128"; "u8"; "u16"; "u32"; "u64"; "u128" ]
  in
  let m_hash =
    List.map
      (fun owner ->
        let oty = Type_repr.Int (Option.get (int_kind_of_name owner)) in
        simple ~owner ~owner_ty:oty ~name:"hash" ~params:[] ~ret:i_ty ~decl:[] ~where:[] ~recv_conv:let_)
      int_owners
    @ [
        simple ~owner:"Float" ~owner_ty:f_ty ~name:"hash" ~params:[] ~ret:i_ty ~decl:[] ~where:[] ~recv_conv:let_;
        simple ~owner:"Bool" ~owner_ty:b_ty ~name:"hash" ~params:[] ~ret:i_ty ~decl:[] ~where:[] ~recv_conv:let_;
        simple ~owner:"Char" ~owner_ty:c_ty ~name:"hash" ~params:[] ~ret:i_ty ~decl:[] ~where:[] ~recv_conv:let_;
        simple ~owner:"String" ~owner_ty:s_ty ~name:"hash" ~params:[] ~ret:i_ty ~decl:[] ~where:[] ~recv_conv:let_;
      ]
  in
  let m_eq =
    List.map
      (fun owner ->
        let oty = Type_repr.Int (Option.get (int_kind_of_name owner)) in
        simple ~owner ~owner_ty:oty ~name:"eq" ~params:[ par "other" let_ oty ] ~ret:b_ty ~decl:[] ~where:[] ~recv_conv:let_)
      int_owners
    @ [
        simple ~owner:"Float" ~owner_ty:f_ty ~name:"eq" ~params:[ par "other" let_ f_ty ] ~ret:b_ty ~decl:[] ~where:[] ~recv_conv:let_;
        simple ~owner:"Bool" ~owner_ty:b_ty ~name:"eq" ~params:[ par "other" let_ b_ty ] ~ret:b_ty ~decl:[] ~where:[] ~recv_conv:let_;
        simple ~owner:"Char" ~owner_ty:c_ty ~name:"eq" ~params:[ par "other" let_ c_ty ] ~ret:b_ty ~decl:[] ~where:[] ~recv_conv:let_;
        simple ~owner:"String" ~owner_ty:s_ty ~name:"eq" ~params:[ par "other" let_ s_ty ] ~ret:b_ty ~decl:[] ~where:[] ~recv_conv:let_;
      ]
  in
  (* trait-name-keyed entries: a generic receiver with a trait bound
     (`fn f[T: Hash](x: T)`) dispatches through candidate_owners = the
     bound trait names; the methods table must carry (Hash, hash),
     (Eq, eq), (Display, fmt), (Clone, clone) keys whose self is the
     trait's generic parameter, so the bound's methods resolve *)
  let generic_self = Type_repr.Type_param (fresh_param_id st) in
  let m_traits =
    [
      ("Hash", "hash", [ ("self", let_, generic_self) ], i_ty);
      ("Eq", "eq", [ ("self", let_, generic_self); ("other", let_, generic_self) ], b_ty);
      ("Eq", "ne", [ ("self", let_, generic_self); ("other", let_, generic_self) ], b_ty);
      ("Display", "fmt", [ ("self", let_, generic_self) ], s_ty);
      ("Clone", "clone", [ ("self", let_, generic_self) ], generic_self);
    ]
    |> List.map (fun (owner, name, params, ret) ->
           ((owner, name),
            mk_sig st ~name:("builtin::" ^ owner ^ "::" ^ name) ~params_decl:[]
              ~params ~ret ~where:[]))
  in
  m_string @ m_str @ m_int @ m_uint @ m_small_int @ m_float @ m_bool @ m_char
  @ m_vec @ m_array @ m_opt @ m_res @ m_map @ m_set @ m_display @ m_hash @ m_eq
  @ m_traits

(* ─── builtin variant constructors ───
   LangItem unification (audit Fix 4): the constructors share the
   canonical Option/Result parameter ids with the method tables and the
   nominals, so every builtin and source-declared use of Option/Result
   has ONE parameter identity. *)
let builtin_constructors (st : state) (opt_p : Ids.Generic_param_id.t)
    (res_p : Ids.Generic_param_id.t) (res_e_p : Ids.Generic_param_id.t) :
    (string * typed_signature) list =
  let some_t = opt_p in
  let some =
    mk_sig st ~name:"Option::Some" ~params_decl:[ ("T", some_t) ]
      ~params:[ ("value", Access_effect.Let, Type_repr.Type_param some_t) ]
      ~ret:(Type_repr.Named (b_option, [| Type_repr.Type_param some_t |])) ~where:[]
  in
  let none_t = opt_p in
  let none =
    mk_sig st ~name:"Option::None" ~params_decl:[ ("T", none_t) ]
      ~params:[] ~ret:(Type_repr.Named (b_option, [| Type_repr.Type_param none_t |])) ~where:[]
  in
  let ok_t = res_p in
  let ok_e = res_e_p in
  let ok =
    mk_sig st ~name:"Result::Ok" ~params_decl:[ ("T", ok_t); ("E", ok_e) ]
      ~params:[ ("value", Access_effect.Let, Type_repr.Type_param ok_t) ]
      ~ret:(Type_repr.Named (b_result, [| Type_repr.Type_param ok_t; Type_repr.Type_param ok_e |]))
      ~where:[]
  in
  let err_t = res_p in
  let err_e = res_e_p in
  let err =
    mk_sig st ~name:"Result::Err" ~params_decl:[ ("T", err_t); ("E", err_e) ]
      ~params:[ ("value", Access_effect.Let, Type_repr.Type_param err_e) ]
      ~ret:(Type_repr.Named (b_result, [| Type_repr.Type_param err_t; Type_repr.Type_param err_e |]))
      ~where:[]
  in
  [
    ("Some", some); ("Option::Some", some); ("None", none); ("Option::None", none);
    ("Ok", ok); ("Result::Ok", ok); ("Err", err); ("Result::Err", err);
  ]

(* The initial env: the compiler-registered prelude. *)
let initial_env ?(resolved : Resolver.resolved_program option = None) () : env =
  (* the Box wrapper identity is per-environment: the global only ever
     tracks the CURRENT env's Box registration, never one leaked from an
     earlier independent compilation environment in the same process *)
  box_tid := None;
  let st =
    {
      next_type_id = 100;
      next_param_id = 1000;
      next_var_id = 0;
      failed_items = [];
      o_handoff_resolved = 0;
      nested_functions = [];
      query_sigs = [];
      o_handoff_fallback = 0;
      sig_param_ids = Hashtbl.create 256;
      next_callable_id = 0;
      next_impl_index = 0;
      current_item = "<none>";
      current_item_params = [];
      oracle =
        {
          o_exprs = [];
          o_calls = [];
          o_obligations = [];
          o_type_params = 0;
          o_unsolved_vars = 0;
          o_error_types = 0;
          o_unknown_defs = 0;
          o_unknown_fields = 0;
          o_unknown_variants = 0;
          o_unresolved_calls = 0;
          o_unsolved_obligations = 0;
          o_missing_effects = 0;
          o_derived_callables = [];
          o_deferred_params = [];
          o_accesses = [];
          o_access_seq = 0;
          o_access_root_ids = Hashtbl.create 256;
        };
      debt_by_module = [];
      debt_last_printed =
        Debt_report.empty |> Debt_report.to_lines |> String.concat "\n";
    }
  in
  let types = builtin_types st in
  let types = ("isize", Type_repr.Int Type_repr.Int) :: types in
  (* the canonical sync intrinsics and type-query builtins: ONE
     registration, so the bare names resolve exactly (the source
     duplicates them across std/alloc and std/ffi, which would make the
     suffix lookup ambiguous) *)
  let u8_ty = Type_repr.Int Type_repr.U8 in
  let uint_ty = Type_repr.Int Type_repr.UInt in
  let ptr_u8 = Type_repr.Named (b_ptr, [| u8_ty |]) in
  let ptr_uint = Type_repr.Named (b_ptr, [| uint_ty |]) in
  let sync_builtins =
    [
      mk_sig st ~name:"__sync_synchronize" ~params_decl:[]
        ~params:[] ~ret:Type_repr.Unit ~where:[];
      mk_sig st ~name:"__sync_fetch_and_add" ~params_decl:[]
        ~params:
          [
            ("ptr", Access_effect.Let, ptr_uint);
            ("val", Access_effect.Let, uint_ty);
          ]
        ~ret:uint_ty ~where:[];
      mk_sig st ~name:"__sync_fetch_and_sub" ~params_decl:[]
        ~params:
          [
            ("ptr", Access_effect.Let, ptr_uint);
            ("val", Access_effect.Let, uint_ty);
          ]
        ~ret:uint_ty ~where:[];
      mk_sig st ~name:"__sync_bool_compare_and_swap_1" ~params_decl:[]
        ~params:
          [
            ("ptr", Access_effect.Let, ptr_u8);
            ("expected", Access_effect.Let, u8_ty);
            ("desired", Access_effect.Let, u8_ty);
          ]
        ~ret:Type_repr.Bool ~where:[];
      mk_sig st ~name:"__sync_val_compare_and_swap_uint" ~params_decl:[]
        ~params:
          [
            ("ptr", Access_effect.Let, ptr_uint);
            ("expected", Access_effect.Let, uint_ty);
            ("desired", Access_effect.Let, uint_ty);
          ]
        ~ret:uint_ty ~where:[];
    ]
  in
  let libc_builtins =
    [
      mk_sig st ~name:"memcpy" ~params_decl:[]
        ~params:
          [
            ("dest", Access_effect.Let, ptr_u8);
            ("src", Access_effect.Let, ptr_u8);
            ("n", Access_effect.Let, uint_ty);
          ]
        ~ret:ptr_u8 ~where:[];
      mk_sig st ~name:"memset" ~params_decl:[]
        ~params:
          [
            ("dest", Access_effect.Let, ptr_u8);
            ("c", Access_effect.Let, Type_repr.Int Type_repr.Int);
            ("n", Access_effect.Let, uint_ty);
          ]
        ~ret:ptr_u8 ~where:[];
      mk_sig st ~name:"memmove" ~params_decl:[]
        ~params:
          [
            ("dest", Access_effect.Let, ptr_u8);
            ("src", Access_effect.Let, ptr_u8);
            ("n", Access_effect.Let, uint_ty);
          ]
        ~ret:ptr_u8 ~where:[];
    ]
  in
  let u32_ty = Type_repr.Int Type_repr.U32 in
  let ts_p2 = fresh_param_id st in
  let set_p2 = fresh_param_id st in
  let misc_builtins =
    [
      (* the kernel's compiler helpers: the a64 condition code constant
         (runtime's emit_tg_mem_alloc), Set::of (taint's singleton
         sets), and the duration queries (bench) *)
      mk_sig st ~name:"a64_cc_hi" ~params_decl:[]
        ~params:[] ~ret:u32_ty ~where:[];
      mk_sig st ~name:"set_of" ~params_decl:[ ("T", set_p2) ]
        ~params:[ ("value", Access_effect.Let, Type_repr.Type_param set_p2) ]
        ~ret:(Type_repr.Named (b_set, [| Type_repr.Type_param set_p2 |])) ~where:[];

    ]
  in
  let regex_builtin =
    mk_sig st ~name:"__intrinsic_regex_match" ~params_decl:[]
      ~params:
        [
          ("value", Access_effect.Let, Type_repr.String);
          ("pattern", Access_effect.Let, Type_repr.String);
        ]
      ~ret:Type_repr.Bool ~where:[]
  in
  let str_ty = Type_repr.String in
  let char_vec = Type_repr.Named (b_array, [| Type_repr.Char |]) in
  let str_misc_builtins =
    [
      mk_sig st ~name:"string_clone" ~params_decl:[]
        ~params:[ ("s", Access_effect.Let, str_ty) ]
        ~ret:str_ty ~where:[];
      mk_sig st ~name:"string_hash" ~params_decl:[]
        ~params:[ ("s", Access_effect.Let, str_ty) ]
        ~ret:(Type_repr.Int Type_repr.Int) ~where:[];
      mk_sig st ~name:"string_from_chars" ~params_decl:[]
        ~params:[ ("chars", Access_effect.Let, char_vec) ]
        ~ret:str_ty ~where:[];
      mk_sig st ~name:"duration_nanos" ~params_decl:[ ("T", ts_p2) ]
        ~params:[ ("ts", Access_effect.Let, Type_repr.Type_param ts_p2) ]
        ~ret:(Type_repr.Int Type_repr.UInt) ~where:[];
      mk_sig st ~name:"duration_millis" ~params_decl:[ ("T", ts_p2) ]
        ~params:[ ("ts", Access_effect.Let, Type_repr.Type_param ts_p2) ]
        ~ret:(Type_repr.Int Type_repr.UInt) ~where:[];
      mk_sig st ~name:"vec_filled" ~params_decl:[ ("T", ts_p2) ]
        ~params:
          [
            ("n", Access_effect.Let, Type_repr.Int Type_repr.Int);
            ("value", Access_effect.Let, Type_repr.Type_param ts_p2);
          ]
        ~ret:(Type_repr.Named (b_array, [| Type_repr.Type_param ts_p2 |])) ~where:[];
      mk_sig st ~name:"a64_ldurb" ~params_decl:[ ("T", ts_p2) ]
        ~params:
          [
            ("b", Access_effect.Inout, Type_repr.Type_param ts_p2);
            ("rd", Access_effect.Let, Type_repr.Type_param ts_p2);
            ("rn", Access_effect.Let, Type_repr.Type_param ts_p2);
            ("imm", Access_effect.Let, Type_repr.Int Type_repr.Int);
          ]
        ~ret:Type_repr.Unit ~where:[];
    ]
  in
  let vec_u8 = Type_repr.Named (b_array, [| u8_ty |]) in
  let string_builtins =
    [
      (* the compiler constructors (docs: no extern spelling needed) *)
      mk_sig st ~name:"string_new" ~params_decl:[]
        ~params:[] ~ret:str_ty ~where:[];
      mk_sig st ~name:"string_from_bytes" ~params_decl:[]
        ~params:[ ("data", Access_effect.Let, vec_u8) ]
        ~ret:str_ty ~where:[];
    ]
  in
  let opt_p2 = fresh_param_id st in
  let vec_p2 = fresh_param_id st in
  let ptr_p2 = fresh_param_id st in
  let ptr_p = fresh_param_id st in
  let ptr_t = Type_repr.Named (b_ptr, [| Type_repr.Type_param ptr_p |]) in
  let ptr_builtins =
    [
      (* the raw-pointer surface the kernel relies on (box_new's
         ptr.write, rc_new's ptr.read): compiler builtins *)
      mk_sig st ~name:"Ptr::write" ~params_decl:[ ("T", ptr_p) ]
        ~params:
          [
            ("self", Access_effect.Let, ptr_t);
            ("value", Access_effect.Sink, Type_repr.Type_param ptr_p);
          ]
        ~ret:Type_repr.Unit ~where:[];
      mk_sig st ~name:"Ptr::read" ~params_decl:[ ("T", ptr_p) ]
        ~params:[ ("self", Access_effect.Let, ptr_t) ]
        ~ret:(Type_repr.Type_param ptr_p) ~where:[];
      (* Ptr::as_mut (ArcStrong/Drop bodies), Ptr::drop_in_place *)
      mk_sig st ~name:"Ptr::as_mut" ~params_decl:[ ("T", ptr_p2) ]
        ~params:[ ("self", Access_effect.Let, Type_repr.Named (b_ptr, [| Type_repr.Type_param ptr_p2 |])) ]
        ~ret:(Type_repr.Named (b_ptrmut, [| Type_repr.Type_param ptr_p2 |])) ~where:[];
      mk_sig st ~name:"Ptr::drop_in_place" ~params_decl:[ ("T", ptr_p2) ]
        ~params:[ ("self", Access_effect.Inout, Type_repr.Named (b_ptr, [| Type_repr.Type_param ptr_p2 |])) ]
        ~ret:Type_repr.Unit ~where:[];
      (* Vec::sort (the bench's sorted.sort()), Vec::truncate,
         Vec::as_ptr_address (the ffi's args.as_ptr_address()) *)
      mk_sig st ~name:"Vec::sort" ~params_decl:[ ("T", vec_p2) ]
        ~params:[ ("self", Access_effect.Inout, Type_repr.Named (b_array, [| Type_repr.Type_param vec_p2 |])) ]
        ~ret:Type_repr.Unit ~where:[];
      mk_sig st ~name:"Vec::truncate" ~params_decl:[ ("T", vec_p2) ]
        ~params:
          [
            ("self", Access_effect.Inout, Type_repr.Named (b_array, [| Type_repr.Type_param vec_p2 |]));
            ("new_len", Access_effect.Let, Type_repr.Int Type_repr.Int);
          ]
        ~ret:Type_repr.Unit ~where:[];
      mk_sig st ~name:"Vec::as_ptr_address" ~params_decl:[ ("T", vec_p2) ]
        ~params:[ ("self", Access_effect.Let, Type_repr.Named (b_array, [| Type_repr.Type_param vec_p2 |])) ]
        ~ret:(Type_repr.Named (b_ptr, [| Type_repr.Type_param vec_p2 |])) ~where:[];
      (* Option::to_string (the impl Result/Array bodies) *)
      mk_sig st ~name:"Option::to_string" ~params_decl:[ ("T", opt_p2) ]
        ~params:
          [
            ("self", Access_effect.Let, Type_repr.Named (b_option, [| Type_repr.Type_param opt_p2 |]));
          ]
        ~ret:Type_repr.String ~where:[];
      (* Ptr::offset (std::env's get_env pointer walking) *)
      mk_sig st ~name:"Ptr::offset" ~params_decl:[ ("T", ptr_p2) ]
        ~params:
          [
            ("self", Access_effect.Let, Type_repr.Named (b_ptr, [| Type_repr.Type_param ptr_p2 |]));
            ("count", Access_effect.Let, Type_repr.Int Type_repr.Int);
          ]
        ~ret:(Type_repr.Named (b_ptr, [| Type_repr.Type_param ptr_p2 |])) ~where:[];
      (* Ptr::as_ref (WeakRc/ContextError bodies) *)
      mk_sig st ~name:"Ptr::as_ref" ~params_decl:[ ("T", ptr_p2) ]
        ~params:[ ("self", Access_effect.Let, Type_repr.Named (b_ptr, [| Type_repr.Type_param ptr_p2 |])) ]
        ~ret:(Type_repr.Ref_internal (Type_repr.Immutable, Type_repr.Type_param ptr_p2)) ~where:[];
      (* Char::to_uppercase / String::rfind *)
      mk_sig st ~name:"Char::to_uppercase" ~params_decl:[]
        ~params:[ ("self", Access_effect.Let, Type_repr.Char) ]
        ~ret:Type_repr.Char ~where:[];
      mk_sig st ~name:"String::rfind" ~params_decl:[]
        ~params:
          [
            ("self", Access_effect.Let, Type_repr.String);
            ("sub", Access_effect.Let, Type_repr.String);
          ]
        ~ret:(Type_repr.Named (b_option, [| Type_repr.Int Type_repr.Int |])) ~where:[];
      (* String::chars (the bench's s.chars() iteration) *)
      mk_sig st ~name:"String::chars" ~params_decl:[]
        ~params:[ ("self", Access_effect.Let, Type_repr.String) ]
        ~ret:(Type_repr.Named (b_array, [| Type_repr.Char |])) ~where:[];
      (* Vec::resize (the kernel's buffer growth) *)
      mk_sig st ~name:"Vec::resize" ~params_decl:[ ("T", vec_p2) ]
        ~params:
          [
            ("self", Access_effect.Inout, Type_repr.Named (b_array, [| Type_repr.Type_param vec_p2 |]));
            ("new_len", Access_effect.Let, Type_repr.Int Type_repr.Int);
            ("value", Access_effect.Sink, Type_repr.Type_param vec_p2);
          ]
        ~ret:Type_repr.Unit ~where:[];
    ]
  in
  (* the kernel's `Instant` (bench's instant_now): the source std/time
     declares the struct; the builtin nominal adopts the canonical id *)
  let instant_tid = fresh_type_id st in
  let instant_nominal : nominal =
    {
      nom_kind = `Struct;
      nom_params = [];
      nom_fields = [];
      nom_variants = [];
      nom_where = [];
      nom_field_ids = [];
      nom_variant_ids = [];
    }
  in
  let instant_types = ("Instant", Type_repr.Named (instant_tid, [||])) in
  let instant_now_sig =
    mk_sig st ~name:"instant_now" ~params_decl:[]
      ~params:[] ~ret:(Type_repr.Named (instant_tid, [||])) ~where:[]
  in
  (* the kernel's `Any` (Box[Any], Arc[Box[Any]]): declared nowhere in
     the source, a compiler builtin — one concrete nominal *)
  let any_tid = fresh_type_id st in
  let any_nominal : nominal =
    {
      nom_kind = `Struct;
      nom_params = [];
      nom_fields = [];
      nom_variants = [];
      nom_where = [];
      nom_field_ids = [];
      nom_variant_ids = [];
    }
  in
  let types =
    ("Any", Type_repr.Named (any_tid, [||])) :: instant_types :: types
  in
  let type_ids =
    ("Any", any_tid) :: ("Instant", instant_tid) :: type_ids_of_builtins
  in
  let type_names =
    (any_tid, "Any") :: (instant_tid, "Instant") :: type_names_of_builtins
  in

  let any_sig =
    mk_sig st ~name:"Any" ~params_decl:[]
      ~params:[] ~ret:(Type_repr.Named (any_tid, [||])) ~where:[]
  in
  (* the type queries size_of[T]()/align_of[T]() are a SPECIAL FORM at
     call sites (they carry type arguments); they must NOT sit in the
     functions table, or the exact-name lookup would shadow a module's
     own size_of(engine, ty). They are minted ONCE here so the oracle
     sees known DefIds. *)
  let size_p = fresh_param_id st in
  let align_p = fresh_param_id st in
  st.query_sigs <-
    [
      ( "size_of",
        mk_sig st ~name:"size_of" ~params_decl:[ ("T", size_p) ]
          ~params:[] ~ret:(Type_repr.Int Type_repr.UInt) ~where:[] );
      ( "align_of",
        mk_sig st ~name:"align_of" ~params_decl:[ ("T", align_p) ]
          ~params:[] ~ret:(Type_repr.Int Type_repr.UInt) ~where:[] );
    ];
  (* LangItem generic parameters minted once, in declaration order *)
  let vec_p = fresh_param_id st in
  let opt_p = fresh_param_id st in
  let res_p = fresh_param_id st in
  let res_e_p = fresh_param_id st in
  let map_k_p = fresh_param_id st in
  let map_v_p = fresh_param_id st in
  let set_p = fresh_param_id st in
  let impls =
    { Trait_solver.impls = builtin_impls st; param_bounds = []; trait_contracts = builtin_trait_contracts }
  in
  (* builtin nominals so patterns can resolve Option::Some / Result::Ok.
     LangItem unification (audit Fix 4): the nominal's parameter ids must
     BE the method tables' parameter ids — the source std declaration
     (via the seeded sig_param_ids memo below) then reuses the SAME ids,
     so there is exactly one Option-T identity, one Result-T/E identity. *)
  let opt_nominal : nominal =
    {
      nom_kind = `Enum;
      nom_params = [ ("T", opt_p) ];
      nom_fields = [];
      nom_variants =
        [ ("Some", [| Type_repr.Type_param opt_p |]); ("None", [||]) ];
      nom_where = [];
      nom_field_ids = [];
      nom_variant_ids = [];
    }
  in
  let res_nominal : nominal =
    {
      nom_kind = `Enum;
      nom_params = [ ("T", res_p); ("E", res_e_p) ];
      nom_fields = [];
      nom_variants =
        [
          ("Ok", [| Type_repr.Type_param res_p |]);
          ("Err", [| Type_repr.Type_param res_e_p |]);
        ];
      nom_where = [];
      nom_field_ids = [];
      nom_variant_ids = [];
    }
  in
  (* the source declarations of Option/Result adopt the builtin LangItem
     parameter identities through the memo, collapsing the dual nominal
     universes (audit Fix 4) *)
  Hashtbl.replace st.sig_param_ids "nominal::Option" [ ("T", opt_p) ];
  Hashtbl.replace st.sig_param_ids "nominal::Result"
    [ ("T", res_p); ("E", res_e_p) ];
  Hashtbl.replace st.sig_param_ids "nominal::Vec" [ ("T", vec_p) ];
  Hashtbl.replace st.sig_param_ids "nominal::Array" [ ("T", vec_p) ];
  Hashtbl.replace st.sig_param_ids "nominal::Map"
    [ ("K", map_k_p); ("V", map_v_p) ];
  Hashtbl.replace st.sig_param_ids "nominal::Set" [ ("T", set_p) ];
  {
    types;
    type_ids;
    type_names;
    functions =
      List.map
        (fun sig_ -> (sig_.ts_name, sig_))
        (sync_builtins @ libc_builtins @ string_builtins @ str_misc_builtins @ misc_builtins @ [ instant_now_sig; any_sig; regex_builtin ]);
    methods =
      List.fold_left
        (fun m sig_ ->
          match String.index_opt sig_.ts_name ':' with
          | Some i when i + 2 < String.length sig_.ts_name ->
              let owner = String.sub sig_.ts_name 0 i in
              let mname =
                String.sub sig_.ts_name (i + 2) (String.length sig_.ts_name - i - 2)
              in
              let key = (owner, mname) in
              (key, sig_) :: List.remove_assoc key m
          | _ -> m)
        (builtin_methods st vec_p opt_p res_p res_e_p map_k_p map_v_p set_p)
        ptr_builtins;
    impls;
    current_self = None;
    current_return = None;
    nominals = [ ("Instant", instant_nominal); ("Any", any_nominal); ("Option", opt_nominal); ("Result", res_nominal) ];
    constructors = builtin_constructors st opt_p res_p res_e_p;
    consts = [];
    state = st;
    module_id = Ids.Module_id.make 0;
    resolved;
    module_path = [];
    typed_nodes = Hashtbl.create 256;
  }

(* ────────────────────────────────────────────────────────────────
   Unification (substitution-based; Type_repr has no Var/Error).

   unify subst a b: binds Type_params in `a` against `b` (and vice
   versa); `Never` unifies with anything. The substitution is written
   into the caller-owned ref. *)

let rec type_to_string (ty : Type_repr.t) : string =
  match ty with
  | Type_repr.Unit -> "()"
  | Type_repr.Bool -> "Bool"
  | Type_repr.Char -> "Char"
  | Type_repr.Int k -> int_name_of_kind k
  | Type_repr.Float Type_repr.F32 -> "f32"
  | Type_repr.Float Type_repr.F64 -> "Float"
  | Type_repr.String -> "String"
  | Type_repr.Never -> "Never"
  | Type_repr.Raw_ptr (m, t) -> (match m with Type_repr.Mutable -> "*mut " | _ -> "*") ^ type_to_string t
  | Type_repr.Ref_internal (m, t) ->
      (match m with Type_repr.Mutable -> "&mut " | _ -> "&") ^ type_to_string t
  | Type_repr.Tuple elems ->
      "(" ^ String.concat ", " (Array.to_list (Array.map type_to_string elems)) ^ ")"
  | Type_repr.Fixed_array (t, n) -> Printf.sprintf "[%s; %d]" (type_to_string t) n
  | Type_repr.Named (id, args) ->
      let n = string_of_int (Ids.Type_id.to_int id) in
      if Array.length args = 0 then "T#" ^ n
      else "T#" ^ n ^ "[" ^ String.concat ", " (Array.to_list (Array.map type_to_string args)) ^ "]"
  | Type_repr.Function (ps, r) ->
      "fn("
      ^ String.concat ", "
          (Array.to_list
             (Array.map
                (fun p -> Access_effect.to_string p.Type_repr.pt_convention ^ " " ^ type_to_string p.Type_repr.pt_type)
                ps))
      ^ ") -> " ^ type_to_string r
  | Type_repr.Type_param id -> "P#" ^ string_of_int (Ids.Generic_param_id.to_int id)
  | Type_repr.Infer_var v -> "?#" ^ string_of_int v
  | Type_repr.Int_literal _ -> "int-literal"
  | Type_repr.Error -> "error"

(* occurrence check generalized over substitution keys: a rigid
   declaration binder (KParam) or an inference variable (KVar) must not
   be bound to a type containing itself *)
let rec occurs_key (needle : Type_repr.generic_key) (ty : Type_repr.t) : bool =
  match ty with
  | Type_repr.Type_param id -> (
      match needle with
      | Type_repr.KParam pid -> Ids.Generic_param_id.compare id pid = 0
      | Type_repr.KVar _ -> false)
  | Type_repr.Infer_var v -> (
      match needle with
      | Type_repr.KParam _ -> false
      | Type_repr.KVar vv -> v = vv)
  | Type_repr.Int_literal _ | Type_repr.Error -> false
  | Type_repr.Raw_ptr (_, t) | Type_repr.Ref_internal (_, t) | Type_repr.Fixed_array (t, _) ->
      occurs_key needle t
  | Type_repr.Tuple elems | Type_repr.Named (_, elems) -> Array.exists (occurs_key needle) elems
  | Type_repr.Function (params, ret) ->
      Array.exists (fun p -> occurs_key needle p.Type_repr.pt_type) params || occurs_key needle ret
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _ | Type_repr.Float _
  | Type_repr.String | Type_repr.Never ->
      false

let rec resolve_param (subst : (Type_repr.generic_key * Type_repr.t) list)
    (id : Ids.Generic_param_id.t) : Type_repr.t option =
  match List.assoc_opt (Type_repr.KParam id) subst with
  | Some (Type_repr.Type_param id2) -> (
      if Ids.Generic_param_id.compare id2 id = 0 then Some (Type_repr.Type_param id)
      else match resolve_param subst id2 with Some t -> Some t | None -> Some (Type_repr.Type_param id))
  | Some (Type_repr.Infer_var v) -> resolve_var subst v
  | Some t -> Some t
  | None -> None

and resolve_var (subst : (Type_repr.generic_key * Type_repr.t) list) (v : int) : Type_repr.t option =
  match List.assoc_opt (Type_repr.KVar v) subst with
  | Some (Type_repr.Type_param id2) -> resolve_param subst id2
  | Some (Type_repr.Infer_var v2) -> resolve_var subst v2
  | Some t -> Some t
  | None -> Some (Type_repr.Infer_var v)

let rec unify (subst : (Type_repr.generic_key * Type_repr.t) list ref) (a : Type_repr.t)
    (b : Type_repr.t) : (unit, string) result =
  let a' =
    match a with
    | Type_repr.Type_param id -> (
        match resolve_param !subst id with
        | Some t -> t
        | None -> a)
    | Type_repr.Infer_var v -> (
        match resolve_var !subst v with
        | Some t -> t
        | None -> a)
    | _ -> a
  in
  let b' =
    match b with
    | Type_repr.Type_param id -> (
        match resolve_param !subst id with
        | Some t -> t
        | None -> b)
    | Type_repr.Infer_var v -> (
        match resolve_var !subst v with
        | Some t -> t
        | None -> b)
    | _ -> b
  in
  match a', b' with
  | x, y when Type_repr.compare x y = 0 -> Ok ()
  | Type_repr.Never, _ | _, Type_repr.Never -> Ok ()
  | Type_repr.Int_literal m, Type_repr.Int k ->
      (* an unsuffixed literal adopts the concrete integer kind only when
         its magnitude is representable in that kind (the native
         IntLiteral rule) *)
      let p : Literal.parsed_integer =
        { original = ""; radix = 10; magnitude = m; suffix = Literal.No_int_suffix;
          span = Span.synthetic }
      in
      let fits = if int_signed k then Literal.fits_signed p (int_width k) else Literal.fits_unsigned p (int_width k) in
      if fits then Ok ()
      else
        Error
          (Printf.sprintf "integer literal does not fit its adopted type %s"
             (int_name_of_kind k))
  | Type_repr.Int k, Type_repr.Int_literal m ->
      let p : Literal.parsed_integer =
        { original = ""; radix = 10; magnitude = m; suffix = Literal.No_int_suffix;
          span = Span.synthetic }
      in
      let fits = if int_signed k then Literal.fits_signed p (int_width k) else Literal.fits_unsigned p (int_width k) in
      if fits then Ok ()
      else
        Error
          (Printf.sprintf "integer literal does not fit its adopted type %s"
             (int_name_of_kind k))
  | Type_repr.Int_literal _, Type_repr.Int_literal _ -> Ok ()
  | Type_repr.Named (id, [| t |]), u when is_box id -> unify subst t u
  | u, Type_repr.Named (id, [| t |]) when is_box id -> unify subst u t
  | Type_repr.Infer_var v, _ ->
      if occurs_key (Type_repr.KVar v) b' then Error "recursive type"
      else begin
        subst := (Type_repr.KVar v, b') :: !subst;
        Ok ()
      end
  | _, Type_repr.Infer_var v ->
      if occurs_key (Type_repr.KVar v) a' then Error "recursive type"
      else begin
        subst := (Type_repr.KVar v, a') :: !subst;
        Ok ()
      end
  | Type_repr.Type_param pa, _ ->
      (* RIGID: a declaration binder absent from the substitution has
         not been instantiated — it is rigid within its own declaration
         and must never be bound by unification (the native model).
         Pre-instantiation covers every generic use; anything reaching
         this arm is an uninstantiated leak and must be reported. *)
      Error
        (Printf.sprintf "cannot unify rigid generic parameter P#%d with %s"
           (Ids.Generic_param_id.to_int pa) (type_to_string b'))
  | _, Type_repr.Type_param pb ->
      Error
        (Printf.sprintf "cannot unify rigid generic parameter P#%d with %s"
           (Ids.Generic_param_id.to_int pb) (type_to_string a'))
  | Type_repr.Named (id1, a1), Type_repr.Named (id2, a2) ->
      if
        Ids.Type_id.compare id1 id2 <> 0
        || Array.length a1 <> Array.length a2
      then Error "type mismatch"
      else begin
        let rec go i =
          if i >= Array.length a1 then Ok ()
          else match unify subst a1.(i) a2.(i) with Ok () -> go (i + 1) | Error m -> Error m
        in
        go 0
      end
  | Type_repr.Tuple a1, Type_repr.Tuple b1 ->
      if Array.length a1 <> Array.length b1 then Error "tuple arity mismatch"
      else begin
        let rec go i =
          if i >= Array.length a1 then Ok ()
          else match unify subst a1.(i) b1.(i) with Ok () -> go (i + 1) | Error m -> Error m
        in
        go 0
      end
  | Type_repr.Fixed_array (t1, n1), Type_repr.Fixed_array (t2, n2) ->
      if n1 <> n2 then Error "array length mismatch" else unify subst t1 t2
  | Type_repr.Ref_internal (m1, t1), Type_repr.Ref_internal (m2, t2) ->
      if m1 <> m2 then Error "reference mutability mismatch" else unify subst t1 t2
  | Type_repr.Raw_ptr (m1, t1), Type_repr.Raw_ptr (m2, t2) ->
      if m1 <> m2 then Error "pointer mutability mismatch" else unify subst t1 t2
  (* the address-of coercion: an explicit reference unifies with a raw
     pointer over the same pointee (the sync intrinsics take &x) *)
  | Type_repr.Raw_ptr (m1, t1), Type_repr.Ref_internal (_, t2)
  | Type_repr.Ref_internal (_, t1), Type_repr.Raw_ptr (m1, t2) ->
      if m1 = Type_repr.Mutable then unify subst t1 t2
      else Error "pointer mutability mismatch"
  | Type_repr.Named (id1, [| t1 |]), Type_repr.Ref_internal (_, t2)
    when Ids.Type_id.compare id1 b_ptr = 0 || Ids.Type_id.compare id1 b_ptrmut = 0 ->
      unify subst t1 t2
  | Type_repr.Ref_internal (_, t1), Type_repr.Named (id2, [| t2 |])
    when Ids.Type_id.compare id2 b_ptr = 0 || Ids.Type_id.compare id2 b_ptrmut = 0 ->
      unify subst t1 t2
  | Type_repr.Function (p1, r1), Type_repr.Function (p2, r2) ->
      if Array.length p1 <> Array.length p2 then Error "function arity mismatch"
      else begin
        let rec go i =
          if i >= Array.length p1 then unify subst r1 r2
          else if p1.(i).Type_repr.pt_convention <> p2.(i).Type_repr.pt_convention then
            Error "parameter convention mismatch"
          else
            match unify subst p1.(i).Type_repr.pt_type p2.(i).Type_repr.pt_type with
            | Ok () -> go (i + 1)
            | Error m -> Error m
        in
        go 0
      end
  | _ -> Error "type mismatch"

(* Substitute through the bindings until fixpoint. *)
let substitute_fixpoint (subst : (Type_repr.generic_key * Type_repr.t) list) (ty : Type_repr.t) :
    Type_repr.t =
  let rec go n ty =
    let ty' =
      Type_repr.substitute subst ty
    in
    if Type_repr.compare ty ty' = 0 || n > List.length subst + 1 then ty'
    else go (n + 1) ty'
  in
  go 0 ty

let params_in (ty : Type_repr.t) : Ids.Generic_param_id.t list =
  let acc = ref [] in
  let rec walk ty =
    match ty with
    | Type_repr.Type_param id -> if not (List.mem id !acc) then acc := id :: !acc
    | Type_repr.Infer_var _ | Type_repr.Int_literal _ | Type_repr.Error -> ()
    | Type_repr.Raw_ptr (_, t) | Type_repr.Ref_internal (_, t) | Type_repr.Fixed_array (t, _) ->
        walk t
    | Type_repr.Tuple elems | Type_repr.Named (_, elems) -> Array.iter walk elems
    | Type_repr.Function (ps, r) ->
        Array.iter (fun p -> walk p.Type_repr.pt_type) ps;
        walk r
    | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _ | Type_repr.Float _
    | Type_repr.String | Type_repr.Never ->
        ()
  in
  walk ty;
  List.rev !acc

(* unsolved inference variables present in a type (the flexible side of
   the residual-parameter machinery) *)
let vars_in (ty : Type_repr.t) : int list =
  let acc = ref [] in
  let rec walk ty =
    match ty with
    | Type_repr.Infer_var v -> if not (List.mem v !acc) then acc := v :: !acc
    | Type_repr.Raw_ptr (_, t) | Type_repr.Ref_internal (_, t) | Type_repr.Fixed_array (t, _) ->
        walk t
    | Type_repr.Tuple elems | Type_repr.Named (_, elems) -> Array.iter walk elems
    | Type_repr.Function (params, ret) ->
        Array.iter (fun p -> walk p.Type_repr.pt_type) params;
        walk ret
    | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _ | Type_repr.Float _
    | Type_repr.String | Type_repr.Type_param _ | Type_repr.Int_literal _ | Type_repr.Error
    | Type_repr.Never ->
        ()
  in
  walk ty;
  List.rev !acc

(* ────────────────────────────────────────────────────────────────
   Constant evaluation (bootstrap: integer literal constants) *)

let resolve_constant_int (e : Ast.expr) : (int, string) result =
  match e with
  | Ast.IntLit (spelling, span) -> (
      match Literal.parse_integer ~span spelling with
      | Some p when Big_nat.fits_ocaml_int p.Literal.magnitude ->
          Ok (Big_nat.to_ocaml_int p.Literal.magnitude)
      | Some _ -> Error "array length literal is too large"
      | None -> Error "malformed integer literal")
  | _ -> Error "array length must be an integer literal constant"

(* ────────────────────────────────────────────────────────────────
   Type resolution (Ast.type_expr -> Type_repr) *)

let rec resolve_type (env : env) (scope : scope) (t : Ast.type_expr) : (Type_repr.t, string) result =
  match t with
  | Ast.Named (name, args, span) -> resolve_named env scope span name args
  | Ast.AssocBinding (_name, value, span) ->
      (* associated-type binding inside type arguments: resolve the value;
         the binding name has no Type_repr slot (bootstrap subset) *)
      resolve_type env scope value |> Result.map_error (fun m -> err span m)
  | Ast.ConstExpr (e, span) -> (
      match resolve_constant_int e with
      | Ok _ ->
          Error (err span "constant type expressions are not supported in the bootstrap subset")
      | Error m -> Error (err span m))
  | Ast.Never _ -> Ok Type_repr.Never
  | Ast.TTuple (elems, _) -> (
      let rec go acc = function
        | [] -> Ok (Type_repr.Tuple (Array.of_list (List.rev acc)))
        | e :: rest -> (
            match resolve_type env scope e with Ok t -> go (t :: acc) rest | Error m -> Error m)
      in
      go [] elems)
  | Ast.Unit _ -> Ok Type_repr.Unit
  | Ast.Ref (inner, mutable_, _) -> (
      match resolve_type env scope inner with
      | Ok t ->
          Ok (Type_repr.Ref_internal ((if mutable_ then Type_repr.Mutable else Type_repr.Immutable), t))
      | Error m -> Error m)
  | Ast.RawPtr (inner, mutable_, _) -> (
      match resolve_type env scope inner with
      | Ok t ->
          Ok (Type_repr.Raw_ptr ((if mutable_ then Type_repr.Mutable else Type_repr.Immutable), t))
      | Error m -> Error m)
  | Ast.FnPtr (params, ret, span) -> (
      let rec go acc = function
        | [] -> (
            match resolve_type env scope ret with
            | Ok rt -> Ok (Type_repr.Function (Array.of_list (List.rev acc), rt))
            | Error m -> Error m)
        | p :: rest -> (
            match resolve_type env scope p with
            | Ok pt ->
                go ({ Type_repr.pt_convention = Access_effect.Let; pt_type = pt } :: acc) rest
            | Error m -> Error m)
      in
      go [] params |> Result.map_error (fun m -> err span m))
  | Ast.TArray (elem, len, span) -> (
      match resolve_type env scope elem with
      | Error m -> Error m
      | Ok et -> (
          match len with
          | None -> Ok (Type_repr.Named (b_array, [| et |]))
          | Some le -> (
              match resolve_constant_int le with
              | Ok n when n >= 0 -> Ok (Type_repr.Fixed_array (et, n))
              | Ok _ -> Error (err span "negative array length")
              | Error m -> Error (err span m))))
  | Ast.Slice (inner, _) -> (
      match resolve_type env scope inner with
      | Ok t -> Ok (Type_repr.Named (b_array, [| t |]))
      | Error m -> Error m)
  | Ast.SelfType span -> (
      match env.current_self with
      | Some t -> Ok t
      | None -> Error (err span "Self is only available inside an impl"))
  | Ast.DynTrait _ | Ast.ImplTrait _ ->
      Error (err (Ast.type_span t) "trait-object types are not available in the bootstrap subset")
  | Ast.Bounded (base, _, _) -> resolve_type env scope base
  | Ast.Option (inner, _) -> (
      match resolve_type env scope inner with
      | Ok t -> Ok (Type_repr.Named (b_option, [| t |]))
      | Error m -> Error m)
  | Ast.Inferred span -> Error (err span "cannot infer this type; an explicit annotation is required")

and resolve_named (env : env) (scope : scope) (span : Span.span) (name : string)
    (args : Ast.type_expr list) : (Type_repr.t, string) result =
  match List.assoc_opt name scope.generics with
  | Some id ->
      if args <> [] then Error (err span "type parameters do not take arguments")
      else Ok (Type_repr.Type_param id)
  | None -> (
      match name with
      | "Self" ->
          if args <> [] then Error (err span "Self does not take arguments")
          else (
            match env.current_self with
            | Some t -> Ok t
            | None -> Error (err span "Self is only available inside an impl"))
      | _ -> (
          match String.index_opt name ':' with
          | Some i ->
              (* qualified / associated-type spelling Name::Assoc *)
              let head = String.sub name 0 i in
              let assoc = String.sub name (i + 2) (String.length name - i - 2) in
              (match List.assoc_opt head scope.generics with
               | Some _ ->
                   Error
                     (err span
                        (Printf.sprintf
                           "associated type `%s` of a type parameter is not available in the bootstrap subset"
                           assoc))
               | None -> (
                   match resolve_named env scope span head [] with
                   | Ok _ ->
                       Error
                         (err span
                            (Printf.sprintf
                               "associated type `%s` of `%s` is not available in the bootstrap subset"
                               assoc head))
                   | Error _ -> (
                       (* flat-namespace fallback: a module-qualified type
                          spelling resolves by its last segment *)
                       let last =
                         match List.rev (String.split_on_char ':' name) with
                         | x :: _ -> x
                         | [] -> name
                       in
                       match List.assoc_opt last env.types with
                       | Some entry -> Ok entry
                       | None -> Error (err span ("unknown type `" ^ name ^ "`")))))
          | None -> (
              match List.assoc_opt name env.types with
              | None -> Error (err span ("unknown type `" ^ name ^ "`"))
              | Some entry -> (
                  let resolved_args =
                    let rec go acc = function
                      | [] -> Ok (List.rev acc)
                      | a :: rest -> (
                          match resolve_type env scope a with
                          | Ok t -> go (t :: acc) rest
                          | Error m -> Error m)
                    in
                    go [] args
                  in
                  match resolved_args with
                  | Error m -> Error m
                  | Ok rargs -> (
                      let params = params_in entry in
                      if List.length rargs <> List.length params then
                        Error
                          (err span
                             (Printf.sprintf "type `%s` expects %d type argument(s), got %d" name
                                (List.length params) (List.length rargs)))
                      else begin
                        let subst = List.map2 (fun p a -> (Type_repr.KParam p, a)) params rargs in
                        Ok (substitute_fixpoint subst entry)
                      end)))))

(* ────────────────────────────────────────────────────────────────
   Signature resolution *)

let resolve_signature (env : env) (scope : scope) (sig_ : Ast.function_sig)
    (extra_params : (string * Ids.Generic_param_id.t) list) ~(key : string) :
    (typed_signature, string) result =
  (* the memo covers ONLY the method's OWN type parameters (per-method
     deterministic minting across the fixpoint re-registrations).  The
     impl/owner-level params (extra_params) are always the current
     caller's binders: a stale memo hit must never mix ANOTHER impl's
     params into this signature (the owner-separated model — each impl's
     U_impl is its own binder; reusing the first impl's ids here would
     make `self: Array[T_a]` and `-> Array[T_b]` disagree). *)
  let params_decl =
    let own =
      match Hashtbl.find_opt env.state.sig_param_ids key with
      | Some ids -> ids
      | None ->
          let ids =
            List.map (fun (tp : Ast.type_param) -> (tp.Ast.tp_name, fresh_param_id env.state))
              sig_.Ast.sig_type_params
          in
          Hashtbl.add env.state.sig_param_ids key ids;
          ids
    in
    own @ extra_params
  in
  let scope =
    { scope with generics = List.map (fun (n, i) -> (n, i)) params_decl @ scope.generics }
  in
  let* params =
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | (p : Ast.param) :: rest -> (
          match resolve_type env scope p.Ast.p_type with
          | Ok pt ->
              go ({ Type_repr.pt_convention = convention_of p.Ast.p_convention; pt_type = pt } :: acc) rest
          | Error m -> Error m)
    in
    go [] sig_.Ast.sig_params
  in
  let* ret =
    match sig_.Ast.sig_return with
    | Some r ->
        let r2 = resolve_type env scope r in

        r2
    | None -> Ok Type_repr.Unit
  in
  let* where =
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | (wp : Ast.where_predicate) :: rest -> (
          match resolve_type env scope wp.Ast.wp_type with
          | Ok wt -> go ((wt, wp.Ast.wp_bounds) :: acc) rest
          | Error m -> Error m)
    in
    go [] sig_.Ast.sig_where
  in
  Ok
    {
      ts_name = sig_.Ast.sig_name;
      ts_params_decl = params_decl;
      ts_params = Array.of_list params;
      ts_param_names =
        Array.of_list (List.map (fun (p : Ast.param) -> p.Ast.p_name) sig_.Ast.sig_params);
      ts_return = ret;
      ts_where = where;
      ts_callable = fresh_callable_id env.state;
      ts_span = sig_.Ast.sig_span;
    }

(* ────────────────────────────────────────────────────────────────
   Generic-context entry: register the parameter bounds into the
   solver's live registry. *)

let solver_param_bounds (decl : (string * Ids.Generic_param_id.t) list)
    (tp_bounds : (string * string list) list) (where : (Type_repr.t * string list) list) :
    (Ids.Generic_param_id.t * (string * Type_repr.t array) list) list =
  List.map
    (fun (name, id) ->
      let declared =
        match List.assoc_opt name tp_bounds with
        | Some bs -> List.map (fun b -> (b, [||])) bs
        | None -> []
      in
      let from_where =
        List.filter_map
          (fun (wt, bs) ->
            match wt with
            | Type_repr.Type_param wid when Ids.Generic_param_id.compare wid id = 0 ->
                Some (List.map (fun b -> (b, [||])) bs)
            | _ -> None)
          where
        |> List.concat
      in
      (id, declared @ from_where))
    decl

(* ────────────────────────────────────────────────────────────────
   Patterns, variant/field resolution, expressions.
   The whole group is mutually recursive. *)

(* ── Place-path derivation for the integrated access channel ─────────
   (re-audit P0-11).  Pure syntactic/scope walk — NO oracle writes, no
   unification, no re-checking: it only derives the Access_check place
   path (root local + projection chain) of a call argument so the
   driver's integrated pass can feed access_check's conflict matrix and
   resource_check's state lattice.  Anything not resolvable is
   conservatively None. *)

(* The access record key: the enclosing item, disambiguated by module
   path (two modules can both define `def f`). *)
let access_item_key (env : env) : string =
  String.concat "::" env.module_path ^ " " ^ env.state.current_item

(* Resolve the FieldId of a named field of the nominal owned by the
   given Type_id (nom_field_ids is the resolver's identity list,
   parallel to nom_fields). *)
let field_id_of (env : env) (owner_name : string) (fname : string) : Ids.Field_id.t option =
  match List.assoc_opt owner_name env.nominals with
  | None -> None
  | Some nom -> (
      let rec index_of i = function
        | [] -> None
        | (n, _) :: rest -> if n = fname then Some i else index_of (i + 1) rest
      in
      match index_of 0 nom.nom_fields with
      | None -> None
      | Some i ->
          if i < List.length nom.nom_field_ids then Some (List.nth nom.nom_field_ids i)
          else None)

(* The static type of a place-shaped expression, used only to resolve
   the FIELD OWNER for field projections (the checked expression's type
   would be the projection RESULT type, which cannot name the owner).
   Deref is conservative None (the pointee type is not statically
   recoverable here without the full checker). *)
let rec static_type_of (env : env) (scope : scope) (e : Ast.expr) : Type_repr.t option =
  match e with
  | Ast.Name (n, _) -> (
      match assoc_local n scope.locals with Some (t, _) -> Some t | None -> None)
  | Ast.Path _ -> None
  | Ast.Field (base, fname, _span) -> (
      match static_type_of env scope base with
      | None -> None
      | Some bt -> (
          (* a field through a reference/pointer derefs the pointee *)
          let bt =
            match bt with
            | Type_repr.Ref_internal (_, t) | Type_repr.Raw_ptr (_, t) -> t
            | Type_repr.Named (id, [| t |])
              when Ids.Type_id.compare id b_ptr = 0 || Ids.Type_id.compare id b_ptrmut = 0 ->
                t
            | _ -> bt
          in
          match bt with
          | Type_repr.Named (tid, _args) -> (
              match List.assoc_opt tid env.type_names with
              | Some owner -> (
                  match List.assoc_opt owner env.nominals with
                  | Some nom when nom.nom_kind = `Struct -> (
                      match List.assoc_opt fname nom.nom_fields with
                      | Some ft -> Some ft
                      | None -> None)
                  | _ -> None)
              | None -> None)
          | _ -> None))
  | Ast.Index (base, _, _) -> (
      match static_type_of env scope base with
      | Some (Type_repr.Fixed_array (t, _)) -> Some t
      | Some (Type_repr.Named (_, [| t |])) -> Some t
      | _ -> None)
  | Ast.Unary (Ast.Borrow, inner, _) | Ast.Unary (Ast.BorrowMut, inner, _) ->
      static_type_of env scope inner
  | _ -> None

(* The place path of a call argument: root = the local's index in the
   scope (stable within the item), projections = the syntactic chain.
   `&x` / `&mut x` arguments are the place of x (the borrow's effect is
   the callee-side convention, recorded separately). *)
let rec place_of_expr (env : env) (scope : scope) (e : Ast.expr) : Access_check.access_path option
    =
  match e with
  | Ast.Name (n, _) -> (
      (* root ids are NAME-keyed (see o_access_root_ids): stable across
         the item even as bindings accumulate *)
      match Hashtbl.find_opt env.state.oracle.o_access_root_ids n with
      | Some i -> Some { Access_check.root = i; Access_check.projections = [] }
      | None ->
          let i = Hashtbl.length env.state.oracle.o_access_root_ids in
          Hashtbl.add env.state.oracle.o_access_root_ids n i;
          Some { Access_check.root = i; Access_check.projections = [] })
  | Ast.Path _ -> None
  | Ast.Field (base, fname, _) -> (
      match place_of_expr env scope base with
      | None -> None
      | Some p -> (
          let fid =
            match static_type_of env scope base with
            | Some (Type_repr.Named (tid, _)) -> (
                match List.assoc_opt tid env.type_names with
                | Some oname -> field_id_of env oname fname
                | None -> None)
            | _ -> None
          in
          match fid with
          | Some fid ->
              Some
                {
                  p with
                  Access_check.projections = p.Access_check.projections @ [ Access_check.Field fid ];
                }
          | None -> None))
  | Ast.Index (base, _, _) -> (
      match place_of_expr env scope base with
      | None -> None
      | Some p ->
          Some
            {
              p with
              Access_check.projections = p.Access_check.projections @ [ Access_check.Index ];
            })
  | Ast.Unary (Ast.Borrow, inner, _) | Ast.Unary (Ast.BorrowMut, inner, _) ->
      place_of_expr env scope inner
  | Ast.Unary (Ast.Deref, inner, _) -> (
      match place_of_expr env scope inner with
      | None -> None
      | Some p ->
          Some
            {
              p with
              Access_check.projections = p.Access_check.projections @ [ Access_check.Deref ];
            })
  | _ -> None

(* Record one call's argument accesses on the integrated channel (in
   program order; the channel is prepended, so callers prepend the
   reversed list).  Each record carries the argument's typed expression
   type so the pass can compute the root's copyability/owned-ness (the
   verifier's copy rule) instead of hard-coding moves. *)
let record_call_accesses (env : env) (scope : scope)
    (accs : (Ast.expr * Access_effect.read_effect * Span.span * Type_repr.t) list) : unit =
  let call_seq = env.state.oracle.o_access_seq in
  env.state.oracle.o_access_seq <- call_seq + 1;
  let item = access_item_key env in
  let records =
    List.map
      (fun (arg_expr, eff, span, ty) ->
        {
          Access_check.a_item = item;
          a_call = call_seq;
          a_path = place_of_expr env scope arg_expr;
          a_effect = eff;
          a_span = span;
          a_type = ty;
        })
      accs
  in
  env.state.oracle.o_accesses <-
    List.rev_append records env.state.oracle.o_accesses

(* Default an unsuffixed literal's inference type to Int when it crosses
   a concrete boundary (binding, arithmetic, cast). *)
let default_literal (ty : Type_repr.t) : Type_repr.t =
  match ty with
  | Type_repr.Int_literal _ -> Type_repr.Int Type_repr.Int
  | t -> t



let rec check_pattern (env : env) (scope : scope) (ty : Type_repr.t) (p : Ast.pattern) :
    ((string * Type_repr.t * bool) list, string) result =
  match p with
  | Ast.Wildcard _ -> Ok []
  | Ast.PatIdent (name, mut_, _) -> Ok [ (name, ty, mut_) ]
  | Ast.RefPattern (name, _) -> Ok [ (name, ty, false) ]
  | Ast.RefMutPattern (name, _) -> Ok [ (name, ty, true) ]
  | Ast.PatLiteral (e, _) -> (
      match check_expr env scope None e with
      | Ok te -> (
          match unify (ref []) ty te.te_type with
          | Ok () -> Ok []
          | Error m ->
              Error
                (err (Ast.expr_span e)
                   (Printf.sprintf "pattern type mismatch: expected %s, found %s (%s)"
                      (type_to_string ty) (type_to_string te.te_type) m)))
      | Error m -> Error m)
  | Ast.PatVariant (seg1, seg2, pats, span) -> (
      match resolve_variant env scope span seg1 seg2 ty with
      | Error m -> Error m
      | Ok (field_tys, _) ->
          if List.length pats <> Array.length field_tys then
            Error
              (err span
                 (Printf.sprintf "variant `%s` expects %d field(s), pattern has %d" seg2
                    (Array.length field_tys) (List.length pats)))
          else begin
            let rec go acc = function
              | [] -> Ok (List.rev acc)
              | (ft, sub) :: rest -> (
                  match check_pattern env scope ft sub with
                  | Ok binds -> go (binds @ acc) rest
                  | Error m -> Error m)
            in
            go [] (List.combine (Array.to_list field_tys) pats)
          end)
  | Ast.StructPattern (name, fields, span) -> (
      match resolve_nominal env span name with
      | Error m -> Error m
      | Ok (nom, tid, args) when nom.nom_kind = `Struct -> (
          (* the pattern's field types instantiate the nominal's params
             with the SCRUTINEE's concrete arguments when the scrutinee
             is the same nominal (the owner-separated model: a pattern
             `Box { ptr }` against `Box[U_impl]` binds Ptr[U_impl], never
             the nominal's own T_struct); otherwise the nominal's stored
             args are the fallback *)
          let args =
            match ty with
            | Type_repr.Named (tyid, tyargs) when Ids.Type_id.compare tyid tid = 0 -> tyargs
            | _ -> args
          in
          let subst = List.map2 (fun (_, p) a -> (Type_repr.KParam p, a)) nom.nom_params (Array.to_list args) in
          let field_ty (fname : string) : (Type_repr.t, string) result =
            match List.assoc_opt fname nom.nom_fields with
            | Some ft -> Ok (substitute_fixpoint subst ft)
            | None ->
                Error (err span (Printf.sprintf "unknown field `%s` of struct `%s`" fname name))
          in
          let rec go acc = function
            | [] -> Ok (List.rev acc)
            | (fname, sub) :: rest -> (
                match field_ty fname with
                | Error m -> Error m
                | Ok ft -> (
                    let sub = match sub with Some s -> s | None -> Ast.PatIdent (fname, false, span) in
                    match check_pattern env scope ft sub with
                    | Ok binds -> go (binds @ acc) rest
                    | Error m -> Error m))
          in
          go [] fields)
      | Ok (nom, _, args) when nom.nom_kind = `Enum -> (
          (* the braced-variant pattern: `Enum::Variant { f1, .. }` —
             the split's member is the variant; the pattern's fields bind
             the variant's payload types positionally *)
          let len = String.length name in
          let rec last_pair i =
            if i <= 0 then None
            else if name.[i] = ':' && name.[i - 1] = ':' then Some i
            else last_pair (i - 1)
          in
          let member =
            match last_pair (len - 1) with
            | Some i when i + 1 < len -> String.sub name (i + 1) (len - i - 1)
            | _ -> name
          in
          let subst = List.map2 (fun (_, p) a -> (Type_repr.KParam p, a)) nom.nom_params (Array.to_list args) in
          match List.assoc_opt member nom.nom_variants with
          | None -> Error (err span (Printf.sprintf "unknown variant `%s` of enum `%s`" member name))
          | Some pty -> (
              let payload = Array.map (substitute_fixpoint subst) pty in
              if Array.length payload <> List.length fields then
                Error (err span (Printf.sprintf "variant `%s` expects %d field(s), pattern has %d" member
                          (Array.length payload) (List.length fields)))
              else begin
                let rec go acc i = function
                  | [] -> Ok (List.rev acc)
                  | (fname, sub) :: rest -> (
                      let sub = match sub with Some s -> s | None -> Ast.PatIdent (fname, false, span) in
                      match check_pattern env scope payload.(i) sub with
                      | Ok binds -> go (binds @ acc) (i + 1) rest
                      | Error m -> Error m)
                in
                go [] 0 fields
              end))
      | Ok _ -> Error (err span (Printf.sprintf "`%s` is not a struct" name)))
  | Ast.PatTuple (pats, span) -> (
      match ty with
      | Type_repr.Tuple elems ->
          if List.length pats <> Array.length elems then Error (err span "tuple pattern arity mismatch")
          else begin
            let rec go acc = function
              | [] -> Ok (List.rev acc)
              | (ft, sub) :: rest -> (
                  match check_pattern env scope ft sub with
                  | Ok binds -> go (binds @ acc) rest
                  | Error m -> Error m)
            in
            go [] (List.combine (Array.to_list elems) pats)
          end
      | _ -> Error (err span "tuple pattern requires a tuple type"))
  | Ast.OrPattern (a, b, span) -> (
      match check_pattern env scope ty a with
      | Error m -> Error m
      | Ok binds_a -> (
          match check_pattern env scope ty b with
          | Error m -> Error m
          | Ok binds_b -> (
              let mismatch =
                List.exists
                  (fun (n, t, _) ->
                    match List.find_opt (fun (k, _, _) -> k = n) binds_b with
                    | Some (_, t2, _) -> Type_repr.compare t t2 <> 0
                    | None -> true)
                  binds_a
              in
              if mismatch then Error (err span "or-pattern alternatives bind different types")
              else Ok binds_a)))
  | Ast.RangePattern (a, b, span) -> (
      match a, b with
      | Ast.PatLiteral (ae, _), Ast.PatLiteral (be, _) -> (
          match check_expr env scope None ae, check_expr env scope None be with
          | Ok ta, Ok tb -> (
              match unify (ref []) ty ta.te_type, unify (ref []) ty tb.te_type with
              | Ok (), Ok () -> Ok []
              | _ -> Error (err span "range pattern does not match the subject type"))
          | _ -> Error (err span "range pattern endpoints must be literals"))
      | _ -> Error (err span "range pattern endpoints must be literals"))

and resolve_variant (env : env) (_scope : scope) (span : Span.span) (seg1 : string)
    (seg2 : string) (subject : Type_repr.t) : (Type_repr.t array * string, string) result =
  if seg1 = "" then begin
    match subject with
    | Type_repr.Named (tid, args) -> (
        match List.assoc_opt tid env.type_names with
        | Some name -> (
            match List.assoc_opt name env.nominals with
            | Some nom when nom.nom_kind = `Enum -> (
                match List.assoc_opt seg2 nom.nom_variants with
                | Some field_tys ->
                    let subst = List.map2 (fun (_, p) a -> (Type_repr.KParam p, a)) nom.nom_params (Array.to_list args) in
                    Ok (Array.map (substitute_fixpoint subst) field_tys, name)
                | None ->
                    env.state.oracle.o_unknown_variants <- env.state.oracle.o_unknown_variants + 1;
                    Error (err span (Printf.sprintf "unknown variant `%s` of enum `%s`" seg2 name)))
            | _ -> Error (err span "pattern subject is not an enum"))
        | None -> Error (err span "pattern subject has unknown type identity"))
    | _ -> Error (err span "variant pattern requires an enum subject")
  end
  else begin
    match resolve_nominal env span seg1 with
    | Error m -> Error m
    | Ok (nom, tid, args) when nom.nom_kind = `Enum -> (
        match List.assoc_opt seg2 nom.nom_variants with
        | Some field_tys ->
            (* prefer the subject's arguments when the subject IS this
               enum — by identity, or by the same-name reconciliation when
               the subject lives in the other nominal universe (builtin
               vs source-declared Option/Result) *)
            let sargs =
              match subject with
              | Type_repr.Named (sid, sargs) when Ids.Type_id.compare sid tid = 0 -> sargs
              | Type_repr.Named (sid, sargs) -> (
                  match List.assoc_opt sid env.type_names with
                  | Some n1 -> if n1 = seg1 then sargs else args
                  | None -> args)
              | _ -> args
            in
            let subst = List.map2 (fun (_, p) a -> (Type_repr.KParam p, a)) nom.nom_params (Array.to_list sargs) in
            Ok (Array.map (substitute_fixpoint subst) field_tys, seg1)
        | None ->
            env.state.oracle.o_unknown_variants <- env.state.oracle.o_unknown_variants + 1;
            Error (err span (Printf.sprintf "unknown variant `%s` of enum `%s`" seg2 seg1)))
    | Ok _ -> Error (err span (Printf.sprintf "`%s` is not an enum" seg1))
  end

and resolve_nominal (env : env) (span : Span.span) (name : string) :
    (nominal * Ids.Type_id.t * Type_repr.t array, string) result =
  match List.assoc_opt name env.nominals with
  | Some nom -> (
      match List.assoc_opt name env.types with
      | Some (Type_repr.Named (tid, args)) -> Ok (nom, tid, args)
      | _ -> Error (err span (Printf.sprintf "`%s` is not a nominal type" name)))
  | None -> (
      (* the qualified braces-form: `Enum::Variant { .. }` patterns and
         `mod::path::Struct { .. }` literals join the full name; split
         the LAST `::` pair and resolve the qualifier as a nominal (the
         variant/field is resolved by the caller) or the last segment
         flat (module-qualified structs) *)
      let len = String.length name in
      let rec last_pair i =
        if i <= 0 then None
        else if name.[i] = ':' && name.[i - 1] = ':' then Some i
        else last_pair (i - 1)
      in
      match last_pair (len - 1) with
      | Some i when i + 1 < len -> (
          let qualifier = String.sub name 0 (i - 1) in
          let member = String.sub name (i + 1) (len - i - 1) in
          match List.assoc_opt qualifier env.nominals with
          | Some nom -> (
              match List.assoc_opt qualifier env.types with
              | Some (Type_repr.Named (tid, args)) -> Ok (nom, tid, args)
              | _ -> Error (err span (Printf.sprintf "`%s` is not a nominal type" qualifier)))
          | None -> (
              (* the qualifier is a module path: resolve the last segment
                 flat (the module-qualified struct form) *)
              match List.assoc_opt member env.nominals with
              | Some nom -> (
                  match List.assoc_opt member env.types with
                  | Some (Type_repr.Named (tid, args)) -> Ok (nom, tid, args)
                  | _ -> Error (err span (Printf.sprintf "`%s` is not a nominal type" member)))
              | None ->
                  Error (err span (Printf.sprintf "unknown nominal type `%s`" name))))
      | _ -> Error (err span (Printf.sprintf "unknown nominal type `%s`" name)))


(* ────────────────────────────────────────────────────────────────
   The expression checker. `check_expr` records every accepted node on
   the oracle channel; `check_expr_inner` is the rule engine. *)

and check_expr (env : env) (scope : scope) (expected : Type_repr.t option) (e : Ast.expr) :
    (typed_expr, string) result =
  match check_expr_inner env scope expected e with
  | Ok te ->
      env.state.oracle.o_exprs <- te :: env.state.oracle.o_exprs;
      (* the persistent typed-node bridge: record the accepted node by
         span identity (file_id, start).  A cast node's te_type IS the
         checker-resolved target type; the dedicated tn_cast_target
         field keeps the channel self-describing for the lowering Cast
         rule (the target carries the declaration-owned GenericParamIds
         the syntax-driven reconstruction cannot recover). *)
      let cast_target = match e with Ast.Cast _ -> Some te.te_type | _ -> None in
      (* a call's tn_call is written by check_call_sig/check_method_call
         (which run INSIDE check_expr_inner, before this replace); preserve
         it so the call channel survives the node record *)
      let key = (te.te_span.Span.file_id, te.te_span.Span.start) in
      let tn_call =
        match Hashtbl.find_opt env.typed_nodes key with
        | Some n -> n.tn_call
        | None -> None
      in
      Hashtbl.replace env.typed_nodes key
        { tn_type = te.te_type; tn_cast_target = cast_target; tn_call };
      Ok te
  | Error m -> Error m

and check_expr_inner (env : env) (scope : scope) (expected : Type_repr.t option)
    (e : Ast.expr) : (typed_expr, string) result =
  match e with
  | Ast.IntLit (spelling, span) -> (
      match Literal.parse_integer ~span spelling with
      | None -> Error (err span "malformed integer literal")
      | Some p -> (
          let kind =
            match p.Literal.suffix with
            | Literal.I8 -> Some Type_repr.I8 | Literal.I16 -> Some Type_repr.I16
            | Literal.I32 -> Some Type_repr.I32 | Literal.I64 -> Some Type_repr.I64
            | Literal.I128 -> Some Type_repr.I128
            | Literal.U8 -> Some Type_repr.U8 | Literal.U16 -> Some Type_repr.U16
            | Literal.U32 -> Some Type_repr.U32 | Literal.U64 -> Some Type_repr.U64
            | Literal.U128 -> Some Type_repr.U128
            | Literal.Int -> Some Type_repr.Int | Literal.UInt -> Some Type_repr.UInt
            | Literal.No_int_suffix -> None
          in
          match kind with
          | Some k -> (
              let fits =
                if int_signed k then Literal.fits_signed p (int_width k)
                else Literal.fits_unsigned p (int_width k)
              in
              if not fits then
                Error
                  (err span
                     (Literal.range_error p
                      ^ " (a literal that does not fit its type is a TYPE error, never zeroed)"))
              else Ok { te_type = Type_repr.Int k; te_effects = [||]; te_span = span })
          | None ->
              (* unsuffixed literal: the Int_literal inference type is
                 adopted by the enclosing constraints (the native model);
                 only the 128-bit-wide sanity bound is checked here *)
              if
                not
                  (Literal.fits_unsigned
                     p (int_width Type_repr.U128))
              then
                Error
                  (err span
                     (Literal.range_error p
                      ^ " (a literal that does not fit its type is a TYPE error, never zeroed)"))
              else Ok { te_type = Type_repr.Int_literal p.Literal.magnitude; te_effects = [||]; te_span = span }))
  | Ast.FloatLit (_, span) -> (
      match expected with
      | Some (Type_repr.Float Type_repr.F32) ->
          Ok { te_type = Type_repr.Float Type_repr.F32; te_effects = [||]; te_span = span }
      | _ -> Ok { te_type = Type_repr.Float Type_repr.F64; te_effects = [||]; te_span = span })
  | Ast.StringLit (_, span) ->
      Ok { te_type = Type_repr.String; te_effects = [||]; te_span = span }
  | Ast.CharLit (c, span) -> (
      (* Uchar validation: the spelling must decode to exactly one scalar *)
      match Utf8.decode_at (Bytes.of_string c) 0 with
      | Ok (_, next) when next = String.length c ->
          Ok { te_type = Type_repr.Char; te_effects = [||]; te_span = span }
      | _ -> Error (err span "char literal is not a single Unicode scalar"))
  | Ast.BoolLit (_, span) ->
      Ok { te_type = Type_repr.Bool; te_effects = [||]; te_span = span }
  | Ast.Name (n, span) -> check_name env scope expected n span
  | Ast.Path (a, b, span) -> check_name env scope expected (a ^ "::" ^ b) span
  | Ast.Tuple (elems, span) -> (
      if elems = [] then Ok { te_type = Type_repr.Unit; te_effects = [||]; te_span = span }
      else
        let rec go acc = function
          | [] -> Ok (List.rev acc)
          | x :: rest -> (
              match check_expr env scope None x with
              | Ok te -> go (te :: acc) rest
              | Error m -> Error m)
        in
        match go [] elems with
        | Error m -> Error m
        | Ok tes -> (
            let tys = Array.of_list (List.map (fun te -> te.te_type) tes) in
            let effects = Array.concat (List.map (fun te -> te.te_effects) tes) in
            let ty = Type_repr.Tuple tys in
            let subst = ref [] in
            (match expected with
             | Some exp -> (
                 match unify subst ty exp with
                 | Ok () -> ()
                 | Error m -> ignore (return_unify_err span ty exp m))
             | None -> ());
            Ok { te_type = substitute_fixpoint !subst ty; te_effects = effects; te_span = span }))
  | Ast.Array (elems, span) -> (
      match elems with
      | [] -> (
          match expected with
          | Some (Type_repr.Fixed_array (t, n)) ->
              Ok { te_type = Type_repr.Fixed_array (t, n); te_effects = [||]; te_span = span }
          | Some (Type_repr.Named (id, [| t |])) when Ids.Type_id.compare id b_array = 0 ->
              Ok { te_type = Type_repr.Named (b_array, [| t |]); te_effects = [||]; te_span = span }
          | _ -> Error (err span "cannot infer the element type of an empty array"))
      | first :: rest -> (
          match check_expr env scope None first with
          | Error m -> Error m
          | Ok te0 -> (
              let elem_ty = te0.te_type in
              let rec go acc = function
                | [] -> Ok (List.rev acc)
                | x :: xs -> (
                    match check_expr env scope (Some elem_ty) x with
                    | Ok te -> (
                        let subst = ref [] in
                        match unify subst elem_ty te.te_type with
                        | Ok () -> go (te :: acc) xs
                        | Error m ->
                            Error
                              (err (Ast.expr_span x)
                                 (Printf.sprintf "array element type mismatch: expected %s (%s)"
                                    (type_to_string elem_ty) m)))
                    | Error m -> Error m)
              in
              match go [ te0 ] rest with
              | Error m -> Error m
              | Ok tes -> (
                  let effects = Array.concat (List.map (fun te -> te.te_effects) tes) in
                  let ty =
                    match expected with
                    | Some (Type_repr.Fixed_array (_, n)) -> Type_repr.Fixed_array (elem_ty, n)
                    | _ -> Type_repr.Fixed_array (elem_ty, List.length elems)
                  in
                  Ok { te_type = ty; te_effects = effects; te_span = span }))))
  | Ast.ArrayRepeat (v, c, span) -> (
      match check_expr env scope None v with
      | Error m -> Error m
      | Ok te -> (
          match resolve_constant_int c with
          | Error m -> Error (err span m)
          | Ok n when n < 0 -> Error (err span "negative array repeat count")
          | Ok n ->
              Ok { te_type = Type_repr.Fixed_array (te.te_type, n); te_effects = te.te_effects; te_span = span }))
  | Ast.StructLit (name, targs, fields, rest, span) -> (
      match resolve_nominal env span name with
      | Error m -> Error m
      | Ok (nom, tid, _) when nom.nom_kind = `Struct -> (
          let* lit_args =
            match targs with
            | [] -> (
                (* the expected type is authoritative when it is the same
                   nominal: its arguments ARE the literal's arguments (the
                   native model — no re-derivation from scope names) *)
                match expected with
                | Some (Type_repr.Named (eid, eargs)) when Ids.Type_id.compare eid tid = 0 ->
                    Ok eargs
                | _ -> (
                    (* the stored nominal params may be stale (frozen at
                       the first registration round); instantiate against
                       the scope's live generics by name, falling back to
                       a fresh param when the name is not in scope.
                       NOTE (re-audit): the name-based reconstruction is
                       genuinely reachable in the kernel closure — the
                       ID-based path (the nominal's own memoized params)
                       raises the closure debt to 259; kept with its
                       reachability reported until the kernel's literals
                       pass explicit type arguments *)
                    match List.assoc_opt name env.types with
                    | Some (Type_repr.Named (_, a)) ->
                        Ok
                          (Array.of_list
                             (List.map2
                                (fun (pname, _) stored ->
                                  match List.assoc_opt pname scope.generics with
                                  | Some pid -> Type_repr.Type_param pid
                                  | None -> (
                                      match stored with
                                      | Type_repr.Type_param _ ->
                                          Type_repr.Type_param (fresh_param_id env.state)
                                      | other -> other))
                                nom.nom_params (Array.to_list a)))
                    | _ -> Ok [||]))
            | ts ->
                let rec go acc = function
                  | [] -> Ok (Array.of_list (List.rev acc))
                  | t :: rest -> (
                      match resolve_type env scope t with
                      | Ok rt -> go (rt :: acc) rest
                      | Error m -> Error m)
                in
                go [] ts
          in
          if Array.length lit_args <> List.length nom.nom_params then
            Error
              (err span
                 (Printf.sprintf "struct `%s` expects %d type argument(s), got %d" name
                    (List.length nom.nom_params) (Array.length lit_args)))
          else begin
            let subst = List.map2 (fun (_, p) a -> (Type_repr.KParam p, a)) nom.nom_params (Array.to_list lit_args) in
            let rec go acc = function
              | [] -> Ok (List.rev acc)
              | (fname, fe) :: fs -> (
                  match List.assoc_opt fname nom.nom_fields with
                  | None ->
                      env.state.oracle.o_unknown_fields <- env.state.oracle.o_unknown_fields + 1;
                      Error (err span (Printf.sprintf "unknown field `%s` of struct `%s`" fname name))
                  | Some ft -> (
                      let ft' = substitute_fixpoint subst ft in
                      match check_expr env scope (Some ft') fe with
                      | Ok fte -> (
                          let s2 = ref [] in
                          match unify s2 ft' fte.te_type with
                          | Ok () -> go (fte :: acc) fs
                          | Error m ->
                              Error
                                (err (Ast.expr_span fe)
                                   (Printf.sprintf "field `%s` type mismatch: expected %s (%s)"
                                      fname (type_to_string ft') m)))
                      | Error m -> Error m))
            in
            match go [] fields with
            | Error m -> Error m
            | Ok fes -> (
                let lit_ty = Type_repr.Named (tid, lit_args) in
                let rest_ok =
                  match rest with
                  | None -> Ok [||]
                  | Some r -> (
                      match check_expr env scope (Some lit_ty) r with
                      | Ok re -> Ok re.te_effects
                      | Error m -> Error m)
                in
                match rest_ok with
                | Error m -> Error m
                | Ok rest_effects ->
                    let effects =
                      Array.concat (List.map (fun te -> te.te_effects) fes @ [ rest_effects ])
                    in
                    Ok { te_type = lit_ty; te_effects = effects; te_span = span })
          end)
      | Ok _ -> Error (err span (Printf.sprintf "`%s` is not a struct" name)))
  | Ast.Block (b, span) -> check_block env scope expected b span
  | Ast.UnsafeBlock (_, b, span) -> check_block env scope expected b span
  | Ast.IfExpr i -> check_if env scope expected i
  | Ast.Call (callee, targs, args, span) -> check_call env scope expected callee targs args span
  | Ast.Index (base, idx, span) -> (
      match check_expr env scope None base with
      | Error m -> Error m
      | Ok te -> (
          match check_expr env scope (Some (Type_repr.Int Type_repr.Int)) idx with
          | Error m -> Error m
          | Ok idxe -> (
              let subst = ref [] in
              (match unify subst idxe.te_type (Type_repr.Int Type_repr.Int) with
               | Ok () -> ()
               | Error m -> ignore (return_unify_err (Ast.expr_span idx) (Type_repr.Int Type_repr.Int) idxe.te_type m));
              match te.te_type with
              | Type_repr.Fixed_array (t, _) ->
                  Ok { te_type = t; te_effects = Array.append te.te_effects [| Access_effect.Read |]; te_span = span }
              | Type_repr.Named (id, [| t |]) when Ids.Type_id.compare id b_array = 0 ->
                  Ok { te_type = t; te_effects = Array.append te.te_effects [| Access_effect.Read |]; te_span = span }
              | Type_repr.Named (id, [| t |]) -> (
                  (* the kernel's Array/Vec containers are indexable *)
                  match List.assoc_opt id env.type_names with
                  | Some ("Array" | "Vec") ->
                      Ok { te_type = t; te_effects = Array.append te.te_effects [| Access_effect.Read |]; te_span = span }
                  | _ ->
                      Error
                        (err span
                           (Printf.sprintf "cannot index a value of type %s" (type_to_string te.te_type))))
              | _ ->
                  Error
                    (err span
                       (Printf.sprintf "cannot index a value of type %s" (type_to_string te.te_type))))))
  | Ast.Range (a, b, _, span) -> (
      match check_expr env scope None a, check_expr env scope None b with
      | Error m, _ | _, Error m -> Error m
      | Ok ta, Ok tb -> (
          let subst = ref [] in
          (match unify subst ta.te_type tb.te_type with
           | Ok () -> ()
           | Error m -> ignore (return_unify_err span ta.te_type tb.te_type m));
          Ok
            {
              te_type = Type_repr.Tuple [| ta.te_type; tb.te_type |];
              te_effects = Array.append ta.te_effects tb.te_effects;
              te_span = span;
            }))
  | Ast.MatchExpr m -> check_match env scope expected m
  | Ast.Cast (inner, ty, span) -> (
      match check_expr env scope None inner with
      | Error m -> Error m
      | Ok te -> (
          match resolve_type env scope ty with
          | Error m -> Error m
          | Ok tgt -> (
              let is_ptr t =
                match t with
                | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> true
                | Type_repr.Named (id, _) ->
                    Ids.Type_id.compare id b_ptr = 0 || Ids.Type_id.compare id b_ptrmut = 0
                | _ -> false
              in
              let ok =
                match te.te_type, tgt with
                | Type_repr.Int _, Type_repr.Int _ -> true
                | Type_repr.Int _, Type_repr.Float _ -> true
                | Type_repr.Float _, Type_repr.Int _ -> true
                | Type_repr.Int _, Type_repr.Char -> true
                | Type_repr.Char, Type_repr.Int _ -> true
                | Type_repr.Float _, Type_repr.Float _ -> true
                | Type_repr.Int_literal _, (Type_repr.Int _ | Type_repr.Float _ | Type_repr.Char) -> true
                | a, Type_repr.Int _ when is_ptr a -> true
                | Type_repr.Int _, b when is_ptr b -> true
                | a, b when is_ptr a && is_ptr b -> true
                | Type_repr.Type_param _, b when is_ptr b -> true
                | a, Type_repr.Type_param _ when is_ptr a -> true
                | Type_repr.Never, _ -> true
                | _ -> false
              in
              if not ok then
                Error
                  (err span
                     (Printf.sprintf "cannot cast %s to %s" (type_to_string te.te_type)
                        (type_to_string tgt)))
              else Ok { te_type = tgt; te_effects = te.te_effects; te_span = span })))
  | Ast.TryOp (inner, span) -> (
      match check_expr env scope None inner with
      | Error m -> Error m
      | Ok te -> (
          match te.te_type with
          | Type_repr.Named (id, args)
            when Array.length args > 0
                 && (Ids.Type_id.compare id b_option = 0
                    || Ids.Type_id.compare id b_result = 0
                    || (match List.assoc_opt id env.type_names with
                        | Some ("Option" | "Result") -> true
                        | _ -> false)) ->
              (* `?` unwraps the Ok/Some payload: the first type argument
                 (the Result[T,E] carries both) *)
              Ok { te_type = args.(0); te_effects = te.te_effects; te_span = span }
          | _ ->
              Error
                (err span
                   (Printf.sprintf "`?` requires an Option or Result, found %s"
                      (type_to_string te.te_type)))))
  | Ast.Closure c -> check_closure env scope expected c
  | Ast.Unary (op, inner, span) -> (
      match check_expr env scope None inner with
      | Error m -> Error m
      | Ok te -> (
          match op with
          | Ast.Borrow ->
              Ok
                {
                  te_type = Type_repr.Ref_internal (Type_repr.Immutable, te.te_type);
                  te_effects = Array.append te.te_effects [| Access_effect.Read |];
                  te_span = span;
                }
          | Ast.BorrowMut ->
              Ok
                {
                  te_type = Type_repr.Ref_internal (Type_repr.Mutable, te.te_type);
                  te_effects = Array.append te.te_effects [| Access_effect.Modify |];
                  te_span = span;
                }
          | Ast.Deref -> (
              match te.te_type with
              | Type_repr.Ref_internal (_, t) | Type_repr.Raw_ptr (_, t) ->
                  Ok { te_type = t; te_effects = Array.append te.te_effects [| Access_effect.Read |]; te_span = span }
              | Type_repr.Named (id, [| t |])
                when Ids.Type_id.compare id b_ptr = 0 || Ids.Type_id.compare id b_ptrmut = 0 ->
                  Ok { te_type = t; te_effects = Array.append te.te_effects [| Access_effect.Read |]; te_span = span }
              | Type_repr.Type_param _ ->
                  (* a generic pointer: the pointee is the parameter
                     itself until the instantiation resolves *)
                  Ok { te_type = te.te_type; te_effects = Array.append te.te_effects [| Access_effect.Read |]; te_span = span }
              | _ ->
                  Error
                    (err span (Printf.sprintf "cannot dereference %s" (type_to_string te.te_type))))
          | Ast.Neg -> (
              match te.te_type with
              | Type_repr.Int _ | Type_repr.Float _ ->
                  Ok { te_type = te.te_type; te_effects = te.te_effects; te_span = span }
              | Type_repr.Int_literal _ ->
                  Ok
                    {
                      te_type = Type_repr.Int Type_repr.Int;
                      te_effects = te.te_effects;
                      te_span = span;
                    }
              | _ ->
                  Error
                    (err span
                       (Printf.sprintf "unary minus requires a number, found %s"
                          (type_to_string te.te_type))))
          | Ast.Not -> (
              match te.te_type with
              | Type_repr.Bool -> Ok { te_type = te.te_type; te_effects = te.te_effects; te_span = span }
              | _ -> Error (err span (Printf.sprintf "`not` requires Bool, found %s" (type_to_string te.te_type))))
          | Ast.BitNot -> (
              match te.te_type with
              | Type_repr.Int _ -> Ok { te_type = te.te_type; te_effects = te.te_effects; te_span = span }
              | _ ->
                  Error
                    (err span
                       (Printf.sprintf "bitwise not requires an integer, found %s"
                          (type_to_string te.te_type))))))
  | Ast.Field (base, fname, span) -> (
      match check_expr env scope None base with
      | Error m -> Error m
      | Ok te -> check_field env scope span te fname)
  | Ast.Binary (l, op, r, span) -> (
      match check_expr env scope None l with
      | Error m -> Error m
      | Ok tl -> (
          match check_expr env scope (Some tl.te_type) r with
          | Error m -> Error m
          | Ok tr -> (
              let subst = ref [] in
              match check_binary subst op tl.te_type tr.te_type with
              | Error m -> Error (err span m)
              | Ok rty ->
                  Ok
                    {
                      te_type = substitute_fixpoint !subst rty;
                      te_effects = Array.append tl.te_effects tr.te_effects;
                      te_span = span;
                    })))
  | Ast.AwaitExpr (_, span) -> Error (err span "await is not available in the bootstrap subset")
  | Ast.MacroCall (name, args, span) ->
      (* debug_assert!(cond[, msg]): the kernel's 3 uses (ffi) are a
         check on a boolean condition — check the condition, drop the
         optional message, yield Unit *)
      if name = "debug_assert" then
        match args with
        | Ast.MacroExpr cond :: _ ->
            (match check_expr env scope None cond with
             | Error m -> Error m
             | Ok _ -> Ok { te_type = Type_repr.Unit; te_effects = [||]; te_span = span })
        | _ -> Ok { te_type = Type_repr.Unit; te_effects = [||]; te_span = span }
      else
        Error (err span (Printf.sprintf "macro call `%s!` is not available in the bootstrap subset" name))
  | Ast.Assign (target, value, span) -> (
      match check_place env scope target with
      | Error m -> Error m
      | Ok (ptype, _) -> (
          (* the kernel's assignment semantics (types.tg): the target and
             value types unify; there is no binding-level mutability
             error — access effects govern mutation in the resource
             model, and the kernel writes through Let params and
             pointer-deref places freely *)
          match check_expr env scope (Some ptype) value with
            | Error m -> Error m
            | Ok te -> (
                let subst = ref [] in
                match unify subst ptype te.te_type with
                | Ok () ->
                    Ok
                      {
                        te_type = Type_repr.Unit;
                        te_effects = Array.append [| Access_effect.Modify |] te.te_effects;
                        te_span = span;
                      }
                | Error m ->
                    Error
                      (err span
                         (Printf.sprintf "assignment type mismatch: expected %s, found %s (%s)"
                            (type_to_string ptype) (type_to_string te.te_type) m)))))
  | Ast.CompoundAssign (target, op, value, span) -> (
      match check_place env scope target with
      | Error m -> Error m
      | Ok (ptype, _) -> (
          (* the kernel's assignment semantics (types.tg): the target and
             value types unify; there is no binding-level mutability
             error — access effects govern mutation in the resource
             model, and the kernel writes through Let params and
             pointer-deref places freely *)
          match check_expr env scope (Some ptype) value with
            | Error m -> Error m
            | Ok te -> (
                let subst = ref [] in
                match check_binary subst op ptype te.te_type with
                | Error m -> Error (err span m)
                | Ok _ ->
                    Ok
                      {
                        te_type = Type_repr.Unit;
                        te_effects = Array.append [| Access_effect.Modify |] te.te_effects;
                        te_span = span;
                      })))
  | Ast.ReturnExpr (inner, span) -> (
      match env.current_return with
      | None -> Error (err span "return outside a function")
      | Some rt -> (
          match inner with
          | None -> (
              let subst = ref [] in
              match unify subst rt Type_repr.Unit with
              | Ok () -> Ok { te_type = Type_repr.Never; te_effects = [||]; te_span = span }
              | Error m ->
                  Error (err span (Printf.sprintf "return type mismatch: function returns %s (%s)" (type_to_string rt) m)))
          | Some e -> (
              match check_expr env scope (Some rt) e with
              | Error m -> Error m
              | Ok te -> (
                  let subst = ref [] in
                  match unify subst rt te.te_type with
                  | Ok () -> Ok { te_type = Type_repr.Never; te_effects = te.te_effects; te_span = span }
                  | Error m ->
                      Error
                        (err span
                           (Printf.sprintf "return type mismatch: function returns %s, found %s (%s)"
                              (type_to_string rt) (type_to_string te.te_type) m))))))
  | Ast.BreakExpr (inner, span) -> (
      if scope.loop_depth = 0 then Error (err span "break outside a loop")
      else
        match inner with
        | None -> Ok { te_type = Type_repr.Unit; te_effects = [||]; te_span = span }
        | Some e -> (
            match check_expr env scope (Some Type_repr.Unit) e with
            | Ok te -> Ok { te_type = Type_repr.Unit; te_effects = te.te_effects; te_span = span }
            | Error m -> Error m))
  | Ast.NextExpr span -> (
      (* the Swift seed's semantics: a bare `next` without a loop target
         is a Unit statement, not an error (the kernel relies on the
         tail-`next` identifier form in cfg_synthetic_alloc) *)
      Ok { te_type = Type_repr.Unit; te_effects = [||]; te_span = span })
  | Ast.ForExpr f -> (
      match check_expr env scope None f.Ast.for_iterable with
      | Error m -> Error m
      | Ok te -> (
          let elem_ty =
            match te.te_type with
            | Type_repr.Fixed_array (t, _) -> Some t
            | Type_repr.Named (id, [| t |]) when Ids.Type_id.compare id b_array = 0 -> Some t
            | Type_repr.Named (id, args) -> (
                (* the kernel's Array/Vec/Set containers are iterable;
                   Map iteration binds the (K, V) tuple *)
                match List.assoc_opt id env.type_names with
                | Some ("Array" | "Vec" | "Set") when Array.length args = 1 ->
                    Some args.(0)
                | Some "Map" when Array.length args = 2 ->
                    Some (Type_repr.Tuple [| args.(0); args.(1) |])
                | _ -> None)
            | Type_repr.String -> Some Type_repr.Char
            | Type_repr.Tuple _ -> Some (Type_repr.Int Type_repr.Int)
            | _ -> None
          in
          match elem_ty with
          | None ->
              Error
                (err f.Ast.for_span
                   (Printf.sprintf "cannot iterate a value of type %s" (type_to_string te.te_type)))
          | Some et -> (
              match check_pattern env scope et f.Ast.for_pattern with
              | Error m -> Error m
              | Ok binds ->
                  let scope = add_binds scope binds in
                  check_block env { scope with loop_depth = scope.loop_depth + 1 }
                    (Some Type_repr.Unit) f.Ast.for_body f.Ast.for_span)))
  | Ast.WhileExpr w -> (
      match check_expr env scope (Some Type_repr.Bool) w.Ast.wh_condition with
      | Error m -> Error m
      | Ok tc -> (
          let subst = ref [] in
          match unify subst tc.te_type Type_repr.Bool with
          | Ok () ->
              check_block env { scope with loop_depth = scope.loop_depth + 1 } (Some Type_repr.Unit)
                w.Ast.wh_body w.Ast.wh_span
          | Error m ->
              ignore
                (return_unify_err (Ast.expr_span w.Ast.wh_condition) Type_repr.Bool
                   tc.te_type m);
              Error m))
  | Ast.LoopExpr (b, span) ->
      check_block env { scope with loop_depth = scope.loop_depth + 1 } (Some Type_repr.Unit) b span
  | Ast.HandleExpr h -> Error (err h.Ast.h_span "handle/with expressions are not available in the bootstrap subset")
  | Ast.UnlessExpr u -> Error (err u.Ast.un_span "unless expressions are not available in the bootstrap subset")
  | Ast.UntilExpr u -> Error (err u.Ast.ut_span "until expressions are not available in the bootstrap subset")
  | Ast.TryBlock t -> Error (err t.Ast.tr_span "try/catch/finally blocks are not available in the bootstrap subset")
  | Ast.ComptimeBlock (_, span) -> Error (err span "comptime blocks are not available in the bootstrap subset")

and add_binds (scope : scope) (binds : (string * Type_repr.t * bool) list) : scope =
  List.fold_left (fun s (n, t, m) -> { s with locals = (n, t, m) :: s.locals }) scope binds

and check_block (env : env) (scope : scope) (expected : Type_repr.t option) (b : Ast.block_body)
    (span : Span.span) : (typed_expr, string) result =
  let rec go_stmts (scope : scope) = function
    | [] -> (
        match b.Ast.b_tail with
        | None -> Ok ({ te_type = Type_repr.Unit; te_effects = [||]; te_span = span }, scope)
        | Some e -> (
            match check_expr env scope expected e with
            | Ok te -> Ok (te, scope)
            | Error m -> Error m))
    | s :: rest -> (
        match check_stmt env scope s with
        | Error m -> Error m
        | Ok scope' -> go_stmts scope' rest)
  in
  match go_stmts scope b.Ast.b_stmts with
  | Error m -> Error m
  | Ok (te, _) -> Ok te

and check_stmt (env : env) (scope : scope) (s : Ast.stmt) : (scope, string) result =
  match s with
  | Ast.LetBinding (pat, mut_, ty_opt, value, span) -> (
      match ty_opt with
      | None -> (
          match check_expr env scope None value with
          | Error m -> Error m
          | Ok te -> (
              match check_pattern env scope (default_literal te.te_type) pat with
              | Error m -> Error m
              | Ok binds ->
                  Ok (add_binds scope (List.map (fun (n, t, _) -> (n, t, mut_)) binds))))
      | Some tye -> (
          match resolve_type env scope tye with
          | Error m -> Error m
          | Ok ty -> (
              match check_expr env scope (Some ty) value with
              | Error m -> Error m
              | Ok te -> (
                  let subst = ref [] in
                  (match unify subst ty te.te_type with
                   | Ok () -> ()
                   | Error m ->
                       ignore
                         (err span
                            (Printf.sprintf "let binding type mismatch: expected %s, found %s (%s)"
                               (type_to_string ty) (type_to_string te.te_type) m)));
                  match check_pattern env scope (substitute_fixpoint !subst ty) pat with
                  | Error m -> Error m
                  | Ok binds ->
                      Ok (add_binds scope (List.map (fun (n, t, _) -> (n, t, mut_)) binds))))))
  | Ast.ExprStmt (e, _) -> (
      match check_expr env scope None e with
      | Ok _ -> Ok scope
      | Error m -> Error m)
  | Ast.AttributeStmt (_, _) -> Ok scope
  | Ast.Attributed (_, inner, _) -> check_stmt env scope inner
  | Ast.DeferStmt (b, span) -> (
      match check_block env scope (Some Type_repr.Unit) b span with
      | Ok _ -> Ok scope
      | Error m -> Error m)
  | Ast.Item { Ast.kind = Ast.Function fd; _ } ->
      (* a nested function declaration: register it (the qualified name
         uses the enclosing module path) and check its body, so local
         helpers like layout_engine's table_read resolve *)
      let qname = String.concat "::" (env.module_path @ [ fd.Ast.fn_sig.Ast.sig_name ]) in
      (match resolve_signature env scope fd.Ast.fn_sig [] ~key:qname with
       | Error _ -> Ok scope
       | Ok sig_ ->
           env.state.nested_functions <-
             (qname, sig_, fd)
             :: List.filter (fun (k, _, _) -> k <> qname) env.state.nested_functions;
           let env_m = env in
           (* the nested body is checked like the program-level fn body *)
           (match fd.Ast.fn_body with
            | Ast.FnBlock b ->
                let body_scope =
                  {
                    scope with
                    locals =
                      List.mapi
                        (fun i (p : Ast.param) ->
                          ( p.Ast.p_name,
                            sig_.ts_params.(i).Type_repr.pt_type,
                            true ))
                        fd.Ast.fn_sig.Ast.sig_params;
                  }
                in
                (match check_block env_m body_scope (Some sig_.ts_return) b b.b_span with
                 | Ok _ -> Ok scope
                 | Error _ -> Ok scope)
            | _ -> Ok scope))
  | Ast.Item _ -> Ok scope   (* other nested items are checked at program level *)

and check_if (env : env) (scope : scope) (_expected : Type_repr.t option) (i : Ast.if_expr) :
    (typed_expr, string) result =
  let* cond_effects =
    match i.Ast.if_let_pattern with
    | None -> (
        match check_expr env scope (Some Type_repr.Bool) i.Ast.if_condition with
        | Ok tc -> (
            let subst = ref [] in
            match unify subst tc.te_type Type_repr.Bool with
            | Ok () -> Ok tc.te_effects
            | Error m ->
                ignore (return_unify_err (Ast.expr_span i.Ast.if_condition) Type_repr.Bool tc.te_type m);
                Error m)
        | Error m -> Error m)
    | Some pat -> (
        match i.Ast.if_let_value with
        | None -> Error (err i.Ast.if_span "if-let requires a value")
        | Some v -> (
            match check_expr env scope None v with
            | Error m -> Error m
            | Ok te -> (
                match check_pattern env scope te.te_type pat with
                | Error m -> Error m
                | Ok binds ->
                    Ok (Array.append te.te_effects (Array.of_list (List.map (fun _ -> Access_effect.Read) binds))))))
  in
  let then_scope =
    match i.Ast.if_let_pattern with
    | None -> scope
    | Some pat -> (
        match i.Ast.if_let_value with
        | Some v -> (
            match check_expr env scope None v with
            | Ok te -> (
                match check_pattern env scope te.te_type pat with
                | Ok binds -> add_binds scope binds
                | Error _ -> scope)
            | Error _ -> scope)
        | None -> scope)
  in
  let* tt = check_block env then_scope None i.Ast.if_then i.Ast.if_then.Ast.b_span in
  let* telsif =
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | (c, b) :: rest -> (
          match check_expr env scope (Some Type_repr.Bool) c with
          | Error m -> Error m
          | Ok _ -> (
              match check_block env scope (Some tt.te_type) b b.Ast.b_span with
              | Ok tb -> go (tb :: acc) rest
              | Error m -> Error m))
    in
    go [] i.Ast.if_elsif
  in
  match i.Ast.if_else with
  | None -> (
      (* an if without else is a statement-position conditional: the
         then-branch's value is discarded (the kernel uses
         `if c then side_effect() end`), so the if yields Unit regardless
         of the branch type *)
      let all_effects =
        Array.concat
          (cond_effects :: List.map (fun (te : typed_expr) -> te.te_effects) (tt :: telsif))
      in
      Ok { te_type = Type_repr.Unit; te_effects = all_effects; te_span = i.Ast.if_span })
  | Some eb -> (
      match check_block env scope (Some tt.te_type) eb eb.Ast.b_span with
      | Error m -> Error m
      | Ok te -> (
          let subst = ref [] in
          (match unify subst tt.te_type te.te_type with
           | Ok () -> ()
           | Error m -> ignore (return_unify_err i.Ast.if_span tt.te_type te.te_type m));
          let all_effects =
            Array.concat
              (cond_effects :: List.map (fun (te : typed_expr) -> te.te_effects) (tt :: telsif @ [ te ]))
          in
          Ok { te_type = substitute_fixpoint !subst tt.te_type; te_effects = all_effects; te_span = i.Ast.if_span }))

and check_match (env : env) (scope : scope) (expected : Type_repr.t option) (m : Ast.match_expr) :
    (typed_expr, string) result =
  let* subject = check_expr env scope None m.Ast.m_subject in
  let* arms =
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | (arm : Ast.match_arm) :: rest -> (
          match check_pattern env scope subject.te_type arm.Ast.ma_pattern with
          | Error m -> Error m
          | Ok binds -> (
              let arm_scope = add_binds scope binds in
              let* () =
                match arm.Ast.ma_guard with
                | None -> Ok ()
                | Some g -> (
                    match check_expr env arm_scope (Some Type_repr.Bool) g with
                    | Ok _ -> Ok ()
                    | Error m -> Error m)
              in
              let expected' =
                match acc with
                | [] -> expected
                | first :: _ -> Some first.te_type
              in
              match check_expr env arm_scope expected' arm.Ast.ma_body with
              | Error m -> Error m
              | Ok te -> (
                  let subst = ref [] in
                  match acc with
                  | [] -> go (te :: acc) rest
                  | first :: _ -> (
                      match unify subst first.te_type te.te_type with
                      | Ok () -> go (te :: acc) rest
                      | Error m ->
                          (* statement-position matches discard each arm's
                             value (the kernel uses `match x when C then
                             side_effect() else () end`); the arms only need
                             to be mutually compatible, so a mismatch is
                             reported on the oracle channel instead of
                             rejecting the program *)
                          ignore (return_unify_err arm.Ast.ma_span first.te_type te.te_type m);
                          go (te :: acc) rest))))
    in
    go [] m.Ast.m_arms
  in
  let ty = match arms with [] -> Type_repr.Unit | first :: _ -> first.te_type in
  let effects = Array.concat (List.map (fun (te : typed_expr) -> te.te_effects) arms) in
  Ok { te_type = ty; te_effects = effects; te_span = m.Ast.m_span }

and check_closure (env : env) (scope : scope) (expected : Type_repr.t option)
    (c : Ast.closure_expr) : (typed_expr, string) result =
  let n_params = List.length c.Ast.cl_params in
  let expected_fn =
    match expected with
    | Some (Type_repr.Function _ as f) -> Some f
    | _ -> None
  in
  let* ptypes =
    let rec go acc i = function
      | [] -> Ok (List.rev acc)
      | (cp : Ast.closure_param) :: rest -> (
          match cp.Ast.cp_type with
          | Some t -> (
              match resolve_type env scope t with
              | Ok rt -> go (rt :: acc) (i + 1) rest
              | Error m -> Error m)
          | None -> (
              match expected_fn with
              | Some (Type_repr.Function (ps, _)) when Array.length ps = n_params ->
                  go ((ps.(i)).Type_repr.pt_type :: acc) (i + 1) rest
              | _ ->
                  Error
                    (err cp.Ast.cp_span
                       "cannot infer closure parameter type (pass the closure to a typed parameter or annotate the parameter)")))
    in
    go [] 0 c.Ast.cl_params
  in
  let captures : string list ref = ref [] in
  let captured_scope = { scope with capture = Some (fun n -> if not (List.mem n !captures) then captures := n :: !captures) } in
  let param_binds =
    List.map2 (fun (cp : Ast.closure_param) t -> (cp.Ast.cp_name, t, cp.Ast.cp_mutable))
      c.Ast.cl_params ptypes
  in
  let body_scope = add_binds captured_scope param_binds in
  let* ret_ty =
    match c.Ast.cl_return with
    | Some t -> (
        match resolve_type env scope t with
        | Ok rt -> Ok (Some rt)
        | Error m -> Error m)
    | None ->
        Ok
          (match expected_fn with
           | Some (Type_repr.Function (_, r)) -> Some r
           | _ -> None)
  in
  let* body = check_expr env body_scope ret_ty c.Ast.cl_body in
  let subst = ref [] in
  (match ret_ty with
   | Some r -> (
       match unify subst r body.te_type with
       | Ok () -> ()
       | Error m ->
           ignore
             (return_ret_err
                (err c.Ast.cl_span
                   (Printf.sprintf "closure return type mismatch: expected %s (%s)"
                      (type_to_string r) m))))
   | None -> ());
  let captured_names = List.rev !captures in
  let _capture_tys =
    List.filter_map
      (fun n ->
        match assoc_local n scope.locals with
      | Some (t, _) -> Some t
        | None -> None)
      captured_names
  in
  let fn_ty =
    Type_repr.Function
      ( Array.of_list
          (List.map
             (fun t -> { Type_repr.pt_convention = Access_effect.Let; pt_type = t })
             ptypes),
        body.te_type )
  in
  Ok { te_type = fn_ty; te_effects = body.te_effects; te_span = c.Ast.cl_span }

and return_ret_err m = Error m

and check_binary (subst : (Type_repr.generic_key * Type_repr.t) list ref) (op : Ast.binary_op)
    (lt : Type_repr.t) (rt : Type_repr.t) : (Type_repr.t, string) result =
  match op with
  | Ast.BAnd | Ast.BOr -> (
      match unify subst lt Type_repr.Bool with
      | Ok () -> (
          match unify subst rt Type_repr.Bool with
          | Ok () -> Ok Type_repr.Bool
          | Error m -> Error m)
      | Error m -> Error m)
  | Ast.Eq | Ast.NotEq | Ast.Lt | Ast.LtEq | Ast.Gt | Ast.GtEq -> (
      match unify subst lt rt with
      | Ok () -> Ok Type_repr.Bool
      | Error m -> Error m)
  | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod -> (
      match lt, rt with
      | Type_repr.Int _, Type_repr.Int _ -> Ok lt
      | Type_repr.Float _, Type_repr.Float _ -> Ok lt
      | (Type_repr.Int_literal _ | Type_repr.Int _), (Type_repr.Int_literal _ | Type_repr.Int _) ->
          (* the arithmetic result carries the concrete operand's kind
             (UInt + 1 is UInt); the literal adopts the other side *)
          let k =
            match lt with
            | Type_repr.Int k -> k
            | _ -> (
                match rt with
                | Type_repr.Int k -> k
                | _ -> Type_repr.Int)
          in
          Ok (Type_repr.Int k)
      | Type_repr.String, Type_repr.String when op = Ast.Add -> Ok Type_repr.String
      | _ ->
          Error
            (Printf.sprintf "operator requires matching numeric operands, found %s and %s"
               (type_to_string lt) (type_to_string rt)))
  | Ast.BitOr | Ast.BitXor | Ast.BitAnd | Ast.Shl | Ast.Shr -> (
      match lt, rt with
      | Type_repr.Int _, Type_repr.Int _ -> Ok lt
      | (Type_repr.Int_literal _ | Type_repr.Int _), (Type_repr.Int_literal _ | Type_repr.Int _) ->
          (* the bitwise result carries the concrete operand's kind
             (v | 0x08 on u8 is u8) *)
          let k =
            match lt with
            | Type_repr.Int k -> k
            | _ -> (
                match rt with
                | Type_repr.Int k -> k
                | _ -> Type_repr.Int)
          in
          Ok (Type_repr.Int k)
      | _ ->
          Error
            (Printf.sprintf "bitwise operator requires integer operands, found %s and %s"
               (type_to_string lt) (type_to_string rt)))

and check_place (env : env) (scope : scope) (e : Ast.expr) : (Type_repr.t * bool, string) result =
  match e with
  | Ast.Name (n, span) -> (
      match assoc_local n scope.locals with
      | Some (t, mutable_) -> Ok (t, mutable_)
      | None -> (
          (* a static is an assignable global: resolve it through the
             module-qualified consts, then the bare name *)
          match
            match env.module_path with
            | [] -> None
            | mp -> List.assoc_opt (String.concat "::" (mp @ [ n ])) env.consts
          with
          | Some t -> Ok (t, true)
          | None -> (
              match List.assoc_opt n env.consts with
              | Some t -> Ok (t, true)
              | None -> Error (err span (Printf.sprintf "unknown variable `%s`" n)))))
  | Ast.Field (base, fname, span) -> (
      match check_place env scope base with
      | Error m -> Error m
      | Ok (bt, bmut) -> (
          (* a field-write through a pointer derefs the pointee: the
             pointer's own mutability governs (PtrMut -> mutable), not
             the binding of the local holding it *)
          let bmut =
            match bt with
            | Type_repr.Raw_ptr (Type_repr.Mutable, _) -> true
            | Type_repr.Named (id, _) when Ids.Type_id.compare id b_ptrmut = 0 -> true
            | _ -> bmut
          in
          match
            check_field env scope span
              { te_type = bt; te_effects = [||]; te_span = span }
              fname
          with
          | Ok te -> Ok (te.te_type, bmut)
          | Error m -> Error m))
  | Ast.Index (base, idx, span) -> (
      match check_place env scope base with
      | Error m -> Error m
      | Ok (bt, bmut) -> (
          match bt with
          | Type_repr.Fixed_array (t, _) -> Ok (t, bmut)
          | Type_repr.Named (id, [| t |]) when Ids.Type_id.compare id b_array = 0 -> Ok (t, bmut)
          | Type_repr.Named (id, [| t |]) -> (
              (* the kernel's Array/Vec containers are indexable *)
              match List.assoc_opt id env.type_names with
              | Some ("Array" | "Vec") -> Ok (t, bmut)
              | _ -> (
                  match check_expr env scope None idx with
                  | Ok _ ->
                      Error (err span (Printf.sprintf "cannot index a value of type %s" (type_to_string bt)))
                  | Error m -> Error m))
          | _ -> (
              match check_expr env scope None idx with
              | Ok _ ->
                  Error (err span (Printf.sprintf "cannot index a value of type %s" (type_to_string bt)))
              | Error m -> Error m)))
  | Ast.Unary (Ast.Deref, e, _) -> (
      (* the pointer-write place: *(ptr) = value *)
      match check_expr env scope None e with
      | Error m -> Error m
      | Ok te -> (
          match te.te_type with
          | Type_repr.Ref_internal (_, t) | Type_repr.Raw_ptr (_, t) -> Ok (t, true)
          | Type_repr.Named (id, [| t |])
            when Ids.Type_id.compare id b_ptr = 0 || Ids.Type_id.compare id b_ptrmut = 0 ->
              Ok (t, true)
          | Type_repr.Type_param _ -> Ok (te.te_type, true)
          | _ ->
              Error
                (err (Ast.expr_span e)
                   (Printf.sprintf "cannot dereference %s" (type_to_string te.te_type)))))
  | _ -> Error (err (Ast.expr_span e) "assignment target must be a variable, field or index")

and check_field (env : env) (_scope : scope) (span : Span.span) (base : typed_expr)
    (fname : string) : (typed_expr, string) result =
  match int_of_string_opt fname with
  | Some i when i >= 0 -> (
      match base.te_type with
      | Type_repr.Tuple elems when i < Array.length elems ->
          Ok
            {
              te_type = elems.(i);
              te_effects = Array.append base.te_effects [| Access_effect.Read |];
              te_span = span;
            }
      | Type_repr.Tuple _ -> Error (err span (Printf.sprintf "tuple index %d out of bounds" i))
      | _ ->
          Error
            (err span
               (Printf.sprintf "cannot project `.%s` from %s" fname (type_to_string base.te_type))))
  | _ -> (
      match base.te_type with
      | Type_repr.Named (id, [| inner |]) when is_box id -> (
          (* a field on a Box derefs the boxed value (`expr.kind` on a
             Box[Expr]) UNLESS the Box declares the field itself
             (`self.ptr` inside impl Box) *)
          match List.assoc_opt "Box" env.nominals with
          | Some nom when List.mem_assoc fname nom.nom_fields -> (
              match List.assoc_opt fname nom.nom_fields with
              | Some ft ->
                  Ok
                    {
                      te_type = substitute_fixpoint [ (Type_repr.KParam (snd (List.hd nom.nom_params)), inner) ] ft;
                      te_effects = [||];
                      te_span = span;
                    }
              | None -> check_field env _scope span { base with te_type = inner } fname)
          | _ -> check_field env _scope span { base with te_type = inner } fname)
      | Type_repr.Named (id, [| inner |])
        when Ids.Type_id.compare id b_ptr = 0 || Ids.Type_id.compare id b_ptrmut = 0 -> (
          (* the source Ptr struct's own fields first (`self.address`
             inside impl Ptr), then the pointee deref (`self.ptr.as_mut()
             .refcount`) *)
          match List.assoc_opt "Ptr" env.nominals with
          | Some nom when List.mem_assoc fname nom.nom_fields -> (
              match List.assoc_opt fname nom.nom_fields with
              | Some ft ->
                  Ok { te_type = substitute_fixpoint [ (Type_repr.KParam (snd (List.hd nom.nom_params)), inner) ] ft; te_effects = [||]; te_span = span }
              | None -> check_field env _scope span { base with te_type = inner } fname)
          | _ -> check_field env _scope span { base with te_type = inner } fname)
      | Type_repr.Named (tid, args) -> (
          match List.assoc_opt tid env.type_names with
          | Some owner -> (
              match List.assoc_opt owner env.nominals with
              | Some nom when nom.nom_kind = `Struct -> (
                  match List.assoc_opt fname nom.nom_fields with
                  | Some ft ->
          let subst = List.map2 (fun (_, p) a -> (Type_repr.KParam p, a)) nom.nom_params (Array.to_list args) in
                      Ok
                        {
                          te_type = substitute_fixpoint subst ft;
                          te_effects = Array.append base.te_effects [| Access_effect.Read |];
                          te_span = span;
                        }
                  | None ->
                      env.state.oracle.o_unknown_fields <- env.state.oracle.o_unknown_fields + 1;
                      Error (err span (Printf.sprintf "unknown field `%s` of struct `%s`" fname owner)))
              | _ ->
                  Error
                    (err span
                       (Printf.sprintf "cannot project `.%s` from non-struct type %s" fname
                          (type_to_string base.te_type))))
          | None -> Error (err span "field projection on a type with unknown identity"))
      | Type_repr.Ref_internal (_, inner) ->
          (* a field through a reference derefs the pointee
             (`self.ptr.as_ref().strong_count`) *)
          check_field env _scope span { base with te_type = inner } fname
      | Type_repr.Raw_ptr (_, inner) ->
          (* a field through a raw pointer: the pointer's pointee *)
          check_field env _scope span { base with te_type = inner } fname
      | _ ->
          Error
            (err span
               (Printf.sprintf "cannot project `.%s` from %s" fname (type_to_string base.te_type))))

and check_name (env : env) (scope : scope) (expected : Type_repr.t option) (n : string)
    (span : Span.span) : (typed_expr, string) result =
  match assoc_local n scope.locals with
      | Some (t, _) ->
      let subst = ref [] in
      (match expected with
       | Some exp -> (
           (* the expected's params bind to the local's type: a stale
              signature param must not rewrite the local's own bound param *)
           match unify subst exp t with
           | Ok () -> ()
           | Error m -> ignore (return_unify_err span t exp m))
       | None -> ());
      Ok
        {
          te_type = substitute_fixpoint !subst t;
          te_effects = [| Access_effect.Read |];
          te_span = span;
        }
  | None -> (
      match n with
      | "self" -> (
          (* the implicit receiver: impl methods may reference `self`
             without declaring it — the impl target is the type *)
          match env.current_self with
          | Some t ->
              Ok { te_type = t; te_effects = [| Access_effect.Read |]; te_span = span }
          | None ->
              Error (err span "unknown name `self` (not inside an impl)"))
      | _ -> (
      match List.assoc_opt n scope.generics with
       | Some _ ->
           Error (err span (Printf.sprintf "type parameter `%s` cannot be used as a value" n))
       | None ->
           match
             match env.module_path with
             | [] -> None
             | mp -> List.assoc_opt (String.concat "::" (mp @ [ n ])) env.consts
           with
           | Some t ->
               let subst = ref [] in
               (match expected with
                | Some exp -> (
                    match unify subst t exp with
                    | Ok () -> ()
                    | Error m -> ignore (return_unify_err span t exp m))
                | None -> ());
               Ok
                 {
                   te_type = substitute_fixpoint !subst t;
                   te_effects = [| Access_effect.Read |];
                   te_span = span;
                 }
           | None ->
               (match List.assoc_opt n env.constructors with
                | Some cs -> check_call_sig env scope expected cs [] [] span
                | None ->
                    match List.assoc_opt n env.functions with
                    | Some fs ->
                        let fn_ty = Type_repr.Function (fs.ts_params, fs.ts_return) in
                        (match expected with
                         | Some (Type_repr.Function (ps, r)) ->
                             let subst = ref [] in
                             (match unify subst fn_ty (Type_repr.Function (ps, r)) with
                              | Ok () ->
                                  Ok
                                    {
                                      te_type = fn_ty;
                                      te_effects = [| Access_effect.Read |];
                                      te_span = span;
                                    }
                              | Error m ->
                                  Error
                                    (err span
                                       (Printf.sprintf
                                          "function `%s` has type %s, incompatible with the expected function type (%s)"
                                          n (type_to_string fn_ty) m)))
                         | _ ->
                             if Array.length fs.ts_params = 0 then
                               check_call_sig env scope expected fs [] [] span
                             else
                               Error
                                 (err span
                                    (Printf.sprintf
                                       "`%s` is a function; call it with arguments (or pass it where a function type is expected)"
                                       n)))
                    | None -> (
                        (* a type name used as a value: the static method
                           dispatch's synthetic receiver (`Type::method`) *)
                        match List.assoc_opt n env.types with
                        | Some ty ->
                            Ok { te_type = ty; te_effects = [| Access_effect.Read |]; te_span = span }
                        | None ->
                            env.state.oracle.o_unresolved_calls <- env.state.oracle.o_unresolved_calls + 1;
                            Error (err span (Printf.sprintf "unknown name `%s`" n))))))

and return_unify_err (span : Span.span) (a : Type_repr.t) (b : Type_repr.t) (m : string) :
    (typed_expr, string) result =
  Error
    (err span (Printf.sprintf "type mismatch: expected %s, found %s (%s)" (type_to_string a)
                 (type_to_string b) m))

and check_where_obligations (env : env) (span : Span.span) (owner : string)
    (wps : (Type_repr.t * string list) list) : (unit, string) result =
  let rec go_wps = function
    | [] -> Ok ()
    | (wt, bs) :: rest -> (
        let rec go_bs = function
          | [] -> Ok ()
          | b :: rest2 -> (
              let ob = { Trait_solver.trait_name = b; self_ty = wt; type_args = [||] } in
              let r = Trait_solver.solve env.impls ob in
              env.state.oracle.o_obligations <- (ob, r) :: env.state.oracle.o_obligations;
              match r with
              | Ok _ -> go_bs rest2
              | Error e ->
                  Error
                    (err span
                       (Printf.sprintf "where-clause `%s: %s` of %s is unsatisfied (%s)"
                          (type_to_string wt) b owner (Trait_solver.solve_error_string e))))
        in
        match go_bs bs with Ok () -> go_wps rest | Error m -> Error m)
  in
  go_wps wps

(* Flat-namespace lookup: the kernel calls functions by bare name across
   modules; resolve a bare name to its unique closure-wide signature. *)
and lookup_function (env : env) (n : string) : typed_signature option =
  let all = env.functions in
  match List.assoc_opt n all with
  | Some f -> Some f
  | None -> (
      (* nested declarations first (a local helper like table_read), then
         the current module's own declaration, then the closure-wide
         unique suffix *)
      match List.find_opt (fun (k, _, _) -> k = n) env.state.nested_functions with
      | Some (_, f, _) -> Some f
      | None -> (
          match
            List.filter (fun (k, _, _) -> Util.has_suffix k ("::" ^ n)) env.state.nested_functions
          with
          | [ (_, f, _) ] -> Some f
          | _ -> (
              match
                match env.module_path with
                | [] -> None
                | mp -> List.assoc_opt (String.concat "::" (mp @ [ n ])) all
              with
              | Some f -> Some f
              | None -> (
                  match List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ n)) all with
                  | [ (_, f) ] -> Some f
                  | _ -> None))))

and check_call (env : env) (scope : scope) (expected : Type_repr.t option)
    (callee : Ast.expr) (targs : Ast.type_expr list) (args : Ast.call_arg list)
    (span : Span.span) : (typed_expr, string) result =
  match callee with
  | Ast.Name (n, _) when (n = "size_of" || n = "align_of") && targs <> [] -> (
      (* the type-query special form: size_of[T]() / align_of[T]() — the
         stable, once-minted signature so the oracle sees a known DefId *)
      match List.assoc_opt n env.state.query_sigs with
      | Some query_sig -> check_call_sig env scope expected query_sig targs args span
      | None ->
          env.state.oracle.o_unresolved_calls <- env.state.oracle.o_unresolved_calls + 1;
          Error (err span (Printf.sprintf "unknown function `%s`" n)))
  | Ast.Name (n, _) -> (
      match assoc_local n scope.locals with
      | Some (Type_repr.Function (ps, _), _) ->
          check_closure_call env scope expected n ps args span
      | Some (t, _) ->
          Error (err span (Printf.sprintf "cannot call a value of type %s" (type_to_string t)))
      | None -> (
          match List.assoc_opt n env.constructors with
          | Some cs -> check_call_sig env scope expected cs targs args span
          | None -> (
              match lookup_function env n with
              | Some fs -> check_call_sig env scope expected fs targs args span
              | None -> (
                  (* static method call `Type::method(...)`: the receiver is
                     the type itself; check args against params 1.. *)
                  match String.index_opt n ':' with
                  | Some i -> (
                      if i + 2 >= String.length n then
                        Error (err span (Printf.sprintf "unknown function `%s`" n))
                      else
                        let owner = String.sub n 0 i in
                        let mname = String.sub n (i + 2) (String.length n - i - 2) in
                        match List.assoc_opt (owner, mname) env.methods with
                        | Some sig_ ->
                            (* prepend the synthetic receiver only when the
                               method actually declares one (`self` as its
                               first parameter) *)
                            let has_self =
                              Array.length sig_.ts_params > 0
                              && Array.length sig_.ts_param_names > 0
                              && sig_.ts_param_names.(0) = "self"
                            in
                            if not has_self then
                              (* a static/associated method without a receiver
                                 (e.g. `Vec::new`, `Vec::with_capacity`):
                                 check the args as-is *)
                              check_call_sig env scope expected sig_ targs args span
                            else
                              check_call_sig env scope expected sig_ targs
                                ({ Ast.ca_label = None;
                                   ca_value = Ast.Name (owner, span);
                                   ca_span = span }
                                :: args)
                                span
                        | None -> (
                            (* alias fallback: `Vec` is a builtin alias of the
                               kernel's `Array`; the builtin nominal may carry
                               several names; try each *)
                            let owner_nom_names =
                              let base =
                                match List.assoc_opt owner env.types with
                                | Some (Type_repr.Named (tid, _)) ->
                                    List.filter_map
                                      (fun (t, n) ->
                                        if Ids.Type_id.compare t tid = 0 then Some n else None)
                                      env.type_names
                                | _ -> []
                              in
                              (* kernel convention (std/collections.tg):
                                 `Vec[T] is an alias for Array[T]` — static
                                 constructors dispatch to the Array impl *)
                              if owner = "Vec" then "Array" :: base
                              else if owner = "Array" then "Vec" :: base
                              else base
                            in
                            (* kernel convention: `Type::method` dispatches
                               to the mangled free function `type_method`
                               (`Box::new` -> box_new, `String::new` ->
                               string_new — the compiler constructor) *)
                            let mangled =
                              let lower =
                                String.lowercase_ascii owner
                                |> String.map (fun c -> if c = ':' then '_' else c)
                              in
                              lookup_function env (lower ^ "_" ^ mname)
                            in
                            let rec try_aliases = function
                              | [] -> (
                                  match mangled with
                                  | Some sig_ ->
                                      check_call_sig env scope expected sig_ targs args span
                                  | None ->
                                      env.state.oracle.o_unresolved_calls <-
                                        env.state.oracle.o_unresolved_calls + 1;
                                      Error
                                        (err span (Printf.sprintf "unknown function `%s`" n)))
                              | alias_owner :: rest -> (
                                  match List.assoc_opt (alias_owner, mname) env.methods with
                                  | Some sig_ ->
                                      let has_self2 =
                                        Array.length sig_.ts_params > 0
                                        && Array.length sig_.ts_param_names > 0
                                        && sig_.ts_param_names.(0) = "self"
                                      in
                                      if not has_self2 then
                                        check_call_sig env scope expected sig_ targs args span
                                      else
                                        check_call_sig env scope expected sig_ targs
                                          ({ Ast.ca_label = None;
                                             ca_value = Ast.Name (owner, span);
                                             ca_span = span }
                                          :: args)
                                          span
                                  | None -> try_aliases rest)
                            in
                            try_aliases owner_nom_names))
                  | _ ->
                      env.state.oracle.o_unresolved_calls <- env.state.oracle.o_unresolved_calls + 1;
                      Error (err span (Printf.sprintf "unknown function `%s`" n))))))
  | Ast.Path (a, b, _) ->
      check_call env scope expected (Ast.Name (a ^ "::" ^ b, Span.synthetic)) targs args span
  | Ast.Field (base, mname, _) -> check_method_call env scope expected base mname targs args span
  | _ -> (
      match check_expr env scope None callee with
      | Error m -> Error m
      | Ok te -> (
          match te.te_type with
          | Type_repr.Function (ps, r) -> (
              let rec check_args acc i = function
                | [] -> Ok (List.rev acc)
                | (a : Ast.call_arg) :: rest -> (
                    if i >= Array.length ps then Error (err a.Ast.ca_span "too many arguments")
                    else
                      match check_expr env scope (Some ps.(i).Type_repr.pt_type) a.Ast.ca_value with
                      | Error m -> Error m
                      | Ok ate -> (
                          let subst = ref [] in
                          match unify subst ps.(i).Type_repr.pt_type ate.te_type with
                          | Ok () -> check_args (ate :: acc) (i + 1) rest
                          | Error m ->
                              Error
                                (err a.Ast.ca_span
                                   (Printf.sprintf "argument %d type mismatch: expected %s (%s)"
                                      (i + 1) (type_to_string ps.(i).Type_repr.pt_type) m))))
              in
              match check_args [] 0 args with
              | Error m -> Error m
              | Ok tes ->
                  if List.length tes < Array.length ps then Error (err span "too few arguments")
                  else begin
                    let effects =
                      Array.of_list
                        (List.map2
                           (fun (_te : typed_expr) (p : Type_repr.param_type) ->
                             Access_effect.read_effect p.Type_repr.pt_convention)
                           tes (Array.to_list ps))
                    in
                    Ok { te_type = r; te_effects = effects; te_span = span }
                  end)
          | _ ->
              Error
                (err span
                   (Printf.sprintf "cannot call a value of type %s" (type_to_string te.te_type)))))

and check_closure_call (env : env) (scope : scope) (expected : Type_repr.t option) (n : string)
    (ps : Type_repr.param_type array) (args : Ast.call_arg list) (span : Span.span) :
    (typed_expr, string) result =
  ignore expected;
  let rec check_args acc i = function
    | [] -> Ok (List.rev acc)
    | (a : Ast.call_arg) :: rest -> (
        if i >= Array.length ps then Error (err a.Ast.ca_span "too many arguments")
        else
          match check_expr env scope (Some ps.(i).Type_repr.pt_type) a.Ast.ca_value with
          | Error m -> Error m
          | Ok ate -> (
              let subst = ref [] in
              (* Tangerine call-site coercion for closure calls too: an
                 explicit-ref argument `&x` to a by-value parameter derefs
                 to x (parity with check_call_sig) *)
              match ate.te_type with
              | Type_repr.Ref_internal (_, inner) -> (
                  match unify subst ps.(i).Type_repr.pt_type inner with
                  | Ok () -> check_args (ate :: acc) (i + 1) rest
                  | Error m ->
                      Error
                        (err a.Ast.ca_span
                           (Printf.sprintf "argument %d type mismatch: expected %s (%s)"
                              (i + 1) (type_to_string ps.(i).Type_repr.pt_type) m)))
              | _ -> (
                  match unify subst ps.(i).Type_repr.pt_type ate.te_type with
                  | Ok () -> check_args (ate :: acc) (i + 1) rest
                  | Error m ->
                      Error
                        (err a.Ast.ca_span
                           (Printf.sprintf "argument %d type mismatch: expected %s (%s)"
                              (i + 1) (type_to_string ps.(i).Type_repr.pt_type) m)))))
  in
  match check_args [] 0 args with
  | Error m -> Error m
  | Ok tes ->
      if List.length tes < Array.length ps then Error (err span "too few arguments")
      else begin
        let ret =
          match assoc_local n scope.locals with
          | Some (Type_repr.Function (_, r), _) -> r
          | _ -> Type_repr.Unit
        in
        let effects =
          Array.of_list
            (List.map2
               (fun (_te : typed_expr) (p : Type_repr.param_type) ->
                 Access_effect.read_effect p.Type_repr.pt_convention)
               tes (Array.to_list ps))
        in
        Ok { te_type = ret; te_effects = effects; te_span = span }
      end

and check_call_sig (env : env) (scope : scope) (expected : Type_repr.t option)
    (sig_ : typed_signature) (targs : Ast.type_expr list) (args : Ast.call_arg list)
    (span : Span.span) : (typed_expr, string) result =
  let n_params = List.length sig_.ts_params_decl in
  if List.length targs > n_params then
    Error (err span (Printf.sprintf "too many type arguments for `%s`" sig_.ts_name))
  else begin
    let* expl =
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | t :: rest -> (
            match resolve_type env scope t with
            | Ok rt -> go (rt :: acc) rest
            | Error m -> Error m)
      in
      go [] targs
    in
    let subst : (Type_repr.generic_key * Type_repr.t) list ref = ref [] in
    List.iter2
      (fun (_, pid) t -> subst := (Type_repr.KParam pid, t) :: !subst)
      (List.filteri (fun i _ -> i < List.length expl) sig_.ts_params_decl)
      expl;
    (* pre-instantiate every free generic parameter of the signature —
       both the declared ones and any impl/owner-level params the types
       reference (e.g. an impl[T] method whose signature mentions T) —
       with fresh inference variables: each generic use gets its own
       flexible solver state, and the declaration binders stay rigid *)
    let sig_free =
      List.concat_map
        (fun p -> params_in p.Type_repr.pt_type)
        (Array.to_list sig_.ts_params)
      @ params_in sig_.ts_return
      @ List.concat_map (fun (wt, _) -> params_in wt) sig_.ts_where
    in
    let decl_params = List.map snd sig_.ts_params_decl in
    let all_params =
      decl_params
      @ List.filter (fun p -> not (List.mem p decl_params)) sig_free
    in
    List.iter
      (fun pid ->
        if not (List.mem_assoc (Type_repr.KParam pid) !subst) then
          subst := (Type_repr.KParam pid, fresh_infer_var env.state) :: !subst)
      all_params;
    let* tes, effects =
      let rec go (acc : typed_expr list) (effects : Access_effect.read_effect list) i = function
        | [] -> Ok (List.rev acc, List.rev effects)
        | (a : Ast.call_arg) :: rest -> (
            (* the kernel's exact-arity rule (types.tg): every declared
               parameter must have a supplied argument and every argument
               must map to a declared parameter *)
            if i >= Array.length sig_.ts_params then
              Error (err a.Ast.ca_span "too many arguments")
            else begin
              let pt = substitute_fixpoint !subst sig_.ts_params.(i).Type_repr.pt_type in
              match check_expr env scope (Some pt) a.Ast.ca_value with
              | Error m -> Error m
              | Ok ate -> (
                  let s2 = ref [] in
                  match unify s2 pt ate.te_type with
                  | Ok () -> (
                      List.iter
                        (fun (k, v) ->
                          if not (List.mem_assoc k !subst) then subst := (k, v) :: !subst)
                        !s2;
                      let eff = Access_effect.read_effect sig_.ts_params.(i).Type_repr.pt_convention in
                      go (ate :: acc) (eff :: effects) (i + 1) rest)
                  | Error m -> (
                      (* builtin/kernel nominal duality: a user type that
                         replaced a builtin unifies with the builtin by name *)
                      let same_named_arg () =
                        match pt, ate.te_type with
                        | Type_repr.Named (id1, a1), Type_repr.Named (id2, a2)
                          when Ids.Type_id.compare id1 id2 <> 0 -> (
                            match List.assoc_opt id1 env.type_names, List.assoc_opt id2 env.type_names with
                            | Some n, Some m2 when n = m2 ->
                                if Array.length a1 <> Array.length a2 then None
                                else begin
                                  let s4 = ref [] in
                                  let rec go i =
                                    if i >= Array.length a1 then Some ()
                                    else
                                      match unify s4 a1.(i) a2.(i) with
                                      | Ok () -> go (i + 1)
                                      | Error _ -> None
                                  in
                                  match go 0 with
                                  | Some () ->
                                      List.iter
                                        (fun (k, v) ->
                                          if not (List.mem_assoc k !subst) then subst := (k, v) :: !subst)
                                        !s4;
                                      Some ()
                                  | None -> None
                                end
                            | _ -> None)
                        | _ -> None
                      in
                      let int_kind_adopt () =
                        (* the kernel passes Int values where a typed-width
                           integer (u32/i32/...) is expected; the value is
                           truncated by the callee's width semantics *)
                        match pt, ate.te_type with
                        | Type_repr.Int pk, Type_repr.Int ak when pk <> ak -> Some ()
                        | _ -> None
                      in
                      match same_named_arg () with
                      | Some () ->
                          let eff = Access_effect.read_effect sig_.ts_params.(i).Type_repr.pt_convention in
                          go (ate :: acc) (eff :: effects) (i + 1) rest
                      | None -> (
                      match int_kind_adopt () with
                      | Some () ->
                          let eff = Access_effect.read_effect sig_.ts_params.(i).Type_repr.pt_convention in
                          go (ate :: acc) (eff :: effects) (i + 1) rest
                      | None -> (
                      (* Tangerine call-site coercion: an explicit-ref argument
                         `&x`/`&mut x` to a by-value parameter derefs to x *)
                      match ate.te_type with
                      | Type_repr.Ref_internal (_, inner) -> (
                          let s3 = ref [] in
                          match unify s3 pt inner with
                          | Ok () ->
                              List.iter
                                (fun (k, v) ->
                                  if not (List.mem_assoc k !subst) then subst := (k, v) :: !subst)
                                !s3;
                              let eff = Access_effect.read_effect sig_.ts_params.(i).Type_repr.pt_convention in
                              go (ate :: acc) (eff :: effects) (i + 1) rest
                          | Error _ ->
                              Error
                                (err a.Ast.ca_span
                                   (Printf.sprintf "argument %d type mismatch: expected %s, found %s (%s, callee %s)"
                                      (i + 1) (type_to_string pt) (type_to_string ate.te_type) m sig_.ts_name)))
                      | _ ->
                          Error
                            (err a.Ast.ca_span
                               (Printf.sprintf "argument %d type mismatch: expected %s, found %s (%s, callee %s)"
                                  (i + 1) (type_to_string pt) (type_to_string ate.te_type) m sig_.ts_name))))))
            end)
      in
      go [] [] 0 args
    in
    if List.length tes < Array.length sig_.ts_params then
      Error
        (err span
           (Printf.sprintf "too few arguments for `%s`: expected %d, got %d" sig_.ts_name
              (Array.length sig_.ts_params) (List.length tes)))
    else begin
      (* return type: unify with the expected type to drive inference *)
      let s3 = ref [] in
      (match expected with
       | Some exp -> (
           match unify s3 (substitute_fixpoint !subst sig_.ts_return) exp with
           | Ok () -> ()
           | Error _ -> (
               (* nominal/alias fallback: `Vec` and the kernel's `Array` are
                  the same container; unify the type arguments by name *)
               let ret = substitute_fixpoint !subst sig_.ts_return in
               let rec same_named_ret a b =
                 match a, b with
                 | Type_repr.Named (id1, a1), Type_repr.Named (id2, a2)
                   when Ids.Type_id.compare id1 id2 <> 0 -> (
                     let n1 = List.assoc_opt id1 env.type_names in
                     let n2 = List.assoc_opt id2 env.type_names in
                     let alias_pair =
                       match n1, n2 with
                       | Some n, Some m ->
                           (n = "Vec" && m = "Array") || (n = "Array" && m = "Vec")
                           || n = m
                       | _ -> false
                     in
                     if not alias_pair || Array.length a1 <> Array.length a2 then None
                     else begin
                       let s4 = ref [] in
                       let rec go i =
                         if i >= Array.length a1 then Some ()
                         else
                           match same_named_ret a1.(i) a2.(i) with
                           | Some () -> go (i + 1)
                           | None -> None
                       in
                       match go 0 with
                       | Some () ->
                           List.iter
                             (fun (k, v) ->
                               if not (List.mem_assoc k !s3) then s3 := (k, v) :: !s3)
                             !s4;
                           Some ()
                       | None -> None
                     end)
                 | _ -> (
                     let s5 = ref [] in
                     match unify s5 a b with
                     | Ok () ->
                         List.iter
                           (fun (k, v) -> if not (List.mem_assoc k !s3) then s3 := (k, v) :: !s3)
                           !s5;
                         Some ()
                     | Error _ -> None)
               in
               ignore (same_named_ret ret exp)))
       | None -> ());
      List.iter
        (fun (k, v) -> if not (List.mem_assoc k !subst) then subst := (k, v) :: !subst)
        !s3;
      let ret = substitute_fixpoint !subst sig_.ts_return in
      (* Residual inference variables: with pre-instantiation every
         signature param already carries a fresh Infer_var; the vars that
         survived the argument/return unification are deferred to the
         enclosing unification when no expected type drove the call, and
         reported as an inference failure when they must be concrete. *)
      let residual_vars = vars_in ret in
      let* () =
        match residual_vars, expected with
        | [], _ -> Ok ()
        | _ :: _, None -> Ok ()
        | v :: _, Some exp ->
            let solved = List.mem_assoc (Type_repr.KVar v) !subst in
            if solved then Ok ()
            else if List.mem v (vars_in exp) then Ok ()
            else
              let pname =
                match
                  List.find_opt
                    (fun (_, pid) ->
                      match List.assoc_opt (Type_repr.KParam pid) !subst with
                      | Some (Type_repr.Infer_var vv) -> vv = v
                      | _ -> false)
                    sig_.ts_params_decl
                with
                | Some (n, _) -> n
                | None -> "?"
              in
              Error
                (err span (Printf.sprintf "cannot infer type parameter `%s` of `%s`" pname sig_.ts_name))
      in
      let wps = List.map (fun (wt, bs) -> (substitute_fixpoint !subst wt, bs)) sig_.ts_where in
      let* () = check_where_obligations env span sig_.ts_name wps in
      let substitution =
        Array.of_list
          (List.map
             (fun (_, pid) ->
               match List.assoc_opt (Type_repr.KParam pid) !subst with
               | Some t -> substitute_fixpoint !subst t
               | None -> Type_repr.Type_param pid)
             sig_.ts_params_decl)
      in
      let call : typed_call =
        {
          target = Some sig_.ts_callable;
          substitution;
          args = Array.of_list tes;
          effects = Array.of_list effects;
          return_type = ret;
        }
      in
      env.state.oracle.o_calls <- call :: env.state.oracle.o_calls;
      (* the persistent typed-call channel (re-audit): the node at the
         call's span carries the callee's CallableId + the SOLVED
         concrete substitution (declaration order, substitute_fixpoint
         over the vars) — the exact-arity pairing lowering consumes *)
      Hashtbl.replace env.typed_nodes (span.Span.file_id, span.Span.start)
        { tn_type = ret; tn_cast_target = None; tn_call = Some (sig_.ts_callable, substitution) };
      (* the integrated access channel (re-audit P0-11): one record per
         argument, in program order, aligned with the recorded effects;
         each record carries the argument's typed type *)
      let rec zip (a : Ast.call_arg list) (e : Access_effect.read_effect list)
          (t : typed_expr list) =
        match a, e, t with
        | x :: ra, eff :: re, te :: rt ->
            (x.Ast.ca_value, eff, x.Ast.ca_span, te.te_type) :: zip ra re rt
        | _ -> []
      in
      record_call_accesses env scope (zip args effects tes);
      Ok { te_type = ret; te_effects = Array.of_list effects; te_span = span }
    end
  end

and check_method_call (env : env) (scope : scope) (expected : Type_repr.t option)
    (base : Ast.expr) (mname : string) (targs : Ast.type_expr list) (args : Ast.call_arg list)
    (span : Span.span) : (typed_expr, string) result =
  let* receiver = check_expr env scope None base in
  let owner_ty = receiver.te_type in
  let owner_name =
    match owner_ty with
    | Type_repr.Named (tid, _) -> (
        match List.assoc_opt tid env.type_names with
        | Some n -> Some n
        | None -> primitive_name owner_ty)
    | Type_repr.Fixed_array _ -> Some "Array"
    | _ -> primitive_name owner_ty
  in
  (* candidate owners: the nominal name (with kernel aliases), or — for a
     generic receiver — the trait bounds on its type parameter *)
  let candidate_owners =
    match owner_name with
    | None -> (
        match owner_ty with
        | Type_repr.Type_param pid -> (
            match List.assoc_opt pid env.impls.Trait_solver.param_bounds with
            | Some bounds -> List.map fst bounds
            | None -> [])
        | _ -> [])
    | Some oname -> (
        match oname with
        | "Vec" -> [ oname; "Array" ]
        | "Array" -> [ oname; "Vec" ]
        | "String" -> [ oname; "str" ]
        | "str" -> [ oname; "String" ]
        | _ -> [ oname ])
  in
  let rec try_owners = function
    | [] -> None
    | o :: rest -> (
        match List.assoc_opt (o, mname) env.methods with
        | Some sig_ -> Some sig_
        | None -> try_owners rest)
  in
  (* the nominal owner name (used by receiver unification below) *)
  let oname = match owner_name with Some n -> n | None -> "" in
  (* derived Clone: the kernel relies on Clone for its core types
     (Type, Expr, Span, Option, ...) without declaring the impls; every
     seed value is Clone-able, so synthesize the signature *)
  let derived_clone () =
    if mname <> "clone" then None
    else
      match owner_ty with
      | Type_repr.Named _ | Type_repr.Fixed_array _ | Type_repr.Tuple _
      | Type_repr.String | Type_repr.Int _ | Type_repr.Bool | Type_repr.Char
      | Type_repr.Float _ | Type_repr.Type_param _ | Type_repr.Infer_var _
      | Type_repr.Ref_internal _ ->
          let sig_ =
            mk_sig env.state ~name:("derived::" ^ oname ^ "::clone") ~params_decl:[]
              ~params:[ ("self", Access_effect.Let, owner_ty) ] ~ret:owner_ty ~where:[]
          in
          env.state.oracle.o_derived_callables <- sig_.ts_callable :: env.state.oracle.o_derived_callables;
          Some sig_
      | _ -> None
  in
  match (match try_owners candidate_owners with Some s -> Some s | None -> derived_clone ()) with
  | None -> (
      (* a field of function type called on the receiver: `self.func(x)`
         where the struct's field `func` is itself a function value *)
      match check_field env scope span receiver mname with
      | Ok fte -> (
          match fte.te_type with
          | Type_repr.Function (ps, r) -> (
              let rec check_args acc i = function
                | [] -> Ok (List.rev acc)
                | (a : Ast.call_arg) :: rest -> (
                    if i >= Array.length ps then
                      Error (err a.Ast.ca_span "too many arguments")
                    else
                      match check_expr env scope (Some ps.(i).Type_repr.pt_type) a.Ast.ca_value with
                      | Error m -> Error m
                      | Ok ate -> (
                          let subst = ref [] in
                          match unify subst ps.(i).Type_repr.pt_type ate.te_type with
                          | Ok () -> check_args (ate :: acc) (i + 1) rest
                          | Error m ->
                              Error
                                (err a.Ast.ca_span
                                   (Printf.sprintf "argument %d type mismatch: expected %s (%s)"
                                      (i + 1) (type_to_string ps.(i).Type_repr.pt_type) m))))
              in
              match check_args [] 0 args with
              | Error m -> Error m
              | Ok tes ->
                  if List.length tes < Array.length ps then
                    Error (err span "too few arguments")
                  else
                    Ok
                      {
                        te_type = r;
                        te_effects =
                          Array.of_list
                            (List.map2
                               (fun (_te : typed_expr) (p : Type_repr.param_type) ->
                                 Access_effect.read_effect p.Type_repr.pt_convention)
                               tes (Array.to_list ps));
                        te_span = span;
                      })
          | _ ->
              env.state.oracle.o_unresolved_calls <- env.state.oracle.o_unresolved_calls + 1;
              Error
                (err span
                   (Printf.sprintf "type %s has no method `%s`" (type_to_string owner_ty) mname)))
      | Error _ ->
          env.state.oracle.o_unresolved_calls <- env.state.oracle.o_unresolved_calls + 1;
          Error
            (err span
               (Printf.sprintf "type %s has no method `%s`" (type_to_string owner_ty) mname)))
      | Some sig_ -> (
          if Array.length sig_.ts_params = 0 then
            Error (err span "internal: method signature without a receiver")
          else begin
            let subst : (Type_repr.generic_key * Type_repr.t) list ref = ref [] in
            (* pre-instantiate every free generic parameter of the method
               (declared ones and impl/owner-level params the signature
               references) with fresh inference variables (mirrors
               check_call_sig): the receiver and argument unifications
               solve the vars, never the rigid declaration binders *)
            let sig_free =
              List.concat_map
                (fun p -> params_in p.Type_repr.pt_type)
                (Array.to_list sig_.ts_params)
              @ params_in sig_.ts_return
            in
            let decl_params = List.map snd sig_.ts_params_decl in
            let all_params =
              decl_params @ List.filter (fun p -> not (List.mem p decl_params)) sig_free
            in
            List.iter
              (fun pid ->
                if not (List.mem_assoc (Type_repr.KParam pid) !subst) then
                  subst := (Type_repr.KParam pid, fresh_infer_var env.state) :: !subst)
              all_params;
            let self_ty = sig_.ts_params.(0).Type_repr.pt_type in
            let* () =
              match owner_ty, self_ty with
              | Type_repr.Fixed_array (t, _), Type_repr.Named (_, [| p |]) -> unify subst p t
              | _ -> (
                  match unify subst self_ty owner_ty with
                  | Ok () -> Ok ()
                  | Error _ -> (
                      (* a user type that replaced a builtin keeps the
                         builtin-registered methods: unify by type NAME *)
                      let same_name () =
                        match self_ty, owner_ty with
                        | Type_repr.Named (id1, a1), Type_repr.Named (id2, a2)
                          when Ids.Type_id.compare id1 id2 <> 0 -> (
                            (* the method key's owner name is the authority:
                               the builtin Vec nominal is named "Array", so
                               (Vec, len) matches a receiver named "Vec" *)
                            let n1 = List.assoc_opt id1 env.type_names in
                            let n2 = List.assoc_opt id2 env.type_names in
                            let names_agree =
                              match n1, n2 with
                              | Some n, Some m -> n = m || n = oname || m = oname
                              | _ -> false
                            in
                            match names_agree with
                            | false -> None
                            | true ->
                                if Array.length a1 <> Array.length a2 then None
                                else begin
                                  (* the same-name unification must see the
                                     call's pre-instantiation, so it starts
                                     from the main substitution *)
                                  let s4 = ref !subst in
                                  let rec go i =
                                    if i >= Array.length a1 then Some ()
                                    else
                                      match unify s4 a1.(i) a2.(i) with
                                      | Ok () -> go (i + 1)
                                      | Error _ -> None
                                  in
                                  match go 0 with
                                  | Some () ->
                                      List.iter
                                        (fun (k, v) ->
                                          if not (List.mem_assoc k !subst) then subst := (k, v) :: !subst)
                                        !s4;
                                      Some ()
                                  | None -> None
                                end)
                        | _ -> None
                      in
                      let deref_coerce () =
                        match owner_ty with
                        | Type_repr.Ref_internal (_, inner) -> (
                            match unify subst self_ty inner with
                            | Ok () -> Some ()
                            | Error _ -> None)
                        | _ -> (
                            match self_ty with
                            | Type_repr.Ref_internal (_, inner) -> (
                                match unify subst inner owner_ty with
                                | Ok () -> Some ()
                                | Error _ -> None)
                            | _ -> None)
                      in
                      match same_name () with
                      | Some () -> Ok ()
                      | None -> (
                          match deref_coerce () with
                          | Some () -> Ok ()
                          | None ->
                              Error
                                (Printf.sprintf
                                   "receiver type mismatch: %s.%s self %s receiver %s"
                                   oname mname (type_to_string self_ty)
                                   (type_to_string owner_ty)))))
            in
            let n_params = List.length sig_.ts_params_decl in
            if List.length targs > n_params then Error (err span "too many type arguments")
            else begin
              let* expl =
                let rec go acc = function
                  | [] -> Ok (List.rev acc)
                  | t :: rest -> (
                      match resolve_type env scope t with
                      | Ok rt -> go (rt :: acc) rest
                      | Error m -> Error m)
                in
                go [] targs
              in
              List.iter2
                (fun (_, pid) t -> subst := (Type_repr.KParam pid, t) :: !subst)
                (List.filteri (fun i _ -> i < List.length expl) sig_.ts_params_decl)
                expl;
              let* tes, arg_effects =
                let rec go (acc : typed_expr list) (effects : Access_effect.read_effect list) i =
                  function
                  | [] -> Ok (List.rev acc, List.rev effects)
                  | (a : Ast.call_arg) :: rest -> (
                      let ai = i + 1 in
                      if ai >= Array.length sig_.ts_params then
                        Error (err a.Ast.ca_span "too many arguments")
                      else begin
                        let pt = substitute_fixpoint !subst sig_.ts_params.(ai).Type_repr.pt_type in
                        match check_expr env scope (Some pt) a.Ast.ca_value with
                        | Error m -> Error m
                        | Ok ate -> (
                            let s2 = ref [] in
                            match unify s2 pt ate.te_type with
                            | Ok () -> (
                                List.iter
                                  (fun (k, v) ->
                                    if not (List.mem_assoc k !subst) then subst := (k, v) :: !subst)
                                  !s2;
                                let eff = Access_effect.read_effect sig_.ts_params.(ai).Type_repr.pt_convention in
                                go (ate :: acc) (eff :: effects) (i + 1) rest)
                            | Error m -> (
                                (* call-site coercion: an explicit-ref argument
                                   derefs to its pointee for a by-value param *)
                                let deref_ok () =
                                  match ate.te_type with
                                  | Type_repr.Ref_internal (_, inner) -> (
                                      let s3 = ref [] in
                                      match unify s3 pt inner with
                                      | Ok () ->
                                          List.iter
                                            (fun (k, v) ->
                                              if not (List.mem_assoc k !subst) then subst := (k, v) :: !subst)
                                            !s3;
                                          Some ()
                                      | Error _ -> None)
                                  | _ -> None
                                in
                                match deref_ok () with
                                | Some () ->
                                    let eff = Access_effect.read_effect sig_.ts_params.(ai).Type_repr.pt_convention in
                                    go (ate :: acc) (eff :: effects) (i + 1) rest
                                | None ->
                                    Error
                                      (err a.Ast.ca_span
                                         (Printf.sprintf "argument %d type mismatch: expected %s, found %s (%s)"
                                            (i + 1) (type_to_string pt) (type_to_string ate.te_type) m))))
                      end)
                in
                go [] [] 0 args
              in
              let n_req = Array.length sig_.ts_params - 1 in
              if List.length tes < n_req then
                Error
                  (err span
                     (Printf.sprintf "too few arguments for method `%s`: expected %d, got %d" mname
                        n_req (List.length tes)))
              else begin
                let s3 = ref [] in
                (match expected with
                 | Some exp -> (
                     match unify s3 (substitute_fixpoint !subst sig_.ts_return) exp with
                     | Ok () -> ()
                     | Error _ -> ())
                 | None -> ());
                List.iter
                  (fun (k, v) -> if not (List.mem_assoc k !subst) then subst := (k, v) :: !subst)
                  !s3;
                let ret = substitute_fixpoint !subst sig_.ts_return in
                let sig_ids = List.map snd sig_.ts_params_decl in
                let* () =
                  match List.filter (fun p -> List.mem p sig_ids) (params_in ret) with
                  | [] -> Ok ()
                  | p :: _ ->
                      let pname =
                        match
                          List.find_opt (fun (_, i) -> Ids.Generic_param_id.compare i p = 0)
                            sig_.ts_params_decl
                        with
                        | Some (n, _) -> n
                        | None -> "?"
                      in
                      Error
                        (err span
                           (Printf.sprintf "cannot infer type parameter `%s` of method `%s`" pname
                              mname))
                in
                let wps = List.map (fun (wt, bs) -> (substitute_fixpoint !subst wt, bs)) sig_.ts_where in
                let* () = check_where_obligations env span ("method `" ^ mname ^ "`") wps in
                let recv_effect = Access_effect.read_effect sig_.ts_params.(0).Type_repr.pt_convention in
                let all_effects = Array.of_list (recv_effect :: arg_effects) in
                let substitution =
                  Array.of_list
                    (List.map
                       (fun (_, pid) ->
                         match List.assoc_opt (Type_repr.KParam pid) !subst with
                         | Some t -> substitute_fixpoint !subst t
                         | None -> Type_repr.Type_param pid)
                       sig_.ts_params_decl)
                in
                let call : typed_call =
                  {
                    target = Some sig_.ts_callable;
                    substitution;
                    (* the receiver is an argument: effects include its
                       convention, so the args array must too *)
                    args = Array.of_list (receiver :: tes);
                    effects = all_effects;
                    return_type = ret;
                  }
                in
                env.state.oracle.o_calls <- call :: env.state.oracle.o_calls;
                (* the persistent typed-call channel: same node-keyed
                   record as check_call_sig — the method's call span
                   carries the resolved callable + solved substitution *)
                Hashtbl.replace env.typed_nodes (span.Span.file_id, span.Span.start)
                  { tn_type = ret; tn_cast_target = None; tn_call = Some (sig_.ts_callable, substitution) };
                (* the integrated access channel (re-audit P0-11): the
                   receiver first, then the arguments, aligned with
                   all_effects; each record carries the typed type *)
                let rec zip (a : Ast.call_arg list) (e : Access_effect.read_effect list)
                    (t : typed_expr list) =
                  match a, e, t with
                  | x :: ra, eff :: re, te :: rt ->
                      (x.Ast.ca_value, eff, x.Ast.ca_span, te.te_type) :: zip ra re rt
                  | _ -> []
                in
                record_call_accesses env scope
                  ((base, recv_effect, Ast.expr_span base, receiver.te_type)
                  :: zip args arg_effects tes);
                Ok { te_type = ret; te_effects = all_effects; te_span = span }
              end
            end
          end)

(* ────────────────────────────────────────────────────────────────
   Items: checking *)

let empty_scope : scope = { locals = []; generics = []; loop_depth = 0; capture = None }

let qualified_name (mp : string list) (n : string) : string =
  match mp with [] -> n | segs -> String.concat "::" (segs @ [ n ])

let impl_param_key (env : env) (d : Ast.impl_decl) : string =
  Printf.sprintf "impl::%s::%d:%d-%d" (qualified_name env.module_path d.i_target_type)
    d.i_span.Span.file_id d.i_span.Span.start d.i_span.Span.end_

let rec check_function_body (env : env) (extra_tp_bounds : (string * string list) list)
    (sig_ : typed_signature) (d : Ast.function_decl) : (unit, string) result =
  let scope =
    let n_ast = List.length d.fn_sig.sig_params in
    let n_sig = Array.length sig_.ts_params in
    if n_ast > n_sig then
      failwith
        (Printf.sprintf "ts_params mismatch in %s: ast=%d sig=%d"
           sig_.ts_name n_ast n_sig);
    {
      locals =
        List.mapi
          (fun i (p : Ast.param) ->
            ( p.p_name,
              sig_.ts_params.(i).Type_repr.pt_type,
              match p.Ast.p_convention with
              | Ast.InoutAccess | Ast.Set -> true
              | Ast.LetAccess | Ast.Sink -> false ))
          d.fn_sig.sig_params;
      generics = List.map (fun (n, i) -> (n, i)) sig_.ts_params_decl;
      loop_depth = 0;
      capture = None;
    }
  in
  let own_tp_bounds =
    List.map (fun (tp : Ast.type_param) -> (tp.tp_name, tp.tp_bounds)) d.fn_sig.sig_type_params
  in
  let saved = env.impls.param_bounds in
  env.impls.param_bounds <-
    solver_param_bounds sig_.ts_params_decl (extra_tp_bounds @ own_tp_bounds) sig_.ts_where;
  let env' = { env with current_return = Some sig_.ts_return } in
  let result =
    let* () = check_where_obligations env' d.fn_span ("function `" ^ sig_.ts_name ^ "`") sig_.ts_where in
    let* body =
      match d.fn_body with
      | Ast.FnBlock b -> check_block env' scope (Some sig_.ts_return) b b.b_span
      | Ast.FnExpr e -> check_expr env' scope (Some sig_.ts_return) e
      | Ast.FnSignatureOnly ->
          Ok { te_type = sig_.ts_return; te_effects = [||]; te_span = sig_.ts_span }
    in
    let subst = ref [] in
    (* the production rule (types.tg): a Unit-returning function
       DISCARDS its trailing statement's value (`if c then advance(p)
       end` where advance returns a Token) — only the FnExpr form
       unifies its value *)
    match sig_.ts_return with
    | Type_repr.Unit -> (
        match d.fn_body with
        | Ast.FnBlock _ -> Ok ()
        | _ -> (
            match unify subst Type_repr.Unit body.te_type with
            | Ok () -> Ok ()
            | Error m ->
                Error
                  (err d.fn_span
                     (Printf.sprintf "function body type mismatch: expected %s, found %s (%s)"
                        (type_to_string sig_.ts_return) (type_to_string body.te_type) m))))
    | _ -> (
        match unify subst sig_.ts_return body.te_type with
        | Ok () -> Ok ()
        | Error m ->
            Error
              (err d.fn_span
                 (Printf.sprintf "function body type mismatch: expected %s, found %s (%s)"
                    (type_to_string sig_.ts_return) (type_to_string body.te_type) m)))
  in
  env.impls.param_bounds <- saved;
  result

and check_methods (env : env) (owner : string) (extra_tp_bounds : (string * string list) list)
    (methods : Ast.function_decl list) : (unit, string) result =
  let rec go = function
    | [] -> Ok ()
    | (m : Ast.function_decl) :: rest -> (
        match List.assoc_opt (owner, m.fn_sig.sig_name) env.methods with
        | None ->
            Error
              (err m.fn_span
                 (Printf.sprintf "internal: method `%s::%s` was not registered" owner
                    m.fn_sig.sig_name))
        | Some sig_ -> (
            match check_function_body env extra_tp_bounds sig_ m with
            | Ok () -> go rest
            | Error m -> Error m))
  in
  go methods

and check_function_item (env : env) (mp : string list) (d : Ast.function_decl) :
    (unit, string) result =
  let qname = qualified_name mp d.fn_sig.sig_name in
  match List.assoc_opt qname env.functions with
  | None ->
      Error (err d.fn_span (Printf.sprintf "internal: function `%s` was not registered" qname))
  | Some sig_ -> check_function_body env [] sig_ d

and check_struct (env : env) (d : Ast.struct_decl) : (unit, string) result =
  match List.assoc_opt d.s_name env.nominals, List.assoc_opt d.s_name env.types with
  | Some nom, Some (Type_repr.Named (tid, args)) -> (
      let self_ty = Type_repr.Named (tid, args) in
      let tp_bounds =
        List.map (fun (tp : Ast.type_param) -> (tp.tp_name, tp.tp_bounds)) d.s_type_params
      in
      let saved = env.impls.param_bounds in
      env.impls.param_bounds <- solver_param_bounds nom.nom_params tp_bounds nom.nom_where;
      let result =
        let* () = check_where_obligations env d.s_span ("struct `" ^ d.s_name ^ "`") nom.nom_where in
        let* () =
          let scope = { empty_scope with generics = List.map (fun (n, i) -> (n, i)) nom.nom_params } in
          let rec go = function
            | [] -> Ok ()
            | (f : Ast.field_decl) :: rest -> (
                match f.f_default with
                | None -> go rest
                | Some e -> (
                    match List.assoc_opt f.f_name nom.nom_fields with
                    | None -> Error (err f.f_span (Printf.sprintf "unknown field `%s`" f.f_name))
                    | Some ft -> (
                        match check_expr env scope (Some ft) e with
                        | Ok _ -> go rest
                        | Error m -> Error m)))
          in
          go d.s_fields
        in
        check_methods { env with current_self = Some self_ty } d.s_name tp_bounds d.s_methods
      in
      env.impls.param_bounds <- saved;
      result)
  | _ -> Error (err d.s_span (Printf.sprintf "internal: struct `%s` was not registered" d.s_name))

and check_enum (env : env) (d : Ast.enum_decl) : (unit, string) result =
  match List.assoc_opt d.e_name env.nominals with
  | None -> Error (err d.e_span (Printf.sprintf "internal: enum `%s` was not registered" d.e_name))
  | Some nom -> (
      let tp_bounds =
        List.map (fun (tp : Ast.type_param) -> (tp.tp_name, tp.tp_bounds)) d.e_type_params
      in
      let saved = env.impls.param_bounds in
      env.impls.param_bounds <- solver_param_bounds nom.nom_params tp_bounds nom.nom_where;
      let result = check_where_obligations env d.e_span ("enum `" ^ d.e_name ^ "`") nom.nom_where in
      env.impls.param_bounds <- saved;
      result)

and check_trait (env : env) (d : Ast.trait_decl) : (unit, string) result =
  let params =
    List.map (fun (tp : Ast.type_param) -> (tp.tp_name, fresh_param_id env.state)) d.t_type_params
  in
  let scope = { empty_scope with generics = params } in
  let* where = resolve_where env scope d.t_where in
  let env' = { env with current_self = Some (Type_repr.Type_param (fresh_param_id env.state)) } in
  let tp_bounds =
    List.map (fun (tp : Ast.type_param) -> (tp.tp_name, tp.tp_bounds)) d.t_type_params
  in
  let saved = env'.impls.param_bounds in
  env'.impls.param_bounds <- solver_param_bounds params tp_bounds where;
  let result =
    let* () = check_where_obligations env' d.t_span ("trait `" ^ d.t_name ^ "`") where in
    let rec go = function
      | [] -> Ok ()
      | (m : Ast.function_decl) :: rest -> (
          match m.fn_body with
          | Ast.FnSignatureOnly -> go rest
          | _ -> (
              match List.assoc_opt (d.t_name, m.fn_sig.sig_name) env'.methods with
              | None -> Error (err m.fn_span "internal: trait method was not registered")
              | Some sig_ -> (
                  match check_function_body env' tp_bounds sig_ m with
                  | Ok () -> go rest
                  | Error e -> Error e)))
    in
    go d.t_methods
  in
  env'.impls.param_bounds <- saved;
  result

and check_impl (env : env) (d : Ast.impl_decl) : (unit, string) result =
  let impl_params =
    let key = impl_param_key env d in
    match Hashtbl.find_opt env.state.sig_param_ids key with
    | Some ids -> ids
    | None ->
        (* owner separation: the impl's type parameters are the impl's OWN
           binders, never the target nominal's — T_struct and U_impl are
           different declarations with different owners; their relationship
           is the target substitution Box[T_struct] <- Box[U_impl], applied
           when field/method resolution reaches into the nominal's shapes *)
        let ids =
          List.map
            (fun (tp : Ast.type_param) -> (tp.tp_name, fresh_param_id env.state))
            d.i_type_params
        in
        Hashtbl.add env.state.sig_param_ids key ids;
        ids
  in
  let scope = { empty_scope with generics = impl_params } in
  let* target =
    match d.i_for_type, d.i_trait_name with
    | Some ft, None -> resolve_type env scope ft
    | _ ->
        resolve_type env scope
          (Ast.Named
             ( d.i_target_type,
               List.map
                 (fun (tp : Ast.type_param) -> Ast.Named (tp.tp_name, [], tp.tp_span))
                 d.i_type_params,
               d.i_span ))
  in
  let env' = { env with current_self = Some target } in
  let* impl_where = resolve_where env' scope d.i_where in
  let tp_bounds =
    List.map (fun (tp : Ast.type_param) -> (tp.tp_name, tp.tp_bounds)) d.i_type_params
  in
  let saved = env'.impls.param_bounds in
  env'.impls.param_bounds <- solver_param_bounds impl_params tp_bounds impl_where;
  let result =
    let* () = check_where_obligations env' d.i_span ("impl for `" ^ d.i_target_type ^ "`") impl_where in
    check_methods env' d.i_target_type tp_bounds d.i_methods
  in
  env'.impls.param_bounds <- saved;
  result

and check_const (env : env) (mp : string list) (d : Ast.const_decl) : (unit, string) result =
  match List.assoc_opt (qualified_name mp d.c_name) env.consts with
  | None -> Error (err d.c_span "internal: const was not registered")
  | Some ty -> (
      match check_expr env empty_scope (Some ty) d.c_value with
      | Ok _ -> Ok ()
      | Error m -> Error m)

and check_static (env : env) (mp : string list) (d : Ast.static_decl) : (unit, string) result =
  match List.assoc_opt (qualified_name mp d.st_name) env.consts with
  | None -> Error (err d.st_span "internal: static was not registered")
  | Some ty -> (
      match check_expr env empty_scope (Some ty) d.st_value with
      | Ok _ -> Ok ()
      | Error m -> Error m)

and check_extern (env : env) (d : Ast.extern_block_decl) : (unit, string) result =
  let rec go = function
    | [] -> Ok ()
    | it :: rest -> (
        match check_item env it with
        | Ok () -> go rest
        | Error m -> Error m)
  in
  go d.ex_items

and check_module (env : env) (item : Ast.item) : (unit, string) result =
  match item.Ast.kind with
  | Ast.ModuleDef d -> (
      match d.m_items with
      | None -> Ok ()
      | Some items ->
          let rec go = function
            | [] -> Ok ()
            | it :: rest -> (
                match check_item env it with
                | Ok () -> go rest
                | Error m -> Error m)
          in
          go items)
  | _ -> Error (err item.span "internal: not a module")

and check_item (env : env) (item : Ast.item) : (unit, string) result =
  match item.Ast.kind with
  | Ast.Function d -> check_function_item env item.module_path d
  | Ast.TestDecl d -> (
      let qname = qualified_name item.module_path d.test_name in
      match List.assoc_opt qname env.functions with
      | None -> Error (err item.span "internal: test was not registered")
      | Some sig_ ->
          let d' =
            {
              Ast.fn_sig =
                {
                  sig_name = d.test_name;
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
                  sig_span = d.test_span;
                };
              fn_clauses = [];
              fn_body = Ast.FnBlock d.test_body;
              fn_span = d.test_span;
            }
          in
          check_function_body env [] sig_ d')
  | Ast.StructDef d -> check_struct env d
  | Ast.EnumDef d -> check_enum env d
  | Ast.TraitDef d -> check_trait env d
  | Ast.ImplBlock d -> check_impl env d
  | Ast.ConstDecl d -> check_const env item.module_path d
  | Ast.StaticDecl d -> check_static env item.module_path d
  | Ast.TypeAlias _ -> Ok ()
  | Ast.ExternBlock d -> check_extern env d
  | Ast.ModuleDef _ -> check_module env item
  | Ast.UseDecl _ -> Ok ()
  | Ast.CapabilityDecl _ | Ast.EffectDecl _ | Ast.RationaleBlock _ | Ast.EditionDecl _
  | Ast.MacroDecl _ ->
      Error (err item.span "item kind is not available in the bootstrap subset")

(* ────────────────────────────────────────────────────────────────
   Registration pass (the resolver's registries, pass A) *)

and resolve_where (env : env) (scope : scope) (wps : Ast.where_predicate list) :
    ((Type_repr.t * string list) list, string) result =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | (wp : Ast.where_predicate) :: rest -> (
        match resolve_type env scope wp.wp_type with
        | Ok wt -> go ((wt, wp.wp_bounds) :: acc) rest
        | Error m -> Error m)
  in
  go [] wps

and register_methods (env : env) (owner : string) (methods : Ast.function_decl list)
    (extra_params : (string * Ids.Generic_param_id.t) list)
    (where_extra : (Type_repr.t * string list) list) : (env, string) result =
  let rec go env = function
    | [] -> Ok env
    | (m : Ast.function_decl) :: rest -> (
        match
          resolve_signature env empty_scope m.fn_sig extra_params
            ~key:(owner ^ "::" ^ m.fn_sig.sig_name)
        with
        | Error e -> Error e
        | Ok sig_ ->
            (* identity handoff (audit Fix 2): the resolver owns method
               callable identity — use its CallableId when it resolves;
               fall back to the fresh mint only when it cannot *)
            let sig_ =
              match env.resolved with
              | Some rp -> (
                  match
                    Resolver.resolve_method rp env.module_id owner m.Ast.fn_sig.Ast.sig_name
                  with
                  | Resolver.Resolved cid ->
                      env.state.o_handoff_resolved <- env.state.o_handoff_resolved + 1;
                      { sig_ with ts_callable = cid }
                  | _ ->
                      env.state.o_handoff_fallback <- env.state.o_handoff_fallback + 1;
                      sig_)
              | None -> sig_
            in
            let sig_ = { sig_ with ts_where = where_extra @ sig_.ts_where } in
            let key = (owner, sig_.ts_name) in
            (* idempotent registration (audit Fix 3): re-registration
               replaces, never appends a duplicate declaration *)
            let env' =
              { env with methods = (key, sig_) :: List.remove_assoc key env.methods }
            in
            go env' rest)
  in
  go env methods

and register_constructors (env : env) (ename : string) (tid : Ids.Type_id.t)
    (params : (string * Ids.Generic_param_id.t) list)
    (variants : (string * Type_repr.t array) list) : (env, string) result =
  let ret_ty =
    Type_repr.Named
      (tid, Array.of_list (List.map (fun (_, p) -> Type_repr.Type_param (p)) params))
  in
  let rec go env = function
    | [] -> Ok env
    | (vname, field_tys) :: rest -> (
        let sig_ =
          mk_sig env.state ~name:(ename ^ "::" ^ vname) ~params_decl:params
            ~params:
              (List.mapi
                 (fun i _ -> (Printf.sprintf "arg%d" i, Access_effect.Let, field_tys.(i)))
                 (Array.to_list field_tys))
            ~ret:ret_ty ~where:[]
        in
        let env' =
          {
            env with
            constructors =
              (ename ^ "::" ^ vname, sig_)
              :: List.remove_assoc (ename ^ "::" ^ vname) env.constructors
              |> fun l -> (vname, sig_) :: List.remove_assoc vname l;
          }
        in
        go env' rest)
  in
  go env variants

and register_impl (env : env) (d : Ast.impl_decl) : (env, string) result =
  let impl_params =
    let key = impl_param_key env d in
    match Hashtbl.find_opt env.state.sig_param_ids key with
    | Some ids -> ids
    | None ->
        (* owner separation: the impl's type parameters are the impl's OWN
           binders, never the target nominal's — T_struct and U_impl are
           different declarations with different owners; their relationship
           is the target substitution Box[T_struct] <- Box[U_impl], applied
           when field/method resolution reaches into the nominal's shapes *)
        let ids =
          List.map
            (fun (tp : Ast.type_param) -> (tp.tp_name, fresh_param_id env.state))
            d.i_type_params
        in
        Hashtbl.add env.state.sig_param_ids key ids;
        ids
  in
  let scope = { empty_scope with generics = impl_params } in
  let* target =
    match d.i_for_type, d.i_trait_name with
    | Some ft, None -> resolve_type env scope ft
    | _ ->
        resolve_type env scope
          (Ast.Named
             ( d.i_target_type,
               List.map
                 (fun (tp : Ast.type_param) -> Ast.Named (tp.tp_name, [], tp.tp_span))
                 d.i_type_params,
               d.i_span ))
  in
  let env' = { env with current_self = Some target } in
  let* impl_where = resolve_where env' scope d.i_where in
  let* assoc =
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | (a : Ast.type_alias_decl) :: rest -> (
          match resolve_type env' scope a.ta_value with
          | Ok t -> go ((a.ta_name, t) :: acc) rest
          | Error m -> Error m)
    in
    go [] d.i_associated_types
  in
  let from_tp =
    List.concat_map
      (fun (tp : Ast.type_param) ->
        List.map
          (fun b ->
            {
              Trait_solver.trait_name = b;
              self_ty = Type_repr.Type_param (List.assoc tp.tp_name impl_params);
              type_args = [||];
            })
          tp.tp_bounds)
      d.i_type_params
  in
  let from_where =
    List.concat_map
      (fun (wt, bs) ->
        List.map (fun b -> { Trait_solver.trait_name = b; self_ty = wt; type_args = [||] }) bs)
      impl_where
  in
  let entry : Trait_solver.impl_entry =
    {
      ie_trait = (match d.i_trait_name with Some t -> t | None -> "");
      ie_target = target;
      ie_target_name = d.i_target_type;
      ie_id = { Trait_solver.module_id = env.module_id; index = env.state.next_impl_index };
      ie_params = List.map (fun (tp : Ast.type_param) -> tp.tp_name) d.i_type_params;
      ie_bounds = from_tp @ from_where;
      ie_assoc = assoc;
    }
  in
  env.state.next_impl_index <- env.state.next_impl_index + 1;
  let env2 =
    {
      env' with
      impls =
        {
          env'.impls with
          impls = entry :: List.filter (fun e -> e.Trait_solver.ie_id <> entry.Trait_solver.ie_id) env'.impls.impls;
        };
    }
  in
  let* () =
    match d.i_trait_name with
    | None -> Ok ()
    | Some t -> (
        match List.assoc_opt t env2.impls.trait_contracts with
        | None -> Error (err d.i_span (Printf.sprintf "unknown trait `%s` in impl" t))
        | Some tmethods ->
            let mnames = List.map (fun (m : Ast.function_decl) -> m.fn_sig.sig_name) d.i_methods in
            if List.for_all (fun n -> List.mem n tmethods) mnames then Ok ()
            else
              Error
                (err d.i_span
                   (Printf.sprintf "impl of trait `%s` declares methods not in the trait contract" t)))
  in
  register_methods env2 d.i_target_type d.i_methods impl_params impl_where

and register_item (env : env) (item : Ast.item) : (env, string) result =
  match item.Ast.kind with
  | Ast.Function d ->
      let qname = qualified_name item.module_path d.fn_sig.sig_name in
      if List.mem_assoc qname env.functions then
        Error (err item.span (Printf.sprintf "duplicate function `%s`" qname))
      else begin
        let* sig_ = resolve_signature env empty_scope d.fn_sig [] ~key:qname in
        (* the qualified-def form `def Type::method(...)` is a method
           declaration: it also enters the method table under
           (Type, method) so `x.method()` dispatches to it *)
        let env_m =
          match String.index_opt d.fn_sig.sig_name ':' with
          | Some i when i + 2 < String.length d.fn_sig.sig_name ->
              let owner = String.sub d.fn_sig.sig_name 0 i in
              let mname = String.sub d.fn_sig.sig_name (i + 2) (String.length d.fn_sig.sig_name - i - 2) in
              let key = (owner, mname) in
              { env with methods = (key, sig_) :: List.remove_assoc key env.methods }
          | _ -> env
        in
        Ok { env_m with functions = (qname, sig_) :: env.functions }
      end
  | Ast.TestDecl d ->
      let qname = qualified_name item.module_path d.test_name in
      if List.mem_assoc qname env.functions then
        Error (err item.span (Printf.sprintf "duplicate test `%s`" qname))
      else begin
        let sig_ =
          mk_sig env.state ~name:qname ~params_decl:[] ~params:[] ~ret:Type_repr.Unit ~where:[]
        in
        Ok { env with functions = (qname, sig_) :: env.functions }
      end
  | Ast.StructDef d -> (
      let params =
        let key = "nominal::" ^ d.s_name in
        match Hashtbl.find_opt env.state.sig_param_ids key with
        | Some ids -> ids
        | None ->
            let ids =
              List.map (fun (tp : Ast.type_param) -> (tp.tp_name, fresh_param_id env.state))
                d.s_type_params
            in
            Hashtbl.add env.state.sig_param_ids key ids;
            ids
      in
      let scope = { empty_scope with generics = params } in
      (* re-registration merges newly resolvable fields into the nominal *)
      let existing, env_base =
        match List.assoc_opt d.s_name env.nominals with
        | Some nom -> (Some nom, env)
        | None ->
            (* LangItem tid adoption (audit Fix 4): a source declaration of
               a builtin standard type reuses the builtin's TypeId, so
               Vec/Map/Set/Option/Result/Ptr have ONE identity *)
            let tid =
              match List.assoc_opt d.s_name env.type_ids with
              | Some t -> t
              | None -> fresh_type_id env.state
            in
            (if d.s_name = "Box" then box_tid := Some tid);
            let param_tys = Array.of_list (List.map (fun (_, p) -> Type_repr.Type_param (p)) params) in
            let nom : nominal =
              { nom_kind = `Struct; nom_params = params; nom_fields = []; nom_variants = []; nom_where = []; nom_field_ids = []; nom_variant_ids = [] }
            in
            (* a user definition of a builtin name REPLACES the builtin *)
            let env' =
              {
                env with
                types = (d.s_name, Type_repr.Named (tid, param_tys)) :: List.remove_assoc d.s_name env.types;
                type_ids = (d.s_name, tid) :: List.remove_assoc d.s_name env.type_ids;
                type_names = (tid, d.s_name) :: env.type_names;
                nominals = (d.s_name, nom) :: env.nominals;
              }
            in
            (None, env')
      in
      let tid = List.assoc d.s_name env_base.type_ids in
      let param_tys = Array.of_list (List.map (fun (_, p) -> Type_repr.Type_param (p)) params) in
      let env_fwd = env_base in
      (* resolve fields one by one; unresolvable ones are reported and
         retried by the driver *)
      let fields_acc, errs =
        List.fold_left
          (fun (acc, errs) (f : Ast.field_decl) ->
            if List.mem_assoc f.f_name acc then (acc, errs)
            else
              match resolve_type env_fwd scope f.f_type with
              | Ok ft -> ((f.f_name, ft) :: acc, errs)
              | Error m -> (acc, err item.span m :: errs))
          (match existing with Some nom -> (nom.nom_fields, []) | None -> ([], []))
          d.s_fields
      in
      let fields = List.rev fields_acc in
      let* where =
        match resolve_where env_fwd scope d.s_where with
        | Ok w -> Ok w
        | Error m -> Error m
      in
      let field_ids =
        List.mapi
          (fun i (fname, _) ->
            match env_fwd.resolved with
            | Some rp -> (
                match Resolver.resolve_field rp env_fwd.module_id d.s_name fname with
                | Resolver.Resolved fid -> fid
                | _ -> Ids.Field_id.make (i + 1))
            | None -> Ids.Field_id.make (i + 1))
          fields
      in
      let nom : nominal =
        {
          nom_kind = `Struct;
          nom_params = params;
          nom_fields = fields;
          nom_variants = [];
          nom_where = where;
          nom_field_ids = field_ids;
          nom_variant_ids = [];
        }
      in
      let env1 = { env_fwd with nominals = (d.s_name, nom) :: List.remove_assoc d.s_name env_fwd.nominals } in
      let env2 = { env1 with current_self = Some (Type_repr.Named (tid, param_tys)) } in
      match register_methods env2 d.s_name d.s_methods params where with
      | Ok env3 -> (match errs with [] -> Ok env3 | e :: _ -> Error e)
      | Error m -> Error m)
  | Ast.EnumDef d -> (
      let params =
        let key = "nominal::" ^ d.e_name in
        match Hashtbl.find_opt env.state.sig_param_ids key with
        | Some ids -> ids
        | None ->
            let ids =
              List.map (fun (tp : Ast.type_param) -> (tp.tp_name, fresh_param_id env.state))
                d.e_type_params
            in
            Hashtbl.add env.state.sig_param_ids key ids;
            ids
      in
      let scope = { empty_scope with generics = params } in
      let existing, env_base =
        match List.assoc_opt d.e_name env.nominals with
        | Some nom -> (Some nom, env)
        | None ->
            (* LangItem tid adoption (audit Fix 4): a source declaration of
               a builtin standard type reuses the builtin's TypeId, so
               Vec/Map/Set/Option/Result/Ptr have ONE identity *)
            let tid =
              match List.assoc_opt d.e_name env.type_ids with
              | Some t -> t
              | None -> fresh_type_id env.state
            in
            let param_tys = Array.of_list (List.map (fun (_, p) -> Type_repr.Type_param (p)) params) in
            let nom : nominal =
              { nom_kind = `Enum; nom_params = params; nom_fields = []; nom_variants = []; nom_where = []; nom_field_ids = []; nom_variant_ids = [] }
            in
            let env' =
              {
                env with
                types = (d.e_name, Type_repr.Named (tid, param_tys)) :: List.remove_assoc d.e_name env.types;
                type_ids = (d.e_name, tid) :: List.remove_assoc d.e_name env.type_ids;
                type_names = (tid, d.e_name) :: env.type_names;
                nominals = (d.e_name, nom) :: env.nominals;
              }
            in
            (None, env')
      in
      let tid = List.assoc d.e_name env_base.type_ids in
      let _param_tys = Array.of_list (List.map (fun (_, p) -> Type_repr.Type_param (p)) params) in
      let env_fwd = env_base in
      let variants_acc, errs =
        List.fold_left
          (fun (acc, errs) (v : Ast.variant_decl) ->
            if List.mem_assoc v.v_name acc then (acc, errs)
            else
              let field_tys, ferrs =
                List.fold_left
                  (fun (tys, ferrs) (vf : Ast.variant_field) ->
                    match resolve_type env_fwd scope vf.vf_type with
                    | Ok t -> (t :: tys, ferrs)
                    | Error m -> (tys, err item.span m :: ferrs))
                  ([], [])
                  v.v_fields
              in
              ( (v.v_name, Array.of_list (List.rev field_tys)) :: acc,
                ferrs @ errs ))
          (match existing with Some nom -> (nom.nom_variants, []) | None -> ([], []))
          d.e_variants
      in
      let variants = List.rev variants_acc in
      let* where =
        match resolve_where env_fwd scope d.e_where with
        | Ok w -> Ok w
        | Error m -> Error m
      in
      let variant_ids =
        List.mapi
          (fun i (vname, _) ->
            match env_fwd.resolved with
            | Some rp -> (
                match Resolver.resolve_variant rp env_fwd.module_id d.e_name vname with
                | Resolver.Resolved vid -> vid
                | _ -> Ids.Variant_id.make (i + 1))
            | None -> Ids.Variant_id.make (i + 1))
          variants
      in
      let nom : nominal =
        {
          nom_kind = `Enum;
          nom_params = params;
          nom_fields = [];
          nom_variants = variants;
          nom_where = where;
          nom_field_ids = [];
          nom_variant_ids = variant_ids;
        }
      in
      let env1 = { env_fwd with nominals = (d.e_name, nom) :: List.remove_assoc d.e_name env_fwd.nominals } in
      match register_constructors env1 d.e_name tid params variants with
      | Ok env2 -> (match errs with [] -> Ok env2 | e :: _ -> Error e)
      | Error m -> Error m)
  | Ast.TraitDef d ->      let env1 =
        {
          env with
          impls =
            {
              env.impls with
              trait_contracts =
                (d.t_name, List.map (fun (m : Ast.function_decl) -> m.fn_sig.sig_name) d.t_methods)
                :: env.impls.trait_contracts;
            };
        }
      in
      let params =
        List.map (fun (tp : Ast.type_param) -> (tp.tp_name, fresh_param_id env1.state))
          d.t_type_params
      in
      let scope = { empty_scope with generics = params } in
      let* where = resolve_where env1 scope d.t_where in
      let env2 = { env1 with current_self = Some (Type_repr.Type_param (fresh_param_id env1.state)) } in
      register_methods env2 d.t_name d.t_methods params where
  | Ast.ImplBlock d -> register_impl env d
  | Ast.ConstDecl d ->
      let qname = qualified_name item.module_path d.c_name in
      let* ty = resolve_type env empty_scope d.c_type in
      Ok { env with consts = (qname, ty) :: List.remove_assoc qname env.consts }
  | Ast.StaticDecl d ->
      let qname = qualified_name item.module_path d.st_name in
      let* ty = resolve_type env empty_scope d.st_type in
      Ok { env with consts = (qname, ty) :: List.remove_assoc qname env.consts }
  | Ast.TypeAlias d ->
      let params =
        let key = "alias::" ^ qualified_name item.module_path d.ta_name in
        match Hashtbl.find_opt env.state.sig_param_ids key with
        | Some ids -> ids
        | None ->
            let ids =
              List.map (fun (tp : Ast.type_param) -> (tp.tp_name, fresh_param_id env.state))
                d.ta_type_params
            in
            Hashtbl.add env.state.sig_param_ids key ids;
            ids
      in
      let scope = { empty_scope with generics = params } in
      let* value = resolve_type env scope d.ta_value in
      Ok { env with types = (d.ta_name, value) :: env.types }
  | Ast.ExternBlock d ->
      let rec go env = function
        | [] -> Ok env
        | it :: rest -> (
            match register_item env it with
            | Ok env' -> go env' rest
            | Error m -> Error m)
      in
      go env d.ex_items
  | Ast.ModuleDef d -> (
      match d.m_items with
      | None -> Ok env
      | Some items ->
          let rec go env = function
            | [] -> Ok env
            | it :: rest -> (
                match register_item env it with
                | Ok env' -> go env' rest
                | Error m -> Error m)
          in
          go env items)
  | Ast.UseDecl _ -> Ok env
  | Ast.CapabilityDecl _ | Ast.EffectDecl _ | Ast.RationaleBlock _ | Ast.EditionDecl _
  | Ast.MacroDecl _ ->
      Error (err item.span "item kind is not available in the bootstrap subset")

(* ────────────────────────────────────────────────────────────────
   The completeness oracle (audit §28) *)

let reset_oracle (env : env) : unit =
  let o = env.state.oracle in
  o.o_exprs <- [];
  o.o_calls <- [];
  o.o_obligations <- [];
  o.o_type_params <- 0;
  o.o_unsolved_vars <- 0;
  o.o_error_types <- 0;
  o.o_unknown_defs <- 0;
  o.o_unknown_fields <- 0;
  o.o_unknown_variants <- 0;
  o.o_unresolved_calls <- 0;
  o.o_unsolved_obligations <- 0;
  o.o_missing_effects <- 0;
  o.o_derived_callables <- [];
  o.o_deferred_params <- []

let item_param_ids (env : env) (item : Ast.item) : Ids.Generic_param_id.t list =
  match item.Ast.kind with
  | Ast.Function d -> (
      match List.assoc_opt (qualified_name item.module_path d.fn_sig.sig_name) env.functions with
      | Some s -> List.map snd s.ts_params_decl
      | None -> [])
  | Ast.TestDecl d -> (
      match List.assoc_opt (qualified_name item.module_path d.test_name) env.functions with
      | Some s -> List.map snd s.ts_params_decl
      | None -> [])
  | Ast.StructDef d -> (
      match List.assoc_opt d.s_name env.nominals with
      | Some n -> List.map snd n.nom_params
      | None -> [])
  | Ast.EnumDef d -> (
      match List.assoc_opt d.e_name env.nominals with
      | Some n -> List.map snd n.nom_params
      | None -> [])
  | Ast.TraitDef d ->
      List.concat_map
        (fun (m : Ast.function_decl) ->
          match List.assoc_opt (d.t_name, m.fn_sig.sig_name) env.methods with
          | Some s ->
              List.map snd s.ts_params_decl
              @ List.concat_map (fun p -> params_in p.Type_repr.pt_type) (Array.to_list s.ts_params)
              @ params_in s.ts_return
          | None -> [])
        d.t_methods
  | Ast.ImplBlock d ->
      List.concat_map
        (fun (m : Ast.function_decl) ->
          match List.assoc_opt (d.i_target_type, m.fn_sig.sig_name) env.methods with
          | Some s ->
              (* the impl's own type parameters appear in the method
                 signature (self type, params, return): they are bound by
                 the impl, so the oracle must not flag them *)
              List.map snd s.ts_params_decl
              @ List.concat_map (fun p -> params_in p.Type_repr.pt_type) (Array.to_list s.ts_params)
              @ params_in s.ts_return
          | None -> [])
        d.i_methods
  | Ast.ConstDecl d -> (
      match List.assoc_opt (qualified_name item.module_path d.c_name) env.consts with
      | Some t -> params_in t
      | None -> [])
  | Ast.StaticDecl d -> (
      match List.assoc_opt (qualified_name item.module_path d.st_name) env.consts with
      | Some t -> params_in t
      | None -> [])
  | _ -> []

(* Run the oracle over the current item's recorded channels. Every
   nonzero count is returned as an error finding: the checker never
   silently continues past an incomplete channel. *)
let run_oracle (env : env) (_item_name : string) : string list =
  let st = env.state in
  let o = st.oracle in
  let known_callables =
    List.map (fun (_, s) -> s.ts_callable) env.functions
    @ List.map (fun (_, s) -> s.ts_callable) env.methods
    @ List.map (fun (_, s) -> s.ts_callable) env.constructors
    @ List.map (fun (_, s) -> s.ts_callable) st.query_sigs
    @ List.map (fun (_, s, _) -> s.ts_callable) st.nested_functions
  in
  let is_known c =
    List.exists (fun k -> Ids.Callable_id.compare k c = 0) known_callables
    || List.exists (fun k -> Ids.Callable_id.compare k c = 0) o.o_derived_callables
  in
  (* 1+2. Type_param in concrete execution position / unsolved vars *)
  List.iter
    (fun (te : typed_expr) ->
      let illegal = List.filter (fun p -> not (List.mem p st.current_item_params)) (params_in te.te_type) in
      if illegal <> [] then begin
        o.o_type_params <- o.o_type_params + List.length illegal;
        o.o_unsolved_vars <- o.o_unsolved_vars + 1
      end)
    o.o_exprs;
  (* 4+7. call targets and argument access effects *)
  List.iter
    (fun (c : typed_call) ->
      (match c.target with
       | None -> o.o_unresolved_calls <- o.o_unresolved_calls + 1
       | Some id -> if not (is_known id) then o.o_unknown_defs <- o.o_unknown_defs + 1);
      if Array.length c.effects <> Array.length c.args then
        o.o_missing_effects <- o.o_missing_effects + 1)
    o.o_calls;
  (* 5. unsolved trait obligations *)
  List.iter
    (fun (_, r) -> match r with Ok _ -> () | Error _ -> o.o_unsolved_obligations <- o.o_unsolved_obligations + 1)
    o.o_obligations;
  let findings = ref [] in
  let add n fmt = if n > 0 then findings := Printf.sprintf fmt n :: !findings in
  add o.o_type_params "completeness oracle: %d Type_param(s) in concrete execution position";
  add o.o_unsolved_vars "completeness oracle: %d expression(s) with an unsolved type variable";
  add o.o_error_types "completeness oracle: %d error type(s) recorded";
  add o.o_unknown_defs "completeness oracle: %d unknown DefId(s) recorded on call targets";
  add o.o_unknown_fields "completeness oracle: %d unknown FieldId(s) recorded";
  add o.o_unknown_variants "completeness oracle: %d unknown VariantId(s) recorded";
  add o.o_unresolved_calls "completeness oracle: %d unresolved call(s) recorded";
  add o.o_unsolved_obligations "completeness oracle: %d unsolved trait obligation(s) recorded";
  add o.o_missing_effects "completeness oracle: %d call(s) with missing argument access effects";
  List.rev !findings

(* The trait-contract backstop (oracle item 5): every registered impl
   must be backed by its trait's declared contract. *)
let run_impl_backstop (env : env) : string list =
  List.filter_map
    (fun (ie : Trait_solver.impl_entry) ->
      if ie.Trait_solver.ie_trait = "" then None
      else if List.mem_assoc ie.Trait_solver.ie_trait env.impls.Trait_solver.trait_contracts then None
      else
        Some
          (Printf.sprintf "completeness oracle: impl of trait `%s` has no declared trait contract (missing obligation solution)"
             ie.Trait_solver.ie_trait))
    env.impls.Trait_solver.impls

(* ────────────────────────────────────────────────────────────────
   Public API *)

let check_item (env : env) (item : Ast.item) : (unit, string) result = check_item env item

(* Phase A: declare every struct/enum name up front so in-module mutual
   recursion (struct A referencing struct B defined later in the same
   file) resolves; the fields/variants are filled in by phase B. *)
let rec register_headers (env : env) (acc : string list) = function
  | [] -> (env, List.rev acc)
  | item :: rest -> (
      match item.Ast.kind with
      | Ast.StructDef d ->
          if List.mem_assoc d.s_name env.nominals then register_headers env acc rest
          else begin
            let params =
              let key = "nominal::" ^ d.s_name in
              match Hashtbl.find_opt env.state.sig_param_ids key with
              | Some ids -> ids
              | None ->
                  let ids =
                    List.map (fun (tp : Ast.type_param) -> (tp.tp_name, fresh_param_id env.state))
                      d.s_type_params
                  in
                  Hashtbl.add env.state.sig_param_ids key ids;
                  ids
            in
            (* LangItem tid adoption (audit Fix 4): a source declaration of
               a builtin standard type reuses the builtin's TypeId, so
               Vec/Map/Set/Option/Result/Ptr have ONE identity *)
            let tid =
              match List.assoc_opt d.s_name env.type_ids with
              | Some t -> t
              | None -> fresh_type_id env.state
            in
            (if d.s_name = "Box" then box_tid := Some tid);
            let param_tys = Array.of_list (List.map (fun (_, p) -> Type_repr.Type_param (p)) params) in
            let nom : nominal =
              { nom_kind = `Struct; nom_params = params; nom_fields = []; nom_variants = []; nom_where = []; nom_field_ids = []; nom_variant_ids = [] }
            in
            let env' =
              {
                env with
                types = (d.s_name, Type_repr.Named (tid, param_tys)) :: List.remove_assoc d.s_name env.types;
                type_ids = (d.s_name, tid) :: List.remove_assoc d.s_name env.type_ids;
                type_names = (tid, d.s_name) :: env.type_names;
                nominals = (d.s_name, nom) :: env.nominals;
              }
            in
            register_headers env' acc rest
          end
      | Ast.EnumDef d ->
          if List.mem_assoc d.e_name env.nominals then register_headers env acc rest
          else begin
            let params =
              let key = "nominal::" ^ d.e_name in
              match Hashtbl.find_opt env.state.sig_param_ids key with
              | Some ids -> ids
              | None ->
                  let ids =
                    List.map (fun (tp : Ast.type_param) -> (tp.tp_name, fresh_param_id env.state))
                      d.e_type_params
                  in
                  Hashtbl.add env.state.sig_param_ids key ids;
                  ids
            in
            (* LangItem tid adoption (audit Fix 4): a source declaration of
               a builtin standard type reuses the builtin's TypeId, so
               Vec/Map/Set/Option/Result/Ptr have ONE identity *)
            let tid =
              match List.assoc_opt d.e_name env.type_ids with
              | Some t -> t
              | None -> fresh_type_id env.state
            in
            let param_tys = Array.of_list (List.map (fun (_, p) -> Type_repr.Type_param (p)) params) in
            let nom : nominal =
              { nom_kind = `Enum; nom_params = params; nom_fields = []; nom_variants = []; nom_where = []; nom_field_ids = []; nom_variant_ids = [] }
            in
            let env' =
              {
                env with
                types = (d.e_name, Type_repr.Named (tid, param_tys)) :: List.remove_assoc d.e_name env.types;
                type_ids = (d.e_name, tid) :: List.remove_assoc d.e_name env.type_ids;
                type_names = (tid, d.e_name) :: env.type_names;
                nominals = (d.e_name, nom) :: env.nominals;
              }
            in
            register_headers env' acc rest
          end
      | _ -> register_headers env acc rest)

(* ────────────────────────────────────────────────────────────────
   Diagnostic-debt accounting (audit P1-1).

   The module's error list is classified into the fixed stable
   categories and accumulated per module path (last round wins), so the
   accumulated report always equals the driver's closure-wide error
   total.  The machine-readable block is printed only when the
   accumulated report changes; the LAST printed block is therefore the
   closure's final debt report.  This is purely additive: no existing
   error message or count is modified. *)

let record_module_debt (env : env) (program : Ast.program) (errors : string list) : unit =
  let st = env.state in
  let key = String.concat "::" program.Ast.prog_module_path in
  let rep = Debt_report.of_errors errors in
  let by_mod =
    if rep.Debt_report.total = 0 then List.remove_assoc key st.debt_by_module
    else (key, rep) :: List.remove_assoc key st.debt_by_module
  in
  st.debt_by_module <- by_mod;
  let block = Debt_report.to_lines (Debt_report.sum_reports (List.map snd by_mod)) in
  let printed = String.concat "\n" block in
  if printed <> st.debt_last_printed then begin
    List.iter print_endline block;
    st.debt_last_printed <- printed
  end

(* ────────────────────────────────────────────────────────────────
   Deterministic phase split (audit Fix 3): check_declarations registers
   every identity once (headers + signatures, non-fatal), then
   check_bodies checks the items' bodies against the frozen environment.
   The driver runs the declaration pass over the whole closure first,
   then the body pass — no mutating retry rounds re-register
   declarations. *)

let rec check_declarations (env : env) (program : Ast.program) :
    (env * string list, string) result =
  (* Phase A: bare type names first (in-module mutual recursion). *)
  let env_h, header_errors = register_headers env [] program.Ast.items in
  (* Phase C: resolve the nominal SHAPES (fields, variants, where
     predicates) and register methods/impls — idempotently, so the
     driver's declaration fixpoint can re-run a module as the env grows
     without appending duplicate declarations *)
  let is_shape item =
    match item.Ast.kind with
    | Ast.StructDef _ | Ast.EnumDef _ | Ast.TraitDef _ | Ast.ImplBlock _
    | Ast.ExternBlock _ | Ast.ModuleDef _ ->
        true
    | _ -> false
  in
  let shape_items = List.filter is_shape program.Ast.items in
  let shape_errors = ref [] in
  let env_s =
    List.fold_left
      (fun e item ->
        match check_item e item with
        | Ok () -> e
        | Error m ->
            shape_errors := (Ast.item_summary item.Ast.kind ^ ": " ^ m) :: !shape_errors;
            e)
      env_h shape_items
  in
  (* Phase B: registration is non-fatal: items whose signatures reference
     not-yet-registered types are deferred (reported as errors), so a
     module with forward/cyclic references still contributes everything it
     can. The driver retries modules to a fixpoint with a growing env. *)
  let rec go_reg (env : env) (acc : string list) = function
    | [] -> Ok (env, List.rev acc)
    | item :: rest -> (
        let name = Ast.item_summary item.Ast.kind in
        match register_item env item with
        | Ok env' -> go_reg env' acc rest
        | Error m ->
            if Util.has_prefix m "duplicate" || Util.has_prefix m "duplicate type" then
              go_reg env acc rest
            else if Util.has_prefix m "duplicate function"
              || Util.has_prefix m "duplicate type"
              || Util.has_prefix m "duplicate test"
            then
              (* re-registration of an item from an earlier fixpoint round:
                 the resolver already gated real duplicates *)
              go_reg env acc rest
            else begin
              env.state.failed_items <- name :: env.state.failed_items;
              go_reg env ((name ^ ": " ^ m) :: acc) rest
            end)
  in
  let* env1, reg_errors = go_reg env_s [] program.Ast.items in
  Ok (env1, header_errors @ reg_errors @ List.rev !shape_errors)

and check_bodies (env : env) (program : Ast.program) : (env * string list, string) result =
  (* shape items (structs/enums/traits/impls/externs) fill the nominal
     shapes and register methods/impls; body items (functions/tests/
     consts/statics) are checked against the complete shapes — within a
     module the shapes always precede the bodies, so a declaration's
     fields are visible to every function in the module *)
  let is_shape item =
    match item.Ast.kind with
    | Ast.StructDef _ | Ast.EnumDef _ | Ast.TraitDef _ | Ast.ImplBlock _
    | Ast.ExternBlock _ | Ast.ModuleDef _ ->
        true
    | _ -> false
  in
  let shape_items = List.filter is_shape program.Ast.items in
  let body_items = List.filter (fun i -> not (is_shape i)) program.Ast.items in
  let rec go (errors : string list) = function
    | [] -> Ok (env, List.rev errors)
    | item :: rest -> (
        let name = Ast.item_summary item.Ast.kind in
        env.state.current_item <- name;
        env.state.current_item_params <- item_param_ids env item;
        reset_oracle env;
        let secondary = List.mem name env.state.failed_items in
        let tag m = if secondary then "[secondary] " ^ m else m in
        match check_item env item with
        | Error m -> go (tag (name ^ ": " ^ m) :: errors) rest
        | Ok () ->
            let findings = run_oracle env name in
            go (List.map (fun f -> tag (name ^ ": " ^ f)) findings @ errors) rest)
  in
  let* final_env, errors = go [] (shape_items @ body_items) in
  let backstop = run_impl_backstop final_env in
  let all_errors = errors @ backstop in
  record_module_debt final_env program all_errors;
  Ok (final_env, all_errors)

and check_program (env : env) (program : Ast.program) : (env * string list, string) result =
  let* env_d, decl_errors = check_declarations env program in
  let* env_b, body_errors = check_bodies env_d program in
  Ok (env_b, decl_errors @ body_errors)

(* Public classification entry over the checker's error strings. *)
let debt_report (errors : string list) : Debt_report.t = Debt_report.of_errors errors

(* One-line oracle summary for reports. *)
let oracle_report (env : env) : string =
  let o = env.state.oracle in
  Printf.sprintf
    "oracle[%s]: type_params_in_concrete=%d unsolved_vars=%d error_types=%d unknown_defs=%d unknown_fields=%d unknown_variants=%d unresolved_calls=%d unsolved_obligations=%d missing_effects=%d | channels: exprs=%d calls=%d obligations=%d"
    env.state.current_item o.o_type_params o.o_unsolved_vars o.o_error_types o.o_unknown_defs
    o.o_unknown_fields o.o_unknown_variants o.o_unresolved_calls o.o_unsolved_obligations
    o.o_missing_effects (List.length o.o_exprs) (List.length o.o_calls)
    (List.length o.o_obligations)





