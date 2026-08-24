(* source.ml — Loaded source text with a single position authority.

   Positions are computed from line starts built once at construction:
   LF increments the line, CR increments the line, and the CRLF pair
   increments it exactly once. Columns are 1-based byte columns (the
   parser/lexer work on raw UTF-8 bytes; a column points at the byte
   offset within the line). *)

type source = {
  name : string;              (* logical or diagnostic name *)
  bytes : string;             (* original bytes (a leading BOM is retained) *)
  bom_len : int;              (* 0, or 3 when EF BB BF was present *)
  line_starts : int array;    (* byte offset of each line start *)
}

(* Scan line starts: LF, CR, and CRLF each begin one new line. *)
let line_starts_of (bytes : string) : int array =
  let n = String.length bytes in
  let starts = ref [ 0 ] in
  let i = ref 0 in
  while !i < n do
    let c = bytes.[!i] in
    if c = '\n' then begin
      starts := (!i + 1) :: !starts;
      incr i
    end
    else if c = '\r' then begin
      if !i + 1 < n && bytes.[!i + 1] = '\n' then i := !i + 2
      else incr i;
      if !i <= n then starts := !i :: !starts
    end
    else incr i
  done;
  Array.of_list (List.rev !starts)

let bom_len_of (bytes : string) : int =
  if String.length bytes >= 3 && bytes.[0] = '\xEF' && bytes.[1] = '\xBB' && bytes.[2] = '\xBF'
  then 3
  else 0

let of_bytes ~(name : string) ~(bytes : string) : source =
  { name; bytes; bom_len = bom_len_of bytes; line_starts = line_starts_of bytes }

(* 1-based (line, column) of a byte offset. An offset past the last line
   start resolves to a phantom line, mirroring the reference behavior. *)
let position (s : source) (offset : int) : int * int =
  let starts = s.line_starts in
  let n = Array.length starts in
  let line =
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
  in
  (line, offset - starts.(line - 1) + 1)
