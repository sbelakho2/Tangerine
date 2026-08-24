(* module_graph.mli — public surface. *)

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
val source_map : t -> Span.source_map
val find_module_by_path : t -> string list -> module_node option
val find_module_by_id : t -> Ids.Module_id.t -> module_node option
val module_id_of_path : t -> string list -> Ids.Module_id.t option
val children_of : t -> Ids.Module_id.t -> Ids.Module_id.t list
