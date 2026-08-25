(* tg_corpus.ml — corpus-wide type-check gate.

   Enumerates ../tests/differential/corpus/*.tg (or the directory given as
   argv[1], resolved against the executable's working directory) plus
   ../tests/differential/negative/*.tg, lexes, parses, and type-checks every
   file with a FRESH environment per file, and prints exact per-file error
   counts.

   This is a regression canary: it does NOT require zero type-check errors
   (the corpus legitimately exercises the full language, and the driver
   reports ~1755 errors on the full manifest closure), but every corpus file
   must PARSE, and the printed counts must be identical across runs (the
   caller diffs two runs to prove typechecker determinism). *)

let take5 l =
  let rec go acc n = function
    | _ when n = 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> go (x :: acc) (n - 1) xs
  in
  go [] 5 l

let render_lines sm diags =
  Diagnostic.render sm diags |> String.split_on_char '\n'

let () =
  let argv = Array.to_list Sys.argv in
  let corpus_dir =
    match argv with _ :: d :: _ -> d | _ -> "../tests/differential/corpus"
  in
  let negative_dir =
    match argv with _ :: _ :: d :: _ -> d | _ -> "../tests/differential/negative"
  in
  let resolve d =
    if Filename.is_relative d then Filename.concat (Sys.getcwd ()) d else d
  in
  let corpus_dir = resolve corpus_dir in
  let negative_dir = resolve negative_dir in
  let list_tg dir =
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".tg")
    |> List.sort String.compare
  in
  let corpus_files = list_tg corpus_dir in
  let negative_files =
    try list_tg negative_dir
    with Sys_error m -> Printf.printf "negative: cannot read %s (%s)\n" negative_dir m; []
  in
  let parse src =
    let sm = Span.create () in
    let file_id = Span.add_file sm src.Source.name src in
    let diags = Diagnostic.create_bag () in
    let lx = Lexer.create src.Source.bytes file_id diags in
    let tokens = Lexer.lex lx in
    let program = Parser.parse tokens src.Source.bytes file_id diags [ "corpus" ] in
    (sm, diags, program)
  in
  let load_fail label file err =
    match err with
    | Source_loader.Unreadable m ->
        Printf.printf "%s %s: load-failed (unreadable: %s)\n" label file m
    | Source_loader.NotUTF8 (_, ue) ->
        Printf.printf "%s %s: load-failed (not UTF-8: %s)\n" label file
          (Utf8.error_string ue.kind)
    | Source_loader.Security (_, m) ->
        Printf.printf "%s %s: load-failed (security: %s)\n" label file m
  in
  let files = ref 0 in
  let parse_fail = ref 0 in
  let clean = ref 0 in
  let failing = ref 0 in
  let aggregate = ref 0 in
  List.iter
    (fun file ->
      let path = Filename.concat corpus_dir file in
      incr files;
      match Source_loader.load path with
      | Error err ->
          incr parse_fail;
          load_fail "corpus" file err
      | Ok src ->
          let sm, diags, program = parse src in
          let pe = Diagnostic.error_count diags in
          if pe > 0 then begin
            incr parse_fail;
            Printf.printf "corpus %s: parse-fail parse_errors=%d\n" file pe;
            List.iter (fun l -> Printf.printf "    %s\n" l)
              (take5 (render_lines sm diags))
          end
          else begin
            let env = Typecheck.initial_env () in
            match Typecheck.check_program env program with
            | Error m ->
                incr failing;
                Printf.printf "corpus %s: parse-ok typecheck-fail (hard error: %s)\n"
                  file m
            | Ok (_, errors) ->
                let n = List.length errors in
                aggregate := !aggregate + n;
                if n = 0 then incr clean else incr failing;
                Printf.printf "corpus %s: parse-ok typecheck-errors=%d\n" file n;
                List.iter (fun e -> Printf.printf "    %s\n" e)
                  (take5 (List.rev errors))
          end)
    corpus_files;
  Printf.printf
    "corpus: files=%d parse_fail=%d typecheck_clean=%d typecheck_failing=%d aggregate_errors=%d\n"
    !files !parse_fail !clean !failing !aggregate;
  List.iter
    (fun file ->
      let path = Filename.concat negative_dir file in
      match Source_loader.load path with
      | Error err -> load_fail "negative" file err
      | Ok src ->
          let _sm, diags, program = parse src in
          let pe = Diagnostic.error_count diags in
          Printf.printf "negative %s: parse_errors=%d" file pe;
          if pe = 0 then begin
            let env = Typecheck.initial_env () in
            match Typecheck.check_program env program with
            | Error m -> Printf.printf " typecheck-fail (hard error: %s)\n" m
            | Ok (_, errors) ->
                Printf.printf " typecheck-errors=%d\n" (List.length errors)
          end
          else Printf.printf "\n")
    negative_files;
  if !parse_fail = 0 then begin
    Printf.printf
      "CORPUS GATE PASS: all %d corpus files parse; typecheck_clean=%d typecheck_failing=%d aggregate_errors=%d\n"
      !files !clean !failing !aggregate;
    exit 0
  end
  else begin
    Printf.printf
      "CORPUS GATE FAIL: %d of %d corpus files failed to parse\n"
      !parse_fail !files;
    exit 1
  end
