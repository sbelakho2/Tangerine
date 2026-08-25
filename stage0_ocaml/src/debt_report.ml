(* debt_report.ml — stable diagnostic-debt accounting (audit P1-1).

   The typechecker's error surface is a plain string list; this module
   assigns every diagnostic a STABLE, machine-readable category by
   matching the EXISTING message texts (the messages are never reworded
   — classification is a pure, deterministic function over the strings
   the checker already produces).  Category names are fixed and the
   bucket order is stable, so a debt report is comparable byte-for-byte
   across runs of the same code, and the health gate can reject any
   per-category increase without relying on a single scalar canary.

   The minimum category set (audit P1-1):
     unresolved_type, unresolved_callable, unresolved_module,
     cannot_infer_generic, type_mismatch, obligation, duplicate_decl,
     other. *)

let categories : string list =
  [
    "unresolved_type";
    "unresolved_callable";
    "unresolved_module";
    "cannot_infer_generic";
    "type_mismatch";
    "obligation";
    "duplicate_decl";
    "other";
  ]

type t = {
  buckets : (string * int) list;  (* one entry per category, categories order *)
  total : int;
  primaries : int;   (* root-failure diagnostics (first symptom per item) *)
  secondaries : int; (* cascade diagnostics (item whose registration failed) *)
}

let empty : t =
  { buckets = List.map (fun c -> (c, 0)) categories; total = 0; primaries = 0; secondaries = 0 }

(* Substring test (stdlib < 5.3 portable). *)
let contains_sub (s : string) (sub : string) : bool =
  let n = String.length s and m = String.length sub in
  if m = 0 then true
  else if m > n then false
  else begin
    let rec go i =
      if i + m > n then false
      else if String.sub s i m = sub then true
      else go (i + 1)
    in
    go 0
  end

(* Ordered first-match pattern table.  The order IS the spec: it is
   fixed, so the classification of any message is stable across runs and
   across refactors that do not reword the messages.  More specific
   phrases precede the general ones they would otherwise shadow. *)
let patterns : (string * string) list =
  [
    (* cannot_infer_generic: inference of generic variables / params *)
    ("cannot infer", "cannot_infer_generic");
    ("Type_param(s) in concrete execution position", "cannot_infer_generic");
    ("unsolved type variable", "cannot_infer_generic");
    ("type parameters do not take arguments", "cannot_infer_generic");
    ("too many type arguments", "cannot_infer_generic");
    ("type parameter `", "cannot_infer_generic");
    (* unresolved_type: type / type-member / trait / variant resolution *)
    ("unknown type `", "unresolved_type");
    ("unknown nominal type `", "unresolved_type");
    ("unknown trait `", "unresolved_type");
    ("unknown field `", "unresolved_type");
    ("unknown variant `", "unresolved_type");
    ("unknown identity", "unresolved_type");
    ("Self is only available", "unresolved_type");
    ("does not take arguments", "unresolved_type");
    ("associated type `", "unresolved_type");
    ("trait-object types", "unresolved_type");
    ("FieldId", "unresolved_type");
    ("VariantId", "unresolved_type");
    (* unresolved_callable: name / function / method / call resolution *)
    ("unknown function `", "unresolved_callable");
    ("unknown name `", "unresolved_callable");
    ("unknown variable `", "unresolved_callable");
    ("has no method `", "unresolved_callable");
    ("cannot call a value of type ", "unresolved_callable");
    ("too many arguments", "unresolved_callable");
    ("too few arguments", "unresolved_callable");
    ("is a function; call it with arguments", "unresolved_callable");
    ("DefId", "unresolved_callable");
    ("unresolved call", "unresolved_callable");
    ("missing argument access effects", "unresolved_callable");
    (* unresolved_module: module-level resolution failures *)
    ("not a module", "unresolved_module");
    (* type_mismatch: type-shape / arity / operation domain errors *)
    ("type mismatch", "type_mismatch");
    ("cannot cast ", "type_mismatch");
    ("cannot index ", "type_mismatch");
    ("cannot iterate ", "type_mismatch");
    ("cannot dereference ", "type_mismatch");
    ("cannot project ", "type_mismatch");
    ("operator requires matching numeric operands", "type_mismatch");
    ("bitwise operator requires integer operands", "type_mismatch");
    ("unary minus requires a number", "type_mismatch");
    ("requires Bool", "type_mismatch");
    ("requires an integer", "type_mismatch");
    ("requires an Option or Result", "type_mismatch");
    ("tuple pattern requires a tuple type", "type_mismatch");
    ("tuple pattern arity mismatch", "type_mismatch");
    ("tuple index ", "type_mismatch");
    ("or-pattern alternatives bind different types", "type_mismatch");
    ("range pattern ", "type_mismatch");
    ("is not a struct", "type_mismatch");
    ("is not an enum", "type_mismatch");
    ("is not a nominal type", "type_mismatch");
    ("type argument(s)", "type_mismatch");
    (" field(s)", "type_mismatch");
    ("incompatible with the expected function type", "type_mismatch");
    ("recursive type", "type_mismatch");
    (* obligation: trait obligations / where clauses / contracts *)
    ("unsatisfied", "obligation");
    ("obligation", "obligation");
    ("trait contract", "obligation");
    (* duplicate_decl: duplicate declarations *)
    ("duplicate ", "duplicate_decl");
  ]

let classify (msg : string) : string =
  match List.find_opt (fun (p, _) -> contains_sub msg p) patterns with
  | Some (_, c) -> c
  | None -> "other"

(* Classify the typechecker's raw error strings.  Every string is
   classified exactly once; the bucket counts therefore always sum to
   the total. *)
let secondary_prefix = "[secondary] "

let of_errors (errors : string list) : t =
  let tbl = Hashtbl.create (List.length categories) in
  let primaries = ref 0 and secondaries = ref 0 in
  List.iter
    (fun e ->
      if String.length e >= String.length secondary_prefix
      && String.sub e 0 (String.length secondary_prefix) = secondary_prefix
      then incr secondaries
      else incr primaries;
      let c = classify e in
      Hashtbl.replace tbl c (1 + Option.value ~default:0 (Hashtbl.find_opt tbl c)))
    errors;
  let buckets = List.map (fun c -> (c, Option.value ~default:0 (Hashtbl.find_opt tbl c))) categories in
  { buckets; total = List.length errors; primaries = !primaries; secondaries = !secondaries }

(* The requested public entry: classify a Diagnostic bag's messages. *)
let debt_report (ds : Diagnostic.diagnostic list) : t =
  of_errors (List.map (fun d -> d.Diagnostic.message) ds)

let sum_reports (reps : t list) : t =
  List.fold_left
    (fun acc r ->
      {
        buckets =
          List.map2
            (fun (c, n1) (_, n2) -> (c, n1 + n2))
            acc.buckets r.buckets;
        total = acc.total + r.total;
        primaries = acc.primaries + r.primaries;
        secondaries = acc.secondaries + r.secondaries;
      })
    empty reps

(* Machine-readable emission block: one `debt: <category> <count>` line
   per category (fixed order, zeros included) plus `debt_total: <K>`. *)
let to_lines (r : t) : string list =
  List.map (fun (c, n) -> Printf.sprintf "debt: %s %d" c n) r.buckets
  @ [
      Printf.sprintf "debt_total: %d" r.total;
      Printf.sprintf "debt_primary: %d" r.primaries;
      Printf.sprintf "debt_secondary: %d" r.secondaries;
    ]

let emit (errors : string list) : unit =
  List.iter print_endline (to_lines (of_errors errors))

(* Invariant used by the self-check: bucket counts sum to the total. *)
let sum_ok (r : t) : bool =
  List.fold_left (fun acc (_, n) -> acc + n) 0 r.buckets = r.total
