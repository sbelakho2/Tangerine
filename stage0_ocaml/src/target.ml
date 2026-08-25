(* target.ml + cfg.ml — Seed targets and @cfg elimination (audit §22, @cfg P0).

   Only the target combinations actually used to bootstrap native stage1
   are supported; anything else errors. The target passed to stage0 when
   producing stage1 determines cfg evaluation — never inferred from the
   OCaml process. *)

type arch = Aarch64 | X86_64

type os = MacOS | Linux

type endian = Little

type t = {
  triple : string;
  arch : arch;
  os : os;
  pointer_width : int;
  endian : endian;
}

let arch_to_string = function Aarch64 -> "aarch64" | X86_64 -> "x86_64"

let os_to_string = function MacOS -> "apple-darwin" | Linux -> "unknown-linux-gnu"

let to_string (t : t) =
  Printf.sprintf "%s-%s" (arch_to_string t.arch) (os_to_string t.os)

let unsupported_triple (triple : string) : (t, string) result =
  match triple with
  | "aarch64-apple-darwin" ->
      Ok { triple; arch = Aarch64; os = MacOS; pointer_width = 64; endian = Little }
  | "aarch64-unknown-linux-gnu" ->
      Ok { triple; arch = Aarch64; os = Linux; pointer_width = 64; endian = Little }
  | "x86_64-apple-darwin" ->
      Ok { triple; arch = X86_64; os = MacOS; pointer_width = 64; endian = Little }
  | "x86_64-unknown-linux-gnu" ->
      Ok { triple; arch = X86_64; os = Linux; pointer_width = 64; endian = Little }
  | other -> Error (Printf.sprintf "unsupported seed target triple '%s'" other)

let of_string (triple : string) : t =
  match unsupported_triple triple with
  | Ok t -> t
  | Error msg -> failwith msg

(* cfg.ml — target-conditioned @cfg declaration elimination (audit @cfg P0).

   The pass runs EARLY in the pipeline — after the parse/dependency merge,
   BEFORE the resolver's duplicate/name registration and the type checker —
   over every module program: an item whose @cfg predicates contradict the
   COMPILE TARGET (the SAME Target.t the rest of the driver uses) is
   PHYSICALLY REMOVED from the program's item list before anything else
   consumes it. The elimination is FINAL: an eliminated declaration does
   not exist for this target, and a kept item that references an
   eliminated name fails the resolver's standard unresolved-name error —
   no reference, no import, no retention can resurrect it.

   FAIL-CLOSED (the kernel's strict semantics, hardened): an empty @cfg()
   is the E108 error; a malformed predicate (a bare key without a value,
   an odd or unknown group) and a condition on an unknown target key are
   errors too — a bad gate NEVER silently stays active (which would make
   the gated declaration unconditionally present) and never silently
   evaluates false (which would unconditionally delete it). The kernel's
   parser rejects empty @cfg() at parse time with
   ErrorCode::E108InvalidCfgPredicate; the OCaml seed's parser collects
   attribute arguments verbatim, so the elimination pass owns the same
   validation here. *)

module Cfg_context = struct
  type seed = t

  type t = { target : seed }

  let of_target (target : seed) : t = { target }

  (* The SHORT target names the @cfg predicates use — the kernel's
     cfg_target_os_name / cfg_target_arch_name ("macos"/"linux"/"windows"
     and "aarch64"/"x86_64") — NOT the triple's OS spelling. *)
  let target_arch (c : t) : string = arch_to_string c.target.arch

  let target_os (c : t) : string =
    match c.target.os with MacOS -> "macos" | Linux -> "linux"
end

(* A single key = value condition against the target context. An unknown
   key (a bare feature flag, a non-target dimension) is an ERROR: the
   TargetSpec carries no such dimension, and a gate on one must not be
   silently treated as false — that would silently DELETE the gated
   declaration on every target. *)
let cfg_simple_holds (c : Cfg_context.t) (key : string) (value : string) :
    (bool, string * string) result =
  match key with
  | "target_arch" -> Ok (Cfg_context.target_arch c = value)
  | "target_os" -> Ok (Cfg_context.target_os c = value)
  | other ->
      Error
        ( "E110",
          Printf.sprintf
            "cfg: unknown target key '%s' in @cfg predicate (supported keys: target_os, target_arch); the gated declaration is not silently kept"
            other )

(* A key = value condition inside a not/any/all group. The OCaml parser
   drops the '=' tokens inside nested argument lists, so a condition is
   the AttrIdent key followed by its AttrIdent/AttrString/AttrInt
   value. *)
let cfg_pair_holds (c : Cfg_context.t) (k : Ast.attribute_arg) (v : Ast.attribute_arg) :
    (bool, string * string) result =
  match (k, v) with
  | Ast.AttrIdent key, (Ast.AttrString value | Ast.AttrIdent value | Ast.AttrInt value) ->
      cfg_simple_holds c key value
  | _ ->
      Error
        ( "E109",
          "cfg: malformed condition in @cfg predicate: expected a target_os/target_arch = \"value\" pair" )

(* any(...) / all(...) groups: any holds iff at least one condition holds
   (an empty group is false); all holds iff every condition holds (an
   empty group is true). *)
let cfg_group_holds (c : Cfg_context.t) (inner : Ast.attribute_arg list)
    (is_any : bool) : (bool, string * string) result =
  let rec go acc = function
    | [] -> Ok acc
    | k :: v :: rest -> (
        match cfg_pair_holds c k v with
        | Ok b ->
            if is_any && b then Ok true
            else if (not is_any) && not b then Ok false
            else go acc rest
        | Error e -> Error e)
    | _ ->
        Error
          ("E109", "cfg: malformed @cfg group: conditions must be key = value pairs")
  in
  go (if is_any then false else true) inner

(* not(...): negates the following condition or any/all group. *)
let cfg_not_holds (c : Cfg_context.t) (inner : Ast.attribute_arg list) :
    (bool, string * string) result =
  match inner with
  | Ast.AttrIdent "any" :: rest -> (
      match cfg_group_holds c rest true with
      | Ok b -> Ok (not b)
      | Error e -> Error e)
  | Ast.AttrIdent "all" :: rest -> (
      match cfg_group_holds c rest false with
      | Ok b -> Ok (not b)
      | Error e -> Error e)
  | [ k; v ] -> (
      match cfg_pair_holds c k v with
      | Ok b -> Ok (not b)
      | Error e -> Error e)
  | _ ->
      Error
        ( "E109",
          "cfg: malformed @cfg(not(...)) predicate: expected one target_os/target_arch = \"value\" condition or a not(any(...))/not(all(...)) group" )

(* Evaluate one @cfg attribute's argument list. The parser emits:
   - AttrKeyValue (k, v) for a top-level `k = v`;
   - AttrNested ("not"|"any"|"all", pairs) for the group forms;
   - a single AttrIdent for a bare key (malformed — no value);
   - [] for @cfg() (the E108 error). *)
let eval_cfg_args (c : Cfg_context.t) (args : Ast.attribute_arg list) :
    (bool, string * string) result =
  match args with
  | [] -> Error ("E108", "E108: @cfg requires a predicate (e.g. @cfg(target_os = \"linux\"))")
  | [ Ast.AttrKeyValue (k, v) ] -> cfg_simple_holds c k v
  | [ Ast.AttrNested (kind, inner) ] -> (
      match kind with
      | "not" -> cfg_not_holds c inner
      | "any" -> cfg_group_holds c inner true
      | "all" -> cfg_group_holds c inner false
      | other ->
          Error
            ( "E109",
              Printf.sprintf "cfg: malformed @cfg predicate: unknown group '%s'" other ))
  | [ Ast.AttrIdent k ] ->
      Error
        ( "E109",
          Printf.sprintf
            "cfg: malformed @cfg predicate: '%s' is not a condition (expected %s = \"value\")" k
            k )
  | _ ->
      Error
        ( "E109",
          "cfg: malformed @cfg predicate: expected a single target_os/target_arch = \"value\" condition or a not/any/all group" )

type cfg_error = {
  code : string;
  message : string;
  span : Span.span;
}

(* Whether one @cfg attribute holds for the target. *)
let cfg_attr_active (c : Cfg_context.t) (a : Ast.attribute) : (bool, cfg_error) result =
  match eval_cfg_args c a.Ast.a_args with
  | Error (code, message) -> Error { code; message; span = a.Ast.a_span }
  | Ok b -> Ok b

(* An item is active iff every @cfg attribute it carries holds; an item
   with no @cfg attribute is always active. *)
let item_active (c : Cfg_context.t) (item : Ast.item) : (bool, cfg_error) result =
  let rec go = function
    | [] -> Ok true
    | a :: rest ->
        if a.Ast.a_name <> "cfg" then go rest
        else
          match cfg_attr_active c a with
          | Error e -> Error e
          | Ok true -> go rest
          | Ok false -> Ok false
  in
  go item.Ast.attributes

(* Filter one item list: (kept items, removed count, removed spans).
   A removed item contributes its OWN span (maximal: an eliminated inline
   module covers its children, whose spans are inside it and must not be
   cut separately). *)
let rec eliminate_items (c : Cfg_context.t) (items : Ast.item list) :
    (Ast.item list * int * Span.span list, cfg_error) result =
  let rec go kept removed spans = function
    | [] -> Ok (List.rev kept, removed, List.rev spans)
    | it :: rest -> (
        match item_active c it with
        | Error e -> Error e
        | Ok false -> go kept (removed + 1) (it.Ast.span :: spans) rest
        | Ok true -> (
            match eliminate_nested c it with
            | Error e -> Error e
            | Ok (it', nested_removed, nested_spans) ->
                go (it' :: kept) (removed + nested_removed)
                  (List.rev_append nested_spans spans)
                  rest))
  in
  go [] 0 [] items

(* Rebuild a kept item's nested item lists (inline modules, edition
   blocks, extern blocks): the inner @cfg-gated declarations are removed
   too and their spans are reported. *)
and eliminate_nested (c : Cfg_context.t) (item : Ast.item) :
    (Ast.item * int * Span.span list, cfg_error) result =
  match item.Ast.kind with
  | Ast.ModuleDef d -> (
      match d.Ast.m_items with
      | None -> Ok (item, 0, [])
      | Some inner -> (
          match eliminate_items c inner with
          | Ok (inner', n, spans) ->
              Ok
                ( { item with Ast.kind = Ast.ModuleDef { d with Ast.m_items = Some inner' } },
                  n,
                  spans )
          | Error e -> Error e))
  | Ast.EditionDecl d -> (
      match d.Ast.ed_items with
      | None -> Ok (item, 0, [])
      | Some inner -> (
          match eliminate_items c inner with
          | Ok (inner', n, spans) ->
              Ok
                ( { item with Ast.kind = Ast.EditionDecl { d with Ast.ed_items = Some inner' } },
                  n,
                  spans )
          | Error e -> Error e))
  | Ast.ExternBlock d -> (
      match eliminate_items c d.Ast.ex_items with
      | Ok (inner', n, spans) ->
          Ok
            ( { item with Ast.kind = Ast.ExternBlock { d with Ast.ex_items = inner' } },
              n,
              spans )
      | Error e -> Error e)
  | _ -> Ok (item, 0, [])

(* The fail-closed elimination result: the filtered program, the number
   of items physically removed (top-level plus nested), and the MAXIMAL
   removed spans (one per top-level eliminated item; nested removals
   contribute their own spans) — the driver cuts these out of the
   module's source snapshot so the re-parsed program (and everything
   downstream, including the resolver's registration) never sees an
   eliminated declaration. *)
type elimination_result = {
  elim_program : Ast.program;
  elim_removed : int;
  elim_spans : Span.span list;
}

let cfg_error_diagnostic (e : cfg_error) : Diagnostic.diagnostic =
  {
    Diagnostic.severity = Diagnostic.Error;
    code = e.code;
    message = e.message;
    span = e.span;
  }

(* The @cfg elimination pass over one program (audit @cfg P0). Fail
   closed: on the FIRST empty/malformed/unknown-key predicate the
   original program is returned untouched alongside the diagnostics —
   nothing is partially eliminated. *)
let eliminate_program (c : Cfg_context.t) (program : Ast.program) :
    (elimination_result, Diagnostic.diagnostic list) result =
  match eliminate_items c program.Ast.items with
  | Error e ->
      Error
        [
          cfg_error_diagnostic e;
          {
            Diagnostic.severity = Diagnostic.Error;
            code = "E108";
            message =
              "cfg elimination failed: an @cfg predicate is empty, malformed, or references an unknown target key; the program is NOT processed with a partially-active gate";
            span = e.span;
          };
        ]
  | Ok (items, removed, spans) ->
      Ok
        {
          elim_program = { program with Ast.items };
          elim_removed = removed;
          elim_spans = spans;
        }

(* The fail-closed transformation API:
   eliminate_cfg : Cfg_context.t -> Ast.program -> (Ast.program, Diagnostic.t list) result. *)
let eliminate_cfg (c : Cfg_context.t) (program : Ast.program) :
    (Ast.program, Diagnostic.diagnostic list) result =
  match eliminate_program c program with
  | Ok r -> Ok r.elim_program
  | Error ds -> Error ds
