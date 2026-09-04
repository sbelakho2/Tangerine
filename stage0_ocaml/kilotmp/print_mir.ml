let () =
  let path = Sys.argv.(1) in
  let src = match Source_loader.load path with
  | Error _ -> failwith "load"
  | Ok s -> s in
  let sm = Span.create () in
  let file_id = Span.add_file sm src.Source.name src in
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create src.Source.bytes file_id diags in
  let toks = Lexer.lex lx in
  let prog = Parser.parse toks src.Source.bytes file_id diags [ "adhoc" ] in
  let env = Typecheck.initial_env () in
  match Typecheck.check_program env prog with
  | Error m -> prerr_endline m
  | Ok (env, errs) ->
      if errs <> [] then List.iter (fun e -> prerr_endline e) errs
      else begin
        let funcs =
          List.filter_map
            (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
            prog.Ast.items
        in
        let base = Driver.lowering_env_of env in
        let variants = Driver.user_variant_table env in
        let tn = Driver.typed_nodes_of env in
        let tp = Driver.typed_patterns_of env in
        let tf = Driver.typed_for_patterns_of env in
        let tl = Driver.typed_let_patterns_of env in
        let mir_funcs =
          List.mapi
            (fun i d ->
              let fn_ret, callable =
                match Driver.lookup_typed_fn env d.Ast.fn_sig.Ast.sig_name with
                | Some ts -> (ts.Typecheck.ts_return, Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                | None -> (Type_repr.Unit, i)
              in
              Mir_lower.lower_function_with_variants ~typed_nodes:tn ~typed_patterns:tp
                ~typed_for_patterns:tf ~typed_let_patterns:tl variants
                { base with Mir_lower.fn_ret }
                d.Ast.fn_sig.Ast.sig_name callable [||] [||] d)
            funcs
        in
        let mprog = { Seed_mir.functions = Array.of_list mir_funcs; statics = [||]; types = [||] } in
        print_string (Seed_mir.print_program mprog)
      end
