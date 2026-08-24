(* access_check.ml — The access-conflict matrix (audit §29, §64).

   A place is (root local, projection chain). Conflicts are determined by
   the effect pair and the place relationship; distinct fixed fields are
   disjoint, dynamic indexes stay conservative (overlap).

   The post-resolution access representation is FieldId-based ONLY: the
   kernel resolver assigns FieldIds (Ids.Field_id.make; see ids.ml) and
   Seed MIR projects with `Field of Ids.Field_id.t` (mir_verify.ml), so
   there is no name-keyed projection. *)

type projection =
  | Field of Ids.Field_id.t
  | Index
  | Deref

type access_path = {
  root : int;
  projections : projection list;
}

type conflict = {
  path_a : access_path;
  effect_a : Access_effect.read_effect;
  path_b : access_path;
  effect_b : Access_effect.read_effect;
}

(* The effect pair matrix (audit §64). *)
let effects_conflict (a : Access_effect.read_effect) (b : Access_effect.read_effect) : bool =
  match a, b with
  | Access_effect.Read, Access_effect.Read -> false
  | Access_effect.Read, Access_effect.Modify -> true
  | Access_effect.Read, Access_effect.Consume -> true
  | Access_effect.Read, Access_effect.Initialize -> true
  | Access_effect.Modify, Access_effect.Modify -> true
  | Access_effect.Modify, Access_effect.Consume -> true
  | Access_effect.Modify, Access_effect.Initialize -> true
  | Access_effect.Consume, Access_effect.Consume -> true
  | Access_effect.Consume, Access_effect.Initialize -> true
  | Access_effect.Initialize, Access_effect.Initialize -> true
  | Access_effect.Modify, Access_effect.Read -> true
  | Access_effect.Consume, Access_effect.Read -> true
  | Access_effect.Consume, Access_effect.Modify -> true
  | Access_effect.Initialize, Access_effect.Read -> true
  | Access_effect.Initialize, Access_effect.Modify -> true
  | Access_effect.Initialize, Access_effect.Consume -> true

(* Same root local. *)
let same_root (a : access_path) (b : access_path) = a.root = b.root

(* Disjoint fixed-field prefixes: x.a vs x.b with a <> b — disjoint.
   Any dynamic component (Index/Deref) is conservative (overlap). *)
let rec disjoint_projs (pa : projection list) (pb : projection list) : bool option =
  match pa, pb with
  | [], _ | _, [] -> None (* prefixes — overlap *)
  | Field fa :: ra, Field fb :: rb ->
      if Ids.Field_id.compare fa fb = 0 then disjoint_projs ra rb
      else Some true
  | (Index | Deref) :: _, _ | _, (Index | Deref) :: _ -> None (* conservative *)

let places_conflict (a : access_path) (b : access_path) : bool =
  if not (same_root a b) then false
  else begin
    match disjoint_projs a.projections b.projections with
    | Some true -> false
    | _ -> true
  end

(* Check a set of argument accesses; returns the first conflict.

   Pairwise conflict checking applies ONLY to DISTINCT argument accesses
   (i <> j): a single access never conflicts with itself, so a lone
   Consume (Sink) argument `f(sink x)` is accepted — there is no second
   overlapping access to conflict with. *)
let check_call_args (accesses : (access_path * Access_effect.read_effect) array) :
    (unit, conflict) result =
  let n = Array.length accesses in
  let rec outer i =
    if i >= n then Ok ()
    else begin
      let (pa, ea) = accesses.(i) in
      let rec inner j =
        if j >= n then outer (i + 1)
        else begin
          let (pb, eb) = accesses.(j) in
          if i <> j && places_conflict pa pb && effects_conflict ea eb then
            Error { path_a = pa; effect_a = ea; path_b = pb; effect_b = eb }
          else inner (j + 1)
        end
      in
      inner i
    end
  in
  outer 0

let effects_of_convention (c : Access_effect.t) : Access_effect.read_effect =
  match c with
  | Access_effect.Let -> Access_effect.Read
  | Access_effect.Inout -> Access_effect.Modify
  | Access_effect.Sink -> Access_effect.Consume
  | Access_effect.Set -> Access_effect.Initialize
