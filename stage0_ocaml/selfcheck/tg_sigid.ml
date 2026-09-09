(* tg_sigid.ml — signature-identity matcher self-check (audit P0-1..P0-4).

   The typed → MIR / host normalization boundary compares DECLARED
   signatures for semantic identity through ONE shared matcher
   (Signature_identity.signatures_match).  This self-check pins the
   matcher's rules with the audit's regression cases:

   P0-1  — Named types compare by EXACT TypeId equality after the
           sanctioned canonicalization only (registry placeholder →
           checker LangItem ids; builtin-alias fold).  A[Int] vs B[Int]
           (equal-arity user ADTs) NEVER match; Vec[Int] vs Set[Int]
           NEVER match; the positive registry-vs-checker cases (Vec[T]
           ↔ Array[T], Option[P0] ↔ Option[T], Map[P0,P1] ↔ Map[K,V])
           MUST match.
   P0-2  — binder alpha-equivalence is a BIJECTION over the whole
           signature: fn(T,T)->T vs fn(A,B)->A FAILS; fn(T,U)->T vs
           fn(A,A)->A FAILS; a consistent rename PASSES.
   P0-4  — conventions are part of identity: [let Set[T]] Bool vs
            [inout Set[T]] Bool FAILS.  The convention check is
            UNCONDITIONAL — it also runs on the strict_when (ref-kind)
            escape, which makes only the TYPE comparison strict:
            [let &mut Int] vs [inout &mut Int] FAILS there too, and the
            boolean matcher always agrees with first_mismatch. *)

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; exit 1) fmt
let pass (label : string) = Printf.printf "PASS: %s\n" label

(* fresh binder ids (any ids work — alpha is id-agnostic) *)
let gp (n : int) : Type_repr.t = Type_repr.Type_param (Ids.Generic_param_id.make n)
let tid (n : int) : Ids.Type_id.t = Ids.Type_id.make n

(* the checker-domain LangItem ids *)
let checker_array = tid 0
let checker_set = tid 2
let checker_option = tid 3

let named (t : Ids.Type_id.t) (args : Type_repr.t array) : Type_repr.t =
  Type_repr.Named (t, args)

let registry_sig (params : Type_repr.param_type array) (ret : Type_repr.t) :
    Signature_identity.signature =
  { Signature_identity.sig_params = params; sig_ret = ret }

let letsig (tys : Type_repr.t list) (ret : Type_repr.t) : Signature_identity.signature =
  registry_sig
    (Array.of_list
       (List.map
          (fun ty -> { Type_repr.pt_convention = Access_effect.Let; pt_type = ty })
          tys))
    ret

let convsig (params : (Access_effect.t * Type_repr.t) list) (ret : Type_repr.t) :
    Signature_identity.signature =
  registry_sig
    (Array.of_list
       (List.map
          (fun (c, ty) -> { Type_repr.pt_convention = c; pt_type = ty })
          params))
    ret

let expect_true (label : string) (a : Signature_identity.signature)
    (b : Signature_identity.signature) : unit =
  if Signature_identity.signatures_match a b then pass label
  else
    fail "%s: the matcher REJECTED two signatures that must match (%s vs %s)" label
      (Signature_identity.to_string a) (Signature_identity.to_string b)

let expect_false (label : string) (a : Signature_identity.signature)
    (b : Signature_identity.signature) : unit =
  if not (Signature_identity.signatures_match a b) then pass label
  else
    fail "%s: the matcher ACCEPTED two signatures that must differ (%s vs %s)" label
      (Signature_identity.to_string a) (Signature_identity.to_string b)

let canonical =
  Signature_identity.canonicalize_registry_placeholder

(* registry-side signatures canonicalized with the registry-domain
   canonical form (the driver's host-channel rewrite applies it to the
   registry declaration); the checker side is compared as-is *)
let reg_vs_checker (reg : Signature_identity.signature) (chk : Signature_identity.signature) :
    bool =
  Signature_identity.signatures_match ~canon_left:canonical reg chk

(* ── the strict_when (ref-kind) escape, mirroring typecheck.ml's
      registry-exact gate predicate: a pair is strict when either side
      carries a ref kind, and the strict comparison is the plain
      structural Type_repr.compare ────────────────────────────────── *)
let rec ty_has_ref_kind (t : Type_repr.t) : bool =
  match t with
  | Type_repr.Ref_internal _ | Type_repr.Raw_ptr _ -> true
  | Type_repr.Named (_, args) -> Array.exists ty_has_ref_kind args
  | Type_repr.Fixed_array (e, _) -> ty_has_ref_kind e
  | Type_repr.Tuple elems -> Array.exists ty_has_ref_kind elems
  | Type_repr.Function (p, r) ->
      Array.exists
        (fun (p : Type_repr.param_type) -> ty_has_ref_kind p.Type_repr.pt_type)
        p
      || ty_has_ref_kind r
  | _ -> false

let strict_ref_pair (a : Type_repr.t) (b : Type_repr.t) : bool =
  ty_has_ref_kind a || ty_has_ref_kind b

let strict_match (a : Signature_identity.signature) (b : Signature_identity.signature) : bool =
  Signature_identity.signatures_match ~strict_when:strict_ref_pair a b

let strict_mismatch (a : Signature_identity.signature)
    (b : Signature_identity.signature) : Signature_identity.mismatch option =
  Signature_identity.first_mismatch ~strict_when:strict_ref_pair a b

let mismatch_to_string = function
  | Signature_identity.Mismatch_arity (d, o) -> Printf.sprintf "arity %d vs %d" d o
  | Signature_identity.Mismatch_param i -> Printf.sprintf "param %d" i
  | Signature_identity.Mismatch_return -> "return"

(* strict-path expectations that also pin the boolean-matcher ↔
   first_mismatch agreement: the matcher accepts iff the report finds
   nothing, under the SAME strict_when *)
let expect_strict_true (label : string) (a : Signature_identity.signature)
    (b : Signature_identity.signature) : unit =
  if not (strict_match a b) then
    fail "%s: the strict matcher REJECTED two signatures that must match (%s vs %s)" label
      (Signature_identity.to_string a) (Signature_identity.to_string b)
  else
    match strict_mismatch a b with
    | None -> pass label
    | Some m ->
        fail "%s: first_mismatch reported %s on a matching pair (%s vs %s)" label
          (mismatch_to_string m) (Signature_identity.to_string a)
          (Signature_identity.to_string b)

let expect_strict_false (label : string) (a : Signature_identity.signature)
    (b : Signature_identity.signature) : unit =
  if strict_match a b then
    fail "%s: the strict matcher ACCEPTED two signatures that must differ (%s vs %s)" label
      (Signature_identity.to_string a) (Signature_identity.to_string b)
  else
    match strict_mismatch a b with
    | Some _ -> pass label
    | None ->
        fail
          "%s: first_mismatch found no disagreement while the matcher rejected (%s vs %s)"
          label (Signature_identity.to_string a) (Signature_identity.to_string b)

(* ── P0-1: exact TypeId equality ─────────────────────────────────── *)

let check_p01 () =
  (* two unrelated user ADTs with the same generic arity: A[Int] vs
     B[Int] must NEVER match (both sides checker-domain) *)
  let a_int =
    letsig [ named (tid 100) [| Type_repr.Int Type_repr.Int |] ] Type_repr.Bool
  in
  let b_int =
    letsig [ named (tid 101) [| Type_repr.Int Type_repr.Int |] ] Type_repr.Bool
  in
  expect_false "P0-1: A[Int] vs B[Int] (equal-shape user ADTs) must NOT match" a_int b_int;
  (* the same nominal on both sides must match *)
  let a_a = letsig [ named (tid 100) [| Type_repr.Int Type_repr.Int |] ] Type_repr.Bool in
  expect_true "P0-1: A[Int] vs A[Int] matches" a_a a_a;
  (* Vec[Int] vs Set[Int] must NEVER match (checker-domain spelling) *)
  let vec_int =
    letsig [ named checker_array [| Type_repr.Int Type_repr.Int |] ] Type_repr.Bool
  in
  let set_int = letsig [ named checker_set [| Type_repr.Int Type_repr.Int |] ] Type_repr.Bool in
  expect_false "P0-1: Vec[Int] vs Set[Int] must NOT match" vec_int set_int;
  (* Vec[Int] vs Vec[String]: same nominal, different args -> no match *)
  let vec_str =
    letsig [ named checker_array [| Type_repr.String |] ] Type_repr.Bool
  in
  expect_false "P0-1: Vec[Int] vs Vec[String] must NOT match" vec_int vec_str;
  (* the positive registry↔checker cases (the driver's boundary) *)
  let registry_vec_t =
    letsig [ Intrinsic_registry.vec_of (gp 0) ] (Type_repr.Int Type_repr.Int)
  in
  let checker_array_t = letsig [ named checker_array [| gp 7 |] ] (Type_repr.Int Type_repr.Int) in
  if
    not
      (reg_vs_checker registry_vec_t checker_array_t)
  then
    fail "P0-1 positive: registry Vec[T] must match checker Array[T] (the builtin-alias rule)";
  pass "P0-1 positive: registry Vec[T] ↔ checker Array[T] matches via the alias rule";
  (* registry Set[T] must NOT match checker Array[T] (wrong nominal class
     even under the alias fold) *)
  let registry_set_t = letsig [ Intrinsic_registry.set_of (gp 0) ] (Type_repr.Int Type_repr.Int) in
  if reg_vs_checker registry_set_t checker_array_t then
    fail "P0-1: registry Set[T] matched checker Array[T] (nominal classes confused)"
  else pass "P0-1: registry Set[T] vs checker Array[T] must NOT match";
  (* Option[P0] ↔ Option[T] and Map[P0,P1] ↔ Map[K,V] *)
  let registry_opt_p =
    letsig [ Intrinsic_registry.option_of (gp 0) ] Type_repr.Bool
  in
  let checker_opt_t = letsig [ named checker_option [| gp 9 |] ] Type_repr.Bool in
  if not (reg_vs_checker registry_opt_p checker_opt_t) then
    fail "P0-1 positive: registry Option[P0] must match checker Option[T]";
  pass "P0-1 positive: registry Option[P0] ↔ checker Option[T] matches";
  let registry_map_p =
    letsig
      [ Intrinsic_registry.map_of (gp 0) (gp 1) ]
      Type_repr.Bool
  in
  let checker_map_kv =
    letsig [ named (tid 1) [| gp 4; gp 5 |] ] Type_repr.Bool
  in
  if not (reg_vs_checker registry_map_p checker_map_kv) then
    fail "P0-1 positive: registry Map[P0,P1] must match checker Map[K,V]";
  pass "P0-1 positive: registry Map[P0,P1] ↔ checker Map[K,V] matches";
  (* registry Vec vs registry Array (the alias fold inside the registry
     placeholder domain — the adapter/binding boundary) *)
  let adapter_array_t = letsig [ Intrinsic_registry.named Intrinsic_registry.Type_id.array_ [| gp 2 |] ] (Type_repr.Int Type_repr.Int) in
  if
    not
      (Signature_identity.signatures_match ~canon_left:canonical
         ~canon_right:canonical registry_vec_t adapter_array_t)
  then
    fail "P0-1: registry Vec[T] must match the registry Array[T] spelling (same nominal)";
  pass "P0-1: registry Vec[T] ↔ registry Array[T] spelling matches (alias fold)"
  ;
  (* a user ADT (id 100) on the registry side must NOT match checker
     Array[T] or any LangItem — the canonicalization never invents
     nominal identity *)
  let reg_user_a = letsig [ named (tid 100) [| gp 0 |] ] Type_repr.Bool in
  if reg_vs_checker reg_user_a checker_array_t then
    fail "P0-1: a registry-side user ADT matched the checker's Array nominal"
  else pass "P0-1: a registry-side user ADT never matches the Array LangItem"

(* ── P0-2: the binder bijection ──────────────────────────────────── *)

let check_p02 () =
  (* fn(T,T)->T vs fn(A,B)->A must FAIL: the same left binder T cannot
     map to two different right binders A and B *)
  let dup_left =
    registry_sig
      [|
        { Type_repr.pt_convention = Access_effect.Let; pt_type = gp 0 };
        { Type_repr.pt_convention = Access_effect.Let; pt_type = gp 1 };
      |]
      (gp 0)
  in
  let fn_ab_a = letsig [ gp 10; gp 11 ] (gp 10) in
  let fn_tt_t = letsig [ gp 0; gp 0 ] (gp 0) in
  expect_false "P0-2: fn(T,T)->T vs fn(A,B)->A must FAIL (T cannot map to A and B)"
    fn_tt_t fn_ab_a;
  (* fn(T,U)->T vs fn(A,A)->A must FAIL: two different left binders
     cannot collapse onto one right binder *)
  let fn_tu_t = letsig [ gp 0; gp 1 ] (gp 0) in
  expect_false "P0-2: fn(T,U)->T vs fn(A,A)->A must FAIL (A cannot map to T and U)"
    fn_tu_t fn_tt_t;
  (* fn(T,U)->T vs fn(A,B)->A: a consistent rename must PASS *)
  expect_true "P0-2: fn(T,U)->T vs fn(A,B)->A matches (consistent rename)"
    fn_tu_t dup_left;
  (* the same binder reused in the return: fn(T,T)->T vs fn(A,A)->A PASSES *)
  expect_true "P0-2: fn(T,T)->T vs fn(A,A)->A matches (consistent reuse)"
    fn_tt_t (letsig [ gp 10; gp 10 ] (gp 10));
  (* a binder disagreement introduced only in the return must FAIL *)
  let fn_tu_u = letsig [ gp 0; gp 1 ] (gp 1) in
  expect_false "P0-2: fn(T,U)->U vs fn(A,B)->A must FAIL (return binder mismatch)"
    fn_tu_u dup_left;
  (* shared state across nested positions: fn(Map[T,U], U) vs
     fn(Map[A,B], A) must FAIL (U is consumed as the map's second arg) *)
  let nested_left =
    letsig [ named (tid 1) [| gp 0; gp 1 |]; gp 1 ] Type_repr.Unit
  in
  let nested_right =
    letsig [ named (tid 1) [| gp 10; gp 11 |]; gp 10 ] Type_repr.Unit
  in
  expect_false
    "P0-2: fn(Map[T,U], U) vs fn(Map[A,B], A) must FAIL (nested binders disagree)"
    nested_left nested_right;
  let nested_right' =
    letsig [ named (tid 1) [| gp 10; gp 11 |]; gp 11 ] Type_repr.Unit
  in
  expect_true "P0-2: fn(Map[T,U], U) vs fn(Map[A,B], B) matches (nested consistency)"
    nested_left nested_right';
  (* registry-side canonicalization must not disturb binder identity:
     registry fn(Set[T], T) matches checker fn(Set[A], A) *)
  let reg_set =
    letsig [ Intrinsic_registry.set_of (gp 0); gp 0 ] Type_repr.Bool
  in
  let chk_set =
    letsig [ named checker_set [| gp 20 |]; gp 20 ] Type_repr.Bool
  in
  if not (reg_vs_checker reg_set chk_set) then
    fail "P0-2: registry fn(Set[T], T) must match checker fn(Set[A], A)"
  else pass "P0-2: registry fn(Set[T], T) ↔ checker fn(Set[A], A) matches"

(* ── P0-4: conventions are part of identity ──────────────────────── *)

let check_p04 () =
  let set_t = named checker_set [| gp 0 |] in
  let by_value = convsig [ (Access_effect.Let, set_t) ] Type_repr.Bool in
  let by_inout = convsig [ (Access_effect.Inout, set_t) ] Type_repr.Bool in
  expect_false "P0-4: [let Set[T]] Bool vs [inout Set[T]] Bool must NOT match" by_value
    by_inout;
  let by_sink = convsig [ (Access_effect.Sink, set_t) ] Type_repr.Bool in
  expect_false "P0-4: [let Set[T]] Bool vs [sink Set[T]] Bool must NOT match" by_value
    by_sink;
  (* an equal-convention copy matches *)
  expect_true "P0-4: [inout Set[T]] Bool vs [inout Set[A]] Bool matches (same convention)"
    by_inout (convsig [ (Access_effect.Inout, named checker_set [| gp 3 |]) ] Type_repr.Bool);
  (* the registry↔checker rewrite gate compares conventions exactly:
     registry sig_conv [inout Set[T]; sink T] Bool vs a checker decl
     with [inout Set[K]; sink K] Bool passes, but [let Set[K]; sink K]
     fails *)
  let reg_insert =
    convsig
      [
        (Access_effect.Inout, Intrinsic_registry.set_of (gp 0));
        (Access_effect.Sink, gp 0);
      ]
      Type_repr.Bool
  in
  let chk_insert_inout =
    convsig
      [
        (Access_effect.Inout, named checker_set [| gp 30 |]);
        (Access_effect.Sink, gp 30);
      ]
      Type_repr.Bool
  in
  if not (reg_vs_checker reg_insert chk_insert_inout) then
    fail "P0-4: registry [inout Set[T], sink T] must match the same-convention checker decl"
  else pass "P0-4: registry [inout Set[T]; sink T] Bool ↔ checker decl with identical conventions";
  let chk_insert_let =
    convsig
      [
        (Access_effect.Let, named checker_set [| gp 30 |]);
        (Access_effect.Sink, gp 30);
      ]
      Type_repr.Bool
  in
  if reg_vs_checker reg_insert chk_insert_let then
    fail "P0-4: a convention drift ([inout] vs [let] on the receiver) was accepted"
  else pass "P0-4: a receiver-convention drift ([inout] vs [let]) fails the rewrite gate";
  (* arity is part of identity *)
  let two_params = letsig [ Type_repr.Bool; Type_repr.Bool ] Type_repr.Unit in
  let one_param = letsig [ Type_repr.Bool ] Type_repr.Unit in
  expect_false "P0-4: arity disagreement must NOT match" two_params one_param;
  (* returns are part of identity *)
  let ret_bool = letsig [ Type_repr.Bool ] Type_repr.Bool in
  let ret_unit = letsig [ Type_repr.Bool ] Type_repr.Unit in
  expect_false "P0-4: return disagreement must NOT match" ret_bool ret_unit

(* ── P0-4 strict path: the convention is compared FIRST and
      unconditionally — strict_when escapes only the TYPE comparison,
      so a convention drift on a ref-bearing parameter is never
      accepted (the P0-1 audit regression: match_signature's strict
      branch previously bypassed the convention check that
      first_mismatch performed) ───────────────────────────────────── *)

let check_p04_strict () =
  let ref_mut_int =
    Type_repr.Ref_internal (Type_repr.Mutable, Type_repr.Int Type_repr.Int)
  in
  let ref_sig (c : Access_effect.t) : Signature_identity.signature =
    convsig [ (c, ref_mut_int) ] Type_repr.Bool
  in
  expect_strict_false "P0-4 strict ref: [let &mut Int] vs [inout &mut Int] must NOT match"
    (ref_sig Access_effect.Let) (ref_sig Access_effect.Inout);
  expect_strict_false "P0-4 strict ref: [sink &mut Int] vs [let &mut Int] must NOT match"
    (ref_sig Access_effect.Sink) (ref_sig Access_effect.Let);
  expect_strict_true
    "P0-4 strict ref: [inout &mut Int] vs [inout &mut Int] matches (identical convention \
     and ref type)"
    (ref_sig Access_effect.Inout) (ref_sig Access_effect.Inout);
  (* with the convention fixed, the strict TYPE comparison still runs: a
     mutability drift on the ref itself must fail *)
  expect_strict_false "P0-4 strict ref: [let &mut Int] vs [let &Int] must NOT match"
    (ref_sig Access_effect.Let)
    (convsig
       [
         ( Access_effect.Let,
           Type_repr.Ref_internal (Type_repr.Immutable, Type_repr.Int Type_repr.Int) );
       ]
       Type_repr.Bool)

(* ── the convention-identity property: for every ordered pair of
      conventions (let/inout/sink/set) on the SAME type the matcher
      accepts iff the conventions are equal — under the ordinary path,
      the generic (binder) path and the strict ref path — and
      match_signature always agrees with first_mismatch ───────────── *)

let all_conventions = [ Access_effect.Let; Access_effect.Inout; Access_effect.Sink; Access_effect.Set ]

let check_convention_identity (label : string)
    (mk_left : Access_effect.t -> Signature_identity.signature)
    (mk_right : Access_effect.t -> Signature_identity.signature)
    (match_pair : Signature_identity.signature -> Signature_identity.signature -> bool)
    (mismatch_pair :
      Signature_identity.signature -> Signature_identity.signature ->
      Signature_identity.mismatch option) : unit =
  List.iter
    (fun c1 ->
      List.iter
        (fun c2 ->
          let a = mk_left c1 and b = mk_right c2 in
          let expected = Access_effect.compare c1 c2 = 0 in
          let matched = match_pair a b in
          let reported = mismatch_pair a b in
          let agrees =
            match matched, reported with
            | true, None -> true
            | false, Some _ -> true
            | true, Some _ | false, None -> false
          in
          if matched <> expected || not agrees then
            fail
              "%s: conventions %s vs %s must %s (matcher said %b, first_mismatch said %s; \
               %s vs %s)"
              label (Access_effect.to_string c1) (Access_effect.to_string c2)
              (if expected then "match" else "not match")
              matched
              (match reported with
              | None -> "no disagreement"
              | Some m -> mismatch_to_string m)
              (Signature_identity.to_string a) (Signature_identity.to_string b))
        all_conventions)
    all_conventions;
  pass label

let check_convention_property () =
  let plain_match (a : Signature_identity.signature) (b : Signature_identity.signature) : bool =
    Signature_identity.signatures_match a b
  in
  let plain_mismatch (a : Signature_identity.signature)
      (b : Signature_identity.signature) : Signature_identity.mismatch option =
    Signature_identity.first_mismatch a b
  in
  (* ordinary: a concrete non-ref parameter type *)
  let ordinary (c : Access_effect.t) : Signature_identity.signature =
    convsig [ (c, Type_repr.Int Type_repr.Int) ] Type_repr.Bool
  in
  check_convention_identity "P0-4 property: ordinary [Int] params match iff the conventions agree"
    ordinary ordinary plain_match plain_mismatch;
  (* generic: a binder parameter, alpha-renamed across the two sides *)
  let generic_left (c : Access_effect.t) : Signature_identity.signature =
    convsig [ (c, gp 0) ] Type_repr.Bool
  in
  let generic_right (c : Access_effect.t) : Signature_identity.signature =
    convsig [ (c, gp 7) ] Type_repr.Bool
  in
  check_convention_identity "P0-4 property: generic [T] params match iff the conventions agree"
    generic_left generic_right plain_match plain_mismatch;
  (* strict ref: a Ref_internal parameter under the ref-kind strict_when
     (the driver's registry-exact gate predicate) *)
  let ref_int (c : Access_effect.t) : Signature_identity.signature =
    convsig
      [ (c, Type_repr.Ref_internal (Type_repr.Mutable, Type_repr.Int Type_repr.Int)) ]
      Type_repr.Bool
  in
  check_convention_identity
    "P0-4 property: strict [&mut Int] params match iff the conventions agree"
    ref_int ref_int strict_match strict_mismatch

let () =
  Printf.printf "signature identity self-check (P0-1..P0-4)\n";
  check_p01 ();
  check_p02 ();
  check_p04 ();
  check_p04_strict ();
  check_convention_property ();
  Printf.printf "OK: signature identity self-check passed\n";
  exit 0
