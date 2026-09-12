(* layout_fold.ml — compile-time resolution of the Seed MIR TypeQuery
   (`size_of[T]()` / `align_of[T]()`) into integer constants.

   WHY THIS IS A SEED-SIDE PASS.  The Seed MIR contract (seed_mir.ml) names
   the TypeQuery class as compile-time-only: "no runtime body: it is
   resolved by layout folding or a precise host channel, never a
   body-less User".  The seed has no runtime layout authority, so the fold
   happens HERE, after mono and immediately before the VM run: every
   `Call (dest, TypeQuery (k, [ty]), [], next, None)` becomes a constant
   assignment to `dest` followed by `Goto next`.

   THE RULES are a faithful port of the direct kernel's layout authority
   (tg_compiler/layout_engine.tg) for the seed's concrete type model:

     - the representation decision table (type_repr,
       layout_engine.tg:355-420) and its storage projection
       (repr_storage_size/repr_storage_align, :614-673);
     - primitive sizes/alignments (primitive_size/primitive_align,
       :1069-1117): Unit 0/1, Bool 1/1, Char 4/4, I8/U8 1/1, I16/U16 2/2,
       I32/U32/F32 4/4, I64/U64/F64 8/8, I128/U128 16/16, Int/UInt 8/8,
       Never 0/pointer-align;
     - struct layout — F7 "declaration order, natural alignment, tail
       padding" (compute_struct_layout, :2226-2319) plus the FFI opaque
       alignment override (:2180-2189);
     - enum layout — F3 "8-byte tag at 0, payload fields at 8" with the
       conservative two-variant niche gate (compute_enum_layout,
       :2432-2655) and niche_of_type (:1862-1918);
     - tuple layout (compute_tuple_layout, :2118-2149) and fixed-array
       inline storage (inline_array_storage_size, :679-688);
     - the name-classified builtin nominals (type_repr's Box/Rc/
       UnsafeSlice/Array/Map/Set arms and container_repr_for_name,
       :427-464): Box/Rc are RawPtr (8/8), UnsafeSlice is the inline
       {ptr,len} view (16/8), Vec/Array/List are heap-vector handles,
       Map/Set are heap headers — all pointer-sized 8/8 at the value
       level; String is the 8-byte handle.

   ERASED-INDIRECTION CYCLES.  The seed's mono type defs erase the Box
   wrapper (the checker's transparent-Box convention) and the direct
   kernel's pointer variants of the self-describing `Type` enum
   (`Type::Ptr(Type)` / `PtrMut` / `RefInternal`) record their payload as
   the enum type itself.  In the direct pipeline those edges are
   indirections (a pointer/Box slot, and `promote_heap_to_stack` removes
   the box entirely); the seed def carries no wrapper to classify.  The
   fold therefore treats a re-entrant edge of an in-progress type as the
   direct kernel's pointer storage (8/8) — the only finite interpretation
   of an erased indirection, and exactly the storage the erased wrapper
   (`Box[T]` = { ptr: Ptr[T] }, or the Ptr variant payload) occupies.  A
   field type outside that class that still carries a type parameter, an
   inference variable or no registered def is a hard failure (fail
   closed, never a guessed word). *)

let pointer_size = 8
let pointer_align = 8

type layout = { size : int; align : int }

type ctx = {
  lang : Lang_items.t;
  defs : (int, Seed_mir.type_def) Hashtbl.t;
  name_of : Ids.Type_id.t -> string option;
  memo : (int, layout) Hashtbl.t;
  (* the in-progress set: a re-entrant edge is the erased indirection *)
  visiting : (int, unit) Hashtbl.t;
}

let fail fmt = Printf.ksprintf (fun s -> failwith ("layout_fold: " ^ s)) fmt

let align_up (v : int) (a : int) : int =
  if a <= 1 then v
  else
    let r = v mod a in
    if r = 0 then v else v + (a - r)

let pointer_layout = { size = pointer_size; align = pointer_align }

let tid_eq_option (o : Ids.Type_id.t option) (tid : Ids.Type_id.t) : bool =
  Lang_items.tid_eq o tid

let is_erased_pointer_nominal (ctx : ctx) (tid : Ids.Type_id.t) : bool =
  Lang_items.is_raw_pointer ctx.lang tid
  || tid_eq_option ctx.lang.Lang_items.ptr tid
  || tid_eq_option ctx.lang.Lang_items.ptr_mut tid

(* The builtin container handles: the direct kernel's name classification
   (type_repr's Adt arm / container_repr_for_name) is 8/8 for every
   Vec/Array/List/Map/HashMap/Set/HashSet/String/Box/Rc nominal, and the
   seed's LangItems record names the Vec/Map/Set/Box/Rc ids directly. *)
let is_pointer_handle_nominal (ctx : ctx) (tid : Ids.Type_id.t) : bool =
  tid_eq_option ctx.lang.Lang_items.vec tid
  || tid_eq_option ctx.lang.Lang_items.map tid
  || tid_eq_option ctx.lang.Lang_items.set tid
  || tid_eq_option ctx.lang.Lang_items.box_ tid
  || tid_eq_option ctx.lang.Lang_items.rc tid
  || tid_eq_option ctx.lang.Lang_items.string tid
  || is_erased_pointer_nominal ctx tid

let name_says_pointer_handle (ctx : ctx) (tid : Ids.Type_id.t) : bool =
  match ctx.name_of tid with
  | Some
      ( "Box" | "Rc" | "Vec" | "Array" | "List" | "Map" | "HashMap"
      | "Set" | "HashSet" | "String" ) ->
      true
  | _ -> false

let name_says_unsafe_slice (ctx : ctx) (tid : Ids.Type_id.t) : bool =
  match ctx.name_of tid with Some "UnsafeSlice" -> true | _ -> false

(* the FFI-opaque native alignment override (layout_engine.tg:2180) *)
let ffi_opaque_native_align (name : string) : int =
  match name with
  | "PthreadT" | "PthreadAttrT" | "PthreadMutexT" | "PthreadCondT"
  | "PthreadBarrierT" ->
      pointer_align
  | _ -> 1

let find_def (ctx : ctx) (tid : Ids.Type_id.t) : Seed_mir.type_def option =
  Hashtbl.find_opt ctx.defs (Ids.Type_id.to_int tid)

let int_layout_of_kind (k : Type_repr.int_kind) : layout =
  match k with
  | Type_repr.I8 | Type_repr.U8 -> { size = 1; align = 1 }
  | Type_repr.I16 | Type_repr.U16 -> { size = 2; align = 2 }
  | Type_repr.I32 | Type_repr.U32 -> { size = 4; align = 4 }
  | Type_repr.I64 | Type_repr.U64 | Type_repr.Int | Type_repr.UInt ->
      { size = 8; align = 8 }
  | Type_repr.I128 | Type_repr.U128 -> { size = 16; align = 16 }

(* the variant's payload field list: Tuple for multi-field payloads, Unit
   for none, the single field's type otherwise (seed_mir.ml contract) *)
let payload_fields (p : Type_repr.t) : Type_repr.t list =
  match p with
  | Type_repr.Tuple elems -> Array.to_list elems
  | Type_repr.Unit -> []
  | t -> [ t ]

(* niche_of_type (layout_engine.tg:1862) restricted to the seed's model:
   pointer null (Raw_ptr / Ref_internal / the Ptr,PtrMut nominals — size 8)
   and the NonZero-style single-integer-field wrapper.  Bool's niche is
   not usable at the pointer-size gate of compute_enum_layout (its storage
   size is 1), so reporting it changes nothing. *)
let rec niche_of_ty (ctx : ctx) (ty : Type_repr.t) : int option =
  match ty with
  | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> Some pointer_size
  | Type_repr.Named (tid, _) when is_erased_pointer_nominal ctx tid ->
      Some pointer_size
  | Type_repr.Named (tid, [| inner |])
    when (match ctx.name_of tid with
          | Some n
            when n = "NonZero" || String.length n >= 7 && String.sub n 0 7 = "NonZero"
            -> true
          | _ -> false) ->
      integer_bits inner
  | _ -> None

and integer_bits (ty : Type_repr.t) : int option =
  match ty with
  | Type_repr.Int Type_repr.I8 | Type_repr.Int Type_repr.U8 -> Some 8
  | Type_repr.Int Type_repr.I16 | Type_repr.Int Type_repr.U16 -> Some 16
  | Type_repr.Int Type_repr.I32 | Type_repr.Int Type_repr.U32 -> Some 32
  | Type_repr.Int Type_repr.I64 | Type_repr.Int Type_repr.U64
  | Type_repr.Int Type_repr.Int | Type_repr.Int Type_repr.UInt ->
      Some 64
  | Type_repr.Int Type_repr.I128 | Type_repr.Int Type_repr.U128 -> Some 128
  | _ -> None

and layout_of_ty (ctx : ctx) (ty : Type_repr.t) : layout =
  match ty with
  | Type_repr.Unit -> { size = 0; align = 1 }
  | Type_repr.Bool -> { size = 1; align = 1 }
  | Type_repr.Char -> { size = 4; align = 4 }
  | Type_repr.Int k -> int_layout_of_kind k
  | Type_repr.Float Type_repr.F32 -> { size = 4; align = 4 }
  | Type_repr.Float Type_repr.F64 -> { size = 8; align = 8 }
  | Type_repr.String -> pointer_layout
  | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> pointer_layout
  | Type_repr.Function _ -> pointer_layout
  | Type_repr.Never -> { size = 0; align = pointer_align }
  | Type_repr.Tuple elems -> tuple_layout ctx (Array.to_list elems)
  | Type_repr.Fixed_array (elem, n) -> fixed_array_layout ctx elem n
  | Type_repr.Named (tid, _) -> named_layout ctx tid
  | Type_repr.Type_param id ->
      fail "type parameter T%d survived mono (no concrete layout)" (Ids.Generic_param_id.to_int id)
  | Type_repr.Infer_var v -> fail "inference variable ?#%d survived mono" v
  | Type_repr.Int_literal _ -> fail "integer literal type survived mono"
  | Type_repr.Error -> fail "error type reached the layout fold"

and tuple_layout (ctx : ctx) (elems : Type_repr.t list) : layout =
  let off = ref 0 and max_align = ref 1 in
  List.iter
    (fun e ->
      let l = layout_of_ty ctx e in
      if l.align > !max_align then max_align := l.align;
      off := align_up !off l.align;
      off := !off + l.size)
    elems;
  { size = align_up !off !max_align; align = !max_align }

and fixed_array_layout (ctx : ctx) (elem : Type_repr.t) (n : int) : layout =
  if n <= 0 then { size = 0; align = (layout_of_ty ctx elem).align }
  else
    let el = layout_of_ty ctx elem in
    let stride = align_up el.size el.align in
    { size = align_up (n * stride) el.align; align = el.align }

and named_layout (ctx : ctx) (tid : Ids.Type_id.t) : layout =
  match Hashtbl.find_opt ctx.memo (Ids.Type_id.to_int tid) with
  | Some l -> l
  | None ->
      if Hashtbl.mem ctx.visiting (Ids.Type_id.to_int tid) then
        (* the erased indirection edge: the wrapper the direct kernel
           carries here is a pointer/Box slot (8/8) *)
        pointer_layout
      else if is_pointer_handle_nominal ctx tid || name_says_pointer_handle ctx tid then
        pointer_layout
      else if name_says_unsafe_slice ctx tid then { size = 16; align = pointer_align }
      else begin
        match find_def ctx tid with
        | None ->
            fail "no def for type#%d (name %s) — fail closed"
              (Ids.Type_id.to_int tid)
              (match ctx.name_of tid with Some n -> n | None -> "?")
        | Some def ->
            Hashtbl.replace ctx.visiting (Ids.Type_id.to_int tid) ();
            let l =
              (try
                 match def with
                 | Seed_mir.StructDef { sd_fields; _ } ->
                     struct_layout ctx tid sd_fields
                 | Seed_mir.EnumDef { ed_variants; _ } ->
                     enum_layout ctx ed_variants
               with e ->
                 Hashtbl.remove ctx.visiting (Ids.Type_id.to_int tid);
                 raise e)
            in
            Hashtbl.remove ctx.visiting (Ids.Type_id.to_int tid);
            Hashtbl.replace ctx.memo (Ids.Type_id.to_int tid) l;
            l
      end

and struct_layout (ctx : ctx) (tid : Ids.Type_id.t)
    (fields : Seed_mir.field_def list) : layout =
  let sorted =
    List.sort
      (fun a b -> Ids.Field_index.compare a.Seed_mir.fd_index b.Seed_mir.fd_index)
      fields
  in
  let off = ref 0 and max_align = ref 1 in
  List.iter
    (fun (f : Seed_mir.field_def) ->
      let l = layout_of_ty ctx f.Seed_mir.fd_ty in
      if l.align > !max_align then max_align := l.align;
      off := align_up !off l.align;
      off := !off + l.size)
    sorted;
  (* the FFI-opaque alignment override on the record's own alignment *)
  (match ctx.name_of tid with
   | Some n ->
       let ffi = ffi_opaque_native_align n in
       if ffi > !max_align then max_align := ffi
   | None -> ());
  { size = align_up !off !max_align; align = !max_align }

and enum_layout (ctx : ctx)
    (variants : Seed_mir.variant_def list) : layout =
  let sorted =
    List.sort
      (fun a b -> Ids.Variant_index.compare a.Seed_mir.vd_index b.Seed_mir.vd_index)
      variants
  in
  let max_payload_size = ref 0 in
  let max_align = ref 8 in
  let variant_shapes =
    List.map
      (fun (v : Seed_mir.variant_def) ->
        let fields = payload_fields v.Seed_mir.vd_payload in
        let payload_offset = ref 8 and payload_size = ref 0 in
        List.iter
          (fun fty ->
            let l = layout_of_ty ctx fty in
            if l.align > !max_align then max_align := l.align;
            payload_offset := align_up !payload_offset l.align;
            payload_offset := !payload_offset + l.size;
            payload_size := !payload_size + l.size)
          fields;
        if !payload_size > !max_payload_size then max_payload_size := !payload_size;
        (fields, !payload_size))
      sorted
  in
  (* the conservative two-variant niche gate (layout_engine.tg:2529) *)
  let niched =
    match variant_shapes with
    | [ (f0, s0); (f1, s1) ] ->
        let payload =
          if s0 = 0 && List.length f1 = 1 then Some f1
          else if s1 = 0 && List.length f0 = 1 then Some f0
          else None
        in
        (match payload with
         | Some [ pty ] -> (
             match niche_of_ty ctx pty with
             | Some bits when bits > 0 && (layout_of_ty ctx pty).size = pointer_size ->
                 true
             | _ -> false)
         | _ -> false)
    | _ -> false
  in
  if niched then pointer_layout
  else
    let payload_total = align_up !max_payload_size !max_align in
    { size = align_up (8 + payload_total) !max_align; align = !max_align }

(* Build the fold context once per mono'd program. *)
let create_ctx ~(lang_items : Lang_items.t)
    ~(name_of : Ids.Type_id.t -> string option) (program : Seed_mir.program) : ctx =
  let defs = Hashtbl.create (Array.length program.Seed_mir.types) in
  Array.iter
    (fun d -> Hashtbl.replace defs (Ids.Type_id.to_int (Seed_mir.def_id d)) d)
    program.Seed_mir.types;
  { lang = lang_items; defs; name_of; memo = Hashtbl.create 128; visiting = Hashtbl.create 64 }

let int_value_of_dest (ty : Type_repr.t) (n : int) : Seed_mir.constant =
  match ty with
  | Type_repr.Int k ->
      let width =
        match k with
        | Type_repr.I8 | Type_repr.U8 -> 8
        | Type_repr.I16 | Type_repr.U16 -> 16
        | Type_repr.I32 | Type_repr.U32 -> 32
        | Type_repr.I64 | Type_repr.U64 | Type_repr.Int | Type_repr.UInt -> 64
        | Type_repr.I128 | Type_repr.U128 -> 128
      in
      let signed =
        match k with
        | Type_repr.I8 | Type_repr.I16 | Type_repr.I32 | Type_repr.I64
        | Type_repr.I128 | Type_repr.Int ->
            true
        | _ -> false
      in
      Seed_mir.Integer (Int_value.of_int64 ~width ~signed (Int64.of_int n))
  | _ ->
      fail "TypeQuery dest is not an integer local (type %s)" (Seed_mir.print_type ty)

let fold_function (ctx : ctx) (fn : Seed_mir.function_) : Seed_mir.function_ =
  let blocks =
    Array.map
      (fun (b : Seed_mir.block) ->
        match b.Seed_mir.terminator with
        | Seed_mir.Call (dest, Seed_mir.TypeQuery (k, qargs), args, next, unwind) ->
            if Array.length qargs <> 1 then
              fail "TypeQuery %s carries %d type arguments (expected 1)"
                (Seed_mir.type_query_name k) (Array.length qargs);
            if Array.length args <> 0 then
              fail "TypeQuery %s has runtime arguments in %s"
                (Seed_mir.type_query_name k) fn.Seed_mir.name;
            if unwind <> None then
              fail "TypeQuery %s carries an unwind target in %s"
                (Seed_mir.type_query_name k) fn.Seed_mir.name;
            let dest_ty =
              match dest.Seed_mir.root with
              | Seed_mir.Local li
                when dest.Seed_mir.projections = []
                     && li >= 0 && li < Array.length fn.Seed_mir.locals ->
                  fn.Seed_mir.locals.(li)
              | _ ->
                  fail "TypeQuery %s dest is not a bare local in %s"
                    (Seed_mir.type_query_name k) fn.Seed_mir.name
            in
            let l = layout_of_ty ctx qargs.(0) in
            let n = match k with Seed_mir.SizeOf -> l.size | Seed_mir.AlignOf -> l.align in
            let v = int_value_of_dest dest_ty n in
            {
              b with
              Seed_mir.statements =
                b.Seed_mir.statements @ [ Seed_mir.Assign (dest, Seed_mir.Use (Seed_mir.Constant v)) ];
              Seed_mir.terminator = Seed_mir.Goto next;
            }
        | _ -> b)
      fn.Seed_mir.blocks
  in
  { fn with Seed_mir.blocks }

(* The fold entry point: resolve every TypeQuery in the program.  The
   result is the same program shape with constant assignments in place of
   the query calls (function/instance/static/type tables untouched). *)
let fold_program ~(lang_items : Lang_items.t)
    ~(name_of : Ids.Type_id.t -> string option) (program : Seed_mir.program) :
    Seed_mir.program =
  let ctx = create_ctx ~lang_items ~name_of program in
  let functions = Array.map (fold_function ctx) program.Seed_mir.functions in
  { program with Seed_mir.functions }

(* ── the transparent Box promotion (the VM-side program only) ────────
   The seed's value model carries the boxed CONTENT in Box-typed slots —
   the checker's transparent-Box convention, and the assumption mir_derive
   records for derived clone and the deref-on-field transparency.  The
   direct kernel reaches the same shape through its
   promote_heap_to_stack pass (`_X = Box::new(v)` -> `_X = v`).  This
   rewrite applies the same promotion to the VM-side program: the
   registered `box_new` instances become `dest = Move(value); Ret` (the
   emitted CALLS stay in the MIR — the typed-vs-emitted evidence rows and
   the concrete verifier keep inspecting the original program — only the
   executed body is transparent).  A `box_new` instance whose shape does
   not match the registered constructor (one param, return slot local _0,
   value local _1) is left untouched and fails closed at the layout/VM
   boundary instead of being mis-promoted. *)
let is_box_ctor_name (name : string) : bool =
  let s = "box_new" in
  let n = String.length name and m = String.length s in
  n >= m && String.sub name (n - m) m = s

let promote_box_constructors (program : Seed_mir.program) : Seed_mir.program =
  let functions =
    Array.map
      (fun (fn : Seed_mir.function_) ->
        if
          is_box_ctor_name fn.Seed_mir.name
          && Array.length fn.Seed_mir.params = 1
          && Array.length fn.Seed_mir.locals >= 2
        then
          let dest = { Seed_mir.root = Seed_mir.Local 0; projections = [] } in
          let src = { Seed_mir.root = Seed_mir.Local 1; projections = [] } in
          {
            fn with
            Seed_mir.entry = 0;
            Seed_mir.blocks =
              [|
                {
                  Seed_mir.id = 0;
                  statements =
                    [ Seed_mir.Assign (dest, Seed_mir.Use (Seed_mir.Move src)) ];
                  terminator = Seed_mir.Ret;
                };
              |];
          }
        else fn)
      program.Seed_mir.functions
  in
  { program with Seed_mir.functions }
