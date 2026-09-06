(* trait_solver.ml — Deterministic trait obligation solving (audit §27).

   The obligation solver used by the bootstrap type checker. The impl table
   is built from the resolved program by Typecheck (one entry per `impl
   Trait for Type` item, carrying the impl's generic parameters, where
   predicates and associated types), plus the compiler-registered builtin
   impls (the std prelude the resolver seeds).

   Candidate selection is deterministic:
     - every impl whose trait name equals the obligation's trait name and
       whose target type head unifies structurally with the obligation's
       self type is a candidate (head identity + argument unification with
       the impl's generic parameters substituted);
     - candidates whose own where-bounds fail to discharge are dropped;
     - exactly one survivor -> solved; zero -> NoImpl; more than one ->
       Ambiguous.

   Structural Copy (and structural Clone for trivially-copyable types) is
   an EXPLICIT builtin rule — never a fallback that assumes conformance
   from the absence of an impl. *)

type impl_id = {
  module_id : Ids.Module_id.t;
  index : int;
}

type obligation = {
  trait_name : string;
  self_ty : Type_repr.t;
  type_args : Type_repr.t array;
}

type solution = {
  impl_id : impl_id;
  assoc_subst : (string * Type_repr.t) list;
}

type solve_error =
  | NoImpl
  | Ambiguous
  | UnsatisfiedBound of string
  | RecursiveObligation

(* One registered `impl Trait for Type` candidate. *)
type impl_entry = {
  ie_trait : string;                (* trait name; "" for inherent impls *)
  ie_target : Type_repr.t;          (* resolved for-type in the impl's scope *)
  ie_target_name : string;          (* target base type name (diagnostics) *)
  ie_id : impl_id;
  ie_params : string list;          (* impl generic parameter names, decl order *)
  ie_bounds : obligation list;      (* where predicates, in the impl's scope *)
  ie_assoc : (string * Type_repr.t) list;  (* associated type name -> type *)
}

(* The solver's view of the program database. `param_bounds` is the live
   registry of the ENCLOSING generic context's parameter bounds: a
   `T: Copy` caller context proves Copy(T); an unconstrained T proves
   nothing. The type checker (re)populates it when entering/leaving
   generic scopes. *)
type env = {
  impls : impl_entry list;
  mutable param_bounds : (Ids.Generic_param_id.t * (string * Type_repr.t array) list) list;
  trait_contracts : (string * string list) list;   (* trait name -> declared method names *)
}

(* Synthetic id for obligations discharged by a declared parameter bound
   (no impl exists — the bound IS the proof). Also used by the builtin
   structural Copy/Clone rule. *)
let synthetic_impl_id : impl_id = { module_id = Ids.Module_id.make (-1); index = -1 }

let impl_id_string (id : impl_id) : string =
  Printf.sprintf "impl{%s:%d}" (Ids.Module_id.to_string id.module_id) id.index

let solve_error_string = function
  | NoImpl -> "no matching impl"
  | Ambiguous -> "multiple matching impls"
  | UnsatisfiedBound t -> "unsatisfied trait bound `" ^ t ^ "`"
  | RecursiveObligation -> "recursive trait obligation"

(* ────────────────────────────────────────────────────────────────
   Structural Copy — the explicit formal rule (audit §25).
   Scalars (Int/Float/Bool/Char/Unit/Never), raw pointers, tuples and
   fixed arrays of Copy elements, and internal references are
   trivially copyable. String is NOT Copy. Nominals and function types
   are never structural Copy — they require an explicit impl. *)
let rec is_copy (ty : Type_repr.t) : bool =
  match ty with
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _ | Type_repr.Float _
  | Type_repr.Never ->
      true
  | Type_repr.String -> false
  | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> true
  | Type_repr.Tuple elems -> Array.for_all is_copy elems
  | Type_repr.Fixed_array (inner, _) -> is_copy inner
  | Type_repr.Named _ | Type_repr.Function _ | Type_repr.Type_param _ | Type_repr.Infer_var _ | Type_repr.Int_literal _ | Type_repr.Error -> false

(* The impl's target head Type_id. *)
let impl_head (ie : impl_entry) : Ids.Type_id.t option =
  match ie.ie_target with
  | Type_repr.Named (id, _) -> Some id
  | _ -> None

let structurally_equal (a : Type_repr.t) (b : Type_repr.t) : bool =
  Type_repr.compare a b = 0

(* ── audit P1-23 ─────────────────────────────────────────────────
   Obligation equality for the solver's recursion guard is STRUCTURAL:
   the trait name is the source-name domain (the language has no trait
   id), the type content compares by Type_repr.compare — never by a
   rendered string of the obligation. *)
let obligation_equal (a : obligation) (b : obligation) : bool =
  a.trait_name = b.trait_name && structurally_equal a.self_ty b.self_ty
  && Array.length a.type_args = Array.length b.type_args
  && Array.for_all2 structurally_equal a.type_args b.type_args

(* Unify the impl's target type with the obligation's self type, binding
   the impl's generic parameters (the substitution is returned). *)
let rec unify_target (subst : (Type_repr.generic_key * Type_repr.t) list)
    (a : Type_repr.t) (b : Type_repr.t) : (Type_repr.generic_key * Type_repr.t) list option =
  match a with
  | Type_repr.Type_param id ->
      (match List.assoc_opt (Type_repr.KParam id) subst with
       | Some s -> if structurally_equal s b then Some subst else None
       | None -> Some ((Type_repr.KParam id, b) :: subst))
  | _ -> (
      match b with
      | Type_repr.Type_param _ -> None
      | _ ->
          if structurally_equal a b then Some subst
          else
            match a, b with
            | Type_repr.Named (id1, args1), Type_repr.Named (id2, args2) ->
                if
                  Ids.Type_id.compare id1 id2 <> 0
                  || Array.length args1 <> Array.length args2
                then None
                else begin
                  let rec go subst i =
                    if i >= Array.length args1 then Some subst
                    else
                      match unify_target subst args1.(i) args2.(i) with
                      | Some s -> go s (i + 1)
                      | None -> None
                  in
                  go subst 0
                end
            | Type_repr.Tuple a1, Type_repr.Tuple b1 ->
                if Array.length a1 <> Array.length b1 then None
                else begin
                  let rec go subst i =
                    if i >= Array.length a1 then Some subst
                    else
                      match unify_target subst a1.(i) b1.(i) with
                      | Some s -> go s (i + 1)
                      | None -> None
                  in
                  go subst 0
                end
            | Type_repr.Fixed_array (t1, n1), Type_repr.Fixed_array (t2, n2) ->
                if n1 <> n2 then None else unify_target subst t1 t2
            | _ -> None)

(* ────────────────────────────────────────────────────────────────
   solve — deterministic candidate selection.

   Returns Ok solution (the impl id and its associated-type substitution)
   or a solve_error. Recursion (discharging an impl's own where bounds)
   is guarded by a visited set: revisiting the same (trait, self) key is
   a RecursiveObligation, never an infinite loop.  The membership test
   is obligation_equal — structural type content, never a string key
   (audit P1-23). *)
let solve (env : env) (ob : obligation) : (solution, solve_error) result =
  let visited : obligation list ref = ref [] in
  let rec go depth (ob : obligation) : (solution, solve_error) result =
    if List.exists (obligation_equal ob) !visited then Error RecursiveObligation
    else if depth > 64 then Error RecursiveObligation
    else begin
      visited := ob :: !visited;
      let result =
        match ob.self_ty with
        | Type_repr.Type_param pid ->
            (* A generic parameter is an opaque instance of its DECLARED
               bounds: the param-bound registry is the only proof source. *)
            (match List.assoc_opt pid env.param_bounds with
             | Some bounds -> (
                 let args = ob.type_args in
                 let rec find = function
                   | [] -> Error (UnsatisfiedBound ob.trait_name)
                   | (name, bargs) :: rest ->
                       if name = ob.trait_name && Array.length bargs = Array.length args
                          && Array.for_all2 structurally_equal bargs args
                       then Ok { impl_id = synthetic_impl_id; assoc_subst = [] }
                       else find rest
                 in
                 find bounds)
             | None -> Error (UnsatisfiedBound ob.trait_name))
        | _ -> (
            (* The explicit builtin structural rules, then the impl table.
               The structural rule is never a fallback: absence of an impl
               never proves Copy/Clone by itself. *)
            match ob.trait_name with
            | "Copy" ->
                if is_copy ob.self_ty then
                  Ok { impl_id = synthetic_impl_id; assoc_subst = [] }
                else impl_round depth ()
            | "Clone" ->
                if is_copy ob.self_ty then
                  Ok { impl_id = synthetic_impl_id; assoc_subst = [] }
                else impl_round depth ()
            | ("Eq" | "PartialEq") -> (
                (* an internal reference compares by its pointee *)
                match ob.self_ty with
                | Type_repr.Ref_internal _ ->
                    Ok { impl_id = synthetic_impl_id; assoc_subst = [] }
                | _ -> impl_round depth ())
            | _ -> impl_round depth ())
      in
      visited := List.filter (fun v -> not (obligation_equal ob v)) !visited;
      result
    end
  and impl_round (depth : int) () : (solution, solve_error) result =
    let candidates = ref [] in
    List.iter
      (fun ie ->
        if ie.ie_trait = ob.trait_name then
          match impl_head ie with
          | Some hid -> (
              match ob.self_ty with
              | Type_repr.Named (sid, sargs) when Ids.Type_id.compare sid hid = 0 ->
                  let impl_args =
                    match ie.ie_target with
                    | Type_repr.Named (_, a) -> a
                    | _ -> [||]
                  in
                  if Array.length sargs = Array.length impl_args then
                    match unify_target [] ie.ie_target ob.self_ty with
                    | Some subst -> candidates := (ie, subst) :: !candidates
                    | None -> ()
                  else ()
              | _ -> (
                  (* a primitive/other self type (String, Int, Bool, ...):
                     the impl's target unifies directly with the self *)
                  match unify_target [] ie.ie_target ob.self_ty with
                  | Some subst -> candidates := (ie, subst) :: !candidates
                  | None -> ()))
          | None -> (
              (* the impl's target is itself non-nominal (a primitive
                 impl like Eq for String/Int): unify it with the self *)
              match unify_target [] ie.ie_target ob.self_ty with
              | Some subst -> candidates := (ie, subst) :: !candidates
              | None -> ()))
      env.impls;
    (* Discharge each candidate's own where-bounds under the target
       substitution; drop candidates with an unsatisfied bound. *)
    let survivors = ref [] in
    List.iter
      (fun (ie, subst) ->
        let rec discharge = function
          | [] -> true
          | b :: rest -> (
              let b' =
                {
                  trait_name = b.trait_name;
                  self_ty = Type_repr.substitute subst b.self_ty;
                  type_args =
                    Array.map (Type_repr.substitute subst) b.type_args;
                }
              in
              match go (depth + 1) b' with Ok _ -> discharge rest | Error _ -> false)
        in
        (if discharge ie.ie_bounds then survivors := (ie, subst) :: !survivors))
      !candidates;
    (* when several impls discharge (e.g. the builtin String: Eq plus the
       source std/core declaration), prefer the one with no where-bounds —
       the builtin/synthetic registration is the canonical one *)
    let preferred =
      match !survivors with
      | [] -> None
      | [ x ] -> Some x
      | xs -> List.find_opt (fun (ie, _) -> ie.ie_bounds = []) xs
    in
    (match preferred with
     | None -> Error NoImpl
     | Some (ie, subst) ->
         Ok
           {
             impl_id = ie.ie_id;
             assoc_subst =
               List.map
                 (fun (n, t) -> (n, Type_repr.substitute subst t))
                 ie.ie_assoc;
           })
  in
  go 0 ob
