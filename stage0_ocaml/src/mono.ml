(* mono.ml — Monomorphizer (audit §32).

   The work queue begins with the bootstrap entry instance and the
   static initializers (Function constants).  Every generic call points
   to a concrete instance: a call whose callee instance still carries the
   CALLER's generic parameters is substituted by the caller's own
   specialization (the reference's deferral) — zero inference, fail
   closed.  The output is the deterministic work-queue order: the entry
   first, then each discovered instance in first-discovered order.  No
   Hashtbl iteration anywhere — membership/state are plain lists and a
   FIFO queue.

   Rules enforced:
   - substitution arity is EXACT: the template's own instance declares
     its generic parameters in declaration order ([Type_param T;
     Type_param U] for f[T,U]); the requested instance must carry
     exactly that many type arguments, paired positionally — extra
     arguments, missing arguments and declaration-order disagreement are
     internal errors (the lowerer must preserve generic substitutions
     through lowering);
   - every instance is specialized AT MOST once (a seen-set by instance);
   - re-discovering an instance is a no-op: the template lookup is
     first-wins over the immutable input program and specialization is
     deterministic, so a re-discovered instance would re-specialize to
     the identical body (the input's one-function-per-callable check
     above is the consistency authority); the drain's seen-set is a
     Hashtbl, keeping the per-call-site duplicate test constant-time
     instead of quadratic over the closure;
   - a generic call with an instance whose type arguments cannot be made
     concrete (an unsolved substitution) is fail-closed: the residual
     type parameter is reported and the build fails;
   - a call whose callee has NO lowered template is fail-closed UNLESS
     the callable is REGISTERED as body-less (the driver's
     ~registered_only surface: extern-declared names, the
     compiler-builtin method/constructor sigs, the derived
     clone/to_string sigs and the size_of/align_of type queries — the
     typed signatures the template verifier resolves through its
     query-sig registry).  Such a call is already concrete and is KEPT
     in the output as-is (no body can exist for it), under the same
     exact-arity contract: the call's type arguments must number
     exactly the sig's declared generic parameters;
   - the input program must not register two functions under one
     callable identity;
   - every embedded instance in the output (call callees, function
     constants, closure aggregates) must be concrete AND either present
     in the output or a kept body-less-registered call — "every generic
     call points to a concrete instance". *)

open Seed_mir

(* A work item: the concrete instance to materialize together with the
   generic template (from the input program) it specializes. *)
type work_item = {
  instance : Instance_id.t;
  fn : function_;
}

(* ── The concrete type-instance queue (re-audit finding: "generic
      nominal type definitions disappear before MIR") ──────────────
   The monomorphizer specializes FUNCTIONS; it never constructed
   concrete type-definition instances.  A specialized body or signature
   mentioning Named (TypeId, args) where args carry no Type_params is a
   CONCRETE instance of a generic nominal (Pair[Int] where Pair[T]'s
   template def has Type_param fields) — a required concrete type
   definition.  The instances are queued ALONGSIDE the function
   instances during the drain: every specialized body is walked for
   Named mentions, each mention whose tid names a generic template is
   queued at most once, and the queue is exposed in first-discovery
   order through build's on_type_instance hook.  The materialization
   itself (substituting the template's field/variant types under the
   KParam-keyed table and minting the instance TypeIds) is the driver's
   post-mono assembly (Driver.materialize_type_instances).

   CANONICAL identity (audit P0-13): when build is handed the shared
   Canonical_type_instance.t cache (the optional ~canonical table the
   driver creates once and passes to the queue, the materializer and
   the verifier alike), discovery and dedup run on the CANONICAL key —
   CanonicalTypeInstance { generic_def_id; canonical_type_args } with
   the args normalized before keying (64-bit alias pairs and literal
   defaulting; never an unsolved Infer_var) — so the queue fires each
   logically identical instance exactly once and interns it to its one
   canonical specialized id at first discovery.  Without the table the
   queue dedups by the raw (tid, args) spelling, exactly as before. *)

type type_instance = {
  ti_tid : Ids.Type_id.t;      (* the generic nominal's TypeId *)
  ti_args : Type_repr.t array; (* the concrete substitution *)
}

(* The generic nominal registry handed to build: the template def (whose
   field/variant types reference the generic params as Type_params) plus
   the declared parameter ids in DECLARATION order — the positional
   KParam substitution maps param i to instance arg i, the same
   declaration-order contract as the function templates.  The seed
   types table is concrete-only by contract, so the templates live in
   this registry, never in program.types. *)
type generic_def = {
  gd_tid : Ids.Type_id.t;
  gd_params : Ids.Generic_param_id.t array; (* declaration order *)
  gd_def : type_def;                        (* template with Type_param field types *)
}

let type_instance_equal (a : type_instance) (b : type_instance) : bool =
  Ids.Type_id.compare a.ti_tid b.ti_tid = 0
  && Array.length a.ti_args = Array.length b.ti_args
  && Array.for_all2
       (fun x y -> Type_repr.compare x y = 0)
       a.ti_args b.ti_args

let find_generic (generic_types : generic_def array) (tid : Ids.Type_id.t) :
    generic_def option =
  Array.to_list generic_types
  |> List.find_opt (fun gd -> Ids.Type_id.compare gd.gd_tid tid = 0)

(* The positional KParam substitution for a generic def's declared
   parameters — the same exact-arity machinery as substitution: the
   instance's type arguments substitute the template's parameter ids in
   declaration order (param i substitutes arg i).  An arity
   disagreement is an internal error (the caller reports it through
   build's errors list; the result type also lets the driver's
   materializer fail closed). *)
let type_substitution (gd : generic_def) (args : Type_repr.t array) :
    ((Type_repr.generic_key * Type_repr.t) list, string) result =
  let n = Array.length gd.gd_params in
  let ni = Array.length args in
  if n <> ni then
    Error
      (Printf.sprintf
         "monomorphization internal error: generic type#%d declares %d parameter(s) but the instance carries %d type argument(s)"
         (Ids.Type_id.to_int gd.gd_tid) n ni)
  else
    Ok
      (List.map2
         (fun p a -> (Type_repr.KParam p, a))
         (Array.to_list gd.gd_params)
         (Array.to_list args))

(* Walk a type and fire queue for every CONCRETE instance of a generic
   nominal: Named (tid, args) with no Type_params anywhere in args,
   where tid is a generic template in the registry.  Recurses through
   the args, so nested instances are discovered too (Pair[Vec[Int]]
   queues both Pair[Vec[Int]] and Vec[Int]).  Dedup is the caller's —
   the queue is a set by (tid, args). *)
let rec scan_type (generic_types : generic_def array)
    (queue : type_instance -> unit) (ty : Type_repr.t) : unit =
  match ty with
  | Type_repr.Named (tid, args) ->
      if
        Array.length generic_types > 0
        && find_generic generic_types tid <> None
        && not (Array.exists Type_repr.has_type_param args)
      then queue { ti_tid = tid; ti_args = args };
      Array.iter (scan_type generic_types queue) args
  | Type_repr.Raw_ptr (_, t) | Type_repr.Ref_internal (_, t) | Type_repr.Fixed_array (t, _) ->
      scan_type generic_types queue t
  | Type_repr.Tuple elems -> Array.iter (scan_type generic_types queue) elems
  | Type_repr.Function (params, ret) ->
      Array.iter
        (fun p -> scan_type generic_types queue p.Type_repr.pt_type)
        params;
      scan_type generic_types queue ret
  | Unit | Bool | Char | Int _ | Float _ | String | Type_param _ | Infer_var _
  | Int_literal _ | Error | Never ->
      ()

let find_template (prog : program) (inst : Instance_id.t) : function_ option =
  let found = ref None in
  Array.iter
    (fun (f : function_) ->
      if Ids.Callable_id.compare (Instance_id.callable f.instance) (Instance_id.callable inst) = 0 && !found = None
      then found := Some f)
    prog.functions;
  !found

(* The substitution map: the template's own instance type arguments
   declare its parameter ids positionally (Type_param 0, 1, ...); the
   requested instance's type arguments are the concrete substitutes.
   Substitution arity is EXACT: template and instance must carry the
   same number of type arguments, else the input program is internally
   inconsistent (the audit's arity contract: extra arguments, missing
   arguments and declaration-order disagreement are internal errors).
   Entries are paired positionally — template arg i substitutes
   instance arg i, so declaration order is authoritative.  The error is
   reported through build's errors list (this file's convention); the
   result type also lets specialize raise a Seed_bug backstop for
   direct (non-build) callers. *)
let substitution (tmpl : function_) (inst : Instance_id.t) :
    ((Type_repr.generic_key * Type_repr.t) list, string) result =
  let nt = Array.length (Instance_id.type_args tmpl.instance) in
  let ni = Array.length (Instance_id.type_args inst) in
  if nt <> ni then
    Error
      (Printf.sprintf
         "monomorphization internal error: template arity %d != instance arity %d for callable %d"
         nt ni (Ids.Callable_id.to_int (Instance_id.callable tmpl.instance)))
  else
    let rec go i acc =
      if i >= ni then Ok (List.rev acc)
      else
        match (Instance_id.type_args tmpl.instance).(i) with
        | Type_repr.Type_param pid ->
            go (i + 1) ((Type_repr.KParam pid, (Instance_id.type_args inst).(i)) :: acc)
        | _ -> go (i + 1) acc
    in
    go 0 []

let subst_instance (subst : (Type_repr.generic_key * Type_repr.t) list)
    (inst : Instance_id.t) : Instance_id.t =
  Instance_id.make
    ~callable:(Instance_id.callable inst)
    ~type_args:
      (Array.map
         (Type_repr.substitute subst)
         (Instance_id.type_args inst))

(* Specialize a template under an instance: every embedded type is
   substituted (params, locals, cast targets, callee instances, function
   constants, closure aggregates).  The result carries the requested
   instance as its identity.  The substitution is applied positionally
   from the template's declaration order. *)
let specialize_under (subst : (Type_repr.generic_key * Type_repr.t) list)
    (tmpl : function_) (inst : Instance_id.t) : function_ =
  let subst_ty =
    Type_repr.substitute subst
  in
  let subst_operand op =
    match op with
    | Constant (Function i) -> Constant (Function (subst_instance subst i))
    | _ -> op
  in
  let subst_rvalue rv =
    match rv with
    | Use op -> Use (subst_operand op)
    | Ref p -> Ref p
    | RefMut p -> RefMut p
    | Aggregate (kind, ops) ->
        let kind' =
          match kind with
          | ClosureAgg i -> ClosureAgg (subst_instance subst i)
          | k -> k
        in
        Aggregate (kind', List.map subst_operand ops)
    | BinaryOp (o, l, r) -> BinaryOp (o, subst_operand l, subst_operand r)
    | UnaryOp (o, op) -> UnaryOp (o, subst_operand op)
    | Discriminant p -> Discriminant p
    | Len p -> Len p
    | Cast (op, ty) -> Cast (subst_operand op, subst_ty ty)
  in
  let subst_statement st =
    match st with
    | Assign (p, rv) -> Assign (p, subst_rvalue rv)
    | s -> s
  in
  let subst_callee_args (args : Type_repr.t array) : Type_repr.t array =
    Array.map subst_ty args
  in
  let subst_terminator t =
    match t with
    | Call (dest, callee, args, next, unwind) ->
        let callee' =
          match callee with
          | User i -> User (subst_instance subst i)
          | Derived (c, cargs) -> Derived (c, subst_callee_args cargs)
          | Intrinsic (i, iargs) -> Intrinsic (i, subst_callee_args iargs)
          | Extern (i, eargs) -> Extern (i, subst_callee_args eargs)
          | TypeQuery (k, qargs) -> TypeQuery (k, subst_callee_args qargs)
          | FnValue op -> FnValue (subst_operand op)
        in
        Call
          ( dest,
            callee',
            Array.map (fun a -> { a with value = subst_operand a.value }) args,
            next,
            unwind )
    | t -> t
  in
  {
    name = tmpl.name;
    instance = inst;
    params = Array.map (fun p -> { p with Type_repr.pt_type = subst_ty p.Type_repr.pt_type }) tmpl.params;
    locals = Array.map subst_ty tmpl.locals;
    blocks =
      Array.map
        (fun b ->
          {
            id = b.id;
            statements = List.map subst_statement b.statements;
            terminator = subst_terminator b.terminator;
          })
        tmpl.blocks;
    entry = tmpl.entry;
  }

(* specialize: compute the exact-arity substitution and specialize.
   An arity disagreement is an internal error; build() reports it
   through the errors list before reaching this, so the raise here is a
   backstop for direct callers (instantiate) only. *)
let specialize (tmpl : function_) (inst : Instance_id.t) : function_ =
  match substitution tmpl inst with
  | Ok subst -> specialize_under subst tmpl inst
  | Error m -> raise (Mir_lower.Seed_bug m)

(* instantiate: substitute the Type_params of the template registered
   under inst's callable.  None when the program has no template for the
   instance (callable not found).  An exact-arity disagreement raises
   (internal error; build reports it through the errors list instead).
   The returned body may still carry Type_params when the instance's
   type arguments do not cover the template's declared parameters —
   build rejects that case fail-closed. *)
let instantiate (prog : program) (inst : Instance_id.t) : function_ option =
  match find_template prog inst with
  | None -> None
  | Some tmpl -> Some (specialize tmpl inst)

(* ──────────────────────────────────────────────────────────────────
   build — the work-queue monomorphizer. *)

let walk_instances (body : function_) (f : Instance_id.t -> unit) : unit =
  let scan_operand op =
    match op with
    | Constant (Function i) -> f i
    | _ -> ()
  in
  let scan_rvalue rv =
    match rv with
    | Use op | Cast (op, _) | UnaryOp (_, op) -> scan_operand op
    | Aggregate (kind, ops) ->
        List.iter scan_operand ops;
        (match kind with
         | ClosureAgg i -> f i
         | _ -> ())
    | BinaryOp (_, l, r) ->
        scan_operand l;
        scan_operand r
    | Ref _ | RefMut _ | Discriminant _ | Len _ -> ()
  in
  Array.iter
    (fun b ->
      List.iter
        (function
          | Assign (_, rv) -> scan_rvalue rv
          | _ -> ())
        b.statements;
      match b.terminator with
      | Call (_, callee, args, _, _) -> (
          (* the callee-class instance surface (audit P0-5): a User
             callee and a Derived callee (the compiler-synthesized
             derived contracts — real bodies under the SAME callable the
             call references) both name an emitted-body instance the
             drain must specialize *)
          (match callee with
           | User i -> f i
           | Derived (c, args) -> f (Instance_id.make ~callable:c ~type_args:args)
           | FnValue op -> scan_operand op
           | Intrinsic _ | Extern _ | TypeQuery _ -> ());
          Array.iter (fun a -> scan_operand a.value) args)
      | SwitchInt (op, _, _) | Assert (op, _, _, _) -> scan_operand op
      | _ -> ())
    body.blocks

(* build — the work-queue monomorphizer.  The optional generic_types
   registry and on_type_instance hook implement the concrete
   type-instance queue: when a registry is supplied, every specialized
   body/signature is walked for concrete Named mentions of generic
   nominals and each first-discovered instance fires the hook (in
   discovery order).  With the defaults (empty registry, no-op hook)
   the behavior is exactly the function-only monomorphizer.  The
   optional ~canonical table (the shared Canonical_type_instance cache)
   makes the queue's membership canonical — same (template, args)
   always fires and interns exactly once, across every consumer.  The
   optional registered_only surface (callable -> declared-parameter
   count) names the typed-but-body-less callables whose concrete calls
   the drain keeps instead of failing on the missing template. *)
let build ~(entry : Instance_id.t) ?(generic_types : generic_def array = [||])
    ?(canonical : Canonical_type_instance.t option = None)
    ?(on_type_instance : type_instance -> unit = fun _ -> ())
    ?(registered_only : (Ids.Callable_id.t -> int option) = fun _ -> None)
    (prog : program) : (function_ array, string list) result =
  let errors = ref [] in
  let err msg = errors := msg :: !errors in
  (* input sanity: one function per callable identity *)
  let seen_callables = Hashtbl.create 16 in
  Array.iter
    (fun (f : function_) ->
      if Hashtbl.mem seen_callables (Instance_id.callable f.instance) then
        err
          (Printf.sprintf
             "mono: duplicate callable %s in the input program (two functions share one callable identity)"
             (Seed_mir.print_instance f.instance))
      else Hashtbl.add seen_callables (Instance_id.callable f.instance) ())
    prog.functions;
  (* find_template is by-callable FIRST-WINS over the immutable input
     program, so every lookup of one callable returns the same template:
     memoize the template per callable (the per-call linear scan would
     be O(templates × calls) over the closure). *)
  let template_tbl : (Ids.Callable_id.t, function_) Hashtbl.t = Hashtbl.create 4096 in
  Array.iter
    (fun (f : function_) ->
      let c = Instance_id.callable f.instance in
      if not (Hashtbl.mem template_tbl c) then Hashtbl.add template_tbl c f)
    prog.functions;
  let queue : work_item Queue.t = Queue.create () in
  (* membership and the body cache are Hashtbls (the drain would
     otherwise be quadratic over the seen list at every call site);
     the queue order alone is the deterministic output order *)
  let seen : (Instance_id.t, unit) Hashtbl.t = Hashtbl.create 65536 in
  let cache : (Instance_id.t, function_) Hashtbl.t = Hashtbl.create 65536 in
  let cache_order : function_ list ref = ref [] in
  (* body-less-registered call instances the drain kept (concrete calls
     to callables with a typed sig but no lowered template): the final
     validation must not demand a specialization for them *)
  let kept_bodyless : (Instance_id.t, unit) Hashtbl.t = Hashtbl.create 1024 in
  let enqueue ~(template : function_) (inst : Instance_id.t) =
    if Hashtbl.mem seen inst then ()
    else begin
      Hashtbl.add seen inst ();
      Queue.add { instance = inst; fn = template } queue
    end
  in
  let enqueue_instance (inst : Instance_id.t) =
    match Hashtbl.find_opt template_tbl (Instance_id.callable inst) with
    | Some tmpl -> enqueue ~template:tmpl inst
    | None -> (
        (* No lowered template: the callee may still be a REGISTERED
           body-less callable — an extern-declared name, a
           compiler-builtin method/constructor, a derived clone/
           to_string sig or a size_of/align_of type-query — whose typed
           signature lives in the checker's tables but which no source
           module implements (the template verifier resolves the same
           calls through its query-sig registry).  Such a call is
           already CONCRETE and needs no specialization: it is kept in
           the output as-is (the caller's substitution was already
           applied to its instance) and verified against the registered
           sig post-mono.  The exact-arity contract applies unchanged:
           the call's type arguments must number exactly the sig's
           declared generic parameters (the driver's registry carries
           the same declaration the template verifier used, so an
           arity disagreement is the same internal error). *)
        match registered_only (Instance_id.callable inst) with
        | None ->
            err
              (Printf.sprintf "mono: no template function for instance %s"
                 (Seed_mir.print_instance inst))
        | Some declared ->
            let carried = Array.length (Instance_id.type_args inst) in
            if declared <> carried then
              err
                (Printf.sprintf
                   "mono: body-less callee %s declares %d generic parameter(s) but the call carries %d type argument(s)"
                   (Seed_mir.print_instance inst) declared carried)
            else Hashtbl.replace kept_bodyless inst ())
  in
  (* the concrete type-instance queue: the hook fires at FIRST
     discovery, so the driver's materialization sees each required
     instance exactly once, in deterministic order.  With the shared
     canonical table the membership is the CANONICAL key — same
     (template, args) fires once regardless of alias/literal arg
     spelling, and the instance is interned to its one canonical
     specialized id at first discovery (audit P0-13).  Without the
     table the membership is the raw (tid, args) spelling, exactly as
     before. *)
  let type_seen : Canonical_type_instance.canonical_type_instance list ref = ref [] in
  let type_seen_raw : type_instance list ref = ref [] in
  let queue_type_instance (ti : type_instance) =
    match canonical with
    | None ->
        if not (List.exists (type_instance_equal ti) !type_seen_raw) then begin
          type_seen_raw := ti :: !type_seen_raw;
          on_type_instance ti
        end
    | Some t ->
        let key = Canonical_type_instance.key_of ti.ti_tid ti.ti_args in
        if not (List.exists (Canonical_type_instance.equal_key key) !type_seen) then begin
          type_seen := key :: !type_seen;
          (* intern at first discovery: the one mint for this instance's
             canonical specialized id (None for the excluded builtin
             runtime nominals — Vec/Map/Set/Ptr/PtrMut never remap) *)
          ignore (Canonical_type_instance.intern t ti.ti_tid ti.ti_args);
          on_type_instance ti
        end
  in
  let scan_ty (ty : Type_repr.t) = scan_type generic_types queue_type_instance ty in
  let scan_inst (inst : Instance_id.t) =
    Array.iter scan_ty (Instance_id.type_args inst)
  in
  let scan_operand (op : operand) =
    match op with
    | Constant (Function i) -> scan_inst i
    | _ -> ()
  in
  let scan_rvalue (rv : rvalue) =
    match rv with
    | Use op -> scan_operand op
    | Ref _ | RefMut _ | Discriminant _ | Len _ -> ()
    | Aggregate (kind, ops) ->
        List.iter scan_operand ops;
        (match kind with
         | ClosureAgg i -> scan_inst i
         | _ -> ())
    | BinaryOp (_, l, r) ->
        scan_operand l;
        scan_operand r
    | UnaryOp (_, op) -> scan_operand op
    | Cast (op, ty) ->
        scan_operand op;
        scan_ty ty
  in
  (* walk every type position of a specialized body/signature: its own
     instance args, params, locals, then every rvalue type (cast
     targets, function constants, closure aggregates, callee instances
     and the class-carried callee type args, call argument operands) *)
  let scan_body_types (body : function_) =
    if Array.length generic_types > 0 then begin
      scan_inst body.instance;
      Array.iter (fun p -> scan_ty p.Type_repr.pt_type) body.params;
      Array.iter scan_ty body.locals;
      let scan_callee_types (callee : callee) : unit =
        match callee with
        | User i -> scan_inst i
        | Derived (_, args) | Intrinsic (_, args) | Extern (_, args)
        | TypeQuery (_, args) ->
            Array.iter scan_ty args
        | FnValue op -> scan_operand op
      in
      Array.iter
        (fun b ->
          List.iter
            (function
              | Assign (_, rv) -> scan_rvalue rv
              | _ -> ())
            b.statements;
          match b.terminator with
          | Call (_, callee, args, _, _) ->
              scan_callee_types callee;
              Array.iter (fun a -> scan_operand a.value) args
          | SwitchInt (op, _, _) | Assert (op, _, _, _) -> scan_operand op
          | _ -> ())
        body.blocks
    end
  in
  (* seed: entry + static initializers *)
  (match Hashtbl.find_opt template_tbl (Instance_id.callable entry) with
   | Some tmpl -> enqueue ~template:tmpl entry
   | None ->
       err
         (Printf.sprintf "mono: no template function for the entry instance %s"
            (Seed_mir.print_instance entry)));
  Array.iter
    (fun (_, _, _, init) ->
      match init with
      | Some (Function inst) -> enqueue_instance inst
      | _ -> ())
    prog.statics;
  (* drain: specialize each work item, then re-walk its calls.
     Nested-substitution chaining: the caller's substitution is applied
     to every instance embedded in its body — callee instances,
     function constants, closure aggregates — BEFORE the callee is
     enqueued, so a generic caller calling a generic callee (the callee
     instance carries the caller's Type_params) specializes the callee
     against the SUBSTITUTED arguments and memoizes by them (the
     seen-set and cache hold post-substitution instances).  An arity
     disagreement is an internal error reported through the errors list;
     the mismatched work item is skipped (it cannot produce a body). *)
  while not (Queue.is_empty queue) do
    let wi = Queue.pop queue in
    match substitution wi.fn wi.instance with
    | Error m -> err m
    | Ok subst ->
        let body = specialize_under subst wi.fn wi.instance in
        Hashtbl.replace cache wi.instance body;
        cache_order := body :: !cache_order;
        walk_instances body (fun inst -> enqueue_instance (subst_instance subst inst));
        scan_body_types body
  done;
  (* final validation: every embedded instance is concrete and
     specialized; every body is concrete; the output is self-contained *)
  let concrete (inst : Instance_id.t) =
    not (Array.exists Type_repr.has_type_param (Instance_id.type_args inst))
  in
  let in_output (inst : Instance_id.t) = Hashtbl.mem cache inst in
  List.iter
    (fun (body : function_) ->
      let inst = body.instance in
      if not (concrete inst) then
        err
          (Printf.sprintf "mono: instance %s has unresolved type arguments" (Seed_mir.print_instance inst));
      Array.iter
        (fun p ->
          if Type_repr.has_type_param p.Type_repr.pt_type then
            err
              (Printf.sprintf "mono: instantiated body of %s still carries a type parameter in a param type (%s)"
                 body.name (Seed_mir.print_type p.Type_repr.pt_type)))
        body.params;
      Array.iter
        (fun ty ->
          if Type_repr.has_type_param ty then
            err
              (Printf.sprintf "mono: instantiated body of %s still carries a type parameter in a local type (%s)"
                 body.name (Seed_mir.print_type ty)))
        body.locals;
      walk_instances body (fun i ->
          if not (concrete i) then
            err
              (Printf.sprintf "mono: call in %s points to instance %s with unresolved type arguments"
                 body.name (Seed_mir.print_instance i));
          if not (in_output i) && not (Hashtbl.mem kept_bodyless i) then
            err
              (Printf.sprintf "mono: call in %s points to instance %s that was never specialized"
                 body.name (Seed_mir.print_instance i))))
    !cache_order;
  match !errors with
  | [] -> Ok (Array.of_list (List.rev !cache_order))
  | errs -> Error (List.rev errs)
