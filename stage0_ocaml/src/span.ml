(* span.ml — Source spans with stable source-map identity.

   A span is a half-open byte range [start, end) into the UTF-8 bytes of a
   source. file_id = -1 marks synthetic spans (never verified, never
   resolved).

   The source map assigns each file a STABLE, monotonically increasing id
   (never derived from list position after insertion — the previous
   reversed-list implementation made every multi-file span resolve to the
   wrong file). *)

type span = {
  start : int;
  end_ : int;
  file_id : int;
}

let synthetic = { start = 0; end_ = 0; file_id = -1 }

let make start end_ file_id = { start; end_; file_id }

let is_synthetic (s : span) = s.file_id = -1

(* Structural bounds: a real span must satisfy 0 <= start <= end. *)
let is_well_ordered (s : span) =
  if is_synthetic s then true
  else s.start >= 0 && s.end_ >= s.start

(* Merge two spans of the same file. A cross-file merge is an internal
   invariant violation and must not be silently accepted. *)
let merged (a : span) (b : span) : (span, string) result =
  if is_synthetic a then Ok b
  else if is_synthetic b then Ok a
  else if a.file_id <> b.file_id then
    Error
      (Printf.sprintf "cross-file span merge: file %d [%d,%d) with file %d [%d,%d)"
         a.file_id a.start a.end_ b.file_id b.start b.end_)
  else
    Ok { start = min a.start b.start; end_ = max a.end_ b.end_; file_id = a.file_id }

let merge_exn (m : (span, string) result) : span =
  match m with
  | Ok s -> s
  | Error msg -> failwith ("internal: " ^ msg)

(* Bounds against a concrete source length. *)
let within_source (s : span) (source_len : int) =
  if is_synthetic s then true
  else s.start <= s.end_ && s.end_ <= source_len

type source_map = {
  files : (int, Source.source) Hashtbl.t;
  mutable next_id : int;
}

let create () = { files = Hashtbl.create 16; next_id = 0 }

let add_file sm (_name : string) (source : Source.source) : int =
  let id = sm.next_id in
  sm.next_id <- id + 1;
  Hashtbl.add sm.files id source;
  id

let file_of_id sm file_id =
  if file_id < 0 then None else Hashtbl.find_opt sm.files file_id

(* Resolve a span to (file name, line, column) — 1-based, via the single
   position authority in Source. *)
let resolve sm (s : span) : (string * int * int) option =
  if s.file_id < 0 then None
  else
    match Hashtbl.find_opt sm.files s.file_id with
    | None -> None
    | Some src ->
        let line, col = Source.position src s.start in
        Some (src.Source.name, line, col)
