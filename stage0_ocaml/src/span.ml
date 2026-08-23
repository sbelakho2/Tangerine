(* span.ml — Source spans and source maps.

   A span is a half-open byte range [start, end) into the UTF-8 source of a
   file, plus the file id. file_id = -1 marks synthetic spans (never
   verified, never resolved). *)

type span = {
  start : int;
  end_ : int;
  file_id : int;
}

let synthetic = { start = 0; end_ = 0; file_id = -1 }

let make start end_ file_id = { start; end_; file_id }

let is_synthetic (s : span) = s.file_id = -1

let is_well_ordered (s : span) =
  if is_synthetic s then true
  else s.start >= 0 && s.end_ >= s.start

let merged (a : span) (b : span) =
  { start = min a.start b.start; end_ = max a.end_ b.end_; file_id = a.file_id }

type file_entry = {
  name : string;
  source : string;
  line_starts : int array;
}

type source_map = {
  mutable files : file_entry list;  (* reversed *)
}

let create () = { files = [] }

let add_file sm name source =
  let len = String.length source in
  let starts = ref [ 0 ] in
  for i = 0 to len - 1 do
    if source.[i] = '\n' then starts := (i + 1) :: !starts
  done;
  let arr = Array.of_list (List.rev !starts) in
  sm.files <- { name; source; line_starts = arr } :: sm.files;
  List.length sm.files - 1

(* Find the 1-based line whose start is the greatest line start <= offset.
   Mirrors the Swift binary search (upper bound); an offset past the last
   line start resolves to a phantom line. *)
let find_line (starts : int array) (offset : int) : int =
  let n = Array.length starts in
  if n = 0 then 1
  else if offset < starts.(0) then 1
  else if offset >= starts.(n - 1) then n
  else begin
    let lo = ref 0 and hi = ref (n - 1) in
    while !hi - !lo > 1 do
      let mid = (!lo + !hi) / 2 in
      if starts.(mid) <= offset then lo := mid else hi := mid
    done;
    !lo + 1
  end

let resolve sm (s : span) : (string * int * int) option =
  if s.file_id < 0 then None
  else begin
    let files = sm.files in
    let n = List.length files in
    if s.file_id >= n then None
    else begin
      let rec pick k = function
        | f :: _ when k = 0 -> f
        | _ :: rest -> pick (k - 1) rest
        | [] -> assert false
      in
      let entry = pick s.file_id files in
      let line = find_line entry.line_starts s.start in
      let col = s.start - entry.line_starts.(line - 1) + 1 in
      Some (entry.name, line, col)
    end
  end
