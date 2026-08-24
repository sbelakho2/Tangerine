(* bootstrap_manifest.ml — The bootstrap manifest (audit §11).

   Module identity is provided by the manifest loader, never derived from
   OS paths. Each entry pairs a logical module path (the qualified path
   that names the module in source, e.g. ["std"; "core"]) with the source
   file that implements it. Entries are kept in manifest (dependency)
   order; every consumer iterates in this order. *)

type module_entry = {
  path : string list;   (* logical module path, e.g. ["std"; "core"] *)
  file : string;        (* source file implementing the module *)
}

type t = {
  entries : module_entry list;  (* manifest order *)
}

let create (entries : module_entry list) : t = { entries }

let entries (m : t) : module_entry list = m.entries

let find (m : t) (path : string list) : module_entry option =
  List.find_opt (fun e -> e.path = path) m.entries

let single ~(file : string) ~(path : string list) : t = create [ { path; file } ]
