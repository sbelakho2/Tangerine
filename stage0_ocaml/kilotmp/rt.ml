let check_src (tag : string) (src : string) : string =
  match Source_loader.load_string ("<" ^ tag ^ ">") src with
  | Error _ -> failwith (tag ^ " source load")
  | Ok src2 ->
      let sm = Span.create () in
      let fid = Span.add_file sm src2.Source.name src2 in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src2.Source.bytes fid diags in
      let toks = Lexer.lex lx in
      let prog = Parser.parse toks src2.Source.bytes fid diags [ tag ] in
      (match Typecheck.check_program (Typecheck.initial_env ()) prog with
       | Error m -> failwith (tag ^ " typecheck: " ^ m)
       | Ok (env, errs) ->
           if errs <> [] then
             failwith (tag ^ " typecheck errors: " ^ String.concat "; " errs)
           else
             let items = prog.Ast.items in
             let base = Driver.lowering_env_of ~items env in
             let funcs =
               List.filter_map
                 (fun i ->
                   match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
                 items
             in
             let mir_funcs =
               List.map
                 (fun d ->
                   let ts =
                     match Driver.lookup_typed_fn_qualified env [] d.Ast.fn_sig.Ast.sig_name
                     with
                     | Some ts -> ts
                     | None -> failwith (tag ^ ": no typed signature for " ^ d.Ast.fn_sig.Ast.sig_name)
                   in
                   Mir_lower.lower_function_with_variants
                     ~typed_nodes:(Driver.typed_nodes_of env)
                     ~typed_patterns:(Driver.typed_patterns_of env)
                     ~typed_for_patterns:(Driver.typed_for_patterns_of env)
                     ~typed_let_patterns:(Driver.typed_let_patterns_of env)
                     (Driver.user_variant_table env)
                     { base with Mir_lower.fn_ret = ts.Typecheck.ts_return }
                     d.Ast.fn_sig.Ast.sig_name
                     (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                     (Array.of_list
                        (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                           ts.Typecheck.ts_params_decl))
                      (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
                      ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
                      d)
                  funcs
              in
              let prog_mir =
                {
                  Seed_mir.functions = Array.of_list mir_funcs;
                  statics = Driver.closure_statics env items;
                  types = Driver.closure_types env;
                }
              in
              (match
                Mir_verify.require_valid_template
                  ~box_tid:(env.Typecheck.state.box_tid)
                  ~generic_types:(Driver.closure_generic_types env)
                  ~query_sigs:(Driver.closure_query_sigs ~lowered:(Some prog_mir) env)
                  prog_mir
              with
              | Ok () -> "VERIFY-OK"
              | Error errs ->
                  let n = List.length errs in
                  "VERIFY-FAIL(" ^ string_of_int n ^ "): "
                  ^ String.concat " | " (List.map (fun e -> e) errs)))

let dump_src (tag : string) (src : string) : string =
  match Source_loader.load_string ("<" ^ tag ^ ">") src with
  | Error _ -> "source load"
  | Ok src2 ->
      let sm = Span.create () in
      let fid = Span.add_file sm src2.Source.name src2 in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src2.Source.bytes fid diags in
      let toks = Lexer.lex lx in
      let prog = Parser.parse toks src2.Source.bytes fid diags [ tag ] in
      (match Typecheck.check_program (Typecheck.initial_env ()) prog with
       | Error m -> "typecheck: " ^ m
       | Ok (env, errs) ->
           if errs <> [] then "typecheck errors: " ^ String.concat "; " errs
           else
             let items = prog.Ast.items in
             let base = Driver.lowering_env_of ~items env in
             let funcs =
               List.filter_map
                 (fun i ->
                   match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
                 items
             in
             let mir_funcs =
               List.map
                 (fun d ->
                   let ts =
                     match Driver.lookup_typed_fn_qualified env [] d.Ast.fn_sig.Ast.sig_name
                     with
                     | Some ts -> ts
                     | None -> failwith "no ts"
                   in
                   Mir_lower.lower_function_with_variants
                     ~typed_nodes:(Driver.typed_nodes_of env)
                     ~typed_patterns:(Driver.typed_patterns_of env)
                     ~typed_for_patterns:(Driver.typed_for_patterns_of env)
                     ~typed_let_patterns:(Driver.typed_let_patterns_of env)
                     (Driver.user_variant_table env)
                     { base with Mir_lower.fn_ret = ts.Typecheck.ts_return }
                     d.Ast.fn_sig.Ast.sig_name
                     (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                     (Array.of_list
                        (List.map (fun (_, pid) -> Type_repr.Type_param pid)
                           ts.Typecheck.ts_params_decl))
                     (Array.map (fun p -> p.Type_repr.pt_convention) ts.Typecheck.ts_params)
                     ~param_tys_opt:(Array.map (fun p -> p.Type_repr.pt_type) ts.Typecheck.ts_params)
                     d)
                 funcs
             in
             let prog_mir =
               {
                 Seed_mir.functions = Array.of_list mir_funcs;
                 statics = Driver.closure_statics env items;
                 types = Driver.closure_types env;
               }
             in
             Seed_mir.print_program prog_mir)

let () =
  match Sys.argv with
  | [| _; "dump"; path |] ->
      let ic = open_in path in
      let n = in_channel_length ic in
      let src = really_input_string ic n in
      close_in ic;
      print_string (dump_src "d" src)
  | [| _; tag; path |] ->
      let ic = open_in path in
      let n = in_channel_length ic in
      let src = really_input_string ic n in
      close_in ic;
      (try Printf.printf "%s\n" (check_src tag src)
       with Failure m -> Printf.printf "FAIL: %s\n" m)
  | _ -> print_endline "usage: rt <tag> <file> | rt dump <file>"
