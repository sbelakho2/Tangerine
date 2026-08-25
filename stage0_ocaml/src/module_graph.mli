(* module_graph.mli — public surface.

   Uniqueness contract: registering the same logical module path twice
   (two manifest entries or two inline declarations resolving to one
   path) hard-fails with Invalid_argument — a map entry is never
   silently replaced. If two logical routes reach the same physical
   source (same canonical `real`), the source module is modeled once and
   the additional route is an alias pointing at the same node id. *)

type module_node = {
  node_id : Ids.Module_id.t;
  node_path : string list;              (* full qualified path *)
  node_file : string;                   (* source file *)
  node_parent : Ids.Module_id.t option; (* None for file modules *)
  node_items : Ast.item list;           (* items in source order *)
  node_program : Ast.program;           (* the owning file's program *)
}

type t = {
  nodes : module_node list;             (* file modules in manifest order, then inline subtrees *)
  node_count : int;
  item_count : int;
  state : state;
}

and state

val create : Bootstrap_manifest.t -> Diagnostic.bag -> t
val create_with_root : string -> Bootstrap_manifest.t -> Diagnostic.bag -> t

(* Build the graph from the manifest's retained source snapshots: no file
   re-read, so the parsed graph is exactly the fingerprinted closure. *)
val create_with_sources : Bootstrap_manifest.t -> Diagnostic.bag -> t
val source_map : t -> Span.source_map
val find_module_by_path : t -> string list -> module_node option
val find_module_by_id : t -> Ids.Module_id.t -> module_node option
val module_id_of_path : t -> string list -> Ids.Module_id.t option
val children_of : t -> Ids.Module_id.t -> Ids.Module_id.t list
