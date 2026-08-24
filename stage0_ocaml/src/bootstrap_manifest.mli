(* bootstrap_manifest.mli — public surface (audit §20). *)

type module_entry = {
  path : string list;   (* logical module path, e.g. ["std"; "core"] *)
  file : string;        (* repository-relative source file *)
}

type t

val entries : t -> module_entry list
val find : t -> string list -> module_entry option
val version_of : t -> string option
val fingerprint : t -> string

(* Load and validate the manifest: unknown record types rejected,
   duplicate paths rejected, absolute paths rejected, `..` rejected,
   symlink escape rejected, files must exist, no duplicate canonical
   file. *)
val load : repo_root:string -> manifest_path:string -> (t, string) result

(* Adhoc single-module manifest (standalone corpus parsing). *)
val single : file:string -> path:string list -> t
