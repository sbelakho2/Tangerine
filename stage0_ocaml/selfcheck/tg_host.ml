(* tg_host.ml — host binding-closure self-check (audit §70).

   Proves four properties of the executable host closure:
     (a) closure_check FAILS (non-zero) when a declared symbol has no
         binding, and names the symbol;
     (b) closure_check PASSES when every declared symbol carries a
         binding with an executable invoke;
     (c) the VM's host dispatch invokes the real binding table entry:
         hand-built Seed MIR with Intrinsic/Extern call terminators run
         through Vm.run, asserting results, plus fail-closed traps for
         declared-but-unbound symbols;
     (d) the REACHABLE-host closure boundary (re-audit: stage 10): the
         static scan collects exactly the host ids a post-mono program
         can dispatch to, and the reachable-set check fails when a
         declared-but-unbound symbol is reachable but passes when it is
         not called (declared-but-unreachable needs no binding), with
         User-form host calls resolved to their host ids. *)

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; exit 1) fmt
let pass fmt = Printf.ksprintf (fun s -> Printf.printf "PASS: %s\n" s) fmt

(* Substring test on VM error messages (err_trap prefixes them). *)
let contains (haystack : string) (needle : string) : bool =
  let h = String.length haystack and n = String.length needle in
  if n = 0 then true
  else if n > h then false
  else begin
    let rec go i =
      i + n <= h && (String.sub haystack i n = needle || go (i + 1))
    in
    go 0
  end

let sig_string_unit : Intrinsic_registry.signature =
  Intrinsic_registry.sig_ ~params:[| Intrinsic_registry.ty_string |]
    ~ret:Intrinsic_registry.ty_unit

let manifest_binding (name : string) : Host.binding =
  match Host.binding_of_manifest name with
  | Some b -> b
  | None -> fail "manifest binding for '%s' not found" name

let mk_host ~intrinsics ~bindings : Host.t =
  Host.create_with ~repo_root:"." ~argv:[||] ~intrinsics
    ~externs:Extern_registry.empty ~bindings

let register (name : string) (id : int) (sig_ : Intrinsic_registry.signature)
    (reg : Intrinsic_registry.t) : Intrinsic_registry.t =
  Intrinsic_registry.register reg ~name ~id:(Intrinsic_registry.Id.make id) sig_

(* (a) a declared symbol without a binding must FAIL the closure check. *)
let check_declared_unbound () =
  let reg =
    Intrinsic_registry.empty
    |> register "print" 0 sig_string_unit
    |> register "println" 1 sig_string_unit
  in
  let host = mk_host ~intrinsics:reg ~bindings:[ manifest_binding "print" ] in
  match Host.closure_check host with
  | Ok _ -> fail "closure_check passed although 'println' is declared but unbound"
  | Error problems -> (
      match List.find_opt (fun p -> Util.has_prefix p "declared but not bound") problems with
      | None ->
          fail "closure_check failed for the wrong reason: %s"
            (String.concat "; " problems)
      | Some p ->
          if not (Util.has_suffix p "println") then
            fail "declared-but-unbound symbol not named in the report: %s" p;
          Printf.printf "  %s\n" p;
          pass "closure_check FAILS (non-zero) when a declared symbol has no binding")

(* (b) every declared symbol bound -> closure_check PASSES. *)
let check_declared_implemented () =
  let sig_panic : Intrinsic_registry.signature =
    Intrinsic_registry.sig_ ~params:[| Intrinsic_registry.ty_string |]
      ~ret:Type_repr.Never
  in
  let sig_int_string : Intrinsic_registry.signature =
    Intrinsic_registry.sig_ ~params:[| Intrinsic_registry.ty_int |]
      ~ret:Intrinsic_registry.ty_string
  in
  let reg =
    Intrinsic_registry.empty
    |> register "print" 0 sig_string_unit
    |> register "println" 1 sig_string_unit
    |> register "panic" 2 sig_panic
    |> register "__intrinsic_int_to_string" 3 sig_int_string
  in
  let bindings =
    [
      manifest_binding "print";
      manifest_binding "println";
      manifest_binding "panic";
      manifest_binding "__intrinsic_int_to_string";
    ]
  in
  let host = mk_host ~intrinsics:reg ~bindings in
  match Host.closure_check host with
  | Error problems ->
      List.iter (fun p -> Printf.printf "    %s\n" p) problems;
      fail "closure_check failed on a host where every declared symbol is bound"
  | Ok report ->
      if
        report.declared <> 4 || report.implemented <> 4
        || List.length report.bound <> 4
      then
        fail "unexpected closure report: declared=%d implemented=%d bound=[%s]"
          report.declared report.implemented (String.concat ", " report.bound);
      Printf.printf "  closure report: declared=%d implemented=%d bound=[%s]\n"
        report.declared report.implemented (String.concat ", " report.bound);
      pass "closure_check PASSES when every declared symbol carries an executable binding"

(* (b') a REAL signature drift between the binding's independent adapter
   declaration and the registry's source-derived declaration must FAIL
   the closure check (the adapter signature is no longer derived from
   the declaration it is compared against). *)
let check_independent_signature_mismatch () =
  let sig_string_never : Intrinsic_registry.signature =
    Intrinsic_registry.sig_ ~params:[| Intrinsic_registry.ty_string |]
      ~ret:Type_repr.Never
  in
  let reg = Intrinsic_registry.empty |> register "print" 0 sig_string_never in
  let host = mk_host ~intrinsics:reg ~bindings:[ manifest_binding "print" ] in
  match Host.closure_check host with
  | Ok _ -> fail "closure_check passed although the binding's adapter signature (String -> Unit) disagrees with the declaration (String -> Never)"
  | Error problems -> (
      match
        List.find_opt (fun p -> Util.has_prefix p "return mismatch for print") problems
      with
      | None ->
          fail "closure_check failed for the wrong reason: %s"
            (String.concat "; " problems)
      | Some p ->
          Printf.printf "  %s\n" p;
          pass "a real adapter-vs-declaration signature mismatch FAILS the closure check")

(* (c) VM dispatch through the binding table. *)

let intrinsic_id (name : string) : int =
  match Intrinsic_registry.lookup Intrinsic_registry.manifest ~name with
  | Some (id, _) -> Intrinsic_registry.Id.to_int id
  | None -> fail "intrinsic '%s' not declared" name

let extern_id (name : string) : int =
  match Extern_registry.lookup Extern_registry.manifest ~name with
  | Some (id, _) -> Extern_registry.Id.to_int id
  | None -> fail "extern '%s' not declared" name

let int_constant (n : int64) : Seed_mir.constant =
  Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true n)

(* A single-function program fragment: name + callee + optional constant
   argument + return type; the reachable-host closure proof builds
   programs whose reachable calls are exactly the given callees. *)
let call_fn (name : string) (cid : int) (callee : Seed_mir.callee)
    (arg : (Type_repr.t * Seed_mir.constant) option) (ret_ty : Type_repr.t) :
    Seed_mir.function_ =
  let statements, args, locals =
    match arg with
    | None -> ([], [||], [| ret_ty |])
    | Some (arg_ty, c) ->
        ( [ Seed_mir.Assign
              ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (Seed_mir.Constant c)) ],
          [| { Seed_mir.effect_ = Access_effect.Read; value = Seed_mir.Copy { root = Seed_mir.Local 1; projections = [] } } |],
          [| ret_ty; arg_ty |] )
  in
  {
    Seed_mir.name;
    instance = Instance_id.make ~callable:(Ids.Callable_id.make cid) ~type_args:[||];
    params = [||];
    locals;
    blocks =
      [|
        { id = 0;
          statements;
          terminator = Seed_mir.Call ({ root = Seed_mir.Local 0; projections = [] }, callee, args, 1, None) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |];
    entry = 0;
  }

(* Hand-built Seed MIR: one function whose only block calls the host
   symbol with the given constant argument (or none) and stores the
   result in the return slot _0, then returns. *)
let call_program (callee : Seed_mir.callee) (arg : (Type_repr.t * Seed_mir.constant) option)
    (ret_ty : Type_repr.t) : Seed_mir.program =
  { Seed_mir.functions = [| call_fn "main" 0 callee arg ret_ty |];
    statics = [||];
    types = [||] }

let check_vm_dispatch () =
  (* __intrinsic_int_to_string(42) -> "42" through the real binding *)
  let p1 =
    call_program (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_int_to_string"))
      (Some (Type_repr.Int Type_repr.Int, int_constant 42L)) Type_repr.String
  in
  let entry = p1.Seed_mir.functions.(0).Seed_mir.instance in
  let host1 = Host.create ~repo_root:"." ~argv:[||] in
  (match Vm.run ~program:p1 ~entry ~argv:[||] ~host:host1 with
   | Error e -> fail "int-to-string host call failed: %s" e.Vm.message
   | Ok 0 -> (
       match Vm.entry_frame_of ~program:p1 ~entry ~argv:[||] with
       | Error m -> fail "entry frame inspection failed: %s" m
       | Ok (vm2, frame) -> (
           match Vm.run_inspect vm2 frame with
           | Ok "42" ->
               pass "VM host dispatch invokes the real __intrinsic_int_to_string binding (42 -> \"42\")"
           | Ok other -> fail "__intrinsic_int_to_string returned %S (expected \"42\")" other
           | Error m -> fail "int-to-string inspect failed: %s" m))
   | Ok _ -> fail "int-to-string program returned a non-zero exit code");
  (* println("...") writes the Host stdout buffer through the binding *)
  let p2 =
    call_program (Seed_mir.Intrinsic (intrinsic_id "println"))
      (Some (Type_repr.String, Seed_mir.String "hello from host self-check"))
      Type_repr.Unit
  in
  let e2 = p2.Seed_mir.functions.(0).Seed_mir.instance in
  let host2 = Host.create ~repo_root:"." ~argv:[||] in
  (match Vm.run ~program:p2 ~entry:e2 ~argv:[||] ~host:host2 with
   | Error e -> fail "println host call failed: %s" e.Vm.message
   | Ok 0 ->
       if Host.stdout_contents host2 = "hello from host self-check\n" then
         pass "VM host dispatch invokes the real println binding (writes the Host stdout buffer)"
       else
         fail "println wrote %S to the stdout buffer" (Host.stdout_contents host2)
   | Ok _ -> fail "println program returned a non-zero exit code");
  (* panic("boom") -> deterministic host error *)
  let p3 =
    call_program (Seed_mir.Intrinsic (intrinsic_id "panic"))
      (Some (Type_repr.String, Seed_mir.String "boom")) Type_repr.Never
  in
  let e3 = p3.Seed_mir.functions.(0).Seed_mir.instance in
  let host3 = Host.create ~repo_root:"." ~argv:[||] in
  (match Vm.run ~program:p3 ~entry:e3 ~argv:[||] ~host:host3 with
   | Error e when contains e.Vm.message "panic: boom" ->
       pass "VM host dispatch invokes the real panic binding (deterministic host error)"
   | Error e -> fail "panic produced the wrong error: %s" e.Vm.message
   | Ok _ -> fail "panic program returned instead of raising a host error");
  (* __intrinsic_abort() -> deterministic host error (zero-arity binding) *)
  let p4 = call_program (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_abort")) None Type_repr.Unit in
  let e4 = p4.Seed_mir.functions.(0).Seed_mir.instance in
  let host4 = Host.create ~repo_root:"." ~argv:[||] in
  (match Vm.run ~program:p4 ~entry:e4 ~argv:[||] ~host:host4 with
   | Error e when contains e.Vm.message "abort: __intrinsic_abort" ->
       pass "VM host dispatch invokes the real __intrinsic_abort binding (zero-arity)"
   | Error e -> fail "__intrinsic_abort produced the wrong error: %s" e.Vm.message
   | Ok _ -> fail "__intrinsic_abort program returned instead of raising a host error");
  (* __sync_synchronize() -> Unit through the Extern dispatch path *)
  let p5 =
    call_program (Seed_mir.Extern (extern_id "__sync_synchronize")) None Type_repr.Unit
  in
  let e5 = p5.Seed_mir.functions.(0).Seed_mir.instance in
  let host5 = Host.create ~repo_root:"." ~argv:[||] in
  (match Vm.run ~program:p5 ~entry:e5 ~argv:[||] ~host:host5 with
   | Ok 0 -> pass "VM host dispatch invokes the real __sync_synchronize binding (Extern path)"
   | Error e -> fail "__sync_synchronize host call failed: %s" e.Vm.message
   | Ok _ -> fail "__sync_synchronize program returned a non-zero exit code");
  (* __intrinsic_char_to_string(U+00E9) -> the two-byte UTF-8 sequence
     C3 A9: the host must use the Stage0 UTF-8 scalar encoder, not
     String.make 1 (Uchar.to_char c) (which truncates non-ASCII). *)
  let p7 =
    call_program (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_char_to_string"))
      (Some (Type_repr.Char, Seed_mir.Char (Uchar.of_int 0xE9))) Type_repr.String
  in
  let e7 = p7.Seed_mir.functions.(0).Seed_mir.instance in
  let host7 = Host.create ~repo_root:"." ~argv:[||] in
  (match Vm.run ~program:p7 ~entry:e7 ~argv:[||] ~host:host7 with
   | Error e -> fail "char-to-string host call failed: %s" e.Vm.message
   | Ok 0 -> (
       match Vm.entry_frame_of ~program:p7 ~entry:e7 ~argv:[||] with
       | Error m -> fail "entry frame inspection failed: %s" m
       | Ok (vm2, frame) -> (
           match Vm.run_inspect vm2 frame with
           | Ok s when s = "\xC3\xA9" ->
               pass
                 "__intrinsic_char_to_string encodes U+00E9 as the two-byte UTF-8 sequence C3 A9"
           | Ok other ->
               fail "__intrinsic_char_to_string returned %S (expected the two-byte UTF-8 sequence)"
                 other
           | Error m -> fail "char-to-string inspect failed: %s" m))
   | Ok _ -> fail "char-to-string program returned a non-zero exit code");
  (* declared-but-unbound symbol traps fail-closed (the intrinsic
     table's declared names without a host binding: __intrinsic_set_remove
     is declared in the registry but has no binding in the default host) *)
  let p6 =
    call_program (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_set_remove"))
      (Some (Type_repr.Unit, Seed_mir.Unit)) Type_repr.Unit
  in
  let e6 = p6.Seed_mir.functions.(0).Seed_mir.instance in
  let host6 = Host.create ~repo_root:"." ~argv:[||] in
  (match Vm.run ~program:p6 ~entry:e6 ~argv:[||] ~host:host6 with
   | Error e when contains e.Vm.message "has no binding (fail-closed)" ->
       pass "VM traps fail-closed for a declared-but-unbound host symbol"
   | Error e -> fail "unbound host call produced the wrong error: %s" e.Vm.message
   | Ok _ -> fail "unbound host call did not trap")

(* ── Reachable-host closure proof (re-audit: stage 10) ────────────
   The REACHABLE set is the right closure boundary: a declared-but-
   unreachable host symbol needs no binding, but a REACHABLE
   declared-but-unbound symbol fails the reachable-host closure check.
   The scan (Driver.collect_reachable_host_ids) collects exactly the
   host ids the program can dispatch to — Intrinsic/Extern call IDs
   directly (the VM's call_host conversion: registry index ->
   Host.Intrinsic/Extern id) plus User-form host calls resolved by
   name.  The check (Host.closure_check_reachable) then requires every
   reachable id to carry an executable binding with the exact typed
   signature. *)

let reachable_names (host : Host.t) (ids : Host.host_id list) : string =
  String.concat ", "
    (List.map
       (fun id -> match Host.name_of_host_id host id with Some n -> n | None -> "?")
       ids)

let check_reachable_closure_boundary () =
  let host = Host.create ~repo_root:"." ~argv:[||] in
  (* (a) reachable calls: one bound intrinsic (__intrinsic_int_to_string)
     and one declared-but-unbound extern (rb_funcall) — the reachable
     closure check must FAIL and name the unbound extern *)
  let prog_a =
    { Seed_mir.functions =
        [| call_fn "use_bound_intrinsic" 1
             (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_int_to_string"))
             (Some (Type_repr.Int Type_repr.Int, int_constant 42L)) Type_repr.String;
           call_fn "use_unbound_extern" 2 (Seed_mir.Extern (extern_id "rb_funcall")) None
             Type_repr.Unit |];
      statics = [||];
      types = [||] }
  in
  let reachable_a = Driver.collect_reachable_host_ids prog_a in
  Printf.printf "  reachable host ids: %s\n" (reachable_names host reachable_a);
  (match Host.closure_check_reachable host reachable_a with
   | Ok _ ->
       fail
         "reachable closure check passed although the reachable set contains the \
          declared-but-unbound extern 'rb_funcall'"
   | Error problems -> (
       match
         List.find_opt (fun p -> Util.has_prefix p "reachable but not bound") problems
       with
       | None ->
           fail "reachable closure check failed for the wrong reason: %s"
             (String.concat "; " problems)
       | Some p ->
           if not (Util.has_suffix p "rb_funcall") then
             fail "reachable-but-unbound symbol not named in the report: %s" p;
           Printf.printf "  %s\n" p;
           pass
             "reachable-host closure FAILS when a declared-but-unbound extern is reachable"));
  (* (b) the same program with the unbound extern NOT called — every
     reachable id is bound, the check must PASS *)
  let prog_b =
    { Seed_mir.functions =
        [| call_fn "use_bound_intrinsic" 1
             (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_int_to_string"))
             (Some (Type_repr.Int Type_repr.Int, int_constant 42L)) Type_repr.String |];
      statics = [||];
      types = [||] }
  in
  let reachable_b = Driver.collect_reachable_host_ids prog_b in
  (match Host.closure_check_reachable host reachable_b with
   | Error problems ->
       List.iter (fun p -> Printf.printf "    %s\n" p) problems;
       fail
         "reachable closure check failed although every reachable host id is bound"
   | Ok report ->
       if report.Host.declared <> 1 || report.Host.implemented <> 1 then
         fail "unexpected reachable closure report: declared=%d implemented=%d"
           report.Host.declared report.Host.implemented;
       pass
         "reachable-host closure PASSES when the unbound extern is not called \
          (declared-but-unreachable needs no binding)");
  (* (c) User-form host calls: a User callee whose specialized function
     name is a declared host symbol maps to that host id (the scan's
     name resolution — the same boundary the binding table uses), and
     the reachable set passes the closure check *)
  let println_inst = Instance_id.make ~callable:(Ids.Callable_id.make 7) ~type_args:[||] in
  let prog_c =
    { Seed_mir.functions =
        [| call_fn "println" 7 (Seed_mir.User println_inst) None Type_repr.Unit;
           call_fn "use_bound_intrinsic" 1
             (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_int_to_string"))
             (Some (Type_repr.Int Type_repr.Int, int_constant 42L)) Type_repr.String |];
      statics = [||];
      types = [||] }
  in
  let reachable_c = Driver.collect_reachable_host_ids prog_c in
  let println_id = Host.Intrinsic (Intrinsic_registry.Id.make (intrinsic_id "println")) in
  if not (List.mem println_id reachable_c) then
    fail "User-form host call to 'println' was not resolved to its intrinsic host id (reachable = [%s])"
      (reachable_names host reachable_c);
  (match Host.closure_check_reachable host reachable_c with
   | Error problems ->
       List.iter (fun p -> Printf.printf "    %s\n" p) problems;
       fail
         "reachable closure check failed on the User-form program (println is bound; the \
          reachable set must pass)"
   | Ok _ ->
       pass "User-form host calls resolve to their host ids (callee instance -> declared host symbol name)")

let () =
  Printf.printf "host closure self-check\n";
  check_declared_unbound ();
  check_declared_implemented ();
  check_independent_signature_mismatch ();
  check_vm_dispatch ();
  check_reachable_closure_boundary ();
  (* Informational: the default manifest host is fail-closed (the Ruby C
     API / map-set / dl* symbols are declared without bindings). *)
  let host = Host.create ~repo_root:"." ~argv:[||] in
  (match Host.closure_check host with
   | Ok report ->
       Printf.printf
         "INFO: default manifest host closure_check passed (declared=%d implemented=%d)\n"
         report.declared report.implemented
   | Error problems ->
       Printf.printf
         "INFO: default manifest host closure_check: %d problem(s), declared=%d bound=%d (fail-closed)\n"
         (List.length problems)
         (List.length (Intrinsic_registry.names host.Host.intrinsics)
         + List.length (Extern_registry.names host.Host.externs))
         (List.length host.Host.bindings));
  Printf.printf "OK: host closure self-check passed\n";
  exit 0
