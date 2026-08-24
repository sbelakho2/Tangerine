(* unicode.ml — Identifier classes and normalization.

   Bootstrap-profile decision (documented, machine-enforced in the subset
   profile): identifiers outside the ASCII range are EXCLUDED from the
   bootstrap profile. The manifest closure (37 files) is ASCII-only;
   non-ASCII identifiers are hard-rejected at lex time so the seed and
   self-host cannot silently diverge on identifier tables.

   The generated Unicode XID/NFC tables (generated/unicode_xid.ml,
   generated/unicode_nfc.ml, generated from the same pinned Unicode data as
   the Tangerine compiler) can replace the ASCII predicates below; the
   interface is identical. *)

let is_xid_start (u : Uchar.t) : bool =
  let c = Uchar.to_int u in
  (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c = 0x5F

let is_xid_continue (u : Uchar.t) : bool =
  let c = Uchar.to_int u in
  is_xid_start u || (c >= 0x30 && c <= 0x39)

(* NFC normalization: the bootstrap profile is ASCII-only, for which NFC
   is the identity. This is the documented exclusion boundary. *)
let identifier_nfc (s : string) : string = s

(* Bidi override/isolate scan: reject sources containing bidi control
   characters before lexing (they can disguise code). *)
let has_bidi_control (s : string) : bool =
  let bad =
    [ 0x061C (* ALM *); 0x200E (* LRE *); 0x200F (* RLE *); 0x202A (* LRE *);
      0x202B (* RLE *); 0x202C (* PDF *); 0x202D (* LRO *); 0x202E (* RLO *);
      0x2066 (* LRI *); 0x2067 (* RLI *); 0x2068 (* FSI *); 0x2069 (* PDI *) ]
  in
  let bytes = Bytes.of_string s in
  let n = String.length s in
  let i = ref 0 in
  let found = ref false in
  while !i < n && not !found do
    match Utf8.decode_at bytes !i with
    | Ok (u, next) ->
        if List.mem (Uchar.to_int u) bad then found := true;
        i := next
    | Error _ -> incr i
  done;
  !found
