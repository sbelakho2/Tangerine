(* vm_value.ml — VM values with the slot-state ownership checker
   (audit §31, §37, §39).

   Values are immutable trees.  The seed's only heap-like objects are
   region-backed references (`Ref (Region p)` — the computed-value refs);
   their regions are freed by the recursive drop glue (see drop_glue). *)

(* The persistent structural-hash index for the runtime Map/Set stores
   (see the store note below): an int-keyed balanced tree is immutable,
   so two store values never share mutable state — the seed's value
   trees stay freely shareable. *)
module Int_map = Map.Make (Int)

(* ── Byte-copy instrumentation (diagnostic; TANGERINE_DEBUG_STEPS) ──
   Counts the element copies the growable-array and store-rewrite paths
   perform, so a profile can name the quadratic copy volume.  The
   counters are pure accounting: they never influence evaluation. *)
let prof_copies = ref 0
let prof_push_copies = ref 0
let prof_set_copies = ref 0
let prof_pushes = ref 0
let prof_map_scans = ref 0
let prof_set_scans = ref 0

type t =
  | Unit
  | Bool of bool
  | Int of Int_value.t
  | Float32 of int32
  | Float64 of int64
  | Char of Uchar.t
  | String of string
  | Tuple of t array
  | Struct of t array
  | Enum of int * t array          (* variant index, payload *)
  | Array of arr
  | Set of set_store               (* the runtime Set: order + hash index *)
  | Map of map_store               (* the runtime Map: order + hash index *)
  | Function of Instance_id.t
  | Closure of Instance_id.t * t array
  | RawPtr of Vm_memory.pointer
  | Ref of ref_target
  | Null
  | MovedOut
  (* re-audit P12: the partial-move HOLE — the projected component of a
     moved-out aggregate.  Reads of the hole trap (defense-in-depth —
     the verifier's moved lattice already blocks the path), and the
     drop glue skips it, so a moved-out field never double-drops.

     ── The growable array (the push/append amortization) ────────────
     A value is { cell; len }: the logical content is cell.data[0..len)
     and `cell.high` is the highest logical length any view of this
     cell has written.  Appending to a view whose len = cell.high writes
     at index high and bumps high (the spare capacity makes it amortized
     O(1)); appending to a shorter view FORKS a private cell (the slots
     >= len may be another view's content — never overwritten).  Since
     every view reads only indices < its own len and the frontier write
     lands at high >= every view's len, no alias can ever observe an
     in-place append: value semantics is preserved with NO uniqueness
     analysis.  Element writes / insert / remove / slice / clone fork a
     private cell, exactly the old whole-array copy. *)
and arr = { cell : arr_cell; len : int }
and arr_cell = {
  mutable data : t array;
  mutable high : int;              (* written frontier: len <= high <= capacity *)
  (* `owned` is false as soon as a second holder of this cell may exist
     (a Read/borrow binding, a Read/Copy operand that stores the value,
     a closure-capture binding, a projected move out of an aggregate).
     An owned cell's only holder is the place a direct element write
     reads and writes back, so the write may mutate `data` in place —
     no other binding can observe it.  Forked cells start owned. *)
  mutable owned : bool;
}

(* ── The hash-indexed Map/Set stores ─────────────────────────────────
   The runtime Map/Set keep their INSERTION ORDER as the iteration
   authority (entries()/the record-visit walk/report rows are
   order-deterministic — the old representation was a plain pair list),
   and carry an IMMUTABLE structural-hash index (hash -> bucket of
   entries sharing it) so contains/get/insert are O(log n) instead of
   the association-list walk's O(n).  The kernel's per-node tables
   (typed channels, subst, name indexes) grow to tens of thousands of
   entries, and every list walk made building them quadratic — the
   seed VM's dominant merged-phase hotspot.

   Semantics are exactly the list's: keys are compared with lookup_eq
   (never a resource-carrier Eq — see the host's collection note),
   replacement PRESERVES the stored key object and the entry's
   position, removal drops only the matched entry, and iteration is
   insertion order.  Every mutation returns a NEW store: the old value
   keeps its own order/index, so the seed's structural sharing (write-
   back replacements, snapshot clones) is never observably aliased. *)
and map_store = {
  map_front : (t * t) list;            (* OLDEST first — the drain/iteration front *)
  map_back : (t * t) list;             (* NEWEST first — the O(1) insert end *)
  map_index : (t * t) list Int_map.t;  (* structural hash -> bucket *)
  map_count : int;
}
and set_store = {
  set_front : t list;                  (* OLDEST first — the drain/iteration front *)
  set_back : t list;                   (* NEWEST first — the O(1) insert end *)
  set_index : t list Int_map.t;        (* structural hash -> bucket *)
  set_count : int;
}

(* Reference targets (the audit's real-references rule):
   - `Place (frame, key, projections)` — a REAL reference: the target is
     a live place in an execution frame; key >= 0 indexes the frame's
     locals, key < 0 the frame's statics slot (-1 - index — seed_mir.ml's
     Local | Static root convention), so a `&STATIC` reference reaches
     the global slot.  Reads resolve to the target place and writes
     through a RefMut resolve to it and write there;
   - `Region p` — a computed-value reference (the source had no place,
     e.g. `&*ptr`): the value is kept as a copy in a fresh region; reads
     load the serialized copy back, and WRITES THROUGH IT ARE A
     DETERMINISTIC TRAP (no silent divergence). *)
and ref_target =
  | Place of frame * int * Seed_mir.projection list
  | Region of Vm_memory.pointer

(* An execution frame identity.  A real reference records the target
   frame RECORD (not a name): the record lives as long as any value
   references it, so reads/writes through the ref always reach the exact
   frame that created it — including refs passed down into callees. *)
and frame = {
  fn : int;
  locals : slot array;
  statics : slot array;  (* the GLOBAL storage: index = -1 - place.local *)
  mutable block : int;
  mutable stmt : int;
}

and slot =
  | Uninitialized
  | Live of t
  | Moved
  | Dropped

(* ── The growable-array surface ─────────────────────────────────────
   All access goes through these helpers so no caller can read a slot at
   or beyond a view's logical length (the frontier invariant at the type
   note above).  `arr_push` is the ONLY operation that may grow in
   place; it writes at the shared cell's written frontier, which is at
   or beyond every view's logical length, so no other view can observe
   it.  Element writes, insert/remove/slice/clone fork a private cell
   (the same whole-array copy the previous representation performed). *)

let arr_length (a : arr) : int = a.len

let arr_get (a : arr) (i : int) : t = a.cell.data.(i)

let arr_of_array (xs : t array) : arr =
  { cell = { data = xs; high = Array.length xs; owned = true };
    len = Array.length xs }

(* mark a value as possibly held by a second binding: in-place writes
   through the top-level array become illegal (they would alias) *)
let arr_mark_shared_value (v : t) : unit =
  match v with Array a -> a.cell.owned <- false | _ -> ()

let arr_mark_shared (a : arr) : unit = a.cell.owned <- false

let arr_empty : arr = arr_of_array [||]

let arr_of_list (xs : t list) : arr = arr_of_array (Array.of_list xs)

(* value constructors for the array payload (the ergonomic shorthand) *)
let array (xs : t array) : t = Array (arr_of_array xs)

let array_of_list (xs : t list) : t = Array (arr_of_list xs)

let arr_to_list (a : arr) : t list =
  let rec go i acc = if i < 0 then acc else go (i - 1) (a.cell.data.(i) :: acc) in
  go (a.len - 1) []

let arr_to_array (a : arr) : t array = Array.sub a.cell.data 0 a.len

let arr_iter (f : t -> unit) (a : arr) : unit =
  for i = 0 to a.len - 1 do
    f a.cell.data.(i)
  done

let arr_iteri (f : int -> t -> unit) (a : arr) : unit =
  for i = 0 to a.len - 1 do
    f i a.cell.data.(i)
  done

let arr_exists (f : t -> bool) (a : arr) : bool =
  let rec go i = i < a.len && (f a.cell.data.(i) || go (i + 1)) in
  go 0

let arr_for_all (f : t -> bool) (a : arr) : bool =
  let rec go i = i >= a.len || (f a.cell.data.(i) && go (i + 1)) in
  go 0

let arr_equal_seq (eq : t -> t -> bool) (a : arr) (b : arr) : bool =
  a.len = b.len
  &&
  let rec go i = i >= a.len || (eq a.cell.data.(i) b.cell.data.(i) && go (i + 1)) in
  go 0

let arr_fold_left (f : 'a -> t -> 'a) (init : 'a) (a : arr) : 'a =
  let acc = ref init in
  for i = 0 to a.len - 1 do
    acc := f !acc a.cell.data.(i)
  done;
  !acc

(* frontier append: in place when this view owns the written frontier
   (len = high), else a private fork of the prefix *)
let arr_push (a : arr) (v : t) : arr =
  let c = a.cell in
  if a.len = c.high then begin
    if c.high >= Array.length c.data then begin
      let cap = max 4 (2 * Array.length c.data) in
      let data' = Array.make cap v in
      Array.blit c.data 0 data' 0 c.high;
      prof_copies := !prof_copies + c.high;
      prof_push_copies := !prof_push_copies + c.high;
      c.data <- data'
    end
    else c.data.(c.high) <- v;
    c.high <- c.high + 1;
    { cell = c; len = a.len + 1 }
  end
  else begin
    let data' = Array.make (a.len + 1) v in
    Array.blit c.data 0 data' 0 a.len;
    prof_copies := !prof_copies + a.len;
    prof_push_copies := !prof_push_copies + a.len;
    { cell = { data = data'; high = a.len + 1; owned = true }; len = a.len + 1 }
  end

let arr_pop (a : arr) : t option * arr =
  if a.len = 0 then (None, a)
  else begin
    let last = a.cell.data.(a.len - 1) in
    (* the element leaves the container: another holder of the
       container still holds it under value semantics *)
    arr_mark_shared_value last;
    (Some last, { cell = a.cell; len = a.len - 1 })
  end

let arr_set (a : arr) (i : int) (v : t) : arr =
  let data = Array.sub a.cell.data 0 a.len in
  prof_copies := !prof_copies + a.len;
  prof_set_copies := !prof_set_copies + a.len;
  data.(i) <- v;
  { cell = { data; high = a.len; owned = true }; len = a.len }

(* The direct element write: an owned cell has exactly one holder — the
   place the write reads and writes back — so the element may be
   replaced in `data` with no observable alias.  A non-owned cell takes
   the fork path (the old whole-array copy). *)
let arr_set_direct (a : arr) (i : int) (v : t) : arr =
  if a.cell.owned then begin
    a.cell.data.(i) <- v;
    a
  end
  else arr_set a i v

let arr_append (a : arr) (b : arr) : arr =
  let n = a.len and m = b.len in
  let data = Array.make (n + m) (if n > 0 then a.cell.data.(0) else Unit) in
  Array.blit a.cell.data 0 data 0 n;
  Array.blit b.cell.data 0 data n m;
  arr_of_array data

let arr_sub (a : arr) (pos : int) (n : int) : arr =
  arr_of_array (Array.sub a.cell.data pos n)

let arr_make (n : int) (v : t) : arr = arr_of_array (Array.make n v)

let arr_truncate (a : arr) (n : int) : arr = arr_sub a 0 n

let arr_remove (a : arr) (i : int) : arr =
  let n = a.len in
  arr_append (arr_sub a 0 i) (arr_sub a (i + 1) (n - i - 1))

let arr_insert (a : arr) (i : int) (v : t) : arr =
  let n = a.len in
  arr_append (arr_sub a 0 i) (arr_append (arr_of_array [| v |]) (arr_sub a i (n - i)))

type slot_error =
  | ReadMoved
  | ReadUninitialized
  | MoveMoved
  | SlotOob of int
  | DropDropped
  | InitializeLive
  | InitializeDropped

let slot_error_string = function
  | ReadMoved -> "read of a moved slot"
  | ReadUninitialized -> "read of an uninitialized slot"
  | SlotOob i -> "static slot out of bounds: " ^ string_of_int i
  | MoveMoved -> "move of a moved slot"
  | DropDropped -> "drop of a dropped slot"
  | InitializeLive -> "initialization of a live slot"
  | InitializeDropped -> "initialization of a dropped slot"

(* Read: requires Live (or Uninitialized for non-owned scalars — the
   caller decides; this checker is strict for owned values). *)
let read_slot (s : slot) : (t, slot_error) result =
  match s with
  | Live v -> Ok v
  | Moved -> Error ReadMoved
  | Dropped -> Error ReadMoved
  | Uninitialized -> Error ReadUninitialized

let move_slot (s : slot) : (t * slot, slot_error) result =
  match s with
  | Live v -> Ok (v, Moved)
  | Moved -> Error MoveMoved
  | Dropped -> Error MoveMoved
  | Uninitialized -> Error ReadUninitialized

let drop_slot (s : slot) : (slot, slot_error) result =
  match s with
  | Live _ -> Ok Dropped
  | Dropped -> Error DropDropped
  | Moved -> Ok Moved
  | Uninitialized -> Ok Uninitialized

let init_slot (s : slot) (v : t) : (slot, slot_error) result =
  match s with
  | Live _ -> Error InitializeLive
  | Dropped -> Error InitializeDropped
  | Uninitialized | Moved -> Ok (Live v)

(* Assign semantics: overwrite a live slot, initialize an empty one. *)
let write_slot (s : slot) (v : t) : (slot, slot_error) result =
  match s with
  | Live _ | Uninitialized | Moved -> Ok (Live v)
  | Dropped -> Error InitializeDropped

(* Machine-readable slot state (self-check helper). *)
let slot_state (s : slot) : string =
  match s with
  | Uninitialized -> "uninitialized"
  | Live _ -> "live"
  | Moved -> "moved"
  | Dropped -> "dropped"

(* ── Structural helpers ─────────────────────────────────────────── *)

let rec equal (a : t) (b : t) : bool =
  match a, b with
  | Unit, Unit -> true
  | Bool x, Bool y -> x = y
  | Int x, Int y -> Int_value.compare_vals x y = 0
  | Float32 x, Float32 y -> Int32.compare x y = 0
  | Float64 x, Float64 y -> Int64.compare x y = 0
  | Char x, Char y -> Uchar.equal x y
  | String x, String y -> x = y
  | Tuple x, Tuple y | Struct x, Struct y ->
      Array.length x = Array.length y && Array.for_all2 equal x y
  | Array x, Array y -> arr_equal_seq equal x y
  | Enum (i, x), Enum (j, y) -> i = j && Array.length x = Array.length y && Array.for_all2 equal x y
  | Function a, Function b -> Instance_id.compare a b = 0
  | Closure (a, ca), Closure (b, cb) ->
      Instance_id.compare a b = 0 && Array.length ca = Array.length cb && Array.for_all2 equal ca cb
  | RawPtr a, RawPtr b ->
      a.Vm_memory.region = b.Vm_memory.region && a.Vm_memory.offset = b.Vm_memory.offset
  | Ref a, Ref b -> (
      match a, b with
      | Place (f1, l1, p1), Place (f2, l2, p2) ->
          f1 == f2 && l1 = l2 && p1 = p2
      | Region p1, Region p2 ->
          p1.Vm_memory.region = p2.Vm_memory.region && p1.Vm_memory.offset = p2.Vm_memory.offset
      | _ -> false)
  | Null, Null -> true
  | _ -> false

(* ── Structural hash for the store indexes ───────────────────────────

   The hash must be CONSISTENT with equal: equal a b implies hash a =
   hash b (a hash collision is fine, a miss is not).  Every constructor
   mirrors equal's comparison key: Int hashes the canonical bits (the
   Int_value invariant already sign/zero-extends width <= 64), Float
   hashes the compared bit pattern, RawPtr/Ref(Region) hash only the
   (region, offset) pair equal compares, and the physical-equality /
   never-equal shapes (Ref(Place), Function, Closure, Set, Map) hash to
   a constant — equal never holds for them, so a constant is exact. *)
let mix (a : int) (b : int) : int =
  let a = a * 0x9E3779B1 in
  (a lxor b) land 0x3FFFFFFF

let rec value_hash (v : t) : int =
  match v with
  | Unit -> 1
  | Bool b -> if b then 3 else 2
  | Int i -> mix (Int64.to_int i.Int_value.bits_lo) (Int64.to_int i.Int_value.bits_hi)
  | Float32 f -> mix 5 (Int32.to_int f)
  | Float64 f -> mix 7 (Int64.to_int f)
  | Char c -> mix 11 (Uchar.to_int c)
  | String s -> mix 13 (Hashtbl.hash s)
  | Tuple elems | Struct elems -> mix 17 (array_hash elems)
  | Array elems -> mix 17 (arr_hash elems)
  | Enum (tag, payload) -> mix 19 (mix tag (array_hash payload))
  | RawPtr p -> mix 29 (mix p.Vm_memory.region p.Vm_memory.offset)
  | Ref (Region p) -> mix 31 (mix p.Vm_memory.region p.Vm_memory.offset)
  | Null -> 41
  | MovedOut -> 43
  | Ref (Place _) | Function _ | Closure _ | Set _ | Map _ -> 47

and array_hash (elems : t array) : int =
  let h = ref 23 in
  Array.iter (fun e -> h := mix !h (value_hash e)) elems;
  !h

and arr_hash (elems : arr) : int =
  let h = ref 23 in
  arr_iter (fun e -> h := mix !h (value_hash e)) elems;
  !h

(* ── The collection-lookup equality (audit P0-11) ─────────────────────

   Moved here from the host: structural equality must NEVER report an
   arbitrary resource-containing aggregate as Eq — the seed's one OWNED
   value shape is a region-backed ref (Ref (Region p)), and a purely
   structural comparison over aggregates carrying such refs would
   equate distinct owners (or alias copies) and let containment invent a
   false positive.  The lookup equality therefore REFUSES — returns
   false — as soon as either side contains a region-backed ref anywhere
   in its tree (fail-closed).  Non-resource values compare structurally. *)
let rec has_owned_ref (v : t) : bool =
  match v with
  | Tuple elems | Struct elems | Enum (_, elems) ->
      Array.exists has_owned_ref elems
  | Array elems -> arr_exists has_owned_ref elems
  | Set s ->
      List.exists has_owned_ref s.set_front || List.exists has_owned_ref s.set_back
  | Map m ->
      List.exists (fun (k, v) -> has_owned_ref k || has_owned_ref v) m.map_front
      || List.exists (fun (k, v) -> has_owned_ref k || has_owned_ref v) m.map_back
  | Closure (_, caps) -> Array.exists has_owned_ref caps
  | Ref (Region _) -> true
  | Unit | Bool _ | Int _ | Float32 _ | Float64 _ | Char _ | String _
  | Function _ | RawPtr _ | Ref (Place _) | Null | MovedOut ->
      false

let lookup_eq (a : t) (b : t) : bool =
  not (has_owned_ref a) && not (has_owned_ref b) && equal a b

(* ── The store surface (see the store note at the type) ────────────── *)

let map_empty : t =
  Map { map_front = []; map_back = []; map_index = Int_map.empty; map_count = 0 }

let set_empty : t =
  Set { set_front = []; set_back = []; set_index = Int_map.empty; set_count = 0 }

let bucket_mem_key (bucket : (t * t) list) (key : t) : (t * t) option =
  List.find_opt (fun (k, _) -> lookup_eq k key) bucket

(* The store's canonical pair/element sequence: oldest-first insertion
   order (front @ reversed back).  The queue split keeps insertion O(1)
   while the iteration, visit and drain interfaces keep the original
   list's order EXACTLY (entries() and drain both walk oldest-first). *)
let map_seq (m : map_store) : (t * t) list = m.map_front @ List.rev m.map_back
let set_seq (s : set_store) : t list = s.set_front @ List.rev s.set_back

(* insert with the container contract: an existing lookup_eq-equal key
   keeps its STORED key object and its position; the value is replaced
   (the displaced value is reported to the caller for the language's
   Option[old V]).  A fresh key is appended at the back (O(1)). *)
let map_insert_entry (m : map_store) (key : t) (value : t) : t option * map_store =
  let h = value_hash key in
  let bucket = match Int_map.find_opt h m.map_index with Some b -> b | None -> [] in
  match bucket_mem_key bucket key with
  | Some ((stored_key, old) as victim) ->
      prof_map_scans :=
        !prof_map_scans + List.length m.map_front + List.length m.map_back;
      (* ONE new pair object shared by both order lists and the index
         bucket: the entry's identity is the pair object, and every
         structure must keep carrying the same one (a later replace or
         drain finds it by physical identity) *)
      let new_pair = (stored_key, value) in
      let replace p = if p == victim then new_pair else p in
      ( Some old,
        {
          map_front = List.map replace m.map_front;
          map_back = List.map replace m.map_back;
          map_index = Int_map.add h (List.map replace bucket) m.map_index;
          map_count = m.map_count;
        } )
  | None ->
      let new_pair = (key, value) in
      ( None,
        {
          map_front = m.map_front;
          map_back = new_pair :: m.map_back;
          map_index = Int_map.add h (new_pair :: bucket) m.map_index;
          map_count = m.map_count + 1;
        } )

let map_insert (m : map_store) (key : t) (value : t) : map_store =
  snd (map_insert_entry m key value)

let map_find (m : map_store) (key : t) : (t * t) option =
  match Int_map.find_opt (value_hash key) m.map_index with
  | None -> None
  | Some bucket -> bucket_mem_key bucket key

let map_mem (m : map_store) (key : t) : bool =
  match map_find m key with Some _ -> true | None -> false

let map_remove (m : map_store) (key : t) : (t * t) option * map_store =
  match map_find m key with
  | None -> (None, m)
  | Some ((stored_key, _) as victim) ->
      let h = value_hash stored_key in
      let bucket =
        match Int_map.find_opt h m.map_index with Some b -> b | None -> []
      in
      (* physical filtering removes exactly the found entry object, never
         a distinct equal sibling *)
      let drop_victim p = not (p == victim) in
      let bucket' = List.filter drop_victim bucket in
      let index' =
        if bucket' = [] then Int_map.remove h m.map_index
        else Int_map.add h bucket' m.map_index
      in
      ( Some victim,
        {
          map_front = List.filter drop_victim m.map_front;
          map_back = List.filter drop_victim m.map_back;
          map_index = index';
          map_count = m.map_count - 1;
        } )

let map_len (m : map_store) : int = m.map_count

let map_pairs (m : map_store) : (t * t) list = map_seq m

let map_of_pairs (pairs : (t * t) list) : t =
  List.fold_left
    (fun acc (k, v) ->
      match acc with
      | Map store -> Map (map_insert store k v)
      | _ -> assert false)
    map_empty pairs

(* the drain contract: the FIRST live entry leaves as an owned pair
   (FIFO, the direct kernel's "remove the first live entry"); the queue
   front is refilled from the back when it empties *)
let map_drain_one (m : map_store) : (t * t) option * map_store =
  let front = if m.map_front = [] then List.rev m.map_back else m.map_front in
  let back = if m.map_front = [] then [] else m.map_back in
  match front with
  | [] -> (None, m)
  | ((k, v) as head) :: rest ->
      let h = value_hash k in
      let bucket =
        match Int_map.find_opt h m.map_index with Some b -> b | None -> []
      in
      (* the head entry's own pair object (a replaced entry keeps the
         object it was rewritten to in every structure; distinct
         duplicate entries are distinct objects) *)
      let drop_victim p = not (p == head) in
      let bucket' = List.filter drop_victim bucket in
      let index' =
        if bucket' = [] then Int_map.remove h m.map_index
        else Int_map.add h bucket' m.map_index
      in
      (Some (k, v),
       { map_front = rest; map_back = back; map_index = index';
         map_count = m.map_count - 1 })

(* insert with the std replacement contract: an existing element is
   REPLACED by the incoming item (the caller's moved value becomes the
   stored element) keeping its position; the presence Bool reports
   whether it already existed. *)
let set_insert_entry (s : set_store) (item : t) : bool * t option * set_store =
  let h = value_hash item in
  let bucket = match Int_map.find_opt h s.set_index with Some b -> b | None -> [] in
  match List.find_opt (fun e -> lookup_eq e item) bucket with
  | Some victim ->
      prof_set_scans :=
        !prof_set_scans + List.length s.set_front + List.length s.set_back;
      let replace e = if e == victim then item else e in
      ( true,
        Some victim,
        {
          set_front = List.map replace s.set_front;
          set_back = List.map replace s.set_back;
          set_index = Int_map.add h (List.map replace bucket) s.set_index;
          set_count = s.set_count;
        } )
  | None ->
      ( false,
        None,
        {
          set_front = s.set_front;
          set_back = item :: s.set_back;
          set_index = Int_map.add h (item :: bucket) s.set_index;
          set_count = s.set_count + 1;
        } )

let set_insert (s : set_store) (item : t) : set_store =
  let _, _, s' = set_insert_entry s item in
  s'

let set_mem (s : set_store) (item : t) : bool =
  match Int_map.find_opt (value_hash item) s.set_index with
  | None -> false
  | Some bucket -> List.exists (fun e -> lookup_eq e item) bucket

let set_remove (s : set_store) (item : t) : (t option * set_store) =
  let h = value_hash item in
  match Int_map.find_opt h s.set_index with
  | None -> (None, s)
  | Some bucket -> (
      match List.find_opt (fun e -> lookup_eq e item) bucket with
      | None -> (None, s)
      | Some victim ->
          let drop_victim e = not (e == victim) in
          let bucket' = List.filter drop_victim bucket in
          let index' =
            if bucket' = [] then Int_map.remove h s.set_index
            else Int_map.add h bucket' s.set_index
          in
          ( Some victim,
            {
              set_front = List.filter drop_victim s.set_front;
              set_back = List.filter drop_victim s.set_back;
              set_index = index';
              set_count = s.set_count - 1;
            } ))

let set_len (s : set_store) : int = s.set_count

let set_elems (s : set_store) : t list = set_seq s

let set_of_list (elems : t list) : t =
  List.fold_left
    (fun acc e -> match acc with Set store -> Set (set_insert store e) | _ -> assert false)
    set_empty elems

(* the set drain contract: the FIRST live element leaves (FIFO) *)
let set_drain_one (s : set_store) : (t option * set_store) =
  let front = if s.set_front = [] then List.rev s.set_back else s.set_front in
  let back = if s.set_front = [] then [] else s.set_back in
  match front with
  | [] -> (None, s)
  | x :: rest ->
      let h = value_hash x in
      let bucket =
        match Int_map.find_opt h s.set_index with Some b -> b | None -> []
      in
      let victim = List.find_opt (fun e -> e == x) bucket in
      let drop_victim e =
        match victim with Some v -> not (e == v) | None -> true
      in
      let bucket' = List.filter drop_victim bucket in
      let index' =
        if bucket' = [] then Int_map.remove h s.set_index
        else Int_map.add h bucket' s.set_index
      in
      (Some x,
       { set_front = rest; set_back = back; set_index = index';
         set_count = s.set_count - 1 })

(* ── Deterministic byte serialization (audit: pointer deref) ─────────

   Self-describing little-endian format; every serializable value
   round-trips (serialize; deserialize = the value):

     Unit               01
     Bool               02 + 1 byte (0/1)
     Char               03 + 4 bytes LE (utf-32 code point)
     Int                04 + width byte + signed byte (0/1)
                            + 8 bytes LE (bits_lo)
                            + 8 bytes LE (bits_hi; width 128 only)
     Float32            05 + 4 bytes LE
     Float64            06 + 8 bytes LE
     String             07 + 8-byte LE length + utf-8 bytes
     Tuple              08 + 8-byte LE count + elements
     Struct             09 + 8-byte LE count + elements
     Array              0A + 8-byte LE count + elements
     Enum               0B + 8-byte LE variant tag + 8-byte LE count
                            + elements
     RawPtr             0C + 8-byte LE region + 8-byte LE offset
     Ref (Region p)     0D + 8-byte LE region + 8-byte LE offset

   Function / Closure / Ref (Place _) / Null are not serializable (a
   deterministic trap; they are execution-context values). *)

let put_u32 (buf : Buffer.t) (v : int32) : unit =
  for i = 0 to 3 do
    Buffer.add_char buf
      (Char.chr (Int32.to_int (Int32.shift_right_logical v (8 * i)) land 0xFF))
  done

let put_u64 (buf : Buffer.t) (v : int64) : unit =
  for i = 0 to 7 do
    Buffer.add_char buf
      (Char.chr (Int64.to_int (Int64.shift_right_logical v (8 * i)) land 0xFF))
  done

let rec serialize_value (buf : Buffer.t) (v : t) : unit =
  match v with
  | Unit -> Buffer.add_char buf (Char.chr 0x01)
  | Bool b ->
      Buffer.add_char buf (Char.chr 0x02);
      Buffer.add_char buf (if b then Char.chr 1 else Char.chr 0)
  | Char c ->
      Buffer.add_char buf (Char.chr 0x03);
      put_u32 buf (Int32.of_int (Uchar.to_int c))
  | Int i ->
      Buffer.add_char buf (Char.chr 0x04);
      Buffer.add_char buf (Char.chr i.Int_value.width);
      Buffer.add_char buf (if i.Int_value.signed then Char.chr 1 else Char.chr 0);
      put_u64 buf i.Int_value.bits_lo;
      if i.Int_value.width = 128 then put_u64 buf i.Int_value.bits_hi
  | Float32 f ->
      Buffer.add_char buf (Char.chr 0x05);
      put_u32 buf f
  | Float64 f ->
      Buffer.add_char buf (Char.chr 0x06);
      put_u64 buf f
  | String s ->
      Buffer.add_char buf (Char.chr 0x07);
      put_u64 buf (Int64.of_int (String.length s));
      Buffer.add_string buf s
  | Tuple elems ->
      Buffer.add_char buf (Char.chr 0x08);
      put_u64 buf (Int64.of_int (Array.length elems));
      Array.iter (serialize_value buf) elems
  | Struct elems ->
      Buffer.add_char buf (Char.chr 0x09);
      put_u64 buf (Int64.of_int (Array.length elems));
      Array.iter (serialize_value buf) elems
  | Array elems ->
      Buffer.add_char buf (Char.chr 0x0A);
      put_u64 buf (Int64.of_int (arr_length elems));
      arr_iter (serialize_value buf) elems
  | Set store ->
      Buffer.add_char buf (Char.chr 0x0E);
      put_u64 buf (Int64.of_int (set_len store));
      List.iter (serialize_value buf) (set_elems store)
  | Map store ->
      Buffer.add_char buf (Char.chr 0x0F);
      put_u64 buf (Int64.of_int (map_len store));
      List.iter
        (fun (k, v) ->
          serialize_value buf k;
          serialize_value buf v)
        (map_pairs store)
  | Enum (tag, payload) ->
      Buffer.add_char buf (Char.chr 0x0B);
      put_u64 buf (Int64.of_int tag);
      put_u64 buf (Int64.of_int (Array.length payload));
      Array.iter (serialize_value buf) payload
  | RawPtr p ->
      Buffer.add_char buf (Char.chr 0x0C);
      put_u64 buf (Int64.of_int p.Vm_memory.region);
      put_u64 buf (Int64.of_int p.Vm_memory.offset)
  | Ref (Region p) ->
      Buffer.add_char buf (Char.chr 0x0D);
      put_u64 buf (Int64.of_int p.Vm_memory.region);
      put_u64 buf (Int64.of_int p.Vm_memory.offset)
  | Ref (Place _) | Function _ | Closure _ | Null | MovedOut ->
      failwith
        "vm serialization: value is not serializable (ref to a place / function / closure / null / moved-out hole)"

let serialize (v : t) : Bytes.t =
  let buf = Buffer.create 32 in
  serialize_value buf v;
  Bytes.of_string (Buffer.contents buf)

(* ── Deserialization ─────────────────────────────────────────────── *)

type cursor = { bytes : Bytes.t; mutable pos : int }

let cursor_take (c : cursor) (n : int) : Bytes.t =
  if n < 0 || c.pos < 0 || c.pos > Bytes.length c.bytes - n then
    failwith "vm serialization: truncated value";
  let b = Bytes.sub c.bytes c.pos n in
  c.pos <- c.pos + n;
  b

let cursor_u8 (c : cursor) : int =
  if c.pos >= Bytes.length c.bytes then failwith "vm serialization: truncated value";
  let b = Char.code (Bytes.get c.bytes c.pos) in
  c.pos <- c.pos + 1;
  b

let cursor_u32 (c : cursor) : int32 =
  let b = cursor_take c 4 in
  let v = ref 0l in
  for i = 0 to 3 do
    v := Int32.logor !v (Int32.shift_left (Int32.of_int (Char.code (Bytes.get b i))) (8 * i))
  done;
  !v

let cursor_u64 (c : cursor) : int64 =
  let b = cursor_take c 8 in
  let v = ref 0L in
  for i = 0 to 7 do
    v := Int64.logor !v (Int64.shift_left (Int64.of_int (Char.code (Bytes.get b i))) (8 * i))
  done;
  !v

let cursor_count (c : cursor) : int =
  let n = cursor_u64 c in
  if n < 0L || Int64.compare n (Int64.of_int max_int) > 0 then
    failwith "vm serialization: invalid element count";
  Int64.to_int n

let rec deserialize_value (c : cursor) : t =
  match cursor_u8 c with
  | 0x01 -> Unit
  | 0x02 -> Bool (cursor_u8 c <> 0)
  | 0x03 ->
      let cp = Int32.to_int (cursor_u32 c) in
      if cp < 0 || cp > 0x10FFFF then failwith "vm serialization: invalid char code point";
      Char (Uchar.of_int cp)
  | 0x04 ->
      let width = cursor_u8 c in
      let signed = cursor_u8 c <> 0 in
      let lo = cursor_u64 c in
      let hi = if width = 128 then cursor_u64 c else 0L in
      (try Int (Int_value.make ~width ~signed ~bits_lo:lo ~bits_hi:hi)
       with Invalid_argument _ -> failwith "vm serialization: invalid int width")
  | 0x05 -> Float32 (cursor_u32 c)
  | 0x06 -> Float64 (cursor_u64 c)
  | 0x07 ->
      let len = cursor_count c in
      String (Bytes.to_string (cursor_take c len))
  | 0x08 -> Tuple (cursor_elems c)
  | 0x09 -> Struct (cursor_elems c)
  | 0x0A -> Array (arr_of_array (cursor_elems c))
  | 0x0B ->
      let tag = cursor_count c in
      Enum (tag, cursor_elems c)
  | 0x0C ->
      let region = cursor_count c in
      let offset = cursor_count c in
      RawPtr { Vm_memory.region; offset }
  | 0x0D ->
      let region = cursor_count c in
      let offset = cursor_count c in
      Ref (Region { Vm_memory.region; offset })
  | 0x0E ->
      let rec elems acc n =
        if n = 0 then List.rev acc
        else elems (deserialize_value c :: acc) (n - 1)
      in
      set_of_list (elems [] (cursor_count c))
  | 0x0F ->
      let rec pairs acc n =
        if n = 0 then List.rev acc
        else
          let k = deserialize_value c in
          let v = deserialize_value c in
          pairs ((k, v) :: acc) (n - 1)
      in
      map_of_pairs (pairs [] (cursor_count c))
  | tag -> failwith (Printf.sprintf "vm serialization: unknown tag 0x%02x" tag)

and cursor_elems (c : cursor) : t array =
  let n = cursor_count c in
  Array.init n (fun _ -> deserialize_value c)

let deserialize (bytes : Bytes.t) : t =
  deserialize_value { bytes; pos = 0 }

(* ── Recursive drop glue (audit: recursive drop) ────────────────────

   The drop transition applied to a value's CONTAINED components before
   the owning slot transitions (vm.ml do_drop): aggregates are visited
   depth-first (a contained value's own glue runs before the next
   sibling).  The seed's only owned heap object is a region-backed
   reference (a computed-value ref); dropping one frees its region
   deterministically — a second free (a double-drop through copied
   refs) traps.  Raw pointers and place-backed references are not owned
   and are left untouched. *)
let rec drop_glue (m : Vm_memory.t) (v : t) : unit =
  match v with
  | Tuple elems | Struct elems -> Array.iter (drop_glue m) elems
  | Array elems -> arr_iter (drop_glue m) elems
  | Set store -> List.iter (drop_glue m) (set_elems store)
  | Map store ->
      List.iter (fun (k, v) -> drop_glue m k; drop_glue m v) (map_pairs store)
  | Enum (_, payload) -> Array.iter (drop_glue m) payload
  | Ref (Region p) -> (
      match Vm_memory.free m p with
      | Ok () -> ()
      | Error e -> failwith ("vm drop glue: " ^ Vm_memory.mem_error_string e))
  | Unit | Bool _ | Int _ | Float32 _ | Float64 _ | Char _ | String _
  | Function _ | Closure _ | RawPtr _ | Ref (Place _) | Null | MovedOut ->
      ()
