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
   - duplicate instances must be identical: re-discovering an instance
     re-specializes it and compares structurally with the cached body —
     an inconsistency is an error;
   - a generic call with an instance whose type arguments cannot be made
     concrete (an unsolved substitution) is fail-closed: the residual
     type parameter is reported and the build fails;
   - the input program must not register two functions under one
     callable identity;
   - every embedded instance in the output (call callees, function
     constants, closure aggregates) must be concrete AND present in the
     output — "every generic call points to a concrete instance". *)

open Seed_mir

(* A work item: the concrete instance to materialize together with the
   generic template (from the input program) it specializes. *)
type work_item = {
  instance : Instance_id.t;
  fn : function_;
}

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
  let subst_terminator t =
    match t with
    | Call (dest, User i, args, next, unwind) ->
        Call
          ( dest,
            User (subst_instance subst i),
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
          (match callee with
           | User i -> f i
           | Intrinsic _ | Extern _ -> ());
          Array.iter (fun a -> scan_operand a.value) args)
      | SwitchInt (op, _, _) | Assert (op, _, _, _) -> scan_operand op
      | _ -> ())
    body.blocks

let build ~(entry : Instance_id.t) (prog : program) : (function_ array, string list) result =
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
  let queue : work_item Queue.t = Queue.create () in
  let seen : Instance_id.t list ref = ref [] in
  let cache : (Instance_id.t * function_) list ref = ref [] in
  let enqueue ~(template : function_) (inst : Instance_id.t) =
    if List.mem inst !seen then begin
      (* duplicate instance: must be identical *)
      match List.assoc_opt inst !cache with
      | Some cached ->
          let fresh = specialize template inst in
          if fresh <> cached then
            err
              (Printf.sprintf "mono: inconsistent duplicate instance %s (two specializations of the same instance differ)"
                 (Seed_mir.print_instance inst))
      | None -> ()
    end
    else begin
      seen := inst :: !seen;
      Queue.add { instance = inst; fn = template } queue
    end
  in
  let enqueue_instance (inst : Instance_id.t) =
    match find_template prog inst with
    | Some tmpl -> enqueue ~template:tmpl inst
    | None ->
        err
          (Printf.sprintf "mono: no template function for instance %s"
             (Seed_mir.print_instance inst))
  in
  (* seed: entry + static initializers *)
  (match find_template prog entry with
   | Some tmpl -> enqueue ~template:tmpl entry
   | None ->
       err
         (Printf.sprintf "mono: no template function for the entry instance %s"
            (Seed_mir.print_instance entry)));
  Array.iter
    (fun (_, _, init) ->
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
        cache := (wi.instance, body) :: !cache;
        walk_instances body (fun inst -> enqueue_instance (subst_instance subst inst))
  done;
  (* final validation: every embedded instance is concrete and
     specialized; every body is concrete; the output is self-contained *)
  let concrete (inst : Instance_id.t) =
    not (Array.exists Type_repr.has_type_param (Instance_id.type_args inst))
  in
  let in_output (inst : Instance_id.t) = List.mem_assoc inst !cache in
  List.iter
    (fun (inst, body) ->
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
          if not (in_output i) then
            err
              (Printf.sprintf "mono: call in %s points to instance %s that was never specialized"
                 body.name (Seed_mir.print_instance i))))
    !cache;
  match !errors with
  | [] -> Ok (Array.of_list (List.rev (List.map snd !cache)))
  | errs -> Error (List.rev errs)
