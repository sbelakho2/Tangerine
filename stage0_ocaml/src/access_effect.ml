(* access_effect.ml — The four access effects (audit §29). *)

type t = Let | Inout | Sink | Set

let compare (a : t) (b : t) =
  match a, b with
  | Let, Let -> 0 | Inout, Inout -> 0 | Sink, Sink -> 0 | Set, Set -> 0
  | Let, _ -> -1 | _, Let -> 1
  | Inout, _ -> -1 | _, Inout -> 1
  | Sink, _ -> -1 | _, Sink -> 1

let to_string = function
  | Let -> "let"
  | Inout -> "inout"
  | Sink -> "sink"
  | Set -> "set"

(* The read-side of each convention. *)
type read_effect = Read | Modify | Consume | Initialize

let read_effect = function
  | Let -> Read
  | Inout -> Modify
  | Sink -> Consume
  | Set -> Initialize

let compare_read (a : read_effect) (b : read_effect) =
  match a, b with
  | Read, Read -> 0 | Modify, Modify -> 0 | Consume, Consume -> 0 | Initialize, Initialize -> 0
  | Read, _ -> -1 | _, Read -> 1
  | Modify, _ -> -1 | _, Modify -> 1
  | Consume, _ -> -1 | _, Consume -> 1
