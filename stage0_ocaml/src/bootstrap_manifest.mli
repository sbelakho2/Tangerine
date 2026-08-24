(* bootstrap_manifest.mli — public surface (audit §20). *)

type module_entry = {
  path : string list;   (* logical module path, e.g. ["std"; "core"] *)
  file : string;        (* repository-relative source file *)
  real : string;        (* canonical resolved absolute path *)
  source : string;      (* validated source bytes (UTF-8, security-scanned) *)
  source_hash : string; (* SHA-256 (hex) of source bytes *)
}

type t

val entries : t -> module_entry list
val find : t -> string list -> module_entry option
val version_of : t -> string option
val fingerprint : t -> string

(* Load and validate the manifest: unknown record types rejected,
   duplicate paths rejected, absolute paths rejected, `..` rejected,
   symlink escape rejected, files must exist and be readable, no
   duplicate canonical file. Each source file is read exactly once;
   its bytes and SHA-256 are retained in the entry (the fingerprint
   covers them, so editing a source file changes the fingerprint). *)
val load : repo_root:string -> manifest_path:string -> (t, string) result

(* Return a copy of the manifest in which the entry with the given logical
   path has its source bytes replaced; the source hash and fingerprint are
   recomputed over the new bytes. *)
val with_entry_source : t -> string list -> string -> t

(* Adhoc single-module manifest (standalone corpus parsing). *)
val single : file:string -> path:string list -> t
