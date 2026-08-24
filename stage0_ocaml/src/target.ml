(* target.ml + cfg.ml — Seed targets and @cfg elimination (audit §22).

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

(* cfg.ml — @cfg attribute evaluation: items whose cfg does not match the
   target are eliminated before semantic processing. *)
module Cfg = struct
  type attr = {
    name : string;              (* e.g. "cfg" *)
    args : Ast.attribute_arg list;
  }

  type env = { target : t }

  let target_arch (e : env) = arch_to_string e.target.arch
  let target_os (e : env) = os_to_string e.target.os

  (* Evaluate a single attribute argument against the environment. *)
  let rec eval_arg (e : env) (arg : Ast.attribute_arg) : bool option =
    match arg with
    | Ast.AttrIdent "target_arch" -> Some true
    | Ast.AttrIdent "target_os" -> Some true
    | Ast.AttrIdent "unix" -> Some true
    | Ast.AttrIdent "not" -> Some true
    | Ast.AttrIdent _ -> None
    | Ast.AttrString s -> (
        match s with
        | "aarch64" | "x86_64" | "macos" | "linux" | "unix" -> Some true
        | _ -> Some false)
    | Ast.AttrKeyValue (k, v) -> (
        match k with
        | "target_arch" -> Some (v = target_arch e)
        | "target_os" -> Some (v = target_os e)
        | _ -> Some false)
    | Ast.AttrNested (k, inner) -> (
        match k with
        | "not" -> (
            match inner with
            | i :: _ -> (
                match eval_arg e i with Some b -> Some (not b) | None -> None)
            | [] -> Some false)
        | "all" -> Some (List.for_all (fun i -> eval_arg e i = Some true) inner)
        | "any" -> Some (List.exists (fun i -> eval_arg e i = Some true) inner)
        | _ -> Some false)
    | Ast.AttrInt _ -> None

  (* An item's cfg attribute list: True = keep, False = eliminate,
     None = no cfg attribute (keep). *)
  let item_active (e : env) (item : Ast.item) : bool =
    let cfg_attrs =
      List.filter (fun a -> a.Ast.a_name = "cfg") item.Ast.attributes
    in
    if cfg_attrs = [] then true
    else
      List.for_all
        (fun a ->
          let results = List.map (eval_arg e) a.Ast.a_args in
          match results with
          | [] -> true
          | _ -> List.for_all (fun r -> r = Some true) results)
        cfg_attrs
end
