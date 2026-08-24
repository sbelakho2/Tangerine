(* type_repr.ml — Bootstrap type representation (audit §25).

   Concrete, post-resolution types. There is NO Unknown: if a type is not
   known at lowering time, lowering is forbidden. *)

type int_kind =
  | I8 | I16 | I32 | I64 | I128
  | U8 | U16 | U32 | U64 | U128
  | Int | UInt

type float_kind = F32 | F64

type mutability = Immutable | Mutable

type param_type = {
  pt_convention : Access_effect.t;
  pt_type : t;
}

and t =
  | Unit
  | Bool
  | Char
  | Int of int_kind
  | Float of float_kind
  | String
  | Raw_ptr of mutability * t
  | Ref_internal of mutability * t
  | Tuple of t array
  | Fixed_array of t * int
  | Named of int * t array
  | Function of param_type array * t
  | Type_param of int
  | Never

(* Lexicographic array comparison over an element comparator (standalone
   so it stays polymorphic — never part of the recursive group). *)
let compare_arrays cmp a b =
  let n = Array.length a and m = Array.length b in
  let rec go i =
    if i >= n && i >= m then 0
    else if i >= n then -1
    else if i >= m then 1
    else
      let c = cmp a.(i) b.(i) in
      if c <> 0 then c else go (i + 1)
  in
  go 0

let rec compare (a : t) (b : t) : int =
  match a, b with
  | Unit, Unit -> 0
  | Bool, Bool -> 0
  | Char, Char -> 0
  | Int k1, Int k2 -> Stdlib.compare k1 k2
  | Float k1, Float k2 -> Stdlib.compare k1 k2
  | String, String -> 0
  | Raw_ptr (m1, t1), Raw_ptr (m2, t2) ->
      let c = Stdlib.compare m1 m2 in if c <> 0 then c else compare t1 t2
  | Ref_internal (m1, t1), Ref_internal (m2, t2) ->
      let c = Stdlib.compare m1 m2 in if c <> 0 then c else compare t1 t2
  | Tuple a1, Tuple a2 -> compare_arrays compare a1 a2
  | Fixed_array (t1, n1), Fixed_array (t2, n2) ->
      let c = Stdlib.compare n1 n2 in if c <> 0 then c else compare t1 t2
  | Named (i1, a1), Named (i2, a2) ->
      let c = Stdlib.compare i1 i2 in if c <> 0 then c else compare_arrays compare a1 a2
  | Function (p1, r1), Function (p2, r2) ->
      let c = compare_arrays compare_param p1 p2 in
      if c <> 0 then c else compare r1 r2
  | Type_param i1, Type_param i2 -> Stdlib.compare i1 i2
  | Never, Never -> 0
  | Unit, _ -> -1 | _, Unit -> 1
  | Bool, _ -> -1 | _, Bool -> 1
  | Char, _ -> -1 | _, Char -> 1
  | Int _, _ -> -1 | _, Int _ -> 1
  | Float _, _ -> -1 | _, Float _ -> 1
  | String, _ -> -1 | _, String -> 1
  | Raw_ptr _, _ -> -1 | _, Raw_ptr _ -> 1
  | Ref_internal _, _ -> -1 | _, Ref_internal _ -> 1
  | Tuple _, _ -> -1 | _, Tuple _ -> 1
  | Fixed_array _, _ -> -1 | _, Fixed_array _ -> 1
  | Named _, _ -> -1 | _, Named _ -> 1
  | Function _, _ -> -1 | _, Function _ -> 1
  | Type_param _, _ -> -1 | _, Type_param _ -> 1

and compare_param (a : param_type) (b : param_type) =
  let c = Access_effect.compare a.pt_convention b.pt_convention in
  if c <> 0 then c else compare a.pt_type b.pt_type

(* Substitute type parameters (used by monomorphization). *)
let rec substitute (subst : (int * t) list) (ty : t) : t =
  match ty with
  | Type_param id -> (
      match List.assoc_opt id subst with
      | Some s -> s
      | None -> ty)
  | Raw_ptr (m, inner) -> Raw_ptr (m, substitute subst inner)
  | Ref_internal (m, inner) -> Ref_internal (m, substitute subst inner)
  | Tuple elems -> Tuple (Array.map (substitute subst) elems)
  | Fixed_array (inner, n) -> Fixed_array (substitute subst inner, n)
  | Named (id, args) -> Named (id, Array.map (substitute subst) args)
  | Function (params, ret) ->
      Function
        ( Array.map (fun p -> { p with pt_type = substitute subst p.pt_type }) params,
          substitute subst ret )
  | Unit | Bool | Char | Int _ | Float _ | String | Never -> ty

let rec has_type_param (ty : t) : bool =
  match ty with
  | Type_param _ -> true
  | Raw_ptr (_, i) | Ref_internal (_, i) | Fixed_array (i, _) -> has_type_param i
  | Tuple elems | Named (_, elems) -> Array.exists has_type_param elems
  | Function (params, ret) ->
      Array.exists (fun p -> has_type_param p.pt_type) params || has_type_param ret
  | Unit | Bool | Char | Int _ | Float _ | String | Never -> false
