(* module_graph.ml — The module graph (audit §11, §24).

   Built from the bootstrap manifest: each manifest entry is parsed into
   a file module node; inline `module ... end` declarations become child
   nodes in source order (pre-order). Every module — file or inline —
   receives a unique, deterministic Module_id: file modules in manifest
   order (0, 1, 2, ...), inline modules immediately after their enclosing
   file module in pre-order DFS.

   All iteration over the graph is deterministic (lists in construction
   order, Maps keyed by path/id). There is no Hashtbl iteration anywhere. *)

module SMap = Util.StringMap
module IntMap = Map.Make (Int)

type module_node = {
  node_id : Ids.Module_id.t;
  node_path : string list;       (* full qualified path *)
  node_file : string;            (* source file *)
  node_parent : Ids.Module_id.t option;  (* None for file modules *)
  node_items : Ast.item list;    (* items in source order *)
  node_program : Ast.program;    (* the owning file's program *)
}

type state = {
  by_path : int SMap.t;          (* joined path -> module id *)
  by_id : module_node IntMap.t;  (* module id -> node *)
  children : int list IntMap.t;  (* module id -> child ids, source order *)
  sm : Span.source_map;          (* shared source map for diagnostics *)
}

type t = {
  nodes : module_node list;      (* file modules in manifest order, then inline subtrees *)
  node_count : int;
  item_count : int;
  state : state;
}

let join_path (p : string list) : string = String.concat "::" p

let parse_one (sm : Span.source_map) (entry : Bootstrap_manifest.module_entry)
    (diags : Diagnostic.bag) : Ast.program option =
  match Source_loader.load entry.Bootstrap_manifest.file with
  | Error _ ->
      Diagnostic.error diags "E1000"
        (Printf.sprintf "cannot read source file '%s' for module '%s'"
           entry.Bootstrap_manifest.file (join_path entry.Bootstrap_manifest.path))
        Span.synthetic;
      None
  | Ok src ->
      let file_id = Span.add_file sm src.Source.name src in
      let lx = Lexer.create src.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      let program = Parser.parse tokens src.Source.bytes file_id diags entry.Bootstrap_manifest.path in
      if not (Diagnostic.has_errors diags) then Verify.verify diags program;
      Some program

(* Split a `module a::b` declaration name into segments (mirrors the
   parser's inline-module path handling). *)
let module_name_segments (name : string) : string list =
  String.split_on_char ':' name |> List.filter (fun s -> s <> "")

let create (manifest : Bootstrap_manifest.t) (diags : Diagnostic.bag) : t =
  let sm = Span.create () in
  let next_id = ref 0 in
  let nodes = ref [] in
  let item_count = ref 0 in
  let by_path = ref SMap.empty in
  let by_id = ref IntMap.empty in
  let children = ref IntMap.empty in
  let assign_id () =
    let i = !next_id in
    incr next_id;
    Ids.Module_id.make i
  in
  let add_node (node : module_node) =
    nodes := node :: !nodes;
    by_path := SMap.add (join_path node.node_path) node.node_id !by_path;
    by_id := IntMap.add node.node_id node !by_id;
    children := IntMap.add node.node_id [] !children;
    item_count := !item_count + List.length node.node_items
  in
  let add_child (parent : Ids.Module_id.t) (child : Ids.Module_id.t) =
    let cur =
      match IntMap.find_opt parent !children with
      | Some l -> l
      | None -> []
    in
    children := IntMap.add parent (child :: cur) !children
  in
  let rec collect_inline (parent : module_node) (items : Ast.item list) : unit =
    List.iter
      (fun it ->
        match it.Ast.kind with
        | Ast.ModuleDef d -> (
            match d.Ast.m_items with
            | None -> ()
            | Some inner ->
                let segs = module_name_segments d.Ast.m_name in
                let cpath = parent.node_path @ segs in
                let cid = assign_id () in
                let cnode =
                  {
                    node_id = cid;
                    node_path = cpath;
                    node_file = parent.node_file;
                    node_parent = Some parent.node_id;
                    node_items = inner;
                    node_program = parent.node_program;
                  }
                in
                add_node cnode;
                add_child parent.node_id cid;
                collect_inline cnode inner)
        | _ -> ())
      items
  in
  List.iter
    (fun entry ->
      match parse_one sm entry diags with
      | None -> ()
      | Some program ->
          let fid = assign_id () in
          let fnode =
            {
              node_id = fid;
              node_path = entry.Bootstrap_manifest.path;
              node_file = entry.Bootstrap_manifest.file;
              node_parent = None;
              node_items = program.Ast.items;
              node_program = program;
            }
          in
          add_node fnode;
          collect_inline fnode program.Ast.items)
    (Bootstrap_manifest.entries manifest);
  let nodes = List.rev !nodes in
  {
    nodes;
    node_count = List.length nodes;
    item_count = !item_count;
    state =
      { by_path = !by_path; by_id = !by_id; children = IntMap.map List.rev !children; sm };
  }

let source_map (g : t) : Span.source_map = g.state.sm

let find_module_by_path (g : t) (path : string list) : module_node option =
  match SMap.find_opt (join_path path) g.state.by_path with
  | None -> None
  | Some id -> IntMap.find_opt id g.state.by_id

let module_id_of_path (g : t) (path : string list) : Ids.Module_id.t option =
  match SMap.find_opt (join_path path) g.state.by_path with
  | None -> None
  | Some id -> Some (Ids.Module_id.make id)

let find_module_by_id (g : t) (id : Ids.Module_id.t) : module_node option =
  IntMap.find_opt (Ids.Module_id.to_int id) g.state.by_id

let children_of (g : t) (id : Ids.Module_id.t) : Ids.Module_id.t list =
  match IntMap.find_opt (Ids.Module_id.to_int id) g.state.children with
  | None -> []
  | Some ids -> List.map Ids.Module_id.make ids
