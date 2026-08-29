(* mir_lower.ml — Typed AST → Seed MIR lowering (audit §34, §35).

   Lowering operates on the syntax AST plus a name→type environment
   produced by the type checker; every lowered construct is typed. If a
   construct is reached with an unknown type, lowering raises Seed_bug
   (never produces Nop).

   Seed-surface constructs implemented here:

   - Variant match arms (Ast.PatVariant): the subject is an enum value.
     The Seed VM represents an enum as `Vm_value.Enum (tag, payload)` —
     tag = variant index in declaration order, payload = the variant's
     field array (see vm_value.ml).  Lowering emits the subject into a
     local, computes the discriminant with the `Discriminant` rvalue
     (the VM returns the tag as an Int), dispatches with one SwitchInt
     whose targets are the per-variant tags (0-based declaration order,
     matching EnumCtor's tags), and binds each arm's payload fields by
     projecting the subject with [Downcast vid; ConstantIndex i] — the
     Downcast carries the SEMANTIC VariantId (the declaration-order tag
     is metadata in the owner EnumDef; the VM derives it through the
     type table), and the payload is a TUPLE (tuples have no FieldId,
     so payload positions are indexed positionally — the reference's
     TupleIndex form).  Payload binding locals are Copy-read when the
     payload type is copyable (non-copy payload binding fails closed:
     the seed VM's Move operand ignores projections, so a projected move
     would be wrong).

   - `?` (Ast.TryOp): the subject is an Option/Result.  The success
     variant (tag 0) supplies the expression value (the payload read
     via the Downcast/Field projection above); the failure variant
     early-returns from the enclosing function: the subject TRANSFERS
     (moves) into the return slot — never a copy, because the verifier's
     enum Copy rule is recursive (an enum is Copy iff every variant
     payload is Copy) and an owning-payload enum must be moved, not
     bitwise-copied — and `Ret` is emitted, with the function-level
     defer bodies running first.  The subject's type
     must equal the enclosing function's return type (fail-closed
     otherwise).

   - `for x in [..] do` (Ast.ForExpr): a for-loop over a compile-time
     Array literal is UNROLLED into per-element body copies with
     ConstantIndex element reads; any other iterable lowers to a runtime
     counter loop — the container is evaluated once into a local, a
     counter local counts from 0 to Len(container), and each iteration
     reads the element through the dynamic `Seed_mir.Index <counter>`
     projection (the VM executes it and bounds-checks the runtime index
     at execution).

   - defer (Ast.DeferStmt): each function accumulates a defer stack
     (function level; nested scopes are flattened to function level for
     the seed).  Every return terminator — explicit `return`, the `?`
     failure path, and the function's final implicit return — first
     lowers the collected defer bodies inline in reverse declaration
     order (LIFO), then assigns the return slot, then emits Ret.

   - Statics/consts: there is AST plumbing (Ast.ConstDecl/Ast.StaticDecl
     and a Typecheck `consts` registry), but the Mir_lower API carries
     no const/static table and the driver passes `statics = [||]`, so
     names that resolve only to consts/statics fail closed at lowering
     with Seed_bug.  See the statics TODO at the bottom of the file.

   - Closure (Ast.Closure): NOT lowered — the seed VM can construct
     closure objects (ClosureAgg -> Vm_value.Closure) but has no
     closure-CALL path (Seed_mir.Call dispatches compile-time instances
     only), so the Closure branch fails closed with a precise Seed_bug
     and Subset rejects the form (E9040).  The typechecker records no
     closure identity/captures in the typed registry (its check_closure
     computes the captured-name list but discards it), so the
     capture-channel is the next step when the VM's closure model lands. *)

exception Seed_bug of string

let seed_bug fmt = Printf.ksprintf (fun m -> raise (Seed_bug m)) fmt

(* ── Environment ──────────────────────────────────────────────── *)

type callable_entry = {
  ce_callable : int;                    (* resolved callable id *)
  ce_template_args : Type_repr.t array; (* declaration-order template params for generic defs *)
  ce_params : Type_repr.param_type array; (* callee parameter contracts (conventions in order) *)
}

(* The resolved method-instance registry (re-audit: a method call must
   reach lowering with the receiver's typed place AND the resolved
   method instance — the `(owner type name, method) -> instance` pair
   the typechecker's own dispatch uses, carried over from the typed
   registry's methods table).  Each entry carries the method's typed
   signature contracts: me_params.(0) is the SELF parameter (its
   convention is the receiver's access effect at the call site — the
   receiver lowers to a place and is passed as the self argument with
   the read-side of that convention), me_ret is the call's result type,
   and me_instance is the (callable, type_args) identity the method body
   is lowered under — so the emitted User callee resolves against the
   callee function in the program (the verifier/VM dispatch instances
   exactly). *)
type method_entry = {
  me_instance : Instance_id.t;
  me_params : Type_repr.param_type array;
  me_ret : Type_repr.t;
}

type func_env = {
  types : (string * Type_repr.t) list;               (* type name -> repr *)
  values : (string * Type_repr.t) list;              (* global value name -> type *)
  consts : (string * (Type_repr.t * Seed_mir.constant)) list;  (* const/static name -> repr + value *)
  callables : (string * callable_entry) list;        (* function name -> resolved entry *)
  methods : ((string * string) * method_entry) list;  (* (receiver type name, method) -> instance + sig contracts *)
  fn_ret : Type_repr.t;
  (* The typed nominal registry (re-audit finding: Field access reached
     MIR lowering without a typed place (FieldId) rule — the lowerer's
     only struct-field emission channel was the out-of-scope typed
     registry).  Type_id -> (field name, SEMANTIC FieldId, field type)
     triples for every Struct/Enum nominal of the typed registry (enums
     carry no fields — their entries are empty, so a field on an enum
     fails closed instead of mis-projecting).  Field types are recorded
     in the nominal's own parameter scope; the lowering substitutes the
     nominal's generic params with the base type's arguments at each use
     (the substitution's param list is derived from env.types' Named
     (tid, params) entries, which the driver keeps aligned with the
     nominals — the same scheme type_of_syntax uses). *)
  struct_fields : (Ids.Type_id.t * (string * Ids.Field_id.t * Type_repr.t) list) list;
}

(* ── The persistent typed-node channel (re-audit: TypedProgram/TypedHIR
      bridge) ─────────────────────────────────────────────────────
   NodeId (the parser-minted per-expression node identity) -> the
   typechecker's resolved node.
   The typed channel is AUTHORITATIVE when present: a cast's resolved
   target comes from the checker's Named(GenericParamId, ...) with the
   declaration-owned ids, never from type_of_syntax's positional
   KParam(make i) reconstruction.  The channel is threaded into lowering
   through the ~typed_nodes parameter of lower_function_with_variants
   (the driver's typed_nodes_of builds it from the typechecker's env);
   hand-built selfcheck envs omit it ([]) and lowering falls back to the
   syntax-driven channels. *)
type typed_node = {
  tn_type : Type_repr.t;               (* the expr's resolved type *)
  tn_cast_target : Type_repr.t option; (* Ast.Cast: checker-resolved target *)
  tn_call : (Ids.Callable_id.t * Type_repr.t array) option;
  (* Ast.Call: the checker-resolved callee CallableId + the SOLVED
     concrete substitution in declaration order — the exact-arity
     pairing for the User instance the Call terminator emits *)
}

(* ── Variant tables ──────────────────────────────────────────────

   The seed representation of an enum value is
   `Vm_value.Enum (variant_index_in_declaration_order, payload)`
   (vm_value.ml), constructed by EnumCtor and read by Discriminant /
   Downcast / ConstantIndex projections.  Variant indices must therefore
   be consistent across construction sites and match arms within one
   program.  Every spec carries TWO ORTHOGONAL coordinates (audit P0):
   the SEMANTIC VariantId (vs_id — the compile-time identity, minted by
   the resolver and carried through the typechecker's typed nominals
   (nom_variant_ids) into this table by the driver) and the RUNTIME tag
   (vs_index — the declaration-order position, used as the EnumCtor tag
   and the SwitchInt target).  The two are NEVER derived from each
   other: the lowerer emits the spec's vs_id in every Downcast
   projection, and the verifier/VM reconcile it through the enum def's
   vd_id (the runtime tag is def metadata).  The builtin enums Option
   (Some=0, None=1) and Result (Ok=0, Err=1) are NOT exempted from the
   semantic registry: their payloads are derived from the enum's type
   arguments at each use site (the repr), but their IDs come from the
   same typed-nominal channel (the table's vt_builtin — the kernel's
   LangItem Option/Result declarations carry resolver ids); user enums
   are declared by the caller through a variant_table (see
   lower_function_with_variants).  The plain lower_function API (used
   by the driver) lowers with the builtin table only, so user-defined
   enum constructs fail closed there with a Seed_bug pointing at
   lower_function_with_variants. *)

type variant_spec = {
  vs_id : Ids.Variant_id.t;         (* SEMANTIC variant identity (registry-minted — never derived from vs_index) *)
  vs_index : int;                   (* runtime tag = declaration-order variant index *)
  vs_fields : Type_repr.t list;     (* payload field types (concrete) *)
}

(* Semantic variant identity of a table spec: the spec's OWN vs_id —
   the identity the typechecker captured from the resolver's
   closure-wide minting (nom_variant_ids) and the driver carried into
   the table.  NEVER reconstructed from vs_index: the old
   `Variant_id.make (vs_index + 1)` scheme was the audit P0 — the
   resolver's ids are closure-wide dense, not declaration positions, so
   a position-derived id does not belong to the projected base's enum
   def and the verifier's owner-identity rule rejects the Downcast. *)
let semantic_variant_id (spec : variant_spec) : Ids.Variant_id.t = spec.vs_id

type variant_table = {
  vt_enums : (string * (string * variant_spec) list) list;  (* enum name -> variant name -> spec *)
  vt_ctors : (string * (string * string)) list;  (* ctor name -> (enum name, variant name) *)
  vt_builtin : (string * (string * Ids.Variant_id.t) list) list;
  (* builtin enum name -> variant name -> SEMANTIC VariantId.  The
     Option/Result identities come from the SAME semantic registry as
     user enums (the driver reads the typed nominals' nom_variant_ids;
     the kernel's LangItem declarations carry resolver ids) — never
     from the declaration positions.  Lowering with a table lacking the
     registry fails closed. *)
}

let builtin_variant_spec (tbl : variant_table) (enum_name : string) (vname : string)
    (repr : Type_repr.t) : variant_spec option =
  let index_of =
    match enum_name, vname with
    | "Option", "Some" -> Some 0
    | "Option", "None" -> Some 1
    | "Result", "Ok" -> Some 0
    | "Result", "Err" -> Some 1
    | _ -> None
  in
  match index_of with
  | None -> None
  | Some idx ->
      (* the SEMANTIC identity from the registry — fail closed when the
         table carries none (the old position-based manufacture is gone) *)
      let vid =
        match List.assoc_opt enum_name tbl.vt_builtin with
        | Some vmap -> (
            match List.assoc_opt vname vmap with
            | Some vid -> vid
            | None ->
                seed_bug
                  "builtin variant `%s` of `%s` has no SEMANTIC VariantId in the variant table's registry"
                  vname enum_name)
        | None ->
            seed_bug
              "builtin enum `%s` has no SEMANTIC VariantId registry in the variant table (Option/Result need the driver's user_variant_table — never position-derived ids)"
              enum_name
      in
      let args = match repr with Type_repr.Named (_, args) -> args | _ -> [||] in
      let fields =
        match vname with
        | "Some" | "Ok" -> if Array.length args > 0 then [ args.(0) ] else []
        | "Err" -> if Array.length args > 1 then [ args.(1) ] else []
        | _ -> []
      in
      Some { vs_id = vid; vs_index = idx; vs_fields = fields }

let variant_spec_of (_env : func_env) (tbl : variant_table) ~(enum_name : string)
    ~(vname : string) ~(repr : Type_repr.t) : variant_spec =
  match List.assoc_opt enum_name tbl.vt_enums with
  | Some varmap -> (
      match List.assoc_opt vname varmap with
      | Some spec -> spec
      | None ->
          seed_bug "unknown variant `%s` of enum `%s` (no variant table entry)" vname enum_name)
  | None -> (
      match builtin_variant_spec tbl enum_name vname repr with
      | Some spec -> spec
      | None ->
          seed_bug
            "unknown variant `%s` of enum `%s` in lowering (user enums require lower_function_with_variants)"
            vname enum_name)

(* The SEMANTIC spec lookup (re-audit P0 #3): the typed-pattern channel
   carries the variant's VARIANT ID — the identity the typechecker
   resolved from the typed nominal registry (nom_variant_ids) — so the
   lowerer resolves the spec BY ID through the same variant table the
   name-keyed path uses (the driver builds both channels from the same
   typed nominals).  The enum name comes from the match subject's type
   (the checker resolved the pattern against that subject, so the
   variant necessarily belongs to its enum). *)
let variant_spec_of_id (_env : func_env) (tbl : variant_table) ~(enum_name : string)
    (vid : Ids.Variant_id.t) ~(repr : Type_repr.t) : variant_spec =
  match List.assoc_opt enum_name tbl.vt_enums with
  | Some varmap -> (
      match List.find_opt (fun (_, spec) -> Ids.Variant_id.compare spec.vs_id vid = 0) varmap with
      | Some (_, spec) -> spec
      | None ->
          seed_bug "variant id #%d of enum `%s` has no variant table entry"
            (Ids.Variant_id.to_int vid) enum_name)
  | None -> (
      (* the builtin Option/Result: the registry carries the SEMANTIC ids
         (vt_builtin), so resolve the variant NAME by id and build the
         spec through the builtin channel (the runtime tags Some=0,
         None=1, Ok=0, Err=1 are the builtin table's constants) *)
      match List.assoc_opt enum_name tbl.vt_builtin with
      | Some vmap -> (
          match List.find_opt (fun (_, id) -> Ids.Variant_id.compare id vid = 0) vmap with
          | Some (vname, _) -> (
              match builtin_variant_spec tbl enum_name vname repr with
              | Some spec -> spec
              | None ->
                  seed_bug
                    "builtin variant id #%d of enum `%s` has no builtin spec (id %d)"
                    (Ids.Variant_id.to_int vid) enum_name (Ids.Variant_id.to_int vid))
          | None ->
              seed_bug
                "builtin variant id #%d of enum `%s` has no SEMANTIC VariantId registry entry"
                (Ids.Variant_id.to_int vid) enum_name)
      | None ->
          seed_bug
            "enum `%s` has no SEMANTIC VariantId registry in the variant table (the typed-pattern path needs the driver's registry channel)"
            enum_name)

let ctor_of (tbl : variant_table) (n : string) : (string * string) option =  match List.assoc_opt n tbl.vt_ctors with
  | Some pair -> Some pair
  | None -> (
      match n with
      | "Some" | "Option::Some" -> Some ("Option", "Some")
      | "None" | "Option::None" -> Some ("Option", "None")
      | "Ok" | "Result::Ok" -> Some ("Result", "Ok")
      | "Err" | "Result::Err" -> Some ("Result", "Err")
      | _ -> (
          (* the qualified user-enum form `Type::Variant` (E9048
             retirement): the driver's table registers bare ctor names
             only, so a qualified reference resolves through the enum's
             own vt_enums entry (the same table the checker's qualified
             constructor registration names) — the variant must actually
             exist in the enum's table or the lookup misses (the caller
             fails closed) *)
          match String.index_opt n ':' with
          | Some i when i + 1 < String.length n && n.[i + 1] = ':' ->
              let qual = String.sub n 0 i in
              let rest = String.sub n (i + 2) (String.length n - i - 2) in
              (match List.assoc_opt qual tbl.vt_enums with
               | Some vmap ->
                   if List.mem_assoc rest vmap then Some (qual, rest) else None
               | None -> None)
          | _ -> None))

let enum_tid_of (env : func_env) (enum_name : string) : Ids.Type_id.t =
  match List.assoc_opt enum_name env.types with
  | Some (Type_repr.Named (tid, _)) -> tid
  | _ -> seed_bug "enum `%s` has no type identity in the lowering env" enum_name

let enum_name_of_ty (env : func_env) (t : Type_repr.t) : string =
  match t with
  | Type_repr.Named (tid, _) -> (
      match
        List.find_opt
          (fun (_, r) ->
            match r with
            | Type_repr.Named (tid2, _) ->
                Ids.Type_id.compare tid tid2 = 0
            | _ -> false)
          env.types
      with
      | Some (n, _) -> n
      | None -> seed_bug "the match subject's enum type has no name in the lowering env")
  | _ -> seed_bug "variant match subject is not an enum value"

let default_variant_table : variant_table = { vt_enums = []; vt_ctors = []; vt_builtin = [] }

type lower_state = {
  mutable next_local : int;
  mutable next_block : int;
  mutable locals : Type_repr.t array;
  mutable local_names : (int * string) list;
  mutable scope : (string * int) list;      (* name -> local id *)
  mutable blocks : Seed_mir.block list;   (* reversed *)
  mutable cur_block : int;
  mutable cur_stmts : Seed_mir.statement list;  (* reversed *)
  mutable break_target : int option;
  mutable continue_target : int option;
  variants : variant_table;              (* enum variant/constructor identity *)
  mutable defer_stack : Ast.block_body list;  (* function-level defer bodies; head = most recent *)
  (* the persistent typed-node channel: NodeId -> the typechecker's
     resolved node ([] = channel absent) *)
  typed_nodes : (Ids.Node_id.t * typed_node) list;
  (* the typed-pattern channel (re-audit P0 #3): (match NodeId, arm
     index) -> the arm's SEMANTIC pattern tree, resolved ONCE by the
     typechecker ([] = channel absent — hand-built selfcheck envs; the
     driver path always carries the channel, so a missing entry there is
     a checker/lowerer contradiction and fails loudly) *)
  typed_patterns : ((Ids.Node_id.t * int) * Typed_pattern.t) list;
}

(* The typed-node channel lookup: the typechecker's resolved node for an
   expr's NodeId, when the channel is present. *)
let typed_node_of (st : lower_state) (node_id : Ids.Node_id.t) : typed_node option =
  List.assoc_opt node_id st.typed_nodes

(* The typed-pattern channel lookup: the typechecker's semantic pattern
   tree for a match arm (match NodeId, arm index). *)
let typed_pattern_of (st : lower_state) (key : Ids.Node_id.t * int) : Typed_pattern.t option =
  List.assoc_opt key st.typed_patterns

let new_block (st : lower_state) : int =
  let id = st.next_block in
  st.next_block <- st.next_block + 1;
  id

let push_block (st : lower_state) (id : int) : unit =
  (* close the current block with a goto to id, then switch *)
  st.blocks <- { Seed_mir.id = st.cur_block; statements = List.rev st.cur_stmts; terminator = Seed_mir.Goto id } :: st.blocks;
  st.cur_stmts <- [];
  st.cur_block <- id

let fresh_local (st : lower_state) (ty : Type_repr.t) : int =
  let id = st.next_local in
  st.next_local <- st.next_local + 1;
  if id >= Array.length st.locals then
    st.locals <- Array.append st.locals [| ty |]
  else st.locals.(id) <- ty;
  id

let cur_place (_st : lower_state) (id : int) : Seed_mir.place =
  { Seed_mir.local = id; projections = [] }

let local_type (st : lower_state) (id : int) : Type_repr.t option =
  if id >= 0 && id < Array.length st.locals then Some st.locals.(id) else None

let emit (st : lower_state) (s : Seed_mir.statement) : unit =
  st.cur_stmts <- s :: st.cur_stmts

let set_terminator (st : lower_state) (t : Seed_mir.terminator) : unit =
  st.blocks <- { Seed_mir.id = st.cur_block; statements = List.rev st.cur_stmts; terminator = t } :: st.blocks;
  st.cur_stmts <- [];
  st.cur_block <- new_block st

(* Close the current block with a terminator whose continuation is a
   specific block (no stray intermediate block). *)
let set_terminator_to (st : lower_state) (t : Seed_mir.terminator) (cont : int) : unit =
  st.blocks <- { Seed_mir.id = st.cur_block; statements = List.rev st.cur_stmts; terminator = t } :: st.blocks;
  st.cur_stmts <- [];
  st.cur_block <- cont

(* ── Small operand/place helpers ──────────────────────────────── *)

let constant_type_of (c : Seed_mir.constant) : Type_repr.t =
  match c with
  | Seed_mir.Unit -> Type_repr.Unit
  | Seed_mir.Bool _ -> Type_repr.Bool
  | Seed_mir.Integer v ->
      let width = v.Int_value.width and signed = v.Int_value.signed in
      let kind =
        match width, signed with
        | 8, true -> Type_repr.I8 | 16, true -> Type_repr.I16 | 32, true -> Type_repr.I32
        | 64, true -> Type_repr.Int | 128, true -> Type_repr.I128
        | 8, false -> Type_repr.U8 | 16, false -> Type_repr.U16 | 32, false -> Type_repr.U32
        | 64, false -> Type_repr.UInt | 128, false -> Type_repr.U128
        | _ -> Type_repr.Int
      in
      Type_repr.Int kind
  | Seed_mir.Float32 _ -> Type_repr.Float Type_repr.F32
  | Seed_mir.Float64 _ -> Type_repr.Float Type_repr.F64
  | Seed_mir.Char _ -> Type_repr.Char
  | Seed_mir.String _ -> Type_repr.String
  | Seed_mir.Function _ -> Type_repr.Function ([||], Type_repr.Unit)

(* Turn an operand into a place (materializing constants into a local). *)
let materialize_place (st : lower_state) (op : Seed_mir.operand) : Seed_mir.place =
  match op with
  | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p | Seed_mir.Consume p -> p
  | Seed_mir.Constant c ->
      let id = fresh_local st (constant_type_of c) in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Use (Seed_mir.Constant c)));
      cur_place st id

(* The element type of an iterable/indexable type.  Named array types
   (Vec/Array nominals) fail closed: the lowering env carries no
   type-substituted element lookup for them (their element reads lower
   to a dynamic Seed_mir.Index projection, which the verifier only
   admits on Fixed_array bases). *)
let element_type_of (t : Type_repr.t) : Type_repr.t =
  match t with
  | Type_repr.Fixed_array (e, _) -> e
  | Type_repr.String -> Type_repr.Char
  | Type_repr.Tuple _ -> Type_repr.Int Type_repr.Int
  | _ -> seed_bug "element access on a non-iterable type %s (the lowering env carries no type-substituted element lookup for named Vec/Array types; the dynamic Seed_mir.Index projection itself is executable — the verifier only admits it on Fixed_array bases)"
           (Seed_mir.print_type t)

(* Conservative copyability for payload binding: the verifier's enum
   rule is recursive (an enum is Copy iff every variant payload is Copy)
   but the lowering has no def table, so Named values are conservatively
   non-copy (a projected Move is wrong: the seed VM's Move ignores
   projections, so non-copy payload binding fails closed). *)
let rec copyable_ty (t : Type_repr.t) : bool =
  match t with
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _
  | Type_repr.Float _ | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _
  | Type_repr.Function _ | Type_repr.Never | Type_repr.Error ->
      true
  | Type_repr.String -> false
  | Type_repr.Tuple elems -> Array.for_all copyable_ty elems
  | Type_repr.Fixed_array (e, _) -> copyable_ty e
  | Type_repr.Named _ | Type_repr.Type_param _ | Type_repr.Infer_var _ | Type_repr.Int_literal _ -> false

(* ── Defer machinery ─────────────────────────────────────────────

   Function-level defer stack: every DeferStmt pushes its body; every
   exit edge (explicit return, `?` failure early-return, final implicit
   return) re-lowers the collected bodies inline in reverse declaration
   order (LIFO) BEFORE the return slot is assigned, so mutations made by
   the defers are observable in the returned value.  Nested scopes are
   flattened to function level (the seed's lowering never pops scope),
   so a defer declared inside a conditional still runs on every exit —
   documented seed approximation of per-scope cleanup.  emit_defers is
   part of the mutually recursive expression-lowering group because it
   re-lowers defer bodies through lower_block. *)

(* Structural scanners used to fail closed on constructs that would be
   unsound when re-lowered inline (a return inside a defer body would
   recurse at lowering time; break/next inside an unrolled loop would
   target the wrong loop). *)

let rec expr_has_return (e : Ast.expr) : bool =
  match e with
  | Ast.ReturnExpr _ -> true
  | Ast.Block (_, b, _) -> block_has_return b
  | Ast.IfExpr (_, i) ->
      expr_has_return i.Ast.if_condition
      || block_has_return i.Ast.if_then
      || List.exists (fun (_, b) -> block_has_return b) i.Ast.if_elsif
      || (match i.Ast.if_else with Some b -> block_has_return b | None -> false)
      || (match i.Ast.if_let_value with Some v -> expr_has_return v | None -> false)
  | Ast.MatchExpr (_, m) ->
      expr_has_return m.Ast.m_subject
      || List.exists
           (fun arm ->
             expr_has_return arm.Ast.ma_body
             || (match arm.Ast.ma_guard with Some g -> expr_has_return g | None -> false))
           m.Ast.m_arms
  | Ast.WhileExpr (_, w) -> expr_has_return w.Ast.wh_condition || block_has_return w.Ast.wh_body
  | Ast.LoopExpr (_, b, _) -> block_has_return b
  | Ast.ForExpr (_, f) -> expr_has_return f.Ast.for_iterable || block_has_return f.Ast.for_body
  | Ast.UntilExpr (_, u) -> expr_has_return u.Ast.ut_condition || block_has_return u.Ast.ut_body
  | Ast.UnlessExpr (_, u) ->
      expr_has_return u.Ast.un_condition
      || block_has_return u.Ast.un_body
      || (match u.Ast.un_else with Some b -> block_has_return b | None -> false)
  | Ast.Call (_, c, _, args, _) ->
      expr_has_return c || List.exists (fun a -> expr_has_return a.Ast.ca_value) args
  | Ast.Index (_, b, i, _) | Ast.Binary (_, b, _, i, _) | Ast.CompoundAssign (_, b, _, i, _) ->
      expr_has_return b || expr_has_return i
  | Ast.Unary (_, _, e, _) | Ast.TryOp (_, e, _) | Ast.Cast (_, e, _, _) | Ast.AwaitExpr (_, e, _) ->
      expr_has_return e
  | Ast.Field (_, b, _, _) | Ast.Assign (_, b, _, _) ->
      expr_has_return b
  | Ast.BreakExpr (_, Some e, _) -> expr_has_return e
  | Ast.BreakExpr (_, None, _) -> false
  | Ast.Tuple (_, es, _) | Ast.Array (_, es, _) -> List.exists expr_has_return es
  | Ast.ArrayRepeat (_, e1, e2, _) -> expr_has_return e1 || expr_has_return e2
  | Ast.Range (_, e1, e2, _, _) -> expr_has_return e1 || expr_has_return e2
  | _ -> false

and block_has_return (b : Ast.block_body) : bool =
  List.exists stmt_has_return b.Ast.b_stmts
  || (match b.Ast.b_tail with Some t -> expr_has_return t | None -> false)

and stmt_has_return (s : Ast.stmt) : bool =
  match s with
  | Ast.ExprStmt (e, _) -> expr_has_return e
  | Ast.LetBinding (_, _, _, v, _) -> expr_has_return v
  | Ast.DeferStmt (b, _) -> block_has_return b
  | Ast.Attributed (_, inner, _) -> stmt_has_return inner
  | Ast.Item _ | Ast.AttributeStmt _ -> false

let rec expr_has_loop_exit (e : Ast.expr) : bool =
  match e with
  | Ast.BreakExpr _ | Ast.NextExpr _ -> true
  | Ast.Block (_, b, _) -> block_has_loop_exit b
  | Ast.IfExpr (_, i) ->
      expr_has_loop_exit i.Ast.if_condition
      || block_has_loop_exit i.Ast.if_then
      || List.exists (fun (_, b) -> block_has_loop_exit b) i.Ast.if_elsif
      || (match i.Ast.if_else with Some b -> block_has_loop_exit b | None -> false)
  | Ast.MatchExpr (_, m) ->
      expr_has_loop_exit m.Ast.m_subject
      || List.exists
           (fun arm ->
             expr_has_loop_exit arm.Ast.ma_body
             || (match arm.Ast.ma_guard with Some g -> expr_has_loop_exit g | None -> false))
           m.Ast.m_arms
  | Ast.WhileExpr (_, w) -> expr_has_loop_exit w.Ast.wh_condition || block_has_loop_exit w.Ast.wh_body
  | Ast.LoopExpr (_, b, _) -> block_has_loop_exit b
  | Ast.ForExpr (_, f) -> expr_has_loop_exit f.Ast.for_iterable || block_has_loop_exit f.Ast.for_body
  | Ast.UntilExpr (_, u) -> expr_has_loop_exit u.Ast.ut_condition || block_has_loop_exit u.Ast.ut_body
  | Ast.UnlessExpr (_, u) ->
      expr_has_loop_exit u.Ast.un_condition
      || block_has_loop_exit u.Ast.un_body
      || (match u.Ast.un_else with Some b -> block_has_loop_exit b | None -> false)
  | Ast.Call (_, c, _, args, _) ->
      expr_has_loop_exit c || List.exists (fun a -> expr_has_loop_exit a.Ast.ca_value) args
  | Ast.Index (_, b, i, _) | Ast.Binary (_, b, _, i, _) | Ast.CompoundAssign (_, b, _, i, _) ->
      expr_has_loop_exit b || expr_has_loop_exit i
  | Ast.Unary (_, _, e, _) | Ast.TryOp (_, e, _) | Ast.Cast (_, e, _, _) | Ast.AwaitExpr (_, e, _) ->
      expr_has_loop_exit e
  | Ast.Field (_, b, _, _) | Ast.Assign (_, b, _, _) ->
      expr_has_loop_exit b
  | Ast.Tuple (_, es, _) | Ast.Array (_, es, _) -> List.exists expr_has_loop_exit es
  | Ast.ArrayRepeat (_, e1, e2, _) -> expr_has_loop_exit e1 || expr_has_loop_exit e2
  | Ast.Range (_, e1, e2, _, _) -> expr_has_loop_exit e1 || expr_has_loop_exit e2
  | _ -> false

and block_has_loop_exit (b : Ast.block_body) : bool =
  List.exists stmt_has_loop_exit b.Ast.b_stmts
  || (match b.Ast.b_tail with Some t -> expr_has_loop_exit t | None -> false)

and stmt_has_loop_exit (s : Ast.stmt) : bool =
  match s with
  | Ast.ExprStmt (e, _) -> expr_has_loop_exit e
  | Ast.LetBinding (_, _, _, v, _) -> expr_has_loop_exit v
  | Ast.DeferStmt (b, _) -> block_has_loop_exit b
  | Ast.Attributed (_, inner, _) -> stmt_has_loop_exit inner
  | Ast.Item _ | Ast.AttributeStmt _ -> false

(* ── Type mapping (syntax type → repr) ────────────────────────── *)

let free_params (ty : Type_repr.t) : Ids.Generic_param_id.t list =
  let acc = ref [] in
  let rec walk ty =
    match ty with
    | Type_repr.Type_param id -> if not (List.mem id !acc) then acc := id :: !acc
    | Type_repr.Infer_var _ | Type_repr.Int_literal _ | Type_repr.Error -> ()
    | Type_repr.Raw_ptr (_, t) | Type_repr.Ref_internal (_, t) | Type_repr.Fixed_array (t, _) ->
        walk t
    | Type_repr.Tuple elems | Type_repr.Named (_, elems) -> Array.iter walk elems
    | Type_repr.Function (ps, r) ->
        Array.iter (fun p -> walk p.Type_repr.pt_type) ps;
        walk r
    | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _ | Type_repr.Float _
    | Type_repr.String | Type_repr.Never ->
        ()
  in
  walk ty;
  List.rev !acc

let rec type_of_syntax (env : func_env) (t : Ast.type_expr) : Type_repr.t =
  match t with
  | Ast.Named (name, args, _) -> (
      match List.assoc_opt name env.types with
      | Some r ->
          (* the substitution binds the registered type's OWN free
             parameters (declaration-owned GenericParamIds) — never a
             positional make i reconstruction, which would miss the
             canonical builtin ids (Option's T etc.) *)
          let params = free_params r in
          if List.length params <> List.length args then
            seed_bug "type `%s` expects %d type argument(s), got %d" name
              (List.length params) (List.length args)
          else
            let subst =
              List.map2
                (fun p a -> (Type_repr.KParam p, type_of_syntax env a))
                params args
            in
            Type_repr.substitute subst r
      | None -> (
          match name with
          | "Int" -> Type_repr.Int Type_repr.Int
          | "UInt" -> Type_repr.Int Type_repr.UInt
          | "Bool" -> Type_repr.Bool
          | "String" -> Type_repr.String
          | "Char" -> Type_repr.Char
          | "Unit" | "()" -> Type_repr.Unit
          | "Never" -> Type_repr.Never
          | "u8" -> Type_repr.Int Type_repr.U8
          | "i32" -> Type_repr.Int Type_repr.I32
          | "f32" -> Type_repr.Float Type_repr.F32
          | "f64" -> Type_repr.Float Type_repr.F64
          | _ -> seed_bug "unknown type name '%s' in lowering" name))
  | Ast.Unit _ -> Type_repr.Unit
  | Ast.TTuple (elems, _) -> Type_repr.Tuple (Array.of_list (List.map (type_of_syntax env) elems))
  | Ast.TArray (inner, _, _) -> Type_repr.Fixed_array (type_of_syntax env inner, 0)
  | Ast.Slice (inner, _) -> Type_repr.Fixed_array (type_of_syntax env inner, 0)
  | Ast.Option (inner, _) -> (
      match List.assoc_opt "Option" env.types with
      | Some r -> (
          match free_params r with
          | [ p ] -> Type_repr.substitute [ (Type_repr.KParam p, type_of_syntax env inner) ] r
          | _ -> seed_bug "Option type has no canonical single parameter in lowering")
      | None -> seed_bug "Option type not in env")
  | Ast.Ref (inner, m, _) -> Type_repr.Ref_internal ((if m then Type_repr.Mutable else Type_repr.Immutable), type_of_syntax env inner)
  | Ast.RawPtr (inner, m, _) -> Type_repr.Raw_ptr ((if m then Type_repr.Mutable else Type_repr.Immutable), type_of_syntax env inner)
  | Ast.SelfType _ -> Type_repr.Unit
  | Ast.Inferred _ -> seed_bug "inferred type in lowering position"
  | other -> seed_bug "unsupported type form in lowering: %s" (type_form_name other)

and type_form_name (t : Ast.type_expr) : string =
  match t with
  | Ast.Named (n, _, _) -> "Named " ^ n
  | Ast.Unit _ -> "Unit"
  | Ast.TTuple _ -> "Tuple"
  | Ast.TArray _ -> "Array"
  | Ast.Slice _ -> "Slice"
  | Ast.Option _ -> "Option"
  | Ast.Ref _ -> "Ref"
  | Ast.RawPtr _ -> "RawPtr"
  | Ast.SelfType _ -> "Self"
  | Ast.Inferred _ -> "_"
  | Ast.FnPtr _ -> "FnPtr"
  | Ast.Bounded _ -> "Bounded"
  | Ast.ConstExpr _ -> "ConstExpr"
  | Ast.AssocBinding _ -> "AssocBinding"
  | Ast.Never _ -> "Never"
  | Ast.DynTrait _ -> "dyn"
  | Ast.ImplTrait _ -> "impl"

(* ── Operand/place helpers ────────────────────────────────────── *)

let operand_of_value (_st : lower_state) (v : Seed_mir.constant) : Seed_mir.operand =
  Seed_mir.Constant v

let copy_place (_st : lower_state) (p : Seed_mir.place) : Seed_mir.operand =
  Seed_mir.Copy p

(* Map an AST binary operator to Seed MIR. *)
let bin_op_of (op : Ast.binary_op) : Seed_mir.bin_op =
  match op with
  | Ast.BOr -> Seed_mir.Or
  | Ast.BAnd -> Seed_mir.And
  | Ast.BitOr -> Seed_mir.BitOr
  | Ast.BitXor -> Seed_mir.BitXor
  | Ast.BitAnd -> Seed_mir.BitAnd
  | Ast.Shl -> Seed_mir.Shl
  | Ast.Shr -> Seed_mir.Shr
  | Ast.Add -> Seed_mir.Add
  | Ast.Sub -> Seed_mir.Sub
  | Ast.Mul -> Seed_mir.Mul
  | Ast.Div -> Seed_mir.Div
  | Ast.Mod -> Seed_mir.Rem
  | Ast.Eq -> Seed_mir.Eq
  | Ast.NotEq -> Seed_mir.Ne
  | Ast.Lt -> Seed_mir.Lt
  | Ast.LtEq -> Seed_mir.Le
  | Ast.Gt -> Seed_mir.Gt
  | Ast.GtEq -> Seed_mir.Ge

let int_width_of (k : Type_repr.int_kind) : int =
  match k with
  | Type_repr.I8 | Type_repr.U8 -> 8
  | Type_repr.I16 | Type_repr.U16 -> 16
  | Type_repr.I32 | Type_repr.U32 -> 32
  | Type_repr.I64 | Type_repr.U64 | Type_repr.Int | Type_repr.UInt -> 64
  | Type_repr.I128 | Type_repr.U128 -> 128

let int_signed_of (k : Type_repr.int_kind) : bool =
  match k with
  | Type_repr.I8 | Type_repr.I16 | Type_repr.I32 | Type_repr.I64 | Type_repr.I128
  | Type_repr.Int -> true
  | _ -> false

let int_constant_of (k : Type_repr.int_kind) (i : int64) : Seed_mir.constant =
  Seed_mir.Integer (Int_value.of_int64 ~width:(int_width_of k) ~signed:(int_signed_of k) i)

let int_constant_of_words (k : Type_repr.int_kind) (lo : int64) (hi : int64) : Seed_mir.constant =
  Seed_mir.Integer
    (Int_value.of_words ~width:(int_width_of k) ~signed:(int_signed_of k) ~bits_lo:lo ~bits_hi:hi)

(* ── Field resolution (re-audit: the typed-place (FieldId) rule) ──

   The lowerer's struct-field emission channel is the typed nominal
   registry carried in func_env.struct_fields: a field access resolves
   the base's type against the registry, finds the field's SEMANTIC
   FieldId (the identity the verifier's owner rule and the VM's
   field_index_of resolve through the owner StructDef), and derives the
   field's type by substituting the nominal's generic params with the
   base type's arguments.  Every unresolvable field fails closed with a
   Seed_bug — never a silent Unit.

   The projection chain mirrors the typechecker's check_field exactly:
   - Named struct (non-transparent): `Field <FieldId>` on the base.
   - Box/Ptr/PtrMut: the nominal's OWN declared fields first (e.g.
     `self.ptr` inside impl Box), then the deref-on-field transparency —
     `Deref; Field <FieldId>` projected through the pointee (the type
     of the chain is the inner field's type).
   - Ref_internal/Raw_ptr: `Deref; Field <FieldId>` through the pointee
     (the verifier admits Deref on ref/raw-pointer bases).
   - A NUMERIC name is the tuple-index form: tuples have no FieldId, so
     the position is a ConstantIndex (the seed's TupleIndex form — the
     same scheme the variant payloads use). *)

(* The generic-param pattern of a nominal, from env.types' Named
   (tid, params) entry (the driver keeps these aligned with the
   nominals): the substitution keys at a use site. *)
let nominal_params_of (env : func_env) (tid : Ids.Type_id.t) : Type_repr.t array =
  match
    List.find_map
      (fun (_, r) ->
        match r with
        | Type_repr.Named (t, params) when Ids.Type_id.compare t tid = 0 -> Some params
        | _ -> None)
      env.types
  with
  | Some params -> params
  | None -> [||]

(* The Box/Ptr/PtrMut transparency (the typechecker's check_field derefs
   these nominals on field access): identified by NAME through env.types
   — the same name-anchored scheme the typechecker uses (b_ptr/b_ptrmut
   and the Box declaration's canonical tid). *)
let transparent_nominal_name_of (env : func_env) (tid : Ids.Type_id.t) : string option =
  List.find_map
    (fun (name, r) ->
      match r with
      | Type_repr.Named (t, _)
        when Ids.Type_id.compare t tid = 0
             && (name = "Box" || name = "Ptr" || name = "PtrMut") ->
          Some name
      | _ -> None)
    env.types

(* The own-field lookup: the registry entry of `tid` (present for every
   Struct/Enum nominal; enums' entries are empty).  The registry's
   entries are (name, FieldId, type) triples. *)
let registry_field_of (env : func_env) (tid : Ids.Type_id.t) (fname : string) :
    (Ids.Field_id.t * Type_repr.t) option =
  let rec go = function
    | [] -> None
    | (n, fid, fty) :: rest ->
        if n = fname then Some (fid, fty) else go rest
  in
  match List.assoc_opt tid env.struct_fields with
  | None -> None
  | Some fields -> go fields

(* Resolve `fname` on `bty`: the projection chain to APPEND to the base
   place and the field's type (the nominal's params substituted with the
   base type's arguments).  Fails closed on every unresolvable case. *)
let rec field_projection_of (env : func_env) (bty : Type_repr.t) (fname : string) :
    Seed_mir.projection list * Type_repr.t =
  match int_of_string_opt fname with
  | Some i when i >= 0 -> (
      (* the tuple-index form: tuples have no FieldId, so the position is
         a ConstantIndex *)
      match bty with
      | Type_repr.Tuple elems when i < Array.length elems -> ([ Seed_mir.ConstantIndex i ], elems.(i))
      | Type_repr.Tuple elems ->
          seed_bug "tuple index %d out of bounds (arity %d) in field lowering" i
            (Array.length elems)
      | _ ->
          seed_bug "tuple-index field `.%s` on a non-tuple base of type %s in lowering" fname
            (Seed_mir.print_type bty))
  | _ -> (
      match bty with
      | Type_repr.Named (tid, args) -> (
          let own = registry_field_of env tid fname in
          match transparent_nominal_name_of env tid with
          | Some name when own = None -> (
              (* the Box/Ptr/PtrMut deref-on-field transparency: the
                 nominal declares no such field, so the field is the
                 POINTEE's — `Deref; Field <FieldId>` *)
              match args with
              | [| inner |] ->
                  let projs, fty = field_projection_of env inner fname in
                  (Seed_mir.Deref :: projs, fty)
              | _ ->
                  seed_bug
                    "transparent nominal `%s` (type#%d) instantiated with %d arguments in lowering — the deref-on-field transparency needs exactly one"
                    name (Ids.Type_id.to_int tid) (Array.length args))
          | _ -> (
              match own with
              | Some (fid, fty) ->
                  (* the nominal's own field: substitute its generic
                     params with the base type's arguments (the fields
                     are recorded in the nominal's own parameter scope) *)
                  let params = nominal_params_of env tid in
                  if Array.length params <> Array.length args then
                    seed_bug
                      "nominal type#%d has %d generic params but the base type carries %d arguments in lowering"
                      (Ids.Type_id.to_int tid) (Array.length params) (Array.length args);
                  let subst =
                    List.mapi
                      (fun i p ->
                        match p with
                        | Type_repr.Type_param pid -> (Type_repr.KParam pid, args.(i))
                        | _ ->
                            seed_bug
                              "nominal type#%d's registered repr entry is not parameter-shaped at position %d in lowering"
                              (Ids.Type_id.to_int tid) i)
                      (Array.to_list params)
                  in
                  ([ Seed_mir.Field fid ], Type_repr.substitute subst fty)
              | None ->
                  seed_bug
                    "unknown field `%s` of type#%d in lowering (the typed nominal registry has no such field%s)"
                    fname (Ids.Type_id.to_int tid)
                    (match transparent_nominal_name_of env tid with
                     | Some name ->
                         Printf.sprintf " — `%s` is transparent and declares no such field" name
                     | None -> "")))
      | Type_repr.Ref_internal (_, inner) | Type_repr.Raw_ptr (_, inner) ->
          (* a field through a reference/raw pointer derefs the pointee *)
          let projs, fty = field_projection_of env inner fname in
          (Seed_mir.Deref :: projs, fty)
      | Type_repr.Tuple _ ->
          seed_bug
            "named field `.%s` on a tuple base in lowering (tuples have no FieldId — use the numeric ConstantIndex form)"
            fname
      | _ ->
          seed_bug "field access on non-struct type %s in lowering" (Seed_mir.print_type bty))

(* ── Expression lowering ──────────────────────────────────────── *)

(* Returns (place-or-constant operand, type). *)
let rec lower_expr (env : func_env) (st : lower_state) (e : Ast.expr) :
    Seed_mir.operand * Type_repr.t =
  match e with
  | Ast.IntLit (_, lit, _) -> (
      match Literal.parse_integer ~span:Span.synthetic lit with
      | Some p -> (
          let kind =
            match p.Literal.suffix with
            | Literal.I8 -> Type_repr.I8 | Literal.I16 -> Type_repr.I16
            | Literal.I32 -> Type_repr.I32 | Literal.I64 -> Type_repr.I64
            | Literal.I128 -> Type_repr.I128
            | Literal.U8 -> Type_repr.U8 | Literal.U16 -> Type_repr.U16
            | Literal.U32 -> Type_repr.U32 | Literal.U64 -> Type_repr.U64
            | Literal.U128 -> Type_repr.U128
            | Literal.Int -> Type_repr.Int | Literal.UInt -> Type_repr.UInt
            | Literal.No_int_suffix -> Type_repr.Int
          in
          let magnitude = p.Literal.magnitude in
          if Big_nat.fits_ocaml_int magnitude then
            (Seed_mir.Constant (int_constant_of kind (Int64.of_int (Big_nat.to_ocaml_int magnitude))),
             Type_repr.Int kind)
          else if Big_nat.fits_unsigned magnitude 128 then
            let lo, hi = Big_nat.to_words_128 magnitude in
            (Seed_mir.Constant (int_constant_of_words kind lo hi), Type_repr.Int kind)
          else seed_bug "integer literal exceeds 128 bits in lowering")
      | None -> seed_bug "unparseable integer literal '%s'" lit)
  | Ast.FloatLit (_, lit, _) -> (
      match float_of_string_opt lit with
      | Some f -> (Seed_mir.Constant (Seed_mir.Float64 (Int64.bits_of_float f)), Type_repr.Float Type_repr.F64)
      | None -> seed_bug "unparseable float literal '%s'" lit)
  | Ast.StringLit (_, s, _) -> (Seed_mir.Constant (Seed_mir.String s), Type_repr.String)
  | Ast.CharLit (_, c, _) -> (
      let b = Bytes.of_string c in
      match Utf8.decode_at b 0 with
      | Ok (u, _) -> (Seed_mir.Constant (Seed_mir.Char u), Type_repr.Char)
      | Error _ -> seed_bug "invalid char literal")
  | Ast.BoolLit (_, b, _) -> (Seed_mir.Constant (Seed_mir.Bool b), Type_repr.Bool)
  | Ast.Name (_, n, _) -> (
      match List.assoc_opt n st.scope with
      | Some id -> (
          match local_type st id with
          | Some ty -> (copy_place st (cur_place st id), ty)
          | None -> seed_bug "local _%d has no type in lowering" id)
      | None -> (
          match ctor_of st.variants n with
          | Some (enum_name, vname) ->
              (* a nullary enum constructor in value position, e.g. `None` *)
              let ty =
                match List.assoc_opt n env.values with
                | Some t -> t
                | None ->
                    seed_bug "enum constructor `%s` has no registered result type in the lowering env" n
              in
              let spec = variant_spec_of env st.variants ~enum_name ~vname ~repr:ty in
              let id = fresh_local st ty in
              emit st
                (Seed_mir.Assign
                   ( cur_place st id,
                     Seed_mir.Aggregate
                       ( Seed_mir.EnumCtor (enum_tid_of env enum_name, Ids.Variant_index.make spec.vs_index),
                         [] ) ));
              (copy_place st (cur_place st id), ty)
          | None -> (
              match List.assoc_opt n env.consts with
              | Some (ty, c) -> (Seed_mir.Constant c, ty)
              | None -> (
                  match List.assoc_opt n env.values with
                  | Some _ ->
                      seed_bug "function value `%s` reached lowering without a resolved callable identity" n
                  | None -> seed_bug "unknown value '%s' in lowering" n))))
  | Ast.Path (_, a, b, span) -> (
      ignore span;
      seed_bug "path value `%s::%s` reached lowering without a resolved callable identity" a b)
  | Ast.Binary (_, l, op, r, _) ->
      let lo, lt = lower_expr env st l in
      let ro, _rt = lower_expr env st r in
      let result_ty =
        match op with
        | Ast.Eq | Ast.NotEq | Ast.Lt | Ast.LtEq | Ast.Gt | Ast.GtEq | Ast.BOr | Ast.BAnd ->
            Type_repr.Bool
        | _ -> lt
      in
      let id = fresh_local st result_ty in
      emit st
        (Seed_mir.Assign
           (cur_place st id, Seed_mir.BinaryOp (bin_op_of op, lo, ro)));
      (copy_place st (cur_place st id), result_ty)
  | Ast.Unary (_, op, inner, _) -> (
      match op with
      | Ast.Neg ->
          let io, it = lower_expr env st inner in
          let id = fresh_local st it in
          emit st (Seed_mir.Assign (cur_place st id, Seed_mir.UnaryOp (Seed_mir.Neg, io)));
          (copy_place st (cur_place st id), it)
      | Ast.Not ->
          let io, _ = lower_expr env st inner in
          let id = fresh_local st Type_repr.Bool in
          emit st (Seed_mir.Assign (cur_place st id, Seed_mir.UnaryOp (Seed_mir.Not, io)));
          (copy_place st (cur_place st id), Type_repr.Bool)
      | Ast.BitNot ->
          let io, it = lower_expr env st inner in
          let id = fresh_local st it in
          (* ~x = x xor all-ones *)
          let all_ones = Seed_mir.Constant (int_constant_of (int_kind_of it) (-1L)) in
          emit st
            (Seed_mir.Assign (cur_place st id, Seed_mir.BinaryOp (Seed_mir.BitXor, io, all_ones)));
          (copy_place st (cur_place st id), it)
      | Ast.Deref | Ast.Borrow | Ast.BorrowMut ->
          lower_expr env st inner)
  | Ast.Cast (nid, inner, ty, span) ->
      ignore span;
      let io, _ = lower_expr env st inner in
      (* the typed channel is authoritative when present: the target is
         the checker's resolved type (declaration-owned GenericParamIds),
         not type_of_syntax's positional KParam(make i) reconstruction
         (re-audit: `x as Ptr[U]` must lower Ptr[U]'s U, not the
         builtin's own param or a synthetic positional id) *)
      let rt =
        match typed_node_of st nid with
        | Some node -> (
            match node.tn_cast_target with
            | Some tgt -> tgt
            | None -> node.tn_type)
        | None -> type_of_syntax env ty
      in
      let id = fresh_local st rt in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Cast (io, rt)));
      (copy_place st (cur_place st id), rt)
  | Ast.Tuple (_, elems, _) ->
      (* each element is lowered exactly once *)
      let lowered = List.map (fun e -> lower_expr env st e) elems in
      let ops = List.map fst lowered in
      let tys = List.map snd lowered in
      let rt = Type_repr.Tuple (Array.of_list tys) in
      let id = fresh_local st rt in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Aggregate (Seed_mir.TupleAgg, ops)));
      (copy_place st (cur_place st id), rt)
  | Ast.Array (_, elems, _) ->
      let lowered = List.map (fun e -> lower_expr env st e) elems in
      let ops = List.map fst lowered in
      let tys = List.map snd lowered in
      let elem_ty =
        match tys with
        | t :: _ -> t
        | [] -> Type_repr.Unit
      in
      let rt = Type_repr.Fixed_array (elem_ty, List.length elems) in
      let id = fresh_local st rt in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Aggregate (Seed_mir.ArrayAgg, ops)));
      (copy_place st (cur_place st id), rt)
  | Ast.MacroCall (_, n, args, _) -> (
      (* the `vec![...]` macro lowers to the array aggregate (the E9049
         vec! form is retired); every other macro fails closed *)
      match n with
      | "debug_assert" -> (
          (* debug_assert!(cond[, msg]): the kernel's uses check a
             boolean condition — the seed evaluates the condition (the
             checked side effects) and discards the value; the optional
             message is dropped (the E9049 debug_assert! form is
             retired) *)
          (match args with
           | Ast.MacroExpr cond :: _ -> ignore (lower_expr env st cond)
           | _ -> ());
          (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit))
      | "vec" ->
          let lowered =
            List.map
              (fun a ->
                match a with
                | Ast.MacroExpr e -> lower_expr env st e
                | Ast.MacroTokens _ ->
                    seed_bug "vec! with raw tokens is not lowered (macro argument is not an expression)")
              args
          in
          let ops = List.map fst lowered in
          let tys = List.map snd lowered in
          let elem_ty =
            match tys with
            | t :: _ -> t
            | [] -> Type_repr.Unit
          in
          let rt = Type_repr.Fixed_array (elem_ty, List.length args) in
          let id = fresh_local st rt in
          emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Aggregate (Seed_mir.ArrayAgg, ops)));
          (copy_place st (cur_place st id), rt)
      | other -> seed_bug "macro invocation `%s!` is not lowered (only vec! is available)" other)
  | Ast.Index (_, base, idx, _) -> (
      let base_op, base_ty = lower_expr env st base in
      let bp = materialize_place st base_op in
      let elem_ty = element_type_of base_ty in
      match idx with
      | Ast.IntLit (_, s, _) -> (
          match Literal.parse_integer ~span:Span.synthetic s with
          | Some p when Big_nat.fits_ocaml_int p.Literal.magnitude ->
              let k = Big_nat.to_ocaml_int p.Literal.magnitude in
              if k < 0 then seed_bug "negative constant index in lowering";
              let p =
                { bp with Seed_mir.projections = bp.Seed_mir.projections @ [ Seed_mir.ConstantIndex k ] }
              in
              (Seed_mir.Copy p, elem_ty)
          | _ -> seed_bug "index expression is not a constant integer")
      | _ ->
          (* nonconstant index: evaluate the index expression exactly
             once into a fresh local and emit the dynamic
             `Seed_mir.Index <index_local>` projection — the payload is
             the LOCAL whose runtime integer value is the index.  The VM
             executes this form and bounds-checks the runtime index
             value at execution; the verifier checks the index local's
             existence/initialization/type. *)
          let idx_op, idx_ty = lower_expr env st idx in
          let iid = fresh_local st idx_ty in
          emit st (Seed_mir.Assign (cur_place st iid, Seed_mir.Use idx_op));
          let p =
            { bp with Seed_mir.projections = bp.Seed_mir.projections @ [ Seed_mir.Index iid ] }
          in
          (Seed_mir.Copy p, elem_ty))
  | Ast.Field (_, base, fname, _span) ->
      (* re-audit: the typed-place (FieldId) rule — lower the base to a
         place, resolve the base's type against the typed nominal
         registry (func_env.struct_fields) and emit the semantic FieldId
         projection with the derived type (tuples project positionally
         with ConstantIndex).  Every unresolvable field fails closed. *)
      let bop, bty = lower_expr env st base in
      let bp = materialize_place st bop in
      let projs, fty = field_projection_of env bty fname in
      ( Seed_mir.Copy { bp with Seed_mir.projections = bp.Seed_mir.projections @ projs },
        fty )
  | Ast.IfExpr (_, i) -> lower_if env st i
  | Ast.MatchExpr (nid, m) -> lower_match env st nid m
  | Ast.WhileExpr (_, w) -> lower_while env st w
  | Ast.LoopExpr (_, b, _) -> lower_loop env st b
  | Ast.Block (_, b, _) -> lower_block env st b
  | Ast.ReturnExpr (_, Some e, _) ->
      let vo, _ = lower_expr env st e in
      emit_defers env st;
      emit st (Seed_mir.Assign (cur_place st 0, Seed_mir.Use vo));
      set_terminator st Seed_mir.Ret;
      (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
  | Ast.ReturnExpr (_, None, _) ->
      emit_defers env st;
      set_terminator st Seed_mir.Ret;
      (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
  | Ast.BreakExpr (_, v, _) -> (
      match st.break_target with
      | Some b ->
          let _ = v in
          set_terminator st (Seed_mir.Goto b);
          (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
      | None -> seed_bug "break outside loop in lowering")
  | Ast.NextExpr _ -> (
      match st.continue_target with
      | Some b ->
          set_terminator st (Seed_mir.Goto b);
          (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
      | None -> seed_bug "next outside loop in lowering")
  | Ast.Assign (_, target, value, _) ->
      let vo, vt = lower_expr env st value in
      (match target with
       | Ast.Name (_, n, _) -> (
           match List.assoc_opt n st.scope with
           | Some id -> (
               emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Use vo));
               match local_type st id with
               | Some ty -> (copy_place st (cur_place st id), ty)
               | None -> (vo, vt))
           | None -> (
               match List.assoc_opt n env.values with
               | Some ty ->
                   let id = fresh_local st ty in
                   emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Use vo));
                   (copy_place st (cur_place st id), ty)
               | None -> seed_bug "assignment to unknown value '%s'" n))
       | Ast.Field (_, base, fname, _) ->
           (* the typed-place writeback rule (E9036 retirement): the
              target base lowers to a place and the field resolves
              against the typed nominal registry — the SAME channel as
              the read path (field_projection_of) — and the Assign is
              emitted to the projected place.  The VM executes the
              projected write (update_place sets the projected
              component, preserving the rest of the aggregate); the
              verifier checks the projected destination (owner identity
              + initialization).  The writeback re-initializes the
              projected component (the moved-remainder semantics: the
              root aggregate stays initialized). *)
           let bop, bty = lower_expr env st base in
           let bp = materialize_place st bop in
           let projs, fty = field_projection_of env bty fname in
           let dst = { bp with Seed_mir.projections = bp.Seed_mir.projections @ projs } in
           emit st (Seed_mir.Assign (dst, Seed_mir.Use vo));
           (copy_place st dst, fty)
       | Ast.Index (_, base, idx, _) -> (
           (* the index writeback: the base lowers to a place; a
              constant index emits the ConstantIndex projection, a
              nonconstant index is evaluated exactly once into a fresh
              local and emits the dynamic `Index <local>` projection —
              the same scheme as the read path (the VM bounds-checks the
              runtime index value at execution). *)
           let bop, bty = lower_expr env st base in
           let bp = materialize_place st bop in
           let elem_ty = element_type_of bty in
           match idx with
           | Ast.IntLit (_, s, _) -> (
               match Literal.parse_integer ~span:Span.synthetic s with
               | Some p when Big_nat.fits_ocaml_int p.Literal.magnitude ->
                   let k = Big_nat.to_ocaml_int p.Literal.magnitude in
                   if k < 0 then seed_bug "negative constant index in lowering";
                   let dst =
                     { bp with Seed_mir.projections = bp.Seed_mir.projections @ [ Seed_mir.ConstantIndex k ] }
                   in
                   emit st (Seed_mir.Assign (dst, Seed_mir.Use vo));
                   (copy_place st dst, elem_ty)
               | _ -> seed_bug "index expression is not a constant integer")
           | _ ->
               let idx_op, idx_ty = lower_expr env st idx in
               let iid = fresh_local st idx_ty in
               emit st (Seed_mir.Assign (cur_place st iid, Seed_mir.Use idx_op));
               let dst =
                 { bp with Seed_mir.projections = bp.Seed_mir.projections @ [ Seed_mir.Index iid ] }
               in
               emit st (Seed_mir.Assign (dst, Seed_mir.Use vo));
               (copy_place st dst, elem_ty))
       | Ast.Unary (_, Ast.Deref, base, _) -> (
           (* `*p = v`: the base lowers to a place and the write emits
              through the Deref projection (the E9036 deref-target form
              is retired) *)
           let bop, bty = lower_expr env st base in
           let bp = materialize_place st bop in
           let pointee_ty =
             match bty with
             | Type_repr.Raw_ptr (_, t) | Type_repr.Ref_internal (_, t) -> t
             | Type_repr.Named (tid, args) -> (
                 match List.assoc_opt tid env.struct_fields with
                 | Some _ -> Type_repr.Named (tid, args)
                 | None -> bty)
             | _ -> bty
           in
           let dst =
             { bp with Seed_mir.projections = bp.Seed_mir.projections @ [ Seed_mir.Deref ] }
           in
           emit st (Seed_mir.Assign (dst, Seed_mir.Use vo));
           (copy_place st dst, pointee_ty))
       | _ ->
           ignore (vo, vt);
           seed_bug "projected assignment reached MIR lowering without a typed-place writeback rule")
  | Ast.CompoundAssign (_, _, _, _, span) ->
      ignore span;
      seed_bug "CompoundAssign reached MIR lowering without a typed-place writeback rule"
  | Ast.Call (nid, callee, _, args, span) ->
      ignore span;
      lower_call env st nid callee args
  | Ast.TryOp (_, inner, _) -> (
      (* `?`: match the Option/Result subject; the success variant (tag
         0) supplies the payload as the expression value; the failure
         variant early-returns from the enclosing function with the
         subject itself (the failure enum value) in the return slot,
         after running the function-level defers (LIFO).  The seed
         representation is Vm_value.Enum (tag, payload); the payload is
         read via [Downcast <success VariantId>; ConstantIndex 0] (the
         payload is a tuple — tuples have no FieldId, so the payload
         position is indexed positionally). *)
      let subj_op, subj_ty = lower_expr env st inner in
      let sid = fresh_local st subj_ty in
      emit st (Seed_mir.Assign (cur_place st sid, Seed_mir.Use subj_op));
      (* the error channel is the identity: for Result[T, E] the
         enclosing function's return must be Result[_, E] (the success
         types may differ); for Option[T] the return must be Option[_] *)
      let is_result, err_payload_ty =
        match subj_ty with
        | Type_repr.Named (_, [| _; e |]) -> (true, Some e)
        | Type_repr.Named (_, [| _ |]) -> (false, None)
        | _ -> seed_bug "`?` subject is not an Option/Result (found %s)" (Seed_mir.print_type subj_ty)
      in
      (match env.fn_ret, is_result with
       | Type_repr.Named (_, [| _; e2 |]), true ->
           if
             (match err_payload_ty with
              | Some e1 -> Type_repr.compare e1 e2 <> 0
              | None -> true)
           then
             seed_bug
               "`?` error channel mismatch: subject error %s vs enclosing return error %s"
               (Seed_mir.print_type (Option.get err_payload_ty)) (Seed_mir.print_type e2)
       | Type_repr.Named (_, [| _ |]), false -> ()
       | Type_repr.Named (_, [| _; _ |]), false ->
           seed_bug "`?` Option subject inside a Result-returning function"
       | Type_repr.Named (_, [| _ |]), true ->
           seed_bug "`?` Result subject inside an Option-returning function"
       | _, _ -> seed_bug "`?` enclosing function does not return an Option/Result (found %s)"
                    (Seed_mir.print_type env.fn_ret));
      let payload_ty =
        match subj_ty with
        | Type_repr.Named (_, args) when Array.length args > 0 -> args.(0)
        | _ -> seed_bug "`?` subject has no payload type"
      in
      (* the semantic identities of the success/failure variants, from
         the same variant universe the EnumCtor tags come from: the
         builtin table for Option/Result, the caller's table otherwise *)
      let variant_vid (vname : string) : Ids.Variant_id.t =
        semantic_variant_id
          (variant_spec_of env st.variants
             ~enum_name:(if is_result then "Result" else "Option")
             ~vname ~repr:subj_ty)
      in
      let ok_vid = variant_vid (if is_result then "Ok" else "Some") in
      let err_vid = variant_vid (if is_result then "Err" else "None") in
      let did = fresh_local st (Type_repr.Int Type_repr.UInt) in
      emit st (Seed_mir.Assign (cur_place st did, Seed_mir.Discriminant (cur_place st sid)));
      let fail = new_block st in
      let success = new_block st in
      let join = new_block st in
      set_terminator_to st
        (Seed_mir.SwitchInt (copy_place st (cur_place st did), [ (0L, success) ], fail))
        fail;
      (* failure path: defers, then the failure value into the return
         slot, then Ret.  The subject TRANSFERS (moves) into the return
         slot — a copy is only legal for a trivially Copy enum, and the
         verifier's enum rule is recursive (Copy iff every variant
         payload is Copy), so an enum with an owning payload
         (Result[Int, String]-shaped) must be MOVED.  For Option the
         subject IS the return value; for Result whose instantiation
         equals the enclosing return type the subject IS the Err value
         (its runtime tag is 1 on this path).  Only when the success
         types differ must Err(e) be reconstructed from the subject's
         error payload — a projected move is NOT expressible in the seed
         operand set (the VM's Move ignores projections and moves the
         whole slot, and the verifier rejects projected moves), so the
         reconstruction reads the payload by Copy and fails closed at
         lowering when the error payload is not Copy. *)
      emit_defers env st;
      (match is_result, err_payload_ty with
       | false, _ ->
           emit st
             (Seed_mir.Assign (cur_place st 0, Seed_mir.Use (Seed_mir.Move (cur_place st sid))))
       | true, Some e ->
           if Type_repr.compare subj_ty env.fn_ret = 0 then
             emit st
               (Seed_mir.Assign (cur_place st 0, Seed_mir.Use (Seed_mir.Move (cur_place st sid))))
           else if not (copyable_ty e) then
             seed_bug
               "`?` Result failure reconstruction is not lowerable for a non-Copy error payload %s (the seed VM's Move ignores projections, so extracting Err's payload from the subject and rebuilding it cannot move the value; pass the value by place or make the payload Copy)"
               (Seed_mir.print_type e)
            else begin
              let eid = fresh_local st e in
              emit st
                (Seed_mir.Assign
                   ( cur_place st eid,
                     Seed_mir.Use
                       (Seed_mir.Copy
                          { Seed_mir.local = sid;
                            projections =
                              [ Seed_mir.Downcast err_vid; Seed_mir.ConstantIndex 0 ] }) ));
              (match env.fn_ret with
              | Type_repr.Named (ret_tid, _) ->
                  emit st
                    (Seed_mir.Assign
                       ( cur_place st 0,
                         Seed_mir.Aggregate
                           ( Seed_mir.EnumCtor (ret_tid, Ids.Variant_index.make 1),
                             [ Seed_mir.Copy (cur_place st eid) ] ) ))
              | _ -> seed_bug "`?` Result failure reconstruction: enclosing return is not a nominal")
           end
       | true, None -> seed_bug "`?` Result subject without an error payload");
      set_terminator st Seed_mir.Ret;
      push_block st success;
      set_terminator_to st (Seed_mir.Goto join) join;
      ( Seed_mir.Copy
          { Seed_mir.local = sid; projections = [ Seed_mir.Downcast ok_vid; Seed_mir.ConstantIndex 0 ] },
        payload_ty ))
  | Ast.ForExpr (_, f) -> (
      (* A for-loop over a compile-time Array literal is UNROLLED into
         per-element body copies with ConstantIndex element reads.
         Any other iterable lowers to a runtime counter loop: the
         container is evaluated once into a local, a counter local
         counts from 0 to Len(container), and each iteration reads the
         element through the dynamic `Seed_mir.Index <counter>`
         projection — the VM executes the dynamic Index form and
         bounds-checks the runtime index value at execution. *)
      match f.Ast.for_iterable with
      | Ast.Array (_, elems, _) ->
          if block_has_loop_exit f.Ast.for_body then
            seed_bug
              "break/next inside a literal-unrolled for loop (the unrolled seed form has no loop structure to target)";
          let arr_op, arr_ty = lower_expr env st f.Ast.for_iterable in
          let arr_id = materialize_place st arr_op in
          let elem_ty = element_type_of arr_ty in
          let elem_ty_of_tuple k =
            match elem_ty with
            | Type_repr.Tuple elems when k < Array.length elems -> elems.(k)
            | _ -> seed_bug "destructuring for-loop pattern against a non-tuple element type"
          in
          let bindings =
            match f.Ast.for_pattern with
            | Ast.PatIdent (n, _, _) -> [ (n, fresh_local st elem_ty, None) ]
            | Ast.Wildcard _ -> []
            | Ast.PatTuple (subs, _) ->
                (* a destructuring loop `for (a, b) in arr`: each
                   component is bound through the element's tuple
                   ConstantIndex projection *)
                List.mapi
                  (fun k sub ->
                    match sub with
                    | Ast.PatIdent (n, _, _) ->
                        (n, fresh_local st (elem_ty_of_tuple k), Some k)
                    | Ast.Wildcard _ ->
                        ("__wild" ^ string_of_int k, fresh_local st (elem_ty_of_tuple k), Some k)
                    | _ -> seed_bug "unsupported destructuring for-loop pattern in lowering")
                  subs
            | _ -> seed_bug "unsupported for-loop pattern in lowering (bind by name or _)"
          in
          List.iter
            (fun (n, id, _) ->
              if not (String.starts_with ~prefix:"__wild" n) then st.scope <- (n, id) :: st.scope)
            bindings;
          List.iteri
            (fun i _ ->
              List.iter
                (fun (_, id, k) ->
                  let projections =
                    match k with
                    | None -> [ Seed_mir.ConstantIndex i ]
                    | Some k -> [ Seed_mir.ConstantIndex i; Seed_mir.ConstantIndex k ]
                  in
                  emit st
                    (Seed_mir.Assign
                       ( cur_place st id,
                         Seed_mir.Use
                           (Seed_mir.Copy
                              { Seed_mir.local = arr_id.Seed_mir.local;
                                projections = arr_id.Seed_mir.projections @ projections }) )))
                bindings;
              ignore (lower_block env st f.Ast.for_body))
            elems;
          (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
      | Ast.Range (_, start_e, end_e, inclusive, _) -> (
          (* `for x in a..b`: the counter counts from a to b; the loop
             variable binds the counter (the E9039 range form is
             retired); `a..=b` compares with <= *)
          let start_op, start_ty = lower_expr env st start_e in
          let end_op, _ = lower_expr env st end_e in
          let cid = fresh_local st start_ty in
          emit st (Seed_mir.Assign (cur_place st cid, Seed_mir.Use start_op));
          let eid = fresh_local st start_ty in
          emit st (Seed_mir.Assign (cur_place st eid, Seed_mir.Use end_op));
          let head_b = new_block st in
          let body_b = new_block st in
          let incr_b = new_block st in
          let join_b = new_block st in
          set_terminator st (Seed_mir.Goto head_b);
          push_block st head_b;
          let cnd_id = fresh_local st Type_repr.Bool in
          emit st
            (Seed_mir.Assign
               ( cur_place st cnd_id,
                 Seed_mir.BinaryOp
                   ( (if inclusive then Seed_mir.Le else Seed_mir.Lt),
                     copy_place st (cur_place st cid),
                     copy_place st (cur_place st eid) ) ));
          set_terminator st
            (Seed_mir.SwitchInt
               (copy_place st (cur_place st cnd_id), [ (1L, body_b) ], join_b));
          push_block st body_b;
          (match f.Ast.for_pattern with
           | Ast.PatIdent (n, _, _) -> st.scope <- (n, cid) :: st.scope
           | Ast.Wildcard _ -> ()
           | _ -> seed_bug "unsupported range for-loop pattern in lowering (bind by name or _)");
          let saved_break = st.break_target in
          let saved_continue = st.continue_target in
          st.break_target <- Some join_b;
          st.continue_target <- Some incr_b;
          ignore (lower_block env st f.Ast.for_body);
          st.break_target <- saved_break;
          st.continue_target <- saved_continue;
          set_terminator st (Seed_mir.Goto incr_b);
          push_block st incr_b;
          emit st
            (Seed_mir.Assign
               ( cur_place st cid,
                 Seed_mir.BinaryOp
                   ( Seed_mir.Add,
                     copy_place st (cur_place st cid),
                     Seed_mir.Constant (int_constant_of (int_kind_of start_ty) 1L) ) ));
          set_terminator st (Seed_mir.Goto head_b);
          push_block st join_b;
          (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit))
      | _ -> (
          let arr_op, arr_ty = lower_expr env st f.Ast.for_iterable in
          match arr_ty with
          | Type_repr.Fixed_array (elem_ty, _) ->
              let arr_id = materialize_place st arr_op in
              (* counter local: UInt so the Len comparison is well-typed
                 (the verifier types Len as UInt) and UInt is an allowed
                 dynamic-index type *)
              let cid = fresh_local st (Type_repr.Int Type_repr.UInt) in
              emit st
                (Seed_mir.Assign
                   ( cur_place st cid,
                     Seed_mir.Use
                       (Seed_mir.Constant (int_constant_of Type_repr.UInt 0L)) ));
              let len_id = fresh_local st (Type_repr.Int Type_repr.UInt) in
              emit st (Seed_mir.Assign (cur_place st len_id, Seed_mir.Len arr_id));
              let head_b = new_block st in
              let body_b = new_block st in
              let incr_b = new_block st in
              let join_b = new_block st in
              set_terminator st (Seed_mir.Goto head_b);
              push_block st head_b;
              let cnd_id = fresh_local st Type_repr.Bool in
              emit st
                (Seed_mir.Assign
                   ( cur_place st cnd_id,
                     Seed_mir.BinaryOp
                       ( Seed_mir.Lt,
                         copy_place st (cur_place st cid),
                         copy_place st (cur_place st len_id) ) ));
              set_terminator st
                (Seed_mir.SwitchInt
                   (copy_place st (cur_place st cnd_id), [ (1L, body_b) ], join_b));
              push_block st body_b;
              let elem_ty_of_tuple k =
                match elem_ty with
                | Type_repr.Tuple elems when k < Array.length elems -> elems.(k)
                | _ -> seed_bug "destructuring for-loop pattern against a non-tuple element type"
              in
              let bindings =
                match f.Ast.for_pattern with
                | Ast.PatIdent (n, _, _) -> [ (n, fresh_local st elem_ty, None) ]
                | Ast.Wildcard _ -> []
                | Ast.PatTuple (subs, _) ->
                    List.mapi
                      (fun k sub ->
                        match sub with
                        | Ast.PatIdent (n, _, _) ->
                            (n, fresh_local st (elem_ty_of_tuple k), Some k)
                        | Ast.Wildcard _ ->
                            ("__wild" ^ string_of_int k, fresh_local st (elem_ty_of_tuple k), Some k)
                        | _ -> seed_bug "unsupported destructuring for-loop pattern in lowering")
                      subs
                | _ -> seed_bug "unsupported for-loop pattern in lowering (bind by name or _)"
              in
              List.iter
                (fun (n, id, _) ->
                  if not (String.starts_with ~prefix:"__wild" n) then st.scope <- (n, id) :: st.scope)
                bindings;
              List.iter
                (fun (_, id, k) ->
                  let projections =
                    match k with
                    | None -> [ Seed_mir.Index cid ]
                    | Some k -> [ Seed_mir.Index cid; Seed_mir.ConstantIndex k ]
                  in
                  emit st
                    (Seed_mir.Assign
                       ( cur_place st id,
                         Seed_mir.Use
                           (Seed_mir.Copy
                              { Seed_mir.local = arr_id.Seed_mir.local;
                                projections }) )))
                bindings;
              let saved_break = st.break_target in
              let saved_continue = st.continue_target in
              st.break_target <- Some join_b;
              st.continue_target <- Some incr_b;
              ignore (lower_block env st f.Ast.for_body);
              st.break_target <- saved_break;
              st.continue_target <- saved_continue;
              set_terminator st (Seed_mir.Goto incr_b);
              push_block st incr_b;
              emit st
                (Seed_mir.Assign
                   ( cur_place st cid,
                     Seed_mir.BinaryOp
                       ( Seed_mir.Add,
                         copy_place st (cur_place st cid),
                         Seed_mir.Constant (int_constant_of Type_repr.UInt 1L) ) ));
              set_terminator st (Seed_mir.Goto head_b);
              push_block st join_b;
              (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
          | _ ->
              seed_bug
                "runtime for-loop over a non-array iterable of type %s is not lowered (the seed verifier admits dynamic Index/Len only on Fixed_array bases; lower it to an Array literal for the unrolled path)"
                (Seed_mir.print_type arr_ty)))
  | Ast.StructLit (nid, name, targs, fields, rest, _span) -> (
      (* re-audit: the StructCtor aggregate rule — `Type { field: value,
         ... }` lowers to a StructCtor aggregate whose type is the
         struct's Named type and whose operand positions are the
         DECLARATION order (the typed registry's struct_fields entries —
         the same order closure_types materializes into the StructDefs,
         so the verifier's aggregate-vs-def count/types check and the
         VM's field_index_of agree).  The aggregate's type is the
         checker's resolved type when the typed channel is present —
         REQUIRED for a generic struct, whose declaration-owned param
         ids the syntax path cannot reconstruct (a generic struct
         literal without the channel fails closed); the non-generic
         case falls back to the env's type table.  Every unresolvable
         field — unknown name, missing field, duplicate, `..` spread —
         fails closed with the reason. *)
      ignore targs;
      (match rest with
       | Some _ ->
           seed_bug
             "struct literal `%s` with a `..` spread is not lowered (the seed StructCtor form has no spread channel)"
             name
       | None -> ());
      (match ctor_of st.variants name with
       | Some (enum_name, vname) ->
           (* the braced-VARIANT constructor `Enum::Variant { f: e, ... }`:
              the variant's payload fields are the SPLIT positional list —
              the EnumCtor's operands are the field values in field
              declaration order *)
           let vname_m =
             match String.rindex_opt vname ':' with
             | Some i -> String.sub vname (i + 1) (String.length vname - i - 1)
             | None -> vname
           in
           let ty =
             match List.assoc_opt name env.values with
             | Some t -> t
             | None -> seed_bug "enum constructor `%s` has no registered result type in the lowering env" name
           in
           let spec = variant_spec_of env st.variants ~enum_name ~vname:vname_m ~repr:ty in
           let ops =
             List.map (fun (_, fe) -> fst (lower_expr env st fe)) fields
           in
           let id = fresh_local st ty in
           emit st
             (Seed_mir.Assign
                ( cur_place st id,
                  Seed_mir.Aggregate
                    ( Seed_mir.EnumCtor (enum_tid_of env enum_name, Ids.Variant_index.make spec.vs_index),
                      ops ) ));
           (copy_place st (cur_place st id), ty)
       | None -> (
      let rt =
        match typed_node_of st nid with
        | Some node -> node.tn_type
        | None -> (
            match List.assoc_opt name env.types with
            | Some (Type_repr.Named (tid, params)) when Array.length params = 0 ->
                Type_repr.Named (tid, [||])
            | Some (Type_repr.Named _) ->
                seed_bug
                  "struct literal `%s` has no typed node (a generic struct literal needs the typechecker's resolved type in the typed channel)"
                  name
            | _ ->
                seed_bug "struct literal `%s`: the type is not in the lowering env's type table"
                  name)
      in
      let tid =
        match rt with
        | Type_repr.Named (t, _) -> t
        | _ ->
            seed_bug "struct literal `%s` resolves to the non-struct type %s" name
              (Seed_mir.print_type rt)
      in
      (match List.assoc_opt tid env.struct_fields with
       | None ->
           seed_bug
             "struct literal `%s` (type#%d): the typed registry has no struct-field entry" name
             (Ids.Type_id.to_int tid)
       | Some reg ->
           let reg_len = List.length reg in
           let index_of fname =
             let rec go i = function
               | [] -> None
               | (fn, _, _) :: rest -> if fn = fname then Some i else go (i + 1) rest
             in
             go 0 reg
           in
           (* unknown field names fail closed FIRST — the more precise
              diagnostic (an unknown name is never a count problem) *)
           List.iter
             (fun (fname, _) ->
               if index_of fname = None then
                 seed_bug "unknown field `%s` of struct `%s` in struct-literal lowering" fname
                   name)
             fields;
           if List.length fields <> reg_len then
             seed_bug
               "struct literal `%s` initializes %d of %d field(s) (the seed StructCtor form needs every field; no defaulting or `..` spread is lowered)"
               name (List.length fields) reg_len;
           (* the field VALUES lower in source order, each exactly once,
              and land at their DECLARATION positions (the typed
              registry's order) *)
           let placed = Array.make reg_len None in
           List.iter
             (fun (fname, fe) ->
               match index_of fname with
               | Some i -> (
                   match placed.(i) with
                   | Some _ ->
                       seed_bug "duplicate field `%s` in the struct literal of `%s`" fname name
                   | None -> placed.(i) <- Some (fst (lower_expr env st fe)))
               | None -> ())
             fields;
           let ops =
             Array.to_list placed
             |> List.map (function
                  | Some op -> op
                  | None ->
                      seed_bug
                         "struct literal `%s` is missing a field (internal: the count check should have failed closed)"
                         name)
           in
           let id = fresh_local st rt in
           emit st
             (Seed_mir.Assign
                ( cur_place st id,
                  Seed_mir.Aggregate
                    ( Seed_mir.StructCtor
                        ( tid,
                          Array.init reg_len (fun i -> Ids.Field_index.make i) ),
                      ops ) ));
           (copy_place st (cur_place st id), rt)))))
  | Ast.Closure _ ->
      (* Closure disposition (re-audit lowering-surface item): the seed
         VM CONSTRUCTS closure objects (ClosureAgg -> Vm_value.Closure as
         the Tuple [Function; Tuple env] shape; see seed_mir.ml's header)
         but has NO closure-CALL path — Seed_mir.Call's callee is a
         compile-time function instance (User/Intrinsic/Extern) only,
         never a runtime closure VALUE.  A lowered closure could be built
         but never invoked, so the honest disposition is to fail closed
         here with the reason; Subset rejects the form up front (E9040)
         so this branch is unreachable through the driver.  NEVER a
         silent Unit. *)
      seed_bug
        "closure expressions are not lowerable: the seed VM has closure objects (ClosureAgg -> Vm_value.Closure, Tuple [Function; Tuple env]) but no closure-CALL path (Seed_mir.Call dispatches compile-time function instances only, never a runtime closure value); lift the closure to a named function"
  | Ast.UnsafeBlock (_, _, b, _) ->
      (* an unsafe block lowers its body exactly like a plain block
         (the seed has no separate unsafe model — the block is the
         lowered body; the E9041 unsafe-block form is retired) *)
      lower_block env st b
  | other -> seed_bug "unhandled supported expression form: %s" (expr_form_name other)

and int_kind_of (t : Type_repr.t) : Type_repr.int_kind =
  match t with
  | Type_repr.Int k -> k
  | _ -> Type_repr.Int

and expr_form_name (e : Ast.expr) : string =
  match e with
  | Ast.IntLit _ -> "IntLit"
  | Ast.FloatLit _ -> "FloatLit"
  | Ast.StringLit _ -> "StringLit"
  | Ast.CharLit _ -> "CharLit"
  | Ast.BoolLit _ -> "BoolLit"
  | Ast.Name (_, n, _) -> "Name " ^ n
  | Ast.Path _ -> "Path"
  | Ast.Array _ -> "Array"
  | Ast.ArrayRepeat _ -> "ArrayRepeat"
  | Ast.Tuple _ -> "Tuple"
  | Ast.StructLit _ -> "StructLit"
  | Ast.Block _ -> "Block"
  | Ast.UnsafeBlock _ -> "UnsafeBlock"
  | Ast.IfExpr _ -> "If"
  | Ast.Call _ -> "Call"
  | Ast.Index _ -> "Index"
  | Ast.Range _ -> "Range"
  | Ast.MatchExpr _ -> "Match"
  | Ast.Cast _ -> "Cast"
  | Ast.TryOp _ -> "TryOp"
  | Ast.Closure _ -> "Closure"
  | Ast.Unary _ -> "Unary"
  | Ast.Field _ -> "Field"
  | Ast.Binary _ -> "Binary"
  | Ast.AwaitExpr _ -> "Await"
  | Ast.MacroCall (_, n, _, _) -> "MacroCall " ^ n
  | Ast.Assign _ -> "Assign"
  | Ast.CompoundAssign _ -> "CompoundAssign"
  | Ast.ReturnExpr _ -> "Return"
  | Ast.BreakExpr _ -> "Break"
  | Ast.NextExpr _ -> "Next"
  | Ast.ForExpr _ -> "For"
  | Ast.WhileExpr _ -> "While"
  | Ast.LoopExpr _ -> "Loop"
  | Ast.HandleExpr _ -> "Handle"
  | Ast.UnlessExpr _ -> "Unless"
  | Ast.UntilExpr _ -> "Until"
  | Ast.TryBlock _ -> "Try"
  | Ast.ComptimeBlock _ -> "Comptime"

and target_type (env : func_env) (target : Ast.expr) : Type_repr.t =
  match target with
  | Ast.Name (_, n, _) -> (
      match List.assoc_opt n env.values with
      | Some ty -> ty
      | None -> seed_bug "assignment target '%s' unknown" n)
  | _ -> Type_repr.Unit

and lower_block (env : func_env) (st : lower_state) (b : Ast.block_body) : Seed_mir.operand * Type_repr.t =
  List.iter (fun s -> lower_stmt env st s) b.Ast.b_stmts;
  match b.Ast.b_tail with
  | Some t -> lower_expr env st t
  | None -> (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_stmt (env : func_env) (st : lower_state) (s : Ast.stmt) : unit =
  match s with
  | Ast.ExprStmt (e, _) ->
      ignore (lower_expr env st e)
  | Ast.LetBinding (pat, _, _ty, value, _) ->
      let vo, vt = lower_expr env st value in
      let id = fresh_local st vt in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Use vo));
      let bind_name n bind_id =
        st.local_names <- (bind_id, n) :: st.local_names;
        st.scope <- (n, bind_id) :: st.scope
      in
      (match pat with
       | Ast.PatIdent (n, _, _) -> bind_name n id
       | Ast.PatTuple (subs, _) ->
           (* a destructuring let `let (a, b) = t`: the tuple value is
              materialized and each component bound through its
              ConstantIndex projection *)
           List.iteri
             (fun k sub ->
               match sub with
               | Ast.PatIdent (n, _, _) ->
                   let cty =
                     match vt with
                     | Type_repr.Tuple elems when k < Array.length elems -> elems.(k)
                     | _ ->
                         seed_bug
                           "destructuring let pattern against a non-tuple value type"
                   in
                   let cid = fresh_local st cty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st cid,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = id;
                                 projections = [ Seed_mir.ConstantIndex k ] }) ));
                   bind_name n cid
               | Ast.Wildcard _ -> ()
               | _ -> seed_bug "unsupported destructuring let pattern in lowering")
             subs
       | Ast.Wildcard _ | Ast.PatLiteral _ -> ()
       | _ -> ())
  | Ast.DeferStmt (b, _) ->
      (* FRONTEND-SUPPORTED (not yet executable-seed-supported per the
         audit): the function-level LIFO stack is an approximation —
         conditional/loop scopes flatten to function level, so a defer
         inside an untaken branch would still run. The audit's exact
         scope-tree + CFG-exit-edge cleanup model is the required
         redesign; until then this construct is documented as
         frontend-supported and its lowering is approximate. *)
      if block_has_return b then seed_bug "defer bodies may not contain `return`";
      st.defer_stack <- b :: st.defer_stack
  | Ast.Item _ -> ()
  | Ast.AttributeStmt _ | Ast.Attributed _ -> ()

and lower_if (env : func_env) (st : lower_state) (i : Ast.if_expr) : Seed_mir.operand * Type_repr.t =
  let arms = (i.Ast.if_condition, i.Ast.if_then) :: i.Ast.if_elsif in
  let join_b = new_block st in
  let result_ty = ref Type_repr.Unit in
  let result_id = ref 0 in
  let has_result = ref false in
  (* Emit an arm chain; returns the block where the else/join continues. *)
  let rec emit_arms arms (fall_b : int) : int =
    match arms with
    | [] -> fall_b
    | (c, b) :: rest ->
        let then_b = new_block st in
        let cnd, _ = lower_expr env st c in
        let cid = fresh_local st Type_repr.Bool in
        emit st (Seed_mir.Assign (cur_place st cid, Seed_mir.Use cnd));
        let next_fall = new_block st in
        set_terminator_to st
          (Seed_mir.SwitchInt (copy_place st (cur_place st cid), [ (1L, then_b) ], next_fall))
          then_b;
        let bval, bty = lower_block env st b in
        if not !has_result then begin
          result_ty := bty;
          result_id := fresh_local st bty;
          has_result := true
        end;
        emit st (Seed_mir.Assign (cur_place st !result_id, Seed_mir.Use bval));
        set_terminator_to st (Seed_mir.Goto join_b) next_fall;
        emit_arms rest next_fall
  in
  let else_cont = emit_arms arms join_b in
  (match i.Ast.if_else with
   | Some eb ->
       if st.cur_block <> else_cont then
         set_terminator_to st (Seed_mir.Goto else_cont) else_cont;
       let eb_val, eb_ty = lower_block env st eb in
       if not !has_result then begin
         result_ty := eb_ty;
         result_id := fresh_local st eb_ty;
         has_result := true
       end;
       emit st (Seed_mir.Assign (cur_place st !result_id, Seed_mir.Use eb_val));
       set_terminator_to st (Seed_mir.Goto join_b) join_b
   | None ->
       if st.cur_block <> join_b then
         set_terminator_to st (Seed_mir.Goto join_b) join_b);
  (* the join block stays open for the continuation *)
  if !has_result then (copy_place st (cur_place st !result_id), !result_ty)
  else (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_match (env : func_env) (st : lower_state) (nid : Ids.Node_id.t)
    (m : Ast.match_expr) : Seed_mir.operand * Type_repr.t =
  (* the typed-pattern channel (re-audit P0 #3): when the channel is
     present (the driver path — the typechecker always ran), the arm
     patterns are CONSUMED as the SEMANTIC trees (VariantIds, binding
     names/types, constants, field names) and a missing entry is a
     checker/lowerer contradiction that fails loudly; when the channel
     is absent (hand-built selfcheck envs), lowering falls back to the
     syntax-driven interpretation. *)
  if st.typed_patterns = [] then lower_match_syntactic env st m
  else lower_match_typed env st nid m

and lower_match_syntactic (env : func_env) (st : lower_state) (m : Ast.match_expr) :
    Seed_mir.operand * Type_repr.t =
  let subj_op, subj_ty = lower_expr env st m.Ast.m_subject in
  let sid = fresh_local st subj_ty in
  (* the match subject is READ, never copied: a non-Copy subject
     (String, an owning enum, ...) must not be bitwise-copied into the
     subject local — the verify rejects the Copy and the Read form is
     the executable projection *)
  let subj_use =
    match subj_op with
    | Seed_mir.Copy p when not (copyable_ty subj_ty) -> Seed_mir.Read p
    | op -> op
  in
  emit st (Seed_mir.Assign (cur_place st sid, Seed_mir.Use subj_use));
  let join_b = new_block st in
  (* one result local shared by every arm (the typechecker unifies arm
     bodies, so the first body's type is the match's type) *)
  let result_id = ref 0 in
  let result_ty : Type_repr.t option ref = ref None in
  let ensure_result ty =
    match !result_ty with
    | None ->
        result_id := fresh_local st ty;
        result_ty := Some ty
    | Some _ -> ()
  in
  if
    List.length
      (List.filter (fun (a : Ast.match_arm) -> match a.Ast.ma_pattern with Ast.Wildcard _ -> true | _ -> false) m.Ast.m_arms)
    > 1
  then seed_bug "multiple wildcard arms in match lowering";
  if List.exists (fun (a : Ast.match_arm) -> a.Ast.ma_guard <> None) m.Ast.m_arms then
    seed_bug "match arm guards are not supported in seed lowering";
  (* ── the ordered decision chain (re-audit P0) ──
     Each arm's pattern is TESTED in source order: a true test enters
     the arm's body, a false test proceeds to the NEXT arm's test, and
     the final fallthrough is a deterministic non-exhaustive abort.
     Source order is preserved by construction (first-match semantics),
     so a wildcard/binding catch-all BEFORE a later specific arm wins;
     same-tag payload arms interleave correctly because a failed
     payload test routes to the next arm's TEST, never to the next
     arm's body block. *)
  let arm_blocks = Array.of_list (List.map (fun _ -> new_block st) m.Ast.m_arms) in
  let test_blocks = Array.of_list (List.map (fun _ -> new_block st) m.Ast.m_arms) in
  let abort_b = new_block st in
  let fail_b i = if i + 1 < Array.length test_blocks then test_blocks.(i + 1) else abort_b in
  (* the dispatch chain: the continuation block closes with a Goto into
     the FIRST test (no separate entry block), and every test leaves the
     current block AT the next test (or the abort) — so the tests need
     no block entry of their own, and the arm bodies are lowered
     afterwards into their own blocks *)
  let first_b =
    if Array.length test_blocks = 0 then abort_b
    else test_blocks.(0)
  in
  set_terminator_to st (Seed_mir.Goto first_b) first_b;
  List.iteri
    (fun i (a : Ast.match_arm) ->
      let then_b = arm_blocks.(i) in
      let next_b = fail_b i in
      (match a.Ast.ma_pattern with
      | Ast.PatVariant (seg1, seg2, _, _) -> (
          let enum_name =
            if seg1 = "" then enum_name_of_ty env subj_ty
            else begin
              if List.assoc_opt seg1 env.types = None then
                seed_bug "variant qualifier `%s` is not a known type in lowering" seg1;
              seg1
            end
          in
          let spec = variant_spec_of env st.variants ~enum_name ~vname:seg2 ~repr:subj_ty in
          (* the discriminant test: subject tag == this variant's tag *)
          let did = fresh_local st (Type_repr.Int Type_repr.UInt) in
          emit st (Seed_mir.Assign (cur_place st did, Seed_mir.Discriminant (cur_place st sid)));
          let eq_id = fresh_local st Type_repr.Bool in
          emit st
            (Seed_mir.Assign
               ( cur_place st eq_id,
                 Seed_mir.BinaryOp
                   ( Seed_mir.Eq,
                     copy_place st (cur_place st did),
                     Seed_mir.Constant
                       (int_constant_of Type_repr.UInt (Int64.of_int spec.vs_index)) ) ));
          set_terminator_to st
            (Seed_mir.SwitchInt (Seed_mir.Copy (cur_place st eq_id), [ (1L, then_b) ], next_b))
            next_b)
      | Ast.PatLiteral (Ast.IntLit (_, lit, _), _) -> (
          let v =
            match int_of_string_opt lit with
            | Some v -> v
            | None -> seed_bug "non-integer literal match arm in lowering"
          in
          let eq_id = fresh_local st Type_repr.Bool in
          emit st
            (Seed_mir.Assign
               ( cur_place st eq_id,
                 Seed_mir.BinaryOp
                   ( Seed_mir.Eq,
                     copy_place st (cur_place st sid),
                     Seed_mir.Constant
                       (int_constant_of (int_kind_of subj_ty) (Int64.of_int v)) ) ));
          set_terminator_to st
            (Seed_mir.SwitchInt (Seed_mir.Copy (cur_place st eq_id), [ (1L, then_b) ], next_b))
            next_b)
      | Ast.PatLiteral (Ast.CharLit (_, c, _), _) -> (
          (* the char test switches the subject DIRECTLY on its
             codepoint: the seed's SwitchInt dispatches Char values, and
             the VM has no Eq on Char — the equality form is not
             executable *)
          let b = Bytes.of_string c in
          let u =
            match Utf8.decode_at b 0 with
            | Ok (u, _) -> u
            | Error _ -> seed_bug "invalid char literal match arm in lowering"
          in
          set_terminator_to st
            (Seed_mir.SwitchInt
               ( copy_place st (cur_place st sid),
                 [ (Int64.of_int (Uchar.to_int u), then_b) ],
                 next_b ))
            next_b)
      | Ast.PatLiteral (Ast.BoolLit (_, bv, _), _) -> (
          (* the bool test switches the subject DIRECTLY (the VM
             dispatches Bool as 1/0) *)
          set_terminator_to st
            (Seed_mir.SwitchInt
               ( copy_place st (cur_place st sid),
                 [ ((if bv then 1L else 0L), then_b) ],
                 next_b ))
            next_b)
      | Ast.PatLiteral (Ast.StringLit (_, sl, _), _) -> (
          let eq_id = fresh_local st Type_repr.Bool in
          emit st
            (Seed_mir.Assign
               ( cur_place st eq_id,
                 Seed_mir.BinaryOp
                   ( Seed_mir.Eq,
                     Seed_mir.Read (cur_place st sid),
                     Seed_mir.Constant (Seed_mir.String sl) ) ));
          set_terminator_to st
            (Seed_mir.SwitchInt (Seed_mir.Copy (cur_place st eq_id), [ (1L, then_b) ], next_b))
            next_b)
      | Ast.Wildcard _ | Ast.PatIdent _ | Ast.PatTuple _ | Ast.StructPattern _ | Ast.OrPattern _
      | Ast.PatLiteral _ | Ast.RefPattern _ | Ast.RefMutPattern _ | Ast.RangePattern _ ->
          (* the catch-all test: enter the body directly (the
             field-equality checks inside the body route the failures
             to the next arm's test) *)
          set_terminator_to st (Seed_mir.Goto then_b) next_b))
    m.Ast.m_arms;
  (* the non-exhaustive abort: the current block is already the abort
     block (the last test's continuation), so it closes directly *)
  set_terminator st Seed_mir.Abort;
  (* lower each arm body into its block *)
  List.iteri
    (fun i (a : Ast.match_arm) ->
      push_block st arm_blocks.(i);
      (match a.Ast.ma_pattern with
       | Ast.PatVariant (seg1, seg2, pats, _) -> (
           let enum_name =
             if seg1 = "" then enum_name_of_ty env subj_ty
             else begin
               if List.assoc_opt seg1 env.types = None then
                 seed_bug "variant qualifier `%s` is not a known type in lowering" seg1;
               seg1
             end
           in
           let spec = variant_spec_of env st.variants ~enum_name ~vname:seg2 ~repr:subj_ty in
           (* bind the payload fields by projecting the subject; the
              Downcast carries the semantic VariantId (the VM derives
              the runtime tag through the enum def) and the payload is a
              TUPLE — tuples have no FieldId, so the payload positions
              are indexed positionally with ConstantIndex (the
              reference's TupleIndex form) *)
           List.iteri
             (fun j pat ->
               match pat with
               | Ast.PatIdent (name, _, _) -> (
                   let fty =
                     match List.nth_opt spec.vs_fields j with
                     | Some t -> t
                     | None -> seed_bug "variant `%s` payload pattern has more fields than the variant" seg2
                   in
                   if not (copyable_ty fty) then
                     seed_bug
                       "non-Copy payload binding in a variant match arm is not supported by the seed VM (a projected Move is not executable; payload type %s)"
                       (Seed_mir.print_type fty);
                    let id = fresh_local st fty in
                    emit st
                      (Seed_mir.Assign
                         ( cur_place st id,
                           Seed_mir.Use
                             (Seed_mir.Copy
                                { Seed_mir.local = sid;
                                  projections =
                                    [
                                      Seed_mir.Downcast (semantic_variant_id spec);
                                      Seed_mir.ConstantIndex j;
                                    ] }) ));
                    st.scope <- (name, id) :: st.scope)
               | Ast.Wildcard _ -> ()
               | Ast.PatLiteral (Ast.CharLit (_, c, _), _) -> (
                   (* a char payload `Some('#')`: the payload position
                      must hold the literal char — emit the equality
                      check that falls to the NEXT arm when it fails
                      (the arm bodies lower sequentially, so the next
                      arm's block is the fallthrough) *)
                   let pty =
                     match List.nth_opt spec.vs_fields j with
                     | Some t -> t
                     | None ->
                         seed_bug "variant `%s` char payload has more fields than the variant" seg2
                   in
                   let b = Bytes.of_string c in
                   let u =
                     match Utf8.decode_at b 0 with
                     | Ok (u, _) -> u
                     | Error _ -> seed_bug "invalid char literal payload in lowering"
                   in
                   let pid = fresh_local st pty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st pid,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid;
                                 projections =
                                   [ Seed_mir.Downcast (semantic_variant_id spec); Seed_mir.ConstantIndex j ]
                               }) ));
                   let eq_id = fresh_local st Type_repr.Bool in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st eq_id,
                          Seed_mir.BinaryOp
                            ( Seed_mir.Eq,
                              copy_place st (cur_place st pid),
                              Seed_mir.Constant (Seed_mir.Char u) ) ));
                   let ok_b = new_block st in
                   let next_b =
                     if i + 1 < Array.length test_blocks then test_blocks.(i + 1)
                     else abort_b
                   in
                   set_terminator_to st
                     (Seed_mir.SwitchInt
                        ( Seed_mir.Copy (cur_place st eq_id),
                          [ (1L, ok_b) ],
                          next_b ))
                     ok_b)
               | Ast.PatVariant (seg1, seg2, _, _) -> (
                   (* a nested-variant payload `Some(Live)`: the payload
                      position must hold the nested variant — its
                      discriminant must equal the nested variant's tag;
                      fall to the NEXT arm when it fails *)
                   let pty =
                     match List.nth_opt spec.vs_fields j with
                     | Some t -> t
                     | None ->
                         seed_bug "variant `%s` nested payload has more fields than the variant" seg2
                   in
                   let nested_spec =
                     variant_spec_of env st.variants ~enum_name:seg1 ~vname:seg2 ~repr:pty
                   in
                   let pid = fresh_local st pty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st pid,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid;
                                 projections =
                                   [ Seed_mir.Downcast (semantic_variant_id spec); Seed_mir.ConstantIndex j ]
                               }) ));
                   let did = fresh_local st (Type_repr.Int Type_repr.UInt) in
                   emit st
                     (Seed_mir.Assign
                        (cur_place st did, Seed_mir.Discriminant (cur_place st pid)));
                   let eq_id = fresh_local st Type_repr.Bool in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st eq_id,
                          Seed_mir.BinaryOp
                            ( Seed_mir.Eq,
                              copy_place st (cur_place st did),
                              Seed_mir.Constant
                                (int_constant_of Type_repr.UInt
                                   (Int64.of_int nested_spec.vs_index)) ) ));
                   let ok_b = new_block st in
                   let next_b =
                     if i + 1 < Array.length test_blocks then test_blocks.(i + 1)
                     else abort_b
                   in
                   set_terminator_to st
                     (Seed_mir.SwitchInt
                        ( Seed_mir.Copy (cur_place st eq_id),
                          [ (1L, ok_b) ],
                          next_b ))
                     ok_b)
               | Ast.PatLiteral (Ast.StringLit (_, slit, _), _) -> (
                   (* a string payload `Some("ast")`: the payload
                      position must hold the literal string — the
                      equality; fall to the NEXT arm when it fails *)
                   let pty =
                     match List.nth_opt spec.vs_fields j with
                     | Some t -> t
                     | None ->
                         seed_bug "variant `%s` string payload has more fields than the variant" seg2
                   in
                   let pid = fresh_local st pty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st pid,
                          Seed_mir.Use
                            (Seed_mir.Read
                               { Seed_mir.local = sid;
                                 projections =
                                   [ Seed_mir.Downcast (semantic_variant_id spec); Seed_mir.ConstantIndex j ]
                               }) ));
                   let eq_id = fresh_local st Type_repr.Bool in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st eq_id,
                          Seed_mir.BinaryOp
                            ( Seed_mir.Eq,
                              copy_place st (cur_place st pid),
                              Seed_mir.Constant (Seed_mir.String slit) ) ));
                   let ok_b = new_block st in
                   let next_b =
                     if i + 1 < Array.length test_blocks then test_blocks.(i + 1)
                     else abort_b
                   in
                   set_terminator_to st
                     (Seed_mir.SwitchInt
                        ( Seed_mir.Copy (cur_place st eq_id),
                          [ (1L, ok_b) ],
                          next_b ))
                     ok_b)
               | Ast.PatLiteral (Ast.BoolLit (_, b, _), _) -> (
                   (* a bool payload `Some(true)`: the payload must hold
                      the literal bool — the equality; fall to the NEXT
                      arm when it fails *)
                   let pty =
                     match List.nth_opt spec.vs_fields j with
                     | Some t -> t
                     | None ->
                         seed_bug "variant `%s` bool payload has more fields than the variant" seg2
                   in
                   let pid = fresh_local st pty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st pid,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid;
                                 projections =
                                   [ Seed_mir.Downcast (semantic_variant_id spec); Seed_mir.ConstantIndex j ]
                               }) ));
                   let eq_id = fresh_local st Type_repr.Bool in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st eq_id,
                          Seed_mir.BinaryOp
                            ( Seed_mir.Eq,
                              copy_place st (cur_place st pid),
                              Seed_mir.Constant (Seed_mir.Bool b) ) ));
                   let ok_b = new_block st in
                   let next_b =
                     if i + 1 < Array.length test_blocks then test_blocks.(i + 1)
                     else abort_b
                   in
                   set_terminator_to st
                     (Seed_mir.SwitchInt
                        ( Seed_mir.Copy (cur_place st eq_id),
                          [ (1L, ok_b) ],
                          next_b ))
                     ok_b)
               | Ast.StructPattern (_, sfields, _) -> (
                   (* a struct-payload `MirRvalue { kind: rvalue_kind }`:
                      the payload position j holds the struct — the
                      named fields bind through [Downcast;
                      ConstantIndex j; Field fid] (the semantic
                      FieldId through the typed registry) *)
                   let styp =
                     match List.nth_opt spec.vs_fields j with
                     | Some t -> t
                     | None ->
                         seed_bug "variant `%s` struct payload has more fields than the variant" seg2
                   in
                   List.iter
                     (fun (fname, fpat) ->
                       match fpat with
                       | Some (Ast.PatIdent (name, _, _)) -> (
                           let projs, fty = field_projection_of env styp fname in
                           if not (copyable_ty fty) then
                             seed_bug
                               "non-Copy struct-payload field binding in a variant match arm is not supported by the seed VM (payload field type %s)"
                               (Seed_mir.print_type fty);
                           let id = fresh_local st fty in
                           emit st
                             (Seed_mir.Assign
                                ( cur_place st id,
                                  Seed_mir.Use
                                    (Seed_mir.Copy
                                       { Seed_mir.local = sid;
                                         projections =
                                           [ Seed_mir.Downcast (semantic_variant_id spec); Seed_mir.ConstantIndex j ]
                                           @ projs }) ));
                           st.scope <- (name, id) :: st.scope)
                       | _ -> ())
                     sfields)
               | Ast.PatLiteral (Ast.IntLit (_, s, _), _) -> (
                   (* an int payload `Some(2)`: the payload must hold
                      the literal int — the equality; fall to the NEXT
                      arm when it fails *)
                   let pty =
                     match List.nth_opt spec.vs_fields j with
                     | Some t -> t
                     | None ->
                         seed_bug "variant `%s` int payload has more fields than the variant" seg2
                   in
                   let v =
                     match int_of_string_opt s with
                     | Some v -> v
                     | None -> seed_bug "non-integer literal payload in lowering"
                   in
                   let pid = fresh_local st pty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st pid,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid;
                                 projections =
                                   [ Seed_mir.Downcast (semantic_variant_id spec); Seed_mir.ConstantIndex j ]
                               }) ));
                   let eq_id = fresh_local st Type_repr.Bool in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st eq_id,
                          Seed_mir.BinaryOp
                            ( Seed_mir.Eq,
                              copy_place st (cur_place st pid),
                              Seed_mir.Constant (int_constant_of (int_kind_of pty) (Int64.of_int v)) ) ));
                   let ok_b = new_block st in
                   let next_b =
                     if i + 1 < Array.length test_blocks then test_blocks.(i + 1)
                     else abort_b
                   in
                   set_terminator_to st
                     (Seed_mir.SwitchInt
                        ( Seed_mir.Copy (cur_place st eq_id),
                          [ (1L, ok_b) ],
                          next_b ))
                     ok_b)
               | Ast.PatTuple (subs, _) ->
                   (* a tuple payload `Some((a, b))`: the j-th payload
                      FIELD is the tuple — each component binds through
                      the nested [Downcast; ConstantIndex j;
                      ConstantIndex k] projection (the registry's
                      substituted payload def resolves the tuple) *)
                   List.iteri
                     (fun k sub ->
                       match sub with
                       | Ast.PatIdent (name, _, _) -> (
                           let fty =
                             match List.nth_opt spec.vs_fields j with
                             | Some t -> (
                                 match t with
                                 | Type_repr.Tuple elems when k < Array.length elems ->
                                     elems.(k)
                                 | Type_repr.Tuple _ ->
                                     seed_bug
                                       "variant tuple payload pattern has more components than the payload tuple"
                                 | _ ->
                                     seed_bug
                                       "variant tuple payload pattern against a non-tuple payload")
                             | None ->
                                 seed_bug
                                   "variant `%s` payload pattern has more fields than the variant"
                                   seg2
                           in
                           if not (copyable_ty fty) then
                             seed_bug
                               "non-Copy payload binding in a variant match arm is not supported by the seed VM (payload type %s)"
                               (Seed_mir.print_type fty);
                           let id = fresh_local st fty in
                           emit st
                             (Seed_mir.Assign
                                ( cur_place st id,
                                  Seed_mir.Use
                                    (Seed_mir.Copy
                                       { Seed_mir.local = sid;
                                         projections =
                                           [
                                             Seed_mir.Downcast (semantic_variant_id spec);
                                             Seed_mir.ConstantIndex j;
                                             Seed_mir.ConstantIndex k;
                                           ] }) ));
                           st.scope <- (name, id) :: st.scope)
                       | Ast.Wildcard _ -> ()
                       | _ ->
                           seed_bug "unsupported nested variant payload pattern in lowering")
                     subs
               | _ -> seed_bug "unsupported variant payload pattern in lowering")
             pats)
       | Ast.StructPattern (vname0, sfields, _) -> (
           (* a struct-pattern arm `Variant { f: x, ... }`: for an ENUM
              subject the payload position j holds the struct — the
              fields bind through [Downcast; ConstantIndex j; Field
              fid]; for a STRUCT subject the fields bind directly
              through the FieldIds (the field-equality checks route) *)
           let enum_name = enum_name_of_ty env subj_ty in
           let vname =
             match String.rindex_opt vname0 ':' with
             | Some i -> String.sub vname0 (i + 1) (String.length vname0 - i - 1)
             | None -> vname0
           in
           (* the enum spec resolves lazily: a STRUCT subject never
              needs it (the fields bind directly) *)
           let spec = lazy (variant_spec_of env st.variants ~enum_name ~vname ~repr:subj_ty) in
           let is_struct_subject ty =
             match ty with
             | Type_repr.Named (tid, _) -> (
                 match List.assoc_opt tid env.struct_fields with
                 | Some (_ :: _) -> true
                 | _ -> false)
             | _ -> false
           in
           let field_projs j fname =
             if is_struct_subject subj_ty then
               let projs, fty = field_projection_of env subj_ty fname in
               ([], projs, fty)
             else
               let styp =
                   match List.nth_opt (Lazy.force spec).vs_fields j with
                   | Some t -> t
                   | None ->
                       seed_bug
                         "struct-payload arm `%s` has more fields than the variant payload"
                         vname
                 in
                 (match styp with
                  | Type_repr.Named (tid, _) when List.mem_assoc tid env.struct_fields ->
                      let projs, fty = field_projection_of env styp fname in
                      ([ Seed_mir.Downcast (semantic_variant_id (Lazy.force spec)); Seed_mir.ConstantIndex j ], projs, fty)
                  | _ ->
                      (* the SPLIT field: the payload position j IS the
                         field (the braced-variant payload is the split
                         positional list) *)
                      ([ Seed_mir.Downcast (semantic_variant_id (Lazy.force spec)); Seed_mir.ConstantIndex j ], [], styp))
           in
           List.iteri
             (fun j (fname, fpat) ->
               match fpat with
               | Some (Ast.PatIdent (name, _, _)) -> (
                   (* the braced-variant payload is the SPLIT field list
                      (the checker records the variant fields
                      positionally) — the field binds through
                      [Downcast; ConstantIndex j], like `Blue(a, b)`;
                      for a STRUCT subject the field binds directly
                      through the FieldIds *)
                   ignore fname;
                   let base_projs, projs, fty = field_projs j fname in
                   if not (copyable_ty fty) then
                     seed_bug
                       "non-Copy struct-payload field binding in a variant match arm is not supported by the seed VM (payload field type %s)"
                       (Seed_mir.print_type fty);
                   let id = fresh_local st fty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st id,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid;
                                 projections = base_projs @ projs }) ));
                   st.scope <- (name, id) :: st.scope)
               | _ -> ())
             sfields)
       | Ast.PatIdent (name, _, _) ->
           (* a binding arm `when x then`: the whole subject binds *)
           st.scope <- (name, sid) :: st.scope
       | Ast.PatTuple (subs, _) -> (
           (* a tuple arm `(a, b) => ...`: the elements bind through the
              ConstantIndex projections; a nested-variant element
              `(Field(fa), ...)` checks the element discriminant and
              binds the nested payload *)
           let elem_ty k =
             match subj_ty with
             | Type_repr.Tuple elems when k < Array.length elems -> elems.(k)
             | _ -> seed_bug "tuple arm pattern against a non-tuple subject type"
           in
           List.iteri
             (fun k sub ->
               match sub with
               | Ast.PatIdent (name, _, _) -> (
                   let fty = elem_ty k in
                   let id = fresh_local st fty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st id,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid;
                                 projections = [ Seed_mir.ConstantIndex k ] }) ));
                   st.scope <- (name, id) :: st.scope)
               | Ast.PatVariant (seg1, seg2, spats, _) -> (
                   let ety = elem_ty k in
                   let eid = fresh_local st ety in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st eid,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid;
                                 projections = [ Seed_mir.ConstantIndex k ] }) ));
                   let nested_spec =
                     variant_spec_of env st.variants ~enum_name:seg1 ~vname:seg2 ~repr:ety
                   in
                   let did = fresh_local st (Type_repr.Int Type_repr.UInt) in
                   emit st
                     (Seed_mir.Assign
                        (cur_place st did, Seed_mir.Discriminant (cur_place st eid)));
                   let eq_id = fresh_local st Type_repr.Bool in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st eq_id,
                          Seed_mir.BinaryOp
                            ( Seed_mir.Eq,
                              copy_place st (cur_place st did),
                              Seed_mir.Constant
                                (int_constant_of Type_repr.UInt
                                   (Int64.of_int nested_spec.vs_index)) ) ));
                    let ok_b = new_block st in
                    set_terminator_to st
                      (Seed_mir.SwitchInt
                         ( Seed_mir.Copy (cur_place st eq_id),
                           [ (1L, ok_b) ],
                           fail_b i ))
                      ok_b;
                   List.iteri
                     (fun j spat ->
                       match spat with
                       | Ast.PatIdent (name, _, _) -> (
                           let fty =
                             match List.nth_opt nested_spec.vs_fields j with
                             | Some t -> t
                             | None ->
                                 seed_bug
                                   "tuple arm nested-variant payload has more fields than the variant"
                           in
                           let id = fresh_local st fty in
                           emit st
                             (Seed_mir.Assign
                                ( cur_place st id,
                                  Seed_mir.Use
                                    (Seed_mir.Copy
                                       { Seed_mir.local = sid;
                                         projections =
                                           [
                                             Seed_mir.ConstantIndex k;
                                             Seed_mir.Downcast (semantic_variant_id nested_spec);
                                             Seed_mir.ConstantIndex j;
                                           ] }) ));
                           st.scope <- (name, id) :: st.scope)
                       | Ast.Wildcard _ -> ()
                       | _ -> seed_bug "unsupported tuple arm nested sub-pattern in lowering")
                     spats)
               | Ast.Wildcard _ -> ()
               | _ -> seed_bug "unsupported tuple arm sub-pattern in lowering")
             subs)
       | Ast.Wildcard _ | Ast.PatLiteral _ | Ast.OrPattern _ -> ()
       | _ -> seed_bug "unsupported match arm pattern in lowering");
      let bval, bty = lower_expr env st a.Ast.ma_body in
      ensure_result bty;
      emit st (Seed_mir.Assign (cur_place st !result_id, Seed_mir.Use bval));
      set_terminator st (Seed_mir.Goto join_b))
    m.Ast.m_arms;
  (* the join block stays open for the continuation: every arm body
     branches to it, and the match result flows out through it *)
  push_block st join_b;
  match !result_ty with
  | Some ty -> (copy_place st (cur_place st !result_id), ty)
  | None -> (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_match_typed (env : func_env) (st : lower_state) (nid : Ids.Node_id.t)
    (m : Ast.match_expr) : Seed_mir.operand * Type_repr.t =
  let subj_op, subj_ty = lower_expr env st m.Ast.m_subject in
  let sid = fresh_local st subj_ty in
  let subj_use =
    match subj_op with
    | Seed_mir.Copy p when not (copyable_ty subj_ty) -> Seed_mir.Read p
    | op -> op
  in
  emit st (Seed_mir.Assign (cur_place st sid, Seed_mir.Use subj_use));
  let join_b = new_block st in
  let result_id = ref 0 in
  let result_ty : Type_repr.t option ref = ref None in
  let ensure_result ty =
    match !result_ty with
    | None ->
        result_id := fresh_local st ty;
        result_ty := Some ty
    | Some _ -> ()
  in
  (* the arm's SEMANTIC pattern trees (the channel is authoritative: the
     typechecker resolves every accepted arm ONCE — a missing entry is
     the checker/lowerer contradiction the re-audit forbids) *)
  let arm_tps =
    List.mapi
      (fun i (_a : Ast.match_arm) ->
        match typed_pattern_of st (nid, i) with
        | Some tp -> tp
        | None ->
            seed_bug
              "match arm %d has no typed pattern on the channel (the typechecker must resolve every arm's pattern once — re-audit P0 #3)"
              i)
      m.Ast.m_arms
  in
  if
    List.length
      (List.filter
         (fun tp -> match tp with Typed_pattern.TP_wildcard -> true | _ -> false)
         arm_tps)
    > 1
  then seed_bug "multiple wildcard arms in match lowering";
  if List.exists (fun (a : Ast.match_arm) -> a.Ast.ma_guard <> None) m.Ast.m_arms then
    seed_bug "match arm guards are not supported in seed lowering";
  let arm_blocks = Array.of_list (List.map (fun _ -> new_block st) m.Ast.m_arms) in
  let test_blocks = Array.of_list (List.map (fun _ -> new_block st) m.Ast.m_arms) in
  let abort_b = new_block st in
  let fail_b i = if i + 1 < Array.length test_blocks then test_blocks.(i + 1) else abort_b in
  let first_b =
    if Array.length test_blocks = 0 then abort_b
    else test_blocks.(0)
  in
  set_terminator_to st (Seed_mir.Goto first_b) first_b;
  let subject_place = cur_place st sid in
  let is_struct_subject ty =
    match ty with
    | Type_repr.Named (tid, _) -> (
        match List.assoc_opt tid env.struct_fields with
        | Some (_ :: _) -> true
        | _ -> false)
    | _ -> false
  in
  (* the SEMANTIC discriminant test: the variant's identity is the
     typechecker's VariantId, resolved through the same variant table the
     name-keyed path uses (the driver builds both channels from the same
     typed nominals) *)
  let rec discriminant_test (enum_name : string) (base : Seed_mir.place)
      (vid : Ids.Variant_id.t) (repr : Type_repr.t) (then_b : int) (else_b : int) : unit =
    let spec = variant_spec_of_id env st.variants ~enum_name vid ~repr in
    let did = fresh_local st (Type_repr.Int Type_repr.UInt) in
    emit st (Seed_mir.Assign (cur_place st did, Seed_mir.Discriminant base));
    let eq_id = fresh_local st Type_repr.Bool in
    emit st
      (Seed_mir.Assign
         ( cur_place st eq_id,
           Seed_mir.BinaryOp
             ( Seed_mir.Eq,
               copy_place st (cur_place st did),
               Seed_mir.Constant (int_constant_of Type_repr.UInt (Int64.of_int spec.vs_index)) ) ));
    set_terminator_to st
      (Seed_mir.SwitchInt (Seed_mir.Copy (cur_place st eq_id), [ (1L, then_b) ], else_b))
      else_b
  and subject_literal_test (c : Seed_mir.constant) (then_b : int) (else_b : int) : unit =
    (* the subject tests consume the CHECKER's constant (the int literal
       carries the subject's kind — the same kind the syntactic path
       derived from the subject type) *)
    match c with
    | Seed_mir.Integer _ ->
        let eq_id = fresh_local st Type_repr.Bool in
        emit st
          (Seed_mir.Assign
             ( cur_place st eq_id,
               Seed_mir.BinaryOp
                 ( Seed_mir.Eq, copy_place st subject_place, Seed_mir.Constant c ) ));
        set_terminator_to st
          (Seed_mir.SwitchInt (Seed_mir.Copy (cur_place st eq_id), [ (1L, then_b) ], else_b))
          else_b
    | Seed_mir.Char u ->
        set_terminator_to st
          (Seed_mir.SwitchInt (copy_place st subject_place, [ (Int64.of_int (Uchar.to_int u), then_b) ], else_b))
          else_b
    | Seed_mir.Bool b ->
        set_terminator_to st
          (Seed_mir.SwitchInt (copy_place st subject_place, [ ((if b then 1L else 0L), then_b) ], else_b))
          else_b
    | Seed_mir.String _ ->
        let eq_id = fresh_local st Type_repr.Bool in
        emit st
          (Seed_mir.Assign
             ( cur_place st eq_id,
               Seed_mir.BinaryOp
                 ( Seed_mir.Eq, Seed_mir.Read subject_place, Seed_mir.Constant c ) ));
        set_terminator_to st
          (Seed_mir.SwitchInt (Seed_mir.Copy (cur_place st eq_id), [ (1L, then_b) ], else_b))
          else_b
    | _ -> seed_bug "unsupported literal match arm in lowering"
  and bind_struct_field ?(plan : (string * int) list option) (sty : Type_repr.t)
      (base_p : Seed_mir.place) (fail : int) (fname : string) (fp : Typed_pattern.t) : unit =
    (* a struct-pattern field: the SEMANTIC FieldId comes from the typed
       nominal registry (field_projection_of), and the field's type is
       the registry's substituted type.  In an or-pattern alternative the
       field projects into the SHARED interface local (plan) — every
       alternative's success path must define the SAME local, or the
       verifier's definite-init dataflow rejects the body's read. *)
    match fp with
    | Typed_pattern.TP_binding (name, _, _) -> (
        let projs, fty = field_projection_of env sty fname in
        if not (copyable_ty fty) then
          seed_bug
            "non-Copy struct-pattern field binding is not supported by the seed VM (field type %s)"
            (Seed_mir.print_type fty);
        let id =
          match plan with Some p -> List.assoc name p | None -> fresh_local st fty
        in
        emit st
          (Seed_mir.Assign
             ( cur_place st id,
               Seed_mir.Use
                 (Seed_mir.Copy
                    { base_p with Seed_mir.projections = base_p.Seed_mir.projections @ projs }) ));
        (match plan with Some _ -> () | None -> st.scope <- (name, id) :: st.scope))
    | Typed_pattern.TP_wildcard -> ()
    | Typed_pattern.TP_literal (c, fty) -> (
        (* a literal struct field `{ owns_state: true, .. }` checks the
           field equality and falls to the next arm's test when it fails *)
        let projs, _ = field_projection_of env sty fname in
        let pid = fresh_local st fty in
        emit st
          (Seed_mir.Assign
             ( cur_place st pid,
               Seed_mir.Use
                 (Seed_mir.Copy
                    { base_p with Seed_mir.projections = base_p.Seed_mir.projections @ projs }) ));
        let eq_id = fresh_local st Type_repr.Bool in
        emit st
          (Seed_mir.Assign
             ( cur_place st eq_id,
               Seed_mir.BinaryOp
                 ( Seed_mir.Eq, copy_place st (cur_place st pid), Seed_mir.Constant c ) ));
        let ok_b = new_block st in
        set_terminator_to st
          (Seed_mir.SwitchInt (Seed_mir.Copy (cur_place st eq_id), [ (1L, ok_b) ], fail))
          ok_b)
    | _ -> seed_bug "unsupported struct-pattern field sub-pattern in lowering"
  and bind_payloads ?(plan : (string * int) list option) (vid : Ids.Variant_id.t)
      (base : Seed_mir.place) (fail : int) (j : int) (tp : Typed_pattern.t) : unit =
    (* bind/check the j-th payload of the variant at [base]; the
       projection carries the SEMANTIC VariantId (the VM derives the
       runtime tag through the enum def) and the payload positions are
       indexed with ConstantIndex (the reference's TupleIndex form) *)
    let proj = { base with Seed_mir.projections = base.Seed_mir.projections @ [ Seed_mir.Downcast vid; Seed_mir.ConstantIndex j ] } in
    match tp with
    | Typed_pattern.TP_wildcard -> ()
    | Typed_pattern.TP_binding (name, fty, _) -> (
        if not (copyable_ty fty) then
          seed_bug
            "non-Copy payload binding in a variant match arm is not supported by the seed VM (a projected Move is not executable; payload type %s)"
            (Seed_mir.print_type fty);
        let id =
          match plan with Some p -> List.assoc name p | None -> fresh_local st fty
        in
        emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Use (Seed_mir.Copy proj)));
        (match plan with Some _ -> () | None -> st.scope <- (name, id) :: st.scope))
    | Typed_pattern.TP_literal (c, fty) -> (
        (* a literal payload `Some('#')` / `Some("ast")` / `Some(true)` /
           `Some(2)`: the payload position must hold the literal — the
           equality; fall to the next arm's test when it fails *)
        let pid = fresh_local st fty in
        let use_op =
          match c with Seed_mir.String _ -> Seed_mir.Read proj | _ -> Seed_mir.Copy proj
        in
        emit st (Seed_mir.Assign (cur_place st pid, Seed_mir.Use use_op));
        let eq_id = fresh_local st Type_repr.Bool in
        emit st
          (Seed_mir.Assign
             ( cur_place st eq_id,
               Seed_mir.BinaryOp
                 ( Seed_mir.Eq, copy_place st (cur_place st pid), Seed_mir.Constant c ) ));
        let ok_b = new_block st in
        set_terminator_to st
          (Seed_mir.SwitchInt (Seed_mir.Copy (cur_place st eq_id), [ (1L, ok_b) ], fail))
          ok_b)
    | Typed_pattern.TP_variant (nvid, nty, npats) -> (
        (* a nested-variant payload `Some(Live)`: the payload position
           must hold the nested variant — its discriminant must equal the
           nested variant's tag; the nested payloads bind through the
           nested Downcast (the checker's semantic tree) *)
        let pid = fresh_local st nty in
        emit st (Seed_mir.Assign (cur_place st pid, Seed_mir.Use (Seed_mir.Copy proj)));
        let ok_b = new_block st in
        discriminant_test (enum_name_of_ty env nty) (cur_place st pid) nvid nty ok_b fail;
        (* continue the nested payload bindings in the success block *)
        st.cur_block <- ok_b;
        List.iteri (fun k np -> bind_payloads ?plan nvid (cur_place st pid) fail k np) npats)
    | Typed_pattern.TP_struct (_, sty, sfields) -> (
        (* a struct-payload `MirRvalue { kind: rvalue_kind }`: the
           payload position holds the struct — the named fields bind
           through [Downcast; ConstantIndex j; Field fid] (the semantic
           FieldId through the typed registry) *)
        List.iter (fun (fname, fp) -> bind_struct_field ?plan sty proj fail fname fp) sfields)
    | Typed_pattern.TP_tuple (_, elems) -> (
        (* a tuple payload `Some((a, b))`: each component binds through
           the nested [Downcast; ConstantIndex j; ConstantIndex k]
           projection *)
        List.iteri
          (fun k ep ->
            match ep with
            | Typed_pattern.TP_binding (name, fty, _) -> (
                if not (copyable_ty fty) then
                  seed_bug
                    "non-Copy payload binding in a variant match arm is not supported by the seed VM (payload type %s)"
                    (Seed_mir.print_type fty);
                let id =
                  match plan with Some p -> List.assoc name p | None -> fresh_local st fty
                in
                emit st
                  (Seed_mir.Assign
                     ( cur_place st id,
                       Seed_mir.Use
                         (Seed_mir.Copy
                            { base with
                              Seed_mir.projections =
                                base.Seed_mir.projections
                                @ [ Seed_mir.Downcast vid; Seed_mir.ConstantIndex j; Seed_mir.ConstantIndex k ]
                            }) ));
                (match plan with Some _ -> () | None -> st.scope <- (name, id) :: st.scope))
            | Typed_pattern.TP_wildcard -> ()
            | _ -> seed_bug "unsupported nested variant payload pattern in lowering")
          elems)
    | Typed_pattern.TP_range _ ->
        seed_bug "range pattern payload in lowering"
    | Typed_pattern.TP_or _ ->
        seed_bug "or-pattern payload in lowering (the subset rejects or-pattern payloads)"
  in
  (* the ordered decision chain: each arm's SEMANTIC pattern is TESTED in
     source order; a true test enters the arm's body, a false test
     proceeds to the next arm's test, and the final fallthrough is the
     deterministic non-exhaustive abort *)
  List.iteri
    (fun i tp ->
      let then_b = arm_blocks.(i) in
      let next_b = fail_b i in
      match tp with
      | Typed_pattern.TP_variant (vid, _, _) ->
          discriminant_test (enum_name_of_ty env subj_ty) subject_place vid subj_ty then_b next_b
      | Typed_pattern.TP_literal (c, _) -> subject_literal_test c then_b next_b
      | Typed_pattern.TP_or (alts, _) -> (
          (* the ordered alternative chain: each alternative tests; a
             match enters the arm body with the common binding interface
             bound by the matching alternative, a miss proceeds to the
             NEXT alternative, and the last miss proceeds to the next
             arm's test *)
          let rec flatten acc = function
            | [] -> List.rev acc
            | Typed_pattern.TP_or (sub, _) :: rest -> flatten (flatten acc sub) rest
            | alt :: rest -> flatten (alt :: acc) rest
          in
          let alts = flatten [] alts in
          (* the COMMON binding interface: one SHARED local per interface
             name, seeded in the scope before the alternatives — every
             alternative's success path projects into the SAME local, so
             the verifier's definite-init dataflow admits the body's read
             (a per-alternative fresh local would leave the body reading
             a possibly-uninitialized local) *)
          let plan =
            match alts with
            | [] -> []
            | first :: _ ->
                let binding_ty name =
                  match List.find_opt (fun (n, _, _) -> n = name) (Typed_pattern.bindings first) with
                  | Some (_, ty, _) -> ty
                  | None -> subj_ty
                in
                List.map
                  (fun (name, _ty, _mut_) ->
                    match first with
                    | Typed_pattern.TP_binding (n, _, _) when n = name ->
                        (* a whole-subject binding: the subject IS the
                           binding (no copy — non-Copy subjects) *)
                        (name, sid)
                    | _ -> (name, fresh_local st (binding_ty name)))
                  (Typed_pattern.bindings first)
          in
          List.iter (fun (name, id) -> st.scope <- (name, id) :: st.scope) plan;
          let rec go_alts = function
            | [] -> set_terminator_to st (Seed_mir.Goto next_b) next_b
            | [ alt ] -> emit_alt_test alt next_b
            | alt :: rest -> (
                let next_alt_b = new_block st in
                emit_alt_test alt next_alt_b;
                (* emit_alt_test leaves the current block AT its else
                   continuation — the next alternative's test block — so
                   no push_block here (the continuation was already
                   opened by the alternative's terminator) *)
                go_alts rest)
          and emit_alt_test alt else_b =
            match alt with
            | Typed_pattern.TP_variant (vid, _, pats) -> (
                let ok_b = new_block st in
                discriminant_test (enum_name_of_ty env subj_ty) subject_place vid subj_ty ok_b else_b;
                (* continue the payload bindings in the success block *)
                st.cur_block <- ok_b;
                List.iteri (fun j p -> bind_payloads ~plan vid subject_place else_b j p) pats;
                set_terminator_to st (Seed_mir.Goto then_b) else_b)
            | Typed_pattern.TP_literal (c, _) -> (
                let ok_b = new_block st in
                subject_literal_test c ok_b else_b;
                st.cur_block <- ok_b;
                set_terminator_to st (Seed_mir.Goto then_b) else_b)
            | Typed_pattern.TP_binding (name, _, _) -> (
                (* the whole-subject binding is the plan's sid entry (or
                   the name when the interface is a plain binding) *)
                if not (List.mem_assoc name plan) then
                  st.scope <- (name, sid) :: st.scope;
                set_terminator_to st (Seed_mir.Goto then_b) else_b)
            | Typed_pattern.TP_wildcard ->
                set_terminator_to st (Seed_mir.Goto then_b) else_b
            | Typed_pattern.TP_struct (_, sty, sfields) -> (
                List.iter (fun (fname, fp) -> bind_struct_field ~plan sty subject_place else_b fname fp) sfields;
                set_terminator_to st (Seed_mir.Goto then_b) else_b)
            | Typed_pattern.TP_tuple (_, elems) -> (
                List.iteri
                  (fun k ep ->
                    match ep with
                    | Typed_pattern.TP_binding (name, fty, _) -> (
                        if not (copyable_ty fty) then
                          seed_bug
                            "non-Copy element binding in an or-pattern alternative is not supported by the seed VM (element type %s)"
                            (Seed_mir.print_type fty);
                        let id =
                          match List.assoc_opt name plan with
                          | Some id -> id
                          | None -> fresh_local st fty
                        in
                        emit st
                          (Seed_mir.Assign
                             ( cur_place st id,
                               Seed_mir.Use
                                 (Seed_mir.Copy
                                    { Seed_mir.local = sid; projections = [ Seed_mir.ConstantIndex k ] }) ));
                        if not (List.mem_assoc name plan) then
                          st.scope <- (name, id) :: st.scope)
                    | Typed_pattern.TP_wildcard -> ()
                    | _ -> seed_bug "unsupported tuple or-pattern alternative sub-pattern in lowering")
                  elems;
                set_terminator_to st (Seed_mir.Goto then_b) else_b)
            | Typed_pattern.TP_range _ ->
                seed_bug "range pattern in an or-pattern alternative in lowering"
            | Typed_pattern.TP_or _ ->
                seed_bug "nested or-pattern alternative in lowering (the checker flattens)"
          in
          go_alts alts)
      | Typed_pattern.TP_wildcard | Typed_pattern.TP_binding _ | Typed_pattern.TP_struct _
      | Typed_pattern.TP_tuple _ ->
          (* the catch-all test: enter the body directly (the field
             equality checks inside the body route the failures to the
             next arm's test) *)
          set_terminator_to st (Seed_mir.Goto then_b) next_b
      | Typed_pattern.TP_range _ ->
          seed_bug "range match arms are not available in the seed lowering")
    arm_tps;
  (* the non-exhaustive abort: the current block is already the abort
     block (the last test's continuation), so it closes directly *)
  set_terminator st Seed_mir.Abort;
  (* lower each arm body into its block *)
  List.iteri
    (fun i (a : Ast.match_arm) ->
      let tp = List.nth arm_tps i in
      push_block st arm_blocks.(i);
      (match tp with
       | Typed_pattern.TP_variant (vid, _, pats) ->
           List.iteri (fun j p -> bind_payloads vid subject_place (fail_b i) j p) pats
       | Typed_pattern.TP_struct (_, sty, sfields) -> (
           (* a struct-pattern arm: for a STRUCT subject the fields bind
              directly through the semantic FieldIds; a non-struct subject
              is a checker/lowerer contradiction (the checker resolves
              braced-variant patterns to TP_variant, never TP_struct) *)
           if is_struct_subject subj_ty then
             List.iter (fun (fname, fp) -> bind_struct_field sty subject_place (fail_b i) fname fp) sfields
           else
             seed_bug
               "struct-pattern arm against a non-struct subject type %s in lowering"
               (Seed_mir.print_type subj_ty))
       | Typed_pattern.TP_binding (name, _, _) ->
           (* a binding arm: the whole subject binds *)
           st.scope <- (name, sid) :: st.scope
       | Typed_pattern.TP_tuple (_, elems) -> (
           (* a tuple arm: the elements bind through the ConstantIndex
              projections; a nested-variant element checks the element
              discriminant and binds the nested payload *)
           List.iteri
             (fun k ep ->
               match ep with
               | Typed_pattern.TP_binding (name, fty, _) -> (
                   if not (copyable_ty fty) then
                     seed_bug
                       "non-Copy element binding in a tuple match arm is not supported by the seed VM (element type %s)"
                       (Seed_mir.print_type fty);
                   let id = fresh_local st fty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st id,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid; projections = [ Seed_mir.ConstantIndex k ] }) ));
                   st.scope <- (name, id) :: st.scope)
               | Typed_pattern.TP_variant (nvid, nty, npats) -> (
                   let eid = fresh_local st nty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st eid,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid; projections = [ Seed_mir.ConstantIndex k ] }) ));
                   let ok_b = new_block st in
                   discriminant_test (enum_name_of_ty env nty) (cur_place st eid) nvid nty ok_b (fail_b i);
                   st.cur_block <- ok_b;
                   List.iteri (fun j np -> bind_payloads nvid (cur_place st eid) (fail_b i) j np) npats)
               | Typed_pattern.TP_wildcard -> ()
               | _ -> seed_bug "unsupported tuple arm sub-pattern in lowering")
             elems)
       | Typed_pattern.TP_wildcard | Typed_pattern.TP_literal _ | Typed_pattern.TP_or _ -> ()
       | Typed_pattern.TP_range _ ->
           seed_bug "range match arms are not available in the seed lowering");
      let bval, bty = lower_expr env st a.Ast.ma_body in
      ensure_result bty;
      emit st (Seed_mir.Assign (cur_place st !result_id, Seed_mir.Use bval));
      set_terminator st (Seed_mir.Goto join_b))
    m.Ast.m_arms;
  (* the join block stays open for the continuation: every arm body
     branches to it, and the match result flows out through it *)
  push_block st join_b;
  match !result_ty with
  | Some ty -> (copy_place st (cur_place st !result_id), ty)
  | None -> (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_while (env : func_env) (st : lower_state) (w : Ast.while_expr) :
    Seed_mir.operand * Type_repr.t =
  let head_b = new_block st in
  let body_b = new_block st in
  let join_b = new_block st in
  set_terminator st (Seed_mir.Goto head_b);
  push_block st head_b;
  let cond, _ = lower_expr env st w.Ast.wh_condition in
  let cid = fresh_local st Type_repr.Bool in
  emit st (Seed_mir.Assign (cur_place st cid, Seed_mir.Use cond));
  set_terminator st (Seed_mir.SwitchInt (copy_place st (cur_place st cid), [ (1L, body_b) ], join_b));
  push_block st body_b;
  let saved_break = st.break_target in
  let saved_continue = st.continue_target in
  st.break_target <- Some join_b;
  st.continue_target <- Some head_b;
  ignore (lower_block env st w.Ast.wh_body);
  st.break_target <- saved_break;
  st.continue_target <- saved_continue;
  set_terminator st (Seed_mir.Goto head_b);
  push_block st join_b;
  (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_loop (env : func_env) (st : lower_state) (b : Ast.block_body) :
    Seed_mir.operand * Type_repr.t =
  let body_b = new_block st in
  let join_b = new_block st in
  set_terminator st (Seed_mir.Goto body_b);
  push_block st body_b;
  let saved_break = st.break_target in
  let saved_continue = st.continue_target in
  st.break_target <- Some join_b;
  st.continue_target <- Some body_b;
  ignore (lower_block env st b);
  st.break_target <- saved_break;
  st.continue_target <- saved_continue;
  set_terminator st (Seed_mir.Goto body_b);
  push_block st join_b;
  (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_call (env : func_env) (st : lower_state) (node_id : Ids.Node_id.t)
    (callee : Ast.expr) (args : Ast.call_arg list) : Seed_mir.operand * Type_repr.t =
  match callee with
  | Ast.Name (_, n, _) -> (
      match ctor_of st.variants n with
      | Some (enum_name, vname) ->
          (* an enum variant constructor call: `Some(x)`, `Green(7)`,
             `Err("...")` — built as an EnumCtor aggregate with the
             declaration-order variant index as the tag.  The result
             type is the constructor's registered type with its OWN free
             parameters substituted by the argument types (the registry
             entries carry the declaration-owned GenericParamIds — a
             positional reconstruction would miss Option's T) *)
          let ty0 =
            match List.assoc_opt n env.values with
            | Some t -> t
            | None ->
                seed_bug "enum constructor `%s` has no registered result type in the lowering env" n
          in
          let arg_ops_ty = List.map (fun a -> lower_expr env st a.Ast.ca_value) args in
          let arg_ops = List.map fst arg_ops_ty in
          let arg_tys = List.map snd arg_ops_ty in
          (* the EnumCtor's operand positions hold the payload fields;
             a non-Copy payload VALUE (the tuple) passes by Read — the
             fresh aggregate local is never bitwise-copied *)
          let arg_ops, arg_tys =
            match arg_ops, arg_tys with
            | [ Seed_mir.Copy p ], [ t ] when not (copyable_ty t) ->
                ([ Seed_mir.Read p ], [ t ])
            | _ -> (arg_ops, arg_tys)
          in
          let params0 = free_params ty0 in
          let ty =
            if List.length params0 = List.length arg_tys then
              Type_repr.substitute
                (List.map2 (fun p a -> (Type_repr.KParam p, a)) params0 arg_tys)
                ty0
            else ty0
          in
          let spec = variant_spec_of env st.variants ~enum_name ~vname ~repr:ty in
          let id = fresh_local st ty in
          emit st
            (Seed_mir.Assign
               ( cur_place st id,
                 Seed_mir.Aggregate
                   ( Seed_mir.EnumCtor (enum_tid_of env enum_name, Ids.Variant_index.make spec.vs_index),
                     arg_ops ) ));
          (copy_place st (cur_place st id), ty)
      | None -> (
          match List.assoc_opt n env.callables with
          | Some entry ->
              let cid = entry.ce_callable in
              let ty =
                match List.assoc_opt n env.values with Some t -> t | None -> Type_repr.Unit
              in
              let arg_ops_ty = List.map (fun a -> lower_expr env st a.Ast.ca_value) args in
              let arg_ops =
                List.map2
                  (fun op ty ->
                    match op with
                    | Seed_mir.Copy p when not (copyable_ty ty) -> Seed_mir.Read p
                    | op -> op)
                  (List.map fst arg_ops_ty) (List.map snd arg_ops_ty)
              in
              let id = fresh_local st ty in
              let rp = cur_place st id in
              (* the typed parameter contracts are authoritative for the
                 argument access effects (Let->Read, Inout->Modify,
                 Sink->Consume, Set->Initialize), so ownership semantics
                 survive into MIR and the verifier can enforce exactness *)
              let ce_params = entry.ce_params in
              let arg_vals =
                Array.of_list
                  (List.mapi
                     (fun i op ->
                       {
                         Seed_mir.effect_ =
                           (if i < Array.length ce_params then
                             Access_effect.read_effect ce_params.(i).Type_repr.pt_convention
                            else Access_effect.Read);
                         value = op;
                       })
                     arg_ops)
              in
              let next_b = new_block st in
              (* the typed lowering channel is authoritative: when the
                 call's span node carries tn_call, the User instance is
                 the checker-resolved callee + the SOLVED concrete
                 substitution (the mono exact-arity pairing — declaration
                 params vs concrete type_args); the [||] path is only the
                 hand-built selfcheck fallback, where the channel is
                 absent and the kernel's zero-generic defs stay exact. *)
              let tn_call = match typed_node_of st node_id with Some n -> n.tn_call | None -> None in
              let instance =
                match tn_call with
                | Some (callable, type_args) ->
                    Instance_id.make ~callable ~type_args
                | None ->
                    Instance_id.make ~callable:(Ids.Callable_id.make cid) ~type_args:[||]
              in
              set_terminator_to st
                (Seed_mir.Call (rp, Seed_mir.User instance, arg_vals, next_b, None))
                next_b;
              (copy_place st rp, ty)
          | None -> (
              (* ── the qualified static-call path (E9048 retirement:
                 `Type::method(...)` — the checker's static-method
                 dispatch lowered.  The resolution mirrors check_call's
                 qualified arm exactly: the (owner, method) pair in the
                 methods registry, then the kernel alias convention
                 (Vec<->Array, String<->str — the checker's base_owners
                 list), then the mangled free function
                 (`String::new` -> `string_new`, `Box::new` -> `box_new`
                 — the checker's mangled fallback).  The call is built
                 like the receiver-method path but WITHOUT a receiver
                 operand: the source args map to the method's params
                 (the constructor-style methods — `new`, `with_capacity`,
                 `from`, `null` — declare NO self, so me_params carries
                 exactly the explicit params).  The instance: the typed
                 channel's tn_call (the checker-resolved callable + SOLVED
                 concrete substitution) is authoritative when present,
                 else the registry's me_instance.  Every unresolvable
                 qualified name fails closed with the reason — the
                 fail-closed channel that replaced the firewall
                 rejection. *)
              let qualified_call () : Seed_mir.operand * Type_repr.t =
                match String.index_opt n ':' with
                | Some i when i + 1 < String.length n && n.[i + 1] = ':' ->
                    let qual = String.sub n 0 i in
                    let mname = String.sub n (i + 2) (String.length n - i - 2) in
                    (* the checker's candidate-owner convention: the
                       nominal's own name first, with the builtin alias
                       swaps (Vec<->Array, String<->str) *)
                    let candidate_owners =
                      match qual with
                      | "Vec" -> [ "Vec"; "Array" ]
                      | "Array" -> [ "Array"; "Vec" ]
                      | "String" -> [ "String"; "str" ]
                      | "str" -> [ "str"; "String" ]
                      | q -> [ q ]
                    in
                    let rec find_method = function
                      | [] -> None
                      | o :: rest -> (
                          match List.assoc_opt (o, mname) env.methods with
                          | Some me -> Some me
                          | None -> find_method rest)
                    in
                    (match find_method candidate_owners with
                     | Some me -> (
                         let nparams = Array.length me.me_params in
                         (* the checker PREPENDS a synthetic receiver (the
                            type used as a value) exactly when the method's
                            first parameter is a self of the OWNER's own
                            type (the has_self && self_is_owner test in
                            check_call); the lowerer mirrors that test to
                            decide whether the source args map to params
                            1.. or to params 0.. *)
                         let self_is_owner =
                           nparams > 0
                           && (match me.me_params.(0).Type_repr.pt_type with
                              | Type_repr.Named (tid1, _) -> (
                                  match List.assoc_opt qual env.types with
                                  | Some (Type_repr.Named (tid2, _)) ->
                                      Ids.Type_id.compare tid1 tid2 = 0
                                  | _ -> false)
                              | _ -> false)
                         in
                         let expected =
                           if self_is_owner then nparams - 1 else nparams
                         in
                         let nargs = List.length args in
                         if nargs <> expected then
                           seed_bug
                             "qualified call `%s` of `%s`: expected %d argument(s), got %d"
                             mname qual expected nargs;
                         if self_is_owner then
                           seed_bug
                             "qualified call `%s`: the method takes a receiver (`self: %s`), which the qualified form cannot supply in the seed (the checker's synthetic receiver is the TYPE used as a value — a type-level fiction with no runtime content); call it on a real receiver value instead"
                             mname (Seed_mir.print_type me.me_params.(0).Type_repr.pt_type);
                         (* the instance: the typed channel's
                            checker-resolved callable + solved concrete
                            substitution when present (the generic call's
                            concrete args arrive there), else the
                            registry's instance *)
                         let instance =
                           match typed_node_of st node_id with
                           | Some node -> (
                               match node.tn_call with
                               | Some (callable, type_args) ->
                                   Instance_id.make ~callable ~type_args
                               | None -> me.me_instance)
                           | None -> me.me_instance
                         in
                         let arg_ops = List.map (fun a -> fst (lower_expr env st a.Ast.ca_value)) args in
                         let id = fresh_local st me.me_ret in
                         let rp = cur_place st id in
                         let arg_vals =
                           Array.of_list
                             (List.mapi
                                (fun i op ->
                                  let eff =
                                    if i < nparams then
                                      Access_effect.read_effect me.me_params.(i).Type_repr.pt_convention
                                    else Access_effect.Read
                                  in
                                  (* a consuming parameter (Sink/Set) TRANSFERS
                                     the argument — the same conversion the
                                     receiver-method path applies to the self
                                     operand: an unprojected Copy becomes a Move
                                     (the seed VM has no partial-move
                                     representation, so a projected place fails
                                     closed exactly like the receiver path) *)
                                  let value =
                                    match eff, op with
                                    | (Access_effect.Consume | Access_effect.Initialize),
                                      Seed_mir.Copy p when p.Seed_mir.projections = [] ->
                                        Seed_mir.Move p
                                    | _ -> op
                                  in
                                  { Seed_mir.effect_ = eff; value })
                                arg_ops)
                         in
                         let next_b = new_block st in
                         set_terminator_to st
                           (Seed_mir.Call (rp, Seed_mir.User instance, arg_vals, next_b, None))
                           next_b;
                         (copy_place st rp, me.me_ret))
                     | None -> (
                         (* the mangled free function: `String::new`
                            dispatches to the compiler constructor
                            `string_new` — the same convention check_call's
                            mangled fallback uses (`box_new`, `vec_filled`,
                            `set_of`, ...) *)
                         let mangled = String.lowercase_ascii qual ^ "_" ^ mname in
                         match List.assoc_opt mangled env.callables with
                         | None ->
                             seed_bug "unknown callee '%s' in lowering" n
                         | Some entry ->
                             let cid = entry.ce_callable in
                             let ty =
                               match List.assoc_opt n env.values with
                               | Some t -> t
                               | None -> (
                                   match List.assoc_opt mangled env.values with
                                   | Some t -> t
                                   | None -> Type_repr.Unit)
                             in
                             let arg_ops =
                               List.map (fun a -> fst (lower_expr env st a.Ast.ca_value)) args
                             in
                             let id = fresh_local st ty in
                             let rp = cur_place st id in
                             let ce_params = entry.ce_params in
                             let arg_vals =
                               Array.of_list
                                 (List.mapi
                                    (fun i op ->
                                      {
                                        Seed_mir.effect_ =
                                          (if i < Array.length ce_params then
                                           Access_effect.read_effect ce_params.(i).Type_repr.pt_convention
                                           else Access_effect.Read);
                                        value = op;
                                      })
                                    arg_ops)
                             in
                             let next_b = new_block st in
                             let tn_call =
                               match typed_node_of st node_id with
                               | Some node -> node.tn_call
                               | None -> None
                             in
                             let instance =
                               match tn_call with
                               | Some (callable, type_args) ->
                                   Instance_id.make ~callable ~type_args
                               | None ->
                                   Instance_id.make
                                     ~callable:(Ids.Callable_id.make cid)
                                     ~type_args:[||]
                             in
                             set_terminator_to st
                               (Seed_mir.Call (rp, Seed_mir.User instance, arg_vals, next_b, None))
                               next_b;
                             (copy_place st rp, ty)))
                | _ -> seed_bug "unknown callee '%s' in lowering" n
              in
              qualified_call ())))
  | Ast.Field (nid, base, mname, span) -> (
      ignore span;
      (* re-audit: the method-call rule — the receiver is lowered to its
         typed PLACE and passed as the SELF argument with the read-side
         of the self parameter's convention (the methods' sig contracts
         are in the registry: me_params.(0) is the self parameter); the
         receiver's type names the owner ((owner, method) -> instance);
         the emitted User callee is the method's instance — the typed
         channel's tn_call (the checker-resolved callable + SOLVED
         concrete substitution) is authoritative when present, else the
         registry's me_instance (the identity the method body was
         lowered under).  Every unresolvable receiver or method fails
         closed with the reason. *)
      let rop, rty = lower_expr env st base in
      let rp = materialize_place st rop in
      let owner =
        match rty with
        | Type_repr.Named (tid, _) -> (
            match
              List.find_map
                (fun (n, r) ->
                  match r with
                  | Type_repr.Named (t2, _) when Ids.Type_id.compare t2 tid = 0 -> Some n
                  | _ -> None)
                env.types
            with
            | Some n -> n
            | None ->
                seed_bug
                  "method call `%s`: the receiver's type#%d has no name in the lowering env's type table"
                  mname (Ids.Type_id.to_int tid))
        | _ ->
            seed_bug "method call `%s`: the receiver is not a nominal (found %s)" mname
              (Seed_mir.print_type rty)
      in
      (match List.assoc_opt (owner, mname) env.methods with
       | None ->
           seed_bug
             "method call `%s`: type `%s` has no method instance in the lowering env's methods table"
             mname owner
       | Some me -> (
           if Array.length me.me_params = 0 then
             seed_bug
               "method call `%s`: the method instance of `%s` carries no self parameter" mname
               owner;
           let nargs = List.length args in
           if nargs <> Array.length me.me_params - 1 then
             seed_bug "method call `%s` of `%s`: expected %d argument(s), got %d" mname owner
               (Array.length me.me_params - 1) nargs;
           (* the instance: the typed channel's checker-resolved callable
              + solved concrete substitution when present (the generic
              call's concrete args arrive there), else the registry's
              instance *)
           let instance =
             match typed_node_of st nid with
             | Some node -> (
                 match node.tn_call with
                 | Some (callable, type_args) ->
                     Instance_id.make ~callable ~type_args
                 | None -> me.me_instance)
             | None -> me.me_instance
           in
           let self_conv = me.me_params.(0).Type_repr.pt_convention in
           let self_eff = Access_effect.read_effect self_conv in
           (* the receiver's operand form follows the self convention:
              a consuming self (Sink/Set) TRANSFERS the receiver (Move —
              never a projected place, the seed VM has no partial-move
              representation); an Inout self keeps the by-place read
              form the free-function call path uses (the seed VM reads
              the arg; the writeback is the documented seed
              approximation, same as Modify args elsewhere) *)
           let self_op =
             match self_eff with
             | Access_effect.Read | Access_effect.Modify -> Seed_mir.Copy rp
             | Access_effect.Consume | Access_effect.Initialize -> (
                 match rp.Seed_mir.projections with
                 | [] -> Seed_mir.Move rp
                 | _ ->
                     seed_bug
                       "method call `%s`: the consuming self argument cannot be a projected place (the seed VM has no partial-move representation)"
                       mname)
           in
           let arg_ops = List.map (fun a -> fst (lower_expr env st a.Ast.ca_value)) args in
           let id = fresh_local st me.me_ret in
           let rp2 = cur_place st id in
           let arg_vals =
             Array.of_list
               ({ Seed_mir.effect_ = self_eff; value = self_op }
                :: List.mapi
                     (fun i op ->
                       {
                         Seed_mir.effect_ =
                           (if i + 1 < Array.length me.me_params then
                             Access_effect.read_effect me.me_params.(i + 1).Type_repr.pt_convention
                            else Access_effect.Read);
                         value = op;
                       })
                     arg_ops)
           in
           let next_b = new_block st in
           set_terminator_to st
             (Seed_mir.Call (rp2, Seed_mir.User instance, arg_vals, next_b, None))
             next_b;
           (copy_place st rp2, me.me_ret))))
  | _ -> seed_bug "unsupported callee form in lowering"

and emit_defers (env : func_env) (st : lower_state) : unit =
  List.iter (fun b -> ignore (lower_block env st b)) st.defer_stack

(* ── Function lowering ────────────────────────────────────────── *)

let lower_function_with_variants
    ?(typed_nodes : (Ids.Node_id.t * typed_node) list = [])
    ?(typed_patterns : ((Ids.Node_id.t * int) * Typed_pattern.t) list = [])
    ?(param_tys_opt : Type_repr.t array option) (variants : variant_table)
    (env : func_env) (name : string)
    (callable : int) (template_args : Type_repr.t array)
    (param_conventions : Access_effect.t array) (fn : Ast.function_decl) : Seed_mir.function_ =
  let st =
    {
      next_local = 0;
      next_block = 0;
      locals = [||];
      local_names = [];
      scope = [];
      blocks = [];
      cur_block = 0;
      cur_stmts = [];
      break_target = None;
      continue_target = None;
      variants;
      defer_stack = [];
      typed_nodes;
      typed_patterns;
    }
  in
  (* local 0 = return slot *)
  let ret_ty = env.fn_ret in
  ignore (fresh_local st ret_ty);
  (* params *)
  let param_tys =
    match param_tys_opt with
    | Some tys -> Array.to_list tys
    | None ->
        List.map
          (fun (p : Ast.param) -> type_of_syntax env p.Ast.p_type)
          fn.Ast.fn_sig.Ast.sig_params
  in
  let param_ids =
    List.map
      (fun ty -> fresh_local st ty)
      param_tys
  in
  List.iter2
    (fun (p : Ast.param) id -> st.scope <- (p.Ast.p_name, id) :: st.scope)
    fn.Ast.fn_sig.Ast.sig_params param_ids;
  (* pre-entry block: the initial empty bb0 routes to the real entry *)
  ignore (new_block st);
  let entry = new_block st in
  push_block st entry;
  let result =
    match fn.Ast.fn_body with
    | Ast.FnBlock b -> Some (lower_block env st b)
    | Ast.FnExpr e -> Some (lower_expr env st e)
    | Ast.FnSignatureOnly -> None
  in
  (* the function's final implicit return runs the defers (LIFO) BEFORE
     the return slot is assigned, so mutations made by the defers are
     observable in the returned value (explicit returns lower the same
     order) *)
  emit_defers env st;
  (match result with
   | Some (vo, _) -> emit st (Seed_mir.Assign (cur_place st 0, Seed_mir.Use vo))
   | None -> ());
  set_terminator st Seed_mir.Ret;
  let params =
    Array.of_list
      (List.mapi
         (fun i ty ->
           let convention =
             if i < Array.length param_conventions then param_conventions.(i)
             else Access_effect.Let
           in
           { Type_repr.pt_convention = convention; pt_type = ty })
         param_tys)
  in
  {
    Seed_mir.name;
    (* the template instance carries the declaration-order generic params,
       so monomorphization can build exact substitutions *)
    instance =
      Instance_id.make ~callable:(Ids.Callable_id.make callable) ~type_args:template_args;
    params;
    locals = st.locals;
    blocks =
      Array.of_list
        (List.sort (fun a b -> compare a.Seed_mir.id b.Seed_mir.id) (List.rev st.blocks));
    entry;
  }

(* The public entry point used by the driver: lowers with the builtin
   variant table (Option/Result) only.  User-defined enums need
   lower_function_with_variants. *)
let lower_function (env : func_env) (name : string) (callable : int) (fn : Ast.function_decl) :
    Seed_mir.function_ =
  lower_function_with_variants default_variant_table env name callable [||] [||] fn

(* ── Statics/consts (audit §35) ─────────────────────────────────
   TODO: Ast.ConstDecl/Ast.StaticDecl exist and the typechecker keeps a
   `consts` registry, but the Mir_lower API carries no const/static
   value table and every caller (driver.ml) passes `statics = [||]`.
   A const/static reference in lowering position therefore reaches
   lower_expr's Name case without a scope/callable/constructor entry and
   fails closed with `unknown value` — the seed does not invent a
   representation for typechecker-registered consts it cannot lower
   soundly (a const is a value, not an addressable global, and the
   seed's operands have no init/load form).  Wiring real consts into
   func_env (name -> (repr, constant)) and lowering Name references to
   Constant operands is the follow-up; it requires extending the
   Mir_lower API and the driver's lowering_env_of together. *)
