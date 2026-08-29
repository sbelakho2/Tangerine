(* tg_pipeline.ml — end-to-end pipeline self-check.

   parse -> typecheck -> lower -> MIR verify -> VM run, on a Tangerine
   source file, asserting the entry function's return value. *)

let src_text = {|
def add(a: Int, b: Int) -> Int
  a + b
end

def max_of(a: Int, b: Int) -> Int
  if a > b then
    a
  else
    b
  end
end

def sum_to(n: Int) -> Int
  var i = 0
  var total = 0
  while i < n do
    total = total + i
    i = i + 1
  end
  total
end

def main() -> Int
  let x = add(3, 4)
  let y = max_of(x, 10)
  let z = sum_to(5)
  y + z
end
|}

let () =
  let file, content =
    match Array.to_list Sys.argv with
    | _ :: f :: _ ->
        let ic = open_in f in
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        close_in ic;
        (f, s)
    | _ -> ("<pipeline-self-check>", src_text)
  in
  match Source_loader.load_string file content with
  | Error _ -> Printf.printf "FAIL: load\n"; exit 1
  | Ok src ->
      let sm = Span.create () in
      let file_id = Span.add_file sm src.Source.name src in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      let program = Parser.parse tokens src.Source.bytes file_id diags [ "pipeline" ] in
      if Diagnostic.has_errors diags then begin
        Printf.printf "parse errors:\n%s\n" (Diagnostic.render sm diags);
        exit 1
      end;
      Printf.printf "pipeline: %s\n" file;
      Printf.printf "  parse: %d items\n" (List.length program.Ast.items);
      let env = Typecheck.initial_env () in
      (match Typecheck.check_program env program with
       | Error m -> Printf.printf "  typecheck: FAIL %s\n" m; exit 1
       | Ok (_, errors) ->
           Printf.printf "  typecheck: %d errors\n" (List.length errors);
           List.iter (fun e -> Printf.printf "    %s\n" e) (List.rev errors);
           if errors <> [] then exit 1);
      let funcs =
        List.filter_map
          (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
          program.Ast.items
      in
      let env2 : Mir_lower.func_env =
        {
          Mir_lower.consts = [];
    statics = [];
    Mir_lower.types =
            [
              ("Int", Type_repr.Int Type_repr.Int);
              ("Unit", Type_repr.Unit);
              ("Bool", Type_repr.Bool);
              ("String", Type_repr.String);
            ];
          values =
            List.filter_map
              (fun i ->
                match i.Ast.kind with
                | Ast.Function d ->
                    Some (d.Ast.fn_sig.Ast.sig_name, Type_repr.Int Type_repr.Int)
                | _ -> None)
              program.Ast.items;
          callables =
            List.filter_map
              (fun i ->
                match i.Ast.kind with
                | Ast.Function d ->
                    Some
                      ( d.Ast.fn_sig.Ast.sig_name,
                        { Mir_lower.ce_callable = 0; ce_template_args = [||]; ce_params = [||] } )
                | _ -> None)
              program.Ast.items
            |> List.mapi (fun i (n, e) -> (n, { e with Mir_lower.ce_callable = i }));
          methods = [];
          fn_ret = Type_repr.Int Type_repr.Int;
          struct_fields = [];
        }
      in
      let mir_funcs =
        List.mapi
          (fun i d -> Mir_lower.lower_function env2 d.Ast.fn_sig.Ast.sig_name i d)
          funcs
      in
      let prog =
        { Seed_mir.functions = Array.of_list mir_funcs; statics = [||]; types = [||] }
      in
      (match Mir_verify.require_valid prog with
       | Ok () -> Printf.printf "  MIR verify: PASS (%d functions)\n" (Array.length prog.Seed_mir.functions)
       | Error errs ->
           Printf.printf "  MIR verify: FAIL\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Printf.printf "%s\n" (Seed_mir.print_program prog);
           exit 1);
      let entry =
        match
          Array.to_list prog.Seed_mir.functions
          |> List.find_opt (fun f -> f.Seed_mir.name = "main")
        with
        | Some f -> f.Seed_mir.instance
        | None -> failwith "no main function"
      in
      let host = Host.create ~repo_root:"." ~argv:[||] in
      (match Vm.run ~program:prog ~entry ~argv:[||] ~host with
       | Error e ->
           Printf.printf "  VM: FAIL %s\n" e.Vm.message;
           exit 1
       | Ok code ->
           Printf.printf "  VM: exit %d\n" code;
           (match Vm.entry_frame_of ~program:prog ~entry ~argv:[||] with
            | Error m -> Printf.printf "  main returned: <inspect failed: %s>\n" m
            | Ok (vm2, entry_frame) -> (
                match Vm.run_inspect vm2 entry_frame with
                | Ok ret_val -> Printf.printf "  main returned: %s\n" ret_val
                | Error m -> Printf.printf "  main returned: <inspect failed: %s>\n" m)))
