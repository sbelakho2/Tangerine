(** Core type representation for Tangerine *)

(** Type identifier (unique ID for type variables) *)
type type_id = int
[@@deriving show, eq, ord]

let next_type_id = ref 0

let fresh_type_id () =
  let id = !next_type_id in
  incr next_type_id;
  id

(** Primitive types *)
type prim_type =
  | TUnit
  | TBool
  | TInt
  | TUInt
  | TFloat
  | TChar
  | TString
  (* FFI-specific sized types *)
  | TI8 | TU8
  | TI16 | TU16
  | TI32 | TU32
  | TI64 | TU64
  | TF32 | TF64
[@@deriving show, eq, ord]

(** Mutability for references *)
type mutability =
  | Immutable
  | Mutable
[@@deriving show, eq, ord]

(** Core type representation *)
type ty =
  (* Primitive types *)
  | TPrim of prim_type
  
  (* Type variable (for inference) *)
  | TVar of type_var ref
  
  (* Named type with type arguments (e.g., Vec[Int], Option[T]) *)
  | TNamed of string * ty list
  
  (* Tuple type *)
  | TTuple of ty list
  
  (* Function type *)
  | TFn of ty list * ty
  
  (* Reference types *)
  | TRef of mutability * ty        (* &T or &mut T *)
  | TPtr of mutability * ty        (* *T or *mut T *)
  
  (* Array types *)
  | TArray of ty * int             (* [T; N] *)
  | TSlice of ty                    (* [T] *)
  
  (* Option shorthand *)
  | TOption of ty
  
  (* Result type *)
  | TResult of ty * ty
  
  (* Self type (in trait/impl contexts) *)
  | TSelf
  
  (* Never type (for expressions that don't return) *)
  | TNever
  
  (* Error type (for error recovery during type checking) *)
  | TError
[@@deriving show, eq, ord]

(** Type variable state *)
and type_var =
  | Unbound of type_id * int       (* id, level for generalization *)
  | Link of ty                      (* unified with another type *)
[@@deriving show, eq, ord]

(** Type scheme (for polymorphism) *)
type scheme = {
  sch_vars : type_id list;          (* bound type variables *)
  sch_type : ty;                    (* the type *)
}
[@@deriving show, eq]

(** Trait bounds *)
type trait_bound = {
  tb_trait : string;
  tb_args : ty list;
}
[@@deriving show, eq]

(** Type parameter with bounds *)
type type_param = {
  tp_name : string;
  tp_var : ty;                      (* The type variable *)
  tp_bounds : trait_bound list;
}
[@@deriving show, eq]

(** Constructor for fresh type variables *)
let fresh_tvar level =
  TVar (ref (Unbound (fresh_type_id (), level)))

(** Follow links in type variables *)
let rec repr ty =
  match ty with
  | TVar { contents = Link t } -> repr t
  | t -> t

(** Check if a type variable occurs in a type (occurs check) *)
let rec occurs_check id ty =
  match repr ty with
  | TVar { contents = Unbound (id', _) } -> id = id'
  | TVar { contents = Link _ } -> failwith "occurs_check: unexpected Link"
  | TPrim _ -> false
  | TNamed (_, args) -> List.exists (occurs_check id) args
  | TTuple tys -> List.exists (occurs_check id) tys
  | TFn (params, ret) ->
    List.exists (occurs_check id) params || occurs_check id ret
  | TRef (_, t) | TPtr (_, t) | TSlice t | TOption t ->
    occurs_check id t
  | TArray (t, _) -> occurs_check id t
  | TResult (ok, err) -> occurs_check id ok || occurs_check id err
  | TSelf | TNever | TError -> false

(** Unify two types *)
let rec unify t1 t2 =
  let t1 = repr t1 in
  let t2 = repr t2 in
  if t1 == t2 then Ok ()
  else match t1, t2 with
  | TError, _ | _, TError -> Ok ()  (* Error types unify with anything *)
  
  | TVar ({ contents = Unbound (id1, _) } as r1),
    TVar { contents = Unbound (id2, _) } when id1 = id2 ->
    Ok ()
    
  | TVar ({ contents = Unbound (id, level) } as r), t
  | t, TVar ({ contents = Unbound (id, level) } as r) ->
    if occurs_check id t then
      Error (`OccursCheck (id, t))
    else begin
      (* Adjust levels for let-polymorphism *)
      adjust_levels level t;
      r := Link t;
      Ok ()
    end
    
  | TPrim p1, TPrim p2 when p1 = p2 -> Ok ()
  
  | TNamed (n1, args1), TNamed (n2, args2) when n1 = n2 ->
    unify_list args1 args2
    
  | TTuple ts1, TTuple ts2 ->
    unify_list ts1 ts2
    
  | TFn (params1, ret1), TFn (params2, ret2) ->
    Result.bind (unify_list params1 params2) (fun () ->
      unify ret1 ret2)
    
  | TRef (m1, t1), TRef (m2, t2) when m1 = m2 -> unify t1 t2
  | TPtr (m1, t1), TPtr (m2, t2) when m1 = m2 -> unify t1 t2
  
  | TArray (t1, n1), TArray (t2, n2) when n1 = n2 -> unify t1 t2
  | TSlice t1, TSlice t2 -> unify t1 t2
  
  | TOption t1, TOption t2 -> unify t1 t2
  | TResult (ok1, err1), TResult (ok2, err2) ->
    Result.bind (unify ok1 ok2) (fun () -> unify err1 err2)
    
  | TSelf, TSelf -> Ok ()
  | TNever, TNever -> Ok ()
  
  | _ -> Error (`Mismatch (t1, t2))

and unify_list ts1 ts2 =
  match ts1, ts2 with
  | [], [] -> Ok ()
  | t1 :: rest1, t2 :: rest2 ->
    Result.bind (unify t1 t2) (fun () -> unify_list rest1 rest2)
  | _ -> Error `ArityMismatch

and adjust_levels level ty =
  match repr ty with
  | TVar ({ contents = Unbound (id, level') } as r) ->
    if level' > level then r := Unbound (id, level)
  | TVar { contents = Link _ } -> failwith "adjust_levels: unexpected Link"
  | TPrim _ -> ()
  | TNamed (_, args) -> List.iter (adjust_levels level) args
  | TTuple tys -> List.iter (adjust_levels level) tys
  | TFn (params, ret) ->
    List.iter (adjust_levels level) params;
    adjust_levels level ret
  | TRef (_, t) | TPtr (_, t) | TSlice t | TOption t ->
    adjust_levels level t
  | TArray (t, _) -> adjust_levels level t
  | TResult (ok, err) ->
    adjust_levels level ok;
    adjust_levels level err
  | TSelf | TNever | TError -> ()

(** Generalize a type at a given level *)
let generalize level ty =
  let rec collect_vars acc ty =
    match repr ty with
    | TVar { contents = Unbound (id, level') } when level' > level ->
      if List.mem id acc then acc else id :: acc
    | TVar { contents = Link _ } -> failwith "generalize: unexpected Link"
    | TPrim _ -> acc
    | TNamed (_, args) -> List.fold_left collect_vars acc args
    | TTuple tys -> List.fold_left collect_vars acc tys
    | TFn (params, ret) ->
      List.fold_left collect_vars (collect_vars acc ret) params
    | TRef (_, t) | TPtr (_, t) | TSlice t | TOption t ->
      collect_vars acc t
    | TArray (t, _) -> collect_vars acc t
    | TResult (ok, err) -> collect_vars (collect_vars acc ok) err
    | _ -> acc
  in
  let vars = collect_vars [] ty in
  { sch_vars = vars; sch_type = ty }

(** Instantiate a type scheme with fresh type variables *)
let instantiate level scheme =
  let subst = List.map (fun id -> (id, fresh_tvar level)) scheme.sch_vars in
  let rec apply ty =
    match repr ty with
    | TVar { contents = Unbound (id, _) } ->
      (try List.assoc id subst with Not_found -> ty)
    | TVar { contents = Link _ } -> failwith "instantiate: unexpected Link"
    | TPrim _ -> ty
    | TNamed (n, args) -> TNamed (n, List.map apply args)
    | TTuple tys -> TTuple (List.map apply tys)
    | TFn (params, ret) -> TFn (List.map apply params, apply ret)
    | TRef (m, t) -> TRef (m, apply t)
    | TPtr (m, t) -> TPtr (m, apply t)
    | TArray (t, n) -> TArray (apply t, n)
    | TSlice t -> TSlice (apply t)
    | TOption t -> TOption (apply t)
    | TResult (ok, err) -> TResult (apply ok, apply err)
    | TSelf | TNever | TError -> ty
  in
  apply scheme.sch_type

(** Pretty print a type *)
let rec pp_ty fmt ty =
  match repr ty with
  | TPrim p -> Format.fprintf fmt "%a" pp_prim_type p
  | TVar { contents = Unbound (id, _) } ->
    Format.fprintf fmt "'t%d" id
  | TVar { contents = Link t } ->
    pp_ty fmt t
  | TNamed (name, []) ->
    Format.fprintf fmt "%s" name
  | TNamed (name, args) ->
    Format.fprintf fmt "%s[%a]" name
      (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ", ") pp_ty) args
  | TTuple [] ->
    Format.fprintf fmt "()"
  | TTuple tys ->
    Format.fprintf fmt "(%a)"
      (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ", ") pp_ty) tys
  | TFn (params, ret) ->
    Format.fprintf fmt "fn(%a) -> %a"
      (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ", ") pp_ty) params
      pp_ty ret
  | TRef (Immutable, t) -> Format.fprintf fmt "&%a" pp_ty t
  | TRef (Mutable, t) -> Format.fprintf fmt "&mut %a" pp_ty t
  | TPtr (Immutable, t) -> Format.fprintf fmt "*%a" pp_ty t
  | TPtr (Mutable, t) -> Format.fprintf fmt "*mut %a" pp_ty t
  | TArray (t, n) -> Format.fprintf fmt "[%a; %d]" pp_ty n
  | TSlice t -> Format.fprintf fmt "[%a]" pp_ty t
  | TOption t -> Format.fprintf fmt "%a?" pp_ty t
  | TResult (ok, err) -> Format.fprintf fmt "Result[%a, %a]" pp_ty ok pp_ty err
  | TSelf -> Format.fprintf fmt "Self"
  | TNever -> Format.fprintf fmt "!"
  | TError -> Format.fprintf fmt "<error>"

let to_string ty =
  Format.asprintf "%a" pp_ty ty
