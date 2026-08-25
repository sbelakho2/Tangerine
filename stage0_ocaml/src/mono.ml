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
   requested instance's type arguments are the concrete substitutes. *)
let substitution (tmpl : function_) (inst : Instance_id.t) :
    (Ids.Generic_param_id.t * Type_repr.t) list =
  let n =
    min
      (Array.length (Instance_id.type_args tmpl.instance))
      (Array.length (Instance_id.type_args inst))
  in
  let rec go i acc =
    if i >= n then List.rev acc
    else
      match (Instance_id.type_args tmpl.instance).(i) with
      | Type_repr.Type_param pid -> go (i + 1) ((pid, (Instance_id.type_args inst).(i)) :: acc)
      | _ -> go (i + 1) acc
  in
  go 0 []

let subst_instance (subst : (Ids.Generic_param_id.t * Type_repr.t) list)
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
   instance as its identity. *)
let specialize (tmpl : function_) (inst : Instance_id.t) : function_ =
  let subst = substitution tmpl inst in
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
    params = Array.map (fun (c, ty) -> (c, subst_ty ty)) tmpl.params;
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

(* instantiate: substitute the Type_params of the template registered
   under inst's callable.  None when the program has no template for the
   instance (callable not found).  The returned body may still carry
   Type_params when the instance's type arguments do not cover the
   template's declared parameters — build rejects that case
   fail-closed. *)
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
  (* drain: specialize each work item, then re-walk its calls *)
  while not (Queue.is_empty queue) do
    let wi = Queue.pop queue in
    let body = specialize wi.fn wi.instance in
    cache := (wi.instance, body) :: !cache;
    let subst = substitution wi.fn wi.instance in
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
        (fun (_, ty) ->
          if Type_repr.has_type_param ty then
            err
              (Printf.sprintf "mono: instantiated body of %s still carries a type parameter in a param type (%s)"
                 body.name (Seed_mir.print_type ty)))
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
