(* bootstrap_manifest.mli *)

type module_entry = {
  path : string list;   (* logical module path, e.g. ["std"; "core"] *)
  file : string;        (* source file implementing the module *)
}

type t

val create : module_entry list -> t
val entries : t -> module_entry list
val find : t -> string list -> module_entry option
val single : file:string -> path:string list -> t
