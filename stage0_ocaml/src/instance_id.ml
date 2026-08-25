(* instance_id.ml — The generic-instance identity (audit §12).

   Moved out of ids.ml: Instance_id is the only ID domain that carries
   Type_repr values, so it must sit ABOVE Type_repr in the module
   dependency graph (ids_core -> Type_repr -> Instance_id), never
   underneath it. *)

type t = { callable : Ids_core.Callable_id.t; type_args : Type_repr.t array }

let make ~callable ~type_args = { callable; type_args }

let callable (t : t) = t.callable

let type_args (t : t) = t.type_args

let compare (a : t) (b : t) =
  let c = Ids_core.Callable_id.compare a.callable b.callable in
  if c <> 0 then c
  else
    let n = Array.length a.type_args in
    let m = Array.length b.type_args in
    let rec cmp i =
      if i >= n && i >= m then 0
      else if i >= n then -1
      else if i >= m then 1
      else
        let c = Type_repr.compare a.type_args.(i) b.type_args.(i) in
        if c <> 0 then c else cmp (i + 1)
    in
    cmp 0
