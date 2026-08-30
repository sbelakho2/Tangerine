let run_src (tag : string) (src : string) : string =
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
           if errs <> [] then failwith (tag ^ " typecheck errors")
           else
             let base = Driver.lowering_env_of ~items:prog.Ast.items env in
             let variants = Driver.user_variant_table env in
             let main_decl =
               match
                 List.find_opt
                   (fun i ->
                     match i.Ast.kind with
                     | Ast.Function d -> d.Ast.fn_sig.Ast.sig_name = "main"
                     | _ -> false)
                   prog.Ast.items
               with
               | Some i -> i
               | None -> failwith (tag ^ ": no main")
             in
             let ts =
               match List.assoc_opt "main" env.Typecheck.functions with
               | Some ts -> ts
               | None -> (
                   match
                     List.filter (fun (k, _) -> Util.has_suffix k "::main")
                       env.Typecheck.functions
                   with
                   | [ (_, ts) ] -> ts
                   | _ -> failwith (tag ^ ": no typed main"))
             in
             let main_fn =
               match main_decl.Ast.kind with
               | Ast.Function d ->
                   Mir_lower.lower_function_with_variants
                     ~typed_nodes:(Driver.typed_nodes_of env)
                     ~typed_patterns:(Driver.typed_patterns_of env)
                     ~typed_for_patterns:(Driver.typed_for_patterns_of env)
                     ~typed_let_patterns:(Driver.typed_let_patterns_of env)
                     variants
                     { base with Mir_lower.fn_ret = ts.Typecheck.ts_return }
                     "main" (Ids.Callable_id.to_int ts.Typecheck.ts_callable)
                     [||] [||] d
               | _ -> failwith (tag ^ ": main not function")
             in
             let prog_mir =
               { Seed_mir.functions = [| main_fn |]; statics = [||]; types = [||] }
             in
             (match Mir_verify.require_valid_concrete prog_mir with
              | Error errs ->
                  failwith
                    (tag ^ " verify: " ^ String.concat "; " (List.map (fun e -> e) errs))
              | Ok () -> ());
             let entry = main_fn.Seed_mir.instance in
             let host = Host.create ~repo_root:"." ~argv:[||] in
             (match Vm.run ~program:prog_mir ~entry ~argv:[||] ~host with
              | Error e -> failwith (tag ^ " VM: " ^ e.Vm.message)
              | Ok _code -> (
                  match Vm.entry_frame_of ~program:prog_mir ~entry ~argv:[||] with
                  | Error m -> "<inspect failed: " ^ m ^ ">"
                  | Ok (vvm, frame) -> (
                      match Vm.run_inspect vvm frame with
                      | Ok v -> v
                      | Error m -> "<run_inspect failed: " ^ m ^ ">"))))

let () =
  let set_src = {|
def main() -> Int
  var s: Set[Int] = Set::new()
  s.insert(1)
  s.insert(2)
  s.insert(3)
  var sum = 0
  for x in s do
    sum = sum + x
  end
  sum
end
|} in
  let map_src = {|
def main() -> Int
  var m: Map[Int, Int] = Map::new()
  m.insert(1, 10)
  m.insert(2, 20)
  m.insert(3, 30)
  var sum = 0
  for (k, v) in m do
    sum = sum + k + v
  end
  sum
end
|} in
  let str_src = {|
def main() -> Int
  var s: String = "abc"
  var n = 0
  for c in s do
    n = n + 1
  end
  n
end
|} in
  Printf.printf "SET=%s\n" (run_src "set" set_src);
  Printf.printf "MAP=%s\n" (run_src "map" map_src);
  Printf.printf "STR=%s\n" (run_src "str" str_src)
