(* tg_lowersurface.ml — lowered-surface self-check.

   parse -> typecheck -> lower (with a variant table + concrete enum
   type defs) -> MIR verify -> VM run, on a Tangerine source exercising
   the seed-surface constructs added to mir_lower.ml:

     (a) an enum with three variants (zero, one and two payload fields)
         plus a match over it binding payloads in every arm;
     (b) Option/Result plumbing: `?` on an Option (success payload
         propagation AND failure early-return), Result construction and
         a Result match;
     (c) a for-loop over an Array literal (unrolled with ConstantIndex
         element reads);
     (d) two function-level defers that must run in reverse declaration
         order (LIFO), observed through mutations of a counter variable
         that the returned value reads after the defers run.

   Expected main return: 113 (see the derivation comment in src_text). *)

let src_text = {|
enum Color
  Red,
  Green(Int),
  Blue(Int, Int)
end

def color_match(c: Color) -> Int
  match c {
    Green(g) => g * 2,
    Red() => 5,
    Blue(a, b) => a + b
  }
end

def make_none() -> Option[Int]
  None
end

def safe_div(a: Int, b: Int) -> Option[Int]
  if b == 0 then
    make_none()
  else
    Some(a / b)
  end
end

def checked_div(a: Int, b: Int) -> Option[Int]
  let q = safe_div(a, b)?
  Some(q * 10)
end

def unwrap_or_zero(o: Option[Int]) -> Int
  match o {
    Some(v) => v,
    None() => 0
  }
end

def checked_div2(a: Int, b: Int) -> Result[Int, String]
  match safe_div(a, b) {
    Some(v) => Ok(v * 3),
    None() => Err("div by zero")
  }
end

def unwrap_res_or_zero(r: Result[Int, String]) -> Int
  match r {
    Ok(v) => v,
    Err(_) => 0
  }
end

def for_sum() -> Int
  var total = 0
  for x in [1, 2, 3, 4] do
    total = total + x
  end
  total
end

def defer_order() -> Int
  var acc = 0
  defer
    acc = acc * 10 + 1
  end
  defer
    acc = acc * 10 + 2
  end
  acc
end

def main() -> Int
  let a = color_match(Green(7))
  let b = color_match(Red())
  let c = color_match(Blue(3, 4))
  let d = unwrap_or_zero(checked_div(10, 2))
  let e = unwrap_or_zero(checked_div(1, 0))
  let f = unwrap_res_or_zero(checked_div2(4, 2))
  let g = unwrap_res_or_zero(checked_div2(1, 0))
  let h = for_sum()
  let i = defer_order()
  a + b + c + d + e + f + g + h + i
end
|}

let int_ty = Type_repr.Int Type_repr.Int
let string_ty = Type_repr.String

(* ── variant table for the user enum (declaration order) ───────── *)
let color_specs =
  [
    ("Red", { Mir_lower.vs_index = 0; vs_fields = [] });
    ("Green", { Mir_lower.vs_index = 1; vs_fields = [ int_ty ] });
    ("Blue", { Mir_lower.vs_index = 2; vs_fields = [ int_ty; int_ty ] });
  ]

let color_ctors = List.map (fun (n, spec) -> (n, ("Color", n, spec))) color_specs

let variant_table : Mir_lower.variant_table =
  { vt_enums = [ ("Color", color_specs) ]; vt_ctors = List.map (fun (n, (e, v, _)) -> (n, (e, v))) color_ctors }

let () =
  let dump = List.mem "--dump" (Array.to_list Sys.argv) in
  let file, content =
    match Array.to_list Sys.argv with
    | _ :: f :: _ when f <> "--dump" ->
        let ic = open_in f in
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        close_in ic;
        (f, s)
    | _ -> ("<lowersurface-self-check>", src_text)
  in
  match Source_loader.load_string file content with
  | Error _ -> Printf.printf "FAIL: load\n"; exit 1
  | Ok src ->
      let sm = Span.create () in
      let file_id = Span.add_file sm src.Source.name src in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      let program = Parser.parse tokens src.Source.bytes file_id diags [ "lowersurface" ] in
      if Diagnostic.has_errors diags then begin
        Printf.printf "parse errors:\n%s\n" (Diagnostic.render sm diags);
        exit 1
      end;
      Printf.printf "lowersurface: %s\n" file;
      Printf.printf "  parse: %d items\n" (List.length program.Ast.items);
      let env = Typecheck.initial_env () in
      let tcheck_env =
        match Typecheck.check_program env program with
        | Error m -> Printf.printf "  typecheck: FAIL %s\n" m; exit 1
        | Ok (env', errors) ->
            Printf.printf "  typecheck: %d errors\n" (List.length errors);
            List.iter (fun e -> Printf.printf "    %s\n" e) (List.rev errors);
            if errors <> [] then exit 1;
            env'
      in
      let option_tid = List.assoc "Option" tcheck_env.Typecheck.type_ids in
      let result_tid = List.assoc "Result" tcheck_env.Typecheck.type_ids in
      let color_tid = List.assoc "Color" tcheck_env.Typecheck.type_ids in
      let option_int = Type_repr.Named (Ids.Type_id.to_int option_tid, [| int_ty |]) in
      let result_int_str = Type_repr.Named (Ids.Type_id.to_int result_tid, [| int_ty; string_ty |]) in
      let color_ty = Type_repr.Named (Ids.Type_id.to_int color_tid, [||]) in
      (* typed signatures per function (flat names) *)
      let ts_of name =
        match List.assoc_opt name tcheck_env.Typecheck.functions with
        | Some ts -> ts
        | None -> (
            match
              List.filter (fun (k, _) -> Util.has_suffix k ("::" ^ name)) tcheck_env.Typecheck.functions
            with
            | [ (_, ts) ] -> ts
            | _ -> failwith ("no typed signature for " ^ name))
      in
      let funcs =
        List.filter_map
          (fun i -> match i.Ast.kind with Ast.Function d -> Some d | _ -> None)
          program.Ast.items
      in
      let env2 : Mir_lower.func_env =
        {
          Mir_lower.types =
            [
              ("Color", color_ty);
              ("Option", Type_repr.Named (Ids.Type_id.to_int option_tid, [| Type_repr.Type_param (Ids.Generic_param_id.to_int (Ids.Generic_param_id.make 0)) |]));
              ("Result", Type_repr.Named (Ids.Type_id.to_int result_tid, [| Type_repr.Type_param (Ids.Generic_param_id.to_int (Ids.Generic_param_id.make 0)); Type_repr.Type_param (Ids.Generic_param_id.to_int (Ids.Generic_param_id.make 1)) |]));
              ("Int", int_ty);
              ("Unit", Type_repr.Unit);
              ("Bool", Type_repr.Bool);
              ("String", string_ty);
            ];
          values =
            [
              ("Some", option_int);
              ("None", option_int);
              ("Ok", result_int_str);
              ("Err", result_int_str);
              ("Red", color_ty);
              ("Green", color_ty);
              ("Blue", color_ty);
            ]
            @ List.map
                (fun d ->
                  let n = d.Ast.fn_sig.Ast.sig_name in
                  (n, (ts_of n).Typecheck.ts_return))
                funcs;
          callables =
            List.map
              (fun d ->
                let n = d.Ast.fn_sig.Ast.sig_name in
                (n, Ids.Callable_id.to_int (ts_of n).Typecheck.ts_callable))
              funcs;
          methods = [];
          fn_ret = int_ty;
        }
      in
      let mir_funcs =
        List.map
          (fun d ->
            let n = d.Ast.fn_sig.Ast.sig_name in
            let ts = ts_of n in
            Mir_lower.lower_function_with_variants variant_table
              { env2 with Mir_lower.fn_ret = ts.Typecheck.ts_return }
              n (Ids.Callable_id.to_int ts.Typecheck.ts_callable) d)
          funcs
      in
      (* concrete enum defs (post-mono): a variant's payload is recorded
         as a Tuple for one-or-more fields, Unit for none; the enum def
         is Function (payloads, Never) — the seed type-definition
         contract (seed_mir.ml). *)
      let payload_def fields =
        match fields with
        | [] -> Type_repr.Unit
        | fs -> Type_repr.Tuple (Array.of_list fs)
      in
      let enum_def payloads =
        Type_repr.Function
          (Array.of_list
             (List.map (fun fs -> { Type_repr.pt_convention = Access_effect.Let; pt_type = payload_def fs }) payloads),
           Type_repr.Never)
      in
      let prog =
        {
          Seed_mir.functions = Array.of_list mir_funcs;
          statics = [||];
          types =
            [|
              (option_tid, enum_def [ [ int_ty ]; [] ]);
              (result_tid, enum_def [ [ int_ty ]; [ string_ty ] ]);
              (color_tid, enum_def [ []; [ int_ty ]; [ int_ty; int_ty ] ]);
            |];
        }
      in
      (match Mir_verify.require_valid prog with
       | Ok () -> Printf.printf "  MIR verify: PASS (%d functions)\n" (Array.length prog.Seed_mir.functions)
       | Error errs ->
           Printf.printf "  MIR verify: FAIL\n";
           List.iter (fun e -> Printf.printf "    %s\n" e) errs;
           Printf.printf "%s\n" (Seed_mir.print_program prog);
           exit 1);
      if dump then Printf.printf "%s\n" (Seed_mir.print_program prog);
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
                | Ok ret_val ->
                    Printf.printf "  main returned: %s\n" ret_val;
                    if ret_val = "113" then Printf.printf "  RESULT: PASS\n"
                    else begin
                      Printf.printf "  RESULT: FAIL (expected 113)\n";
                      exit 1
                    end
                | Error m -> Printf.printf "  main returned: <inspect failed: %s>\n" m)))
