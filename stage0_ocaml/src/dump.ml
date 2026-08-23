(* dump.ml — Deterministic, diffable AST text representation.

   Byte-identical to the reference ASTDumper (span-free, 2-space-indented
   lines) plus the FNV-1a 64-bit hash of the dump text. *)

type dumper = {
  mutable lines : string list;  (* reversed *)
  mutable indent : int;
}

let create () = { lines = []; indent = 0 }

let emit d text =
  d.lines <- (String.make (2 * d.indent) ' ' ^ text) :: d.lines

let push d = d.indent <- d.indent + 1
let pop d = d.indent <- d.indent - 1

let type_params_str (params : Ast.type_param list) =
  match params with
  | [] -> ""
  | _ -> "[" ^ String.concat ", " (List.map (fun p -> p.Ast.tp_name) params) ^ "]"

let convention_tag = function
  | Ast.LetAccess -> ""
  | Ast.InoutAccess -> " [inout]"
  | Ast.Sink -> " [sink]"
  | Ast.Set -> " [set]"

let modifier_tag = function
  | None -> ""
  | Some Ast.ModMut -> " [mod:mut]"
  | Some Ast.ModRef -> " [mod:ref]"
  | Some Ast.ModRefMut -> " [mod:refmut]"
  | Some Ast.ModMove -> " [mod:move]"
  | Some Ast.ModOwn -> " [mod:own]"

let binary_op_str = function
  | Ast.BOr -> "||"
  | Ast.BAnd -> "&&"
  | Ast.BitOr -> "|"
  | Ast.BitXor -> "^"
  | Ast.BitAnd -> "&"
  | Ast.Shl -> "<<"
  | Ast.Shr -> ">>"
  | Ast.Add -> "+"
  | Ast.Sub -> "-"
  | Ast.Mul -> "*"
  | Ast.Div -> "/"
  | Ast.Mod -> "%"
  | Ast.Eq -> "=="
  | Ast.NotEq -> "!="
  | Ast.Lt -> "<"
  | Ast.LtEq -> "<="
  | Ast.Gt -> ">"
  | Ast.GtEq -> ">="

let unary_op_str = function
  | Ast.Not -> "not"
  | Ast.BitNot -> "bitNot"
  | Ast.Neg -> "neg"
  | Ast.Deref -> "deref"
  | Ast.Borrow -> "borrow"
  | Ast.BorrowMut -> "borrowMut"

let rec dump_expr d (e : Ast.expr) =
  match e with
  | Ast.IntLit (v, _) -> emit d ("Int(" ^ v ^ ")")
  | Ast.FloatLit (v, _) -> emit d ("Float(" ^ v ^ ")")
  | Ast.StringLit (v, _) -> emit d ("String(\"" ^ v ^ "\")")
  | Ast.CharLit (v, _) -> emit d ("Char('" ^ v ^ "')")
  | Ast.BoolLit (b, _) -> emit d ("Bool(" ^ string_of_bool b ^ ")")
  | Ast.Name (n, _) -> emit d ("Name(" ^ n ^ ")")
  | Ast.Path (a, b, _) -> emit d ("Path(" ^ a ^ "::" ^ b ^ ")")
  | Ast.Array (elems, _) ->
      emit d "Array";
      push d;
      List.iter (dump_expr d) elems;
      pop d
  | Ast.ArrayRepeat (v, c, _) ->
      emit d "ArrayRepeat";
      push d;
      dump_expr d v;
      dump_expr d c;
      pop d
  | Ast.Tuple (elems, _) ->
      emit d "Tuple";
      push d;
      List.iter (dump_expr d) elems;
      pop d
  | Ast.StructLit (name, _, fields, rest, _) ->
      emit d ("StructLit(" ^ name ^ ")");
      push d;
      List.iter
        (fun (k, v) ->
          emit d (k ^ ":");
          push d;
          dump_expr d v;
          pop d)
        fields;
      (match rest with
       | Some r ->
           emit d "..rest:";
           push d;
           dump_expr d r;
           pop d
       | None -> ());
      pop d
  | Ast.Block (b, _) ->
      emit d "Block";
      push d;
      dump_block d b;
      pop d
  | Ast.UnsafeBlock (reason, b, _) ->
      emit d ("UnsafeBlock(" ^ reason ^ ")");
      push d;
      dump_block d b;
      pop d
  | Ast.IfExpr i ->
      emit d "If";
      push d;
      emit d "Cond:";
      push d;
      dump_expr d i.Ast.if_condition;
      pop d;
      emit d "Then:";
      push d;
      dump_block d i.Ast.if_then;
      pop d;
      List.iter
        (fun (c, b) ->
          emit d "ElsIf:";
          push d;
          dump_expr d c;
          dump_block d b;
          pop d)
        i.Ast.if_elsif;
      (match i.Ast.if_else with
       | Some b ->
           emit d "Else:";
           push d;
           dump_block d b;
           pop d
       | None -> ());
      pop d
  | Ast.Call (callee, _, args, _) ->
      emit d "Call";
      push d;
      emit d "Callee:";
      push d;
      dump_expr d callee;
      pop d;
      if args <> [] then begin
        emit d "Args:";
        push d;
        List.iter
          (fun a ->
            (match a.Ast.ca_label with
             | Some lbl -> emit d (lbl ^ ":")
             | None -> ());
            push d;
            dump_expr d a.Ast.ca_value;
            pop d)
          args;
        pop d
      end;
      pop d
  | Ast.Index (base, idx, _) ->
      emit d "Index";
      push d;
      dump_expr d base;
      dump_expr d idx;
      pop d
  | Ast.Range (s, e, incl, _) ->
      emit d (if incl then "RangeInclusive" else "Range");
      push d;
      dump_expr d s;
      dump_expr d e;
      pop d
  | Ast.MatchExpr m ->
      emit d "Match";
      push d;
      emit d "Subject:";
      push d;
      dump_expr d m.Ast.m_subject;
      pop d;
      List.iter
        (fun arm ->
          emit d "Arm:";
          push d;
          dump_pattern d arm.Ast.ma_pattern;
          (match arm.Ast.ma_guard with
           | Some g ->
               emit d "Guard:";
               push d;
               dump_expr d g;
               pop d
           | None -> ());
          emit d "Body:";
          push d;
          dump_expr d arm.Ast.ma_body;
          pop d;
          pop d)
        m.Ast.m_arms;
      pop d
  | Ast.Cast (e, t, _) ->
      emit d "Cast";
      push d;
      dump_expr d e;
      dump_type d t;
      pop d
  | Ast.TryOp (e, _) ->
      emit d "TryOp";
      push d;
      dump_expr d e;
      pop d
  | Ast.Closure c ->
      emit d "Closure";
      push d;
      if c.Ast.cl_params <> [] then begin
        emit d "Params:";
        push d;
        List.iter (fun p -> emit d p.Ast.cp_name) c.Ast.cl_params;
        pop d
      end;
      emit d "Body:";
      push d;
      dump_expr d c.Ast.cl_body;
      pop d;
      pop d
  | Ast.Unary (op, e, _) ->
      emit d ("Unary(" ^ unary_op_str op ^ ")");
      push d;
      dump_expr d e;
      pop d
  | Ast.Field (base, f, _) ->
      emit d ("Field(." ^ f ^ ")");
      push d;
      dump_expr d base;
      pop d
  | Ast.Binary (l, op, r, _) ->
      emit d ("Binary(" ^ binary_op_str op ^ ")");
      push d;
      dump_expr d l;
      dump_expr d r;
      pop d
  | Ast.AwaitExpr (e, _) ->
      emit d "Await";
      push d;
      dump_expr d e;
      pop d
  | Ast.MacroCall (name, args, _) ->
      emit d ("MacroCall(" ^ name ^ ")");
      push d;
      List.iter
        (function
          | Ast.MacroExpr e -> dump_expr d e
          | Ast.MacroTokens (text, _) -> emit d ("MacroTokens(" ^ text ^ ")"))
        args;
      pop d
  | Ast.Assign (t, v, _) ->
      emit d "Assign";
      push d;
      dump_expr d t;
      dump_expr d v;
      pop d
  | Ast.CompoundAssign (t, op, v, _) ->
      emit d ("CompoundAssign(" ^ binary_op_str op ^ ")");
      push d;
      dump_expr d t;
      dump_expr d v;
      pop d
  | Ast.ReturnExpr (e, _) ->
      emit d "Return";
      (match e with
       | Some e ->
           push d;
           dump_expr d e;
           pop d
       | None -> ())
  | Ast.BreakExpr (e, _) ->
      emit d "Break";
      (match e with
       | Some e ->
           push d;
           dump_expr d e;
           pop d
       | None -> ())
  | Ast.NextExpr _ -> emit d "Next"
  | Ast.ForExpr f ->
      emit d "For";
      push d;
      dump_pattern d f.Ast.for_pattern;
      emit d "In:";
      push d;
      dump_expr d f.Ast.for_iterable;
      pop d;
      emit d "Body:";
      push d;
      dump_block d f.Ast.for_body;
      pop d;
      pop d
  | Ast.WhileExpr w ->
      emit d "While";
      push d;
      emit d "Cond:";
      push d;
      dump_expr d w.Ast.wh_condition;
      pop d;
      emit d "Body:";
      push d;
      dump_block d w.Ast.wh_body;
      pop d;
      pop d
  | Ast.LoopExpr (b, _) ->
      emit d "Loop";
      push d;
      dump_block d b;
      pop d
  | Ast.HandleExpr h ->
      emit d ("Handle(" ^ h.Ast.h_effect_name ^ ")");
      push d;
      dump_expr d h.Ast.h_expr;
      List.iter
        (fun (op, _, body) ->
          emit d ("Op(" ^ op ^ "):");
          push d;
          dump_expr d body;
          pop d)
        h.Ast.h_arms;
      pop d
  | Ast.UnlessExpr u ->
      emit d "Unless";
      push d;
      emit d "Cond:";
      push d;
      dump_expr d u.Ast.un_condition;
      pop d;
      emit d "Body:";
      push d;
      dump_block d u.Ast.un_body;
      pop d;
      pop d
  | Ast.UntilExpr u ->
      emit d "Until";
      push d;
      emit d "Cond:";
      push d;
      dump_expr d u.Ast.ut_condition;
      pop d;
      emit d "Body:";
      push d;
      dump_block d u.Ast.ut_body;
      pop d;
      pop d
  | Ast.TryBlock t ->
      emit d "TryBlock";
      push d;
      emit d "Body:";
      push d;
      dump_block d t.Ast.tr_body;
      pop d;
      List.iter
        (fun (_, b) ->
          emit d "Catch:";
          push d;
          dump_block d b;
          pop d)
        t.Ast.tr_catches;
      (match t.Ast.tr_finally with
       | Some b ->
           emit d "Finally:";
           push d;
           dump_block d b;
           pop d
       | None -> ());
      pop d
  | Ast.ComptimeBlock (b, _) ->
      emit d "Comptime";
      push d;
      dump_block d b;
      pop d

and dump_type d (t : Ast.type_expr) =
  match t with
  | Ast.Named (n, args, _) ->
      if args = [] then emit d ("Type(" ^ n ^ ")")
      else begin
        emit d ("Type(" ^ n ^ ")");
        push d;
        List.iter (dump_type d) args;
        pop d
      end
  | Ast.AssocBinding (name, value, _) ->
      emit d ("AssocBinding(" ^ name ^ ")");
      push d;
      dump_type d value;
      pop d
  | Ast.ConstExpr (e, _) ->
      emit d "ConstTypeArg";
      push d;
      dump_expr d e;
      pop d
  | Ast.Never _ -> emit d "Never"
  | Ast.TTuple (elems, _) ->
      emit d "TupleType";
      push d;
      List.iter (dump_type d) elems;
      pop d
  | Ast.Unit _ -> emit d "Unit"
  | Ast.Ref (t, m, _) ->
      emit d (if m then "RefMut" else "Ref");
      push d;
      dump_type d t;
      pop d
  | Ast.RawPtr (t, m, _) ->
      emit d (if m then "RawPtrMut" else "RawPtr");
      push d;
      dump_type d t;
      pop d
  | Ast.FnPtr (params, ret, _) ->
      emit d "FnPtr";
      push d;
      List.iter (dump_type d) params;
      emit d "->";
      dump_type d ret;
      pop d
  | Ast.TArray (t, len, _) ->
      emit d (match len with Some _ -> "ArrayType[fixed]" | None -> "ArrayType");
      push d;
      dump_type d t;
      pop d
  | Ast.Slice (t, _) ->
      emit d "Slice";
      push d;
      dump_type d t;
      pop d
  | Ast.SelfType _ -> emit d "Self"
  | Ast.DynTrait (inner, _) ->
      emit d "dyn";
      push d;
      dump_type d inner;
      pop d
  | Ast.ImplTrait (inner, _) ->
      emit d "impl";
      push d;
      dump_type d inner;
      pop d
  | Ast.Bounded (base, bounds, _) ->
      emit d "Bounds";
      push d;
      dump_type d base;
      List.iter (dump_type d) bounds;
      pop d
  | Ast.Option (t, _) ->
      emit d "Option";
      push d;
      dump_type d t;
      pop d
  | Ast.Inferred _ -> emit d "_"

and dump_pattern d (p : Ast.pattern) =
  match p with
  | Ast.Wildcard _ -> emit d "_"
  | Ast.PatIdent (n, m, _) -> emit d ("Pat(" ^ (if m then "mut " else "") ^ n ^ ")")
  | Ast.RefPattern (n, _) -> emit d ("Pat(&" ^ n ^ ")")
  | Ast.RefMutPattern (n, _) -> emit d ("Pat(&mut " ^ n ^ ")")
  | Ast.PatLiteral (e, _) -> dump_expr d e
  | Ast.PatVariant (t, v, fields, _) ->
      emit d ("Pat(" ^ t ^ "::" ^ v ^ ")");
      if fields <> [] then begin
        push d;
        List.iter (dump_pattern d) fields;
        pop d
      end
  | Ast.StructPattern (n, fields, _) ->
      emit d ("StructPat(" ^ n ^ ")");
      if fields <> [] then begin
        push d;
        List.iter
          (fun (field_name, opt) ->
            match opt with
            | Some p ->
                emit d (field_name ^ ":");
                push d;
                dump_pattern d p;
                pop d
            | None -> emit d field_name)
          fields;
        pop d
      end
  | Ast.PatTuple (pats, _) ->
      emit d "Pat()";
      push d;
      List.iter (dump_pattern d) pats;
      pop d
  | Ast.OrPattern (a, b, _) ->
      emit d "Pat(|)";
      push d;
      dump_pattern d a;
      dump_pattern d b;
      pop d
  | Ast.RangePattern (a, b, _) ->
      emit d "Pat(..)";
      push d;
      dump_pattern d a;
      dump_pattern d b;
      pop d

and dump_block d (b : Ast.block_body) =
  List.iter (dump_stmt d) b.Ast.b_stmts;
  match b.Ast.b_tail with
  | Some t ->
      emit d "TailExpr:";
      push d;
      dump_expr d t;
      pop d
  | None -> ()

and dump_stmt d (s : Ast.stmt) =
  match s with
  | Ast.LetBinding (pat, mutable_, ty, value, _) ->
      emit d (if mutable_ then "Let mut" else "Let");
      push d;
      emit d "Pattern:";
      push d;
      dump_pattern d pat;
      pop d;
      (match ty with
       | Some t ->
           emit d "Type:";
           push d;
           dump_type d t;
           pop d
       | None -> ());
      emit d "Value:";
      push d;
      dump_expr d value;
      pop d;
      pop d
  | Ast.ExprStmt (e, _) -> dump_expr d e
  | Ast.AttributeStmt (attrs, _) ->
      emit d "StmtAttrs";
      push d;
      List.iter (fun a -> emit d ("@" ^ a.Ast.a_name)) attrs;
      pop d
  | Ast.Attributed (attrs, inner, _) ->
      emit d "StmtAttrs";
      push d;
      List.iter (fun a -> emit d ("@" ^ a.Ast.a_name)) attrs;
      dump_stmt d inner;
      pop d
  | Ast.DeferStmt (body, _) ->
      emit d "Defer";
      push d;
      dump_block d body;
      pop d
  | Ast.Item i -> dump_item d i

and dump_function_decl d (fn : Ast.function_decl) =
  let sig_ = fn.Ast.fn_sig in
  let mods = ref "" in
  if sig_.Ast.sig_public then mods := !mods ^ " [pub]";
  if sig_.Ast.sig_async then mods := !mods ^ " [async]";
  if sig_.Ast.sig_unsafe then mods := !mods ^ " [unsafe]";
  if sig_.Ast.sig_const then mods := !mods ^ " [const]";
  if sig_.Ast.sig_pure then mods := !mods ^ " [pure]";
  if sig_.Ast.sig_inline then mods := !mods ^ " [inline]";
  if sig_.Ast.sig_extern then mods := !mods ^ " [extern]";
  emit d ("Fn " ^ sig_.Ast.sig_name ^ !mods ^ type_params_str sig_.Ast.sig_type_params);
  push d;
  if sig_.Ast.sig_params <> [] then begin
    emit d "Params:";
    push d;
    List.iter
      (fun p ->
        emit d
          (p.Ast.p_name ^ (if p.Ast.p_mutable then " [mut]" else "")
         ^ convention_tag p.Ast.p_convention ^ modifier_tag p.Ast.p_modifier);
        push d;
        dump_type d p.Ast.p_type;
        pop d)
      sig_.Ast.sig_params;
    pop d
  end;
  (match sig_.Ast.sig_return with
   | Some ret ->
       emit d "Returns:";
       push d;
       dump_type d ret;
       pop d
   | None -> ());
  (match fn.Ast.fn_body with
   | Ast.FnBlock b ->
       emit d "Body:";
       push d;
       dump_block d b;
       pop d
   | Ast.FnExpr e ->
       emit d "Body =";
       push d;
       dump_expr d e;
       pop d
   | Ast.FnSignatureOnly -> emit d "Body: (none)");
  pop d

and dump_item (d : dumper) (i : Ast.item) =
  List.iter
    (fun a ->
      emit d
        ("@" ^ a.Ast.a_name ^ (if a.Ast.a_args = [] then "" else "(...)")))
    i.Ast.attributes;
  (match i.Ast.kind with
   | Ast.ModuleDef _ -> ()
   | _ ->
       if i.Ast.module_path <> [] then
         emit d ("ItemModule " ^ String.concat "::" i.Ast.module_path));
  match i.Ast.kind with
  | Ast.Function fn -> dump_function_decl d fn
  | Ast.TestDecl td ->
      emit d ("Test " ^ td.Ast.test_name);
      push d;
      dump_block d td.Ast.test_body;
      pop d
  | Ast.StructDef sd ->
      emit d
        ("Struct " ^ sd.Ast.s_name ^ (if sd.Ast.s_public then " [pub]" else "")
       ^ type_params_str sd.Ast.s_type_params
       ^ (if sd.Ast.s_kind = Ast.NominalResource then " [resource]" else ""));
      push d;
      List.iter
        (fun f ->
          emit d ("Field " ^ f.Ast.f_name);
          push d;
          dump_type d f.Ast.f_type;
          pop d)
        sd.Ast.s_fields;
      List.iter (dump_function_decl d) sd.Ast.s_methods;
      pop d
  | Ast.EnumDef ed ->
      emit d ("Enum " ^ ed.Ast.e_name ^ (if ed.Ast.e_public then " [pub]" else "")
             ^ type_params_str ed.Ast.e_type_params);
      push d;
      List.iter (fun v -> emit d ("Variant " ^ v.Ast.v_name)) ed.Ast.e_variants;
      pop d
  | Ast.TraitDef td ->
      emit d ("Trait " ^ td.Ast.t_name ^ (if td.Ast.t_public then " [pub]" else "")
             ^ type_params_str td.Ast.t_type_params);
      push d;
      List.iter (dump_function_decl d) td.Ast.t_methods;
      List.iter (fun a -> emit d ("AssocType " ^ a.Ast.ta_name)) td.Ast.t_associated_types;
      pop d
  | Ast.ImplBlock id ->
      emit d
        ("Impl" ^ (match id.Ast.i_trait_name with Some t -> " " ^ t ^ " for" | None -> "")
       ^ " " ^ id.Ast.i_target_type ^ type_params_str id.Ast.i_type_params);
      push d;
      List.iter (dump_function_decl d) id.Ast.i_methods;
      pop d
  | Ast.UseDecl ud -> emit d ("Use " ^ Ast.use_path_string ud.Ast.u_path)
  | Ast.ConstDecl cd ->
      emit d ("Const " ^ cd.Ast.c_name ^ (if cd.Ast.c_public then " [pub]" else ""));
      push d;
      emit d "Type:";
      push d;
      dump_type d cd.Ast.c_type;
      pop d;
      emit d "Value:";
      push d;
      dump_expr d cd.Ast.c_value;
      pop d;
      pop d
  | Ast.StaticDecl std ->
      emit d
        ("Static " ^ std.Ast.st_name ^ (if std.Ast.st_public then " [pub]" else "")
       ^ (if std.Ast.st_mutable then " [mut]" else ""));
      push d;
      emit d "Type:";
      push d;
      dump_type d std.Ast.st_type;
      pop d;
      emit d "Value:";
      push d;
      dump_expr d std.Ast.st_value;
      pop d;
      pop d
  | Ast.TypeAlias tad ->
      emit d ("TypeAlias " ^ tad.Ast.ta_name ^ (if tad.Ast.ta_public then " [pub]" else ""))
  | Ast.ExternBlock exd ->
      emit d
        ("Extern" ^ (match exd.Ast.ex_abi with Some abi -> " \"" ^ abi ^ "\"" | None -> ""));
      push d;
      List.iter (dump_item d) exd.Ast.ex_items;
      pop d
  | Ast.ModuleDef md ->
      emit d ("Module " ^ md.Ast.m_name ^ (if md.Ast.m_public then " [pub]" else ""));
      (match md.Ast.m_items with
       | Some items ->
           push d;
           List.iter (dump_item d) items;
           pop d
       | None -> ())
  | Ast.CapabilityDecl capd -> emit d ("Cap " ^ capd.Ast.cap_name)
  | Ast.EffectDecl effd -> emit d ("Effect " ^ effd.Ast.ef_name)
  | Ast.RationaleBlock _ -> emit d "Rationale"
  | Ast.MacroDecl macd -> emit d ("Macro " ^ macd.Ast.mac_name)
  | Ast.EditionDecl edd -> emit d ("Edition " ^ edd.Ast.ed_version)

let dump (program : Ast.program) : string =
  let d = create () in
  emit d "Program";
  if program.Ast.prog_module_path <> [] then
    emit d ("ModulePath " ^ String.concat "::" program.Ast.prog_module_path);
  push d;
  List.iter (dump_item d) program.Ast.items;
  pop d;
  String.concat "\n" (List.rev d.lines)

(* FNV-1a 64-bit over UTF-8 bytes of the dump text. *)
let fnv1a64 (s : string) : int64 =
  let h = ref 0xcbf29ce484222325L in
  String.iter
    (fun c ->
      let b = Char.code c in
      h := Int64.logxor !h (Int64.of_int b);
      h := Int64.mul !h 0x100000001b3L)
    s;
  !h

let hash (program : Ast.program) : int64 = fnv1a64 (dump program)

let hash_hex (program : Ast.program) : string =
  Printf.sprintf "%016Lx" (hash program)
