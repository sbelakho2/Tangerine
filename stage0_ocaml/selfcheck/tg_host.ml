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
    call_program (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_int_to_string", [||]))
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
    call_program (Seed_mir.Intrinsic (intrinsic_id "println", [||]))
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
    call_program (Seed_mir.Intrinsic (intrinsic_id "panic", [||]))
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
  let p4 = call_program (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_abort", [||])) None Type_repr.Unit in
  let e4 = p4.Seed_mir.functions.(0).Seed_mir.instance in
  let host4 = Host.create ~repo_root:"." ~argv:[||] in
  (match Vm.run ~program:p4 ~entry:e4 ~argv:[||] ~host:host4 with
   | Error e when contains e.Vm.message "abort: __intrinsic_abort" ->
       pass "VM host dispatch invokes the real __intrinsic_abort binding (zero-arity)"
   | Error e -> fail "__intrinsic_abort produced the wrong error: %s" e.Vm.message
   | Ok _ -> fail "__intrinsic_abort program returned instead of raising a host error");
  (* __sync_synchronize() -> Unit through the Extern dispatch path *)
  let p5 =
    call_program (Seed_mir.Extern (extern_id "__sync_synchronize", [||])) None Type_repr.Unit
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
    call_program (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_char_to_string", [||]))
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
  (* declared-but-unbound symbol traps fail-closed (the registry's
     declared names without a host binding: the Ruby C API externs are
     declared in the manifest but have no binding in the default host —
     the five record-visit intrinsics ARE bound now, so the trap proof
     uses the still-deliberately-unbound rb_funcall) *)
  let p6 =
    call_program (Seed_mir.Extern (extern_id "rb_funcall", [||])) None Type_repr.Unit
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
             (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_int_to_string", [||]))
             (Some (Type_repr.Int Type_repr.Int, int_constant 42L)) Type_repr.String;
           call_fn "use_unbound_extern" 2 (Seed_mir.Extern (extern_id "rb_funcall", [||])) None
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
             (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_int_to_string", [||]))
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
             (Seed_mir.Intrinsic (intrinsic_id "__intrinsic_int_to_string", [||]))
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

(* ── poll(2) adapter (the linker's macOS codesign step reads its two
   stdio pipes through it) ──────────────────────────────────────────
   Property: with a byte pending in a pipe, poll reports exactly one
   ready entry and writes POLLIN into the pollfd record inside the Raw
   arena region; after the byte is drained a zero-timeout poll reports
   nothing; a guest fd without a host descriptor reports POLLNVAL. *)

let poll_uint (n : int) : Vm_value.t =
  Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:false (Int64.of_int n))

(* Invoke the poll binding on one pollfd { fd; POLLIN } held in a fresh
   Raw arena region; returns (ready count, revents). *)
let poll_probe (binding : Host.binding) (host : Host.t) (fd : int)
    (timeout : int) : int * int =
  match Host.arena_alloc host 8 1 with
  | Error e -> fail "poll self-check: arena_alloc failed: %s" e
  | Ok p ->
      let arr = Bytes.make 8 '\000' in
      Raw_memory.put_u64_le arr 0 4 (Int64.of_int fd);
      Raw_memory.put_u64_le arr 4 2 0x001L (* POLLIN *);
      (match Host.arena_store host p arr with
      | Error e -> fail "poll self-check: arena_store failed: %s" e
      | Ok () -> ());
      let ready =
        match
          binding.Host.invoke host
            [| Vm_value.RawPtr p; poll_uint 1;
               Vm_value.Int
                 (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int timeout)) |]
        with
        | Error e -> fail "poll self-check: invoke failed: %s" e
        | Ok res -> (
            match res.Host.value with
            | Vm_value.Int i -> Int64.to_int (Int_value.to_int64 i)
            | _ -> fail "poll self-check: poll returned a non-integer value")
      in
      let revents =
        match Host.arena_load host p 8 with
        | Error e -> fail "poll self-check: arena_load failed: %s" e
        | Ok rb -> Int64.to_int (Raw_memory.u64_le rb 6 2)
      in
      (ready, revents)

(* Invoke the poll binding on TWO pollfd entries (the Command::output
   interleave shape); returns (ready count, revents entry 1, revents
   entry 2) — proving the per-entry writeback at a nonzero offset. *)
let poll_probe2 (binding : Host.binding) (host : Host.t) (fd1 : int) (fd2 : int)
    (timeout : int) : int * int * int =
  match Host.arena_alloc host 16 1 with
  | Error e -> fail "poll self-check: arena_alloc failed: %s" e
  | Ok p ->
      let arr = Bytes.make 16 '\000' in
      Raw_memory.put_u64_le arr 0 4 (Int64.of_int fd1);
      Raw_memory.put_u64_le arr 4 2 0x001L;
      Raw_memory.put_u64_le arr 8 4 (Int64.of_int fd2);
      Raw_memory.put_u64_le arr 12 2 0x001L;
      (match Host.arena_store host p arr with
      | Error e -> fail "poll self-check: arena_store failed: %s" e
      | Ok () -> ());
      let ready =
        match
          binding.Host.invoke host
            [| Vm_value.RawPtr p; poll_uint 2;
               Vm_value.Int
                 (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int timeout)) |]
        with
        | Error e -> fail "poll self-check: invoke failed: %s" e
        | Ok res -> (
            match res.Host.value with
            | Vm_value.Int i -> Int64.to_int (Int_value.to_int64 i)
            | _ -> fail "poll self-check: poll returned a non-integer value")
      in
      match Host.arena_load host p 16 with
      | Error e -> fail "poll self-check: arena_load failed: %s" e
      | Ok rb ->
          ( ready,
            Int64.to_int (Raw_memory.u64_le rb 6 2),
            Int64.to_int (Raw_memory.u64_le rb 14 2) )

let check_poll_adapter () =
  let binding = manifest_binding "poll" in
  let host = Host.create ~repo_root:"." ~argv:[||] in
  let r, w = Unix.pipe ~cloexec:false () in
  let r2, w2 = Unix.pipe ~cloexec:false () in
  let guest_r = Host.register_guest_fd r in
  let guest_w = Host.register_guest_fd w in
  let guest_r2 = Host.register_guest_fd r2 in
  let guest_w2 = Host.register_guest_fd w2 in
  ignore (Unix.write w (Bytes.of_string "x") 0 1);
  ignore (Unix.write w2 (Bytes.of_string "y") 0 1);
  let ready, rev = poll_probe binding host guest_r (-1) in
  if ready <> 1 then fail "poll self-check: expected 1 ready entry, got %d" ready;
  if rev land 0x001 = 0 then fail "poll self-check: POLLIN not set in revents (0x%x)" rev;
  ignore (Unix.read r (Bytes.make 1 ' ') 0 1);
  let ready_after, _ = poll_probe binding host guest_r 0 in
  if ready_after <> 0 then
    fail "poll self-check: drained pipe reported %d ready entries" ready_after;
  (* the two-entry shape: entry 1 drained (not ready), entry 2 has a byte *)
  let ready2, rev1, rev2 = poll_probe2 binding host guest_r guest_r2 0 in
  if ready2 <> 1 then fail "poll self-check: two-entry poll reported %d ready" ready2;
  if rev1 <> 0 then fail "poll self-check: drained entry 1 reported revents 0x%x" rev1;
  if rev2 land 0x001 = 0 then
    fail "poll self-check: entry 2 POLLIN missing (revents=0x%x)" rev2;
  let unknown, unknown_rev = poll_probe binding host 999999 0 in
  if unknown <> 1 then fail "poll self-check: unknown fd reported %d ready entries" unknown;
  if unknown_rev land 0x020 = 0 then
    fail "poll self-check: unknown guest fd must report POLLNVAL (revents=0x%x)" unknown_rev;
  Host.unregister_guest_fd guest_r |> ignore;
  Host.unregister_guest_fd guest_w |> ignore;
  Host.unregister_guest_fd guest_r2 |> ignore;
  Host.unregister_guest_fd guest_w2 |> ignore;
  pass
    "poll decodes the arena pollfd array (1- and 2-entry), reports POLLIN/POLLNVAL and writes revents back"

(* ── _exit adapter ───────────────────────────────────────────────────
   Property (the direct kernel's semantics, split at the process
   boundary): in the parent — the seed host running the VM — _exit traps
   deterministically; in an OS child created by the guest's own fork it
   terminates exactly that child with the requested code. *)
let check_exit_adapter () =
  let binding = manifest_binding "_exit" in
  let code () =
    Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true 42L)
  in
  let host = Host.create ~repo_root:"." ~argv:[||] in
  (match binding.invoke host [| code () |] with
  | Ok _ -> fail "_exit self-check: the parent-host _exit returned instead of trapping"
  | Error m ->
      if not (contains m "in-process VM must not terminate the seed host") then
        fail "_exit self-check: parent trap has the wrong message: %s" m);
  match Unix.fork () with
  | 0 ->
      let child_host = Host.create ~repo_root:"." ~argv:[||] in
      child_host.Host.in_fork_child <- true;
      (match binding.invoke child_host [| code () |] with
      | Ok _ -> Unix._exit 7
      | Error _ -> Unix._exit 8)
  | pid -> (
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED 42 ->
          pass
            "_exit traps in the parent seed host and terminates a guest-forked child with the requested code"
      | Unix.WEXITED n -> fail "_exit self-check: child exited %d (expected 42)" n
      | _ -> fail "_exit self-check: child did not exit normally")

(* ── syscall completion (mmap / getcwd / getdents / ioctl / dup) ─────
   The five raw-syscall numbers the path audit left unmapped.  No kernel
   closure path reaches them (the audit's path table names each as "not
   in the closure call graph"), so these checks pin the honest host
   semantics the seed now provides: arena-backed anonymous mmap and
   file-backed mappings, the VIRTUAL getcwd, the audited macOS
   getdirentries layout (plus the Linux getdents64 layout), ENOTTY
   ioctl, and dup over the guest descriptor table. *)

let s64 (n : int64) : Vm_value.t =
  Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true n)

let addr_value (p : Vm_memory.pointer) : Vm_value.t =
  s64 (Vm_memory.pointer_to_int64 p)

(* Invoke a __intrinsic_syscallN binding and return the integer result. *)
let syscall (name : string) (host : Host.t) (args : Vm_value.t array) : int =
  let b = manifest_binding name in
  match b.Host.invoke host args with
  | Error e -> fail "syscall %s: invoke failed: %s" name e
  | Ok res -> (
      match res.Host.value with
      | Vm_value.Int i -> Int64.to_int (Int_value.to_int64 i)
      | _ -> fail "syscall %s: returned a non-integer" name)

let check_getcwd () =
  let host = Host.create ~repo_root:"." ~argv:[||] in
  let call_cwd (p : Vm_memory.pointer) (size : int) : int =
    syscall "__intrinsic_syscall2" host
      [| s64 310L; addr_value p; s64 (Int64.of_int size) |]
  in
  (* the virtual root is the initial cwd (Host_fs.cwd = []) *)
  (match Host.arena_alloc host 64 1 with
  | Error e -> fail "getcwd: arena_alloc failed: %s" e
  | Ok p ->
      let r = call_cwd p 64 in
      if r <= 0 then fail "getcwd: expected the buffer address, got %d" r;
      (match Host.arena_load host p 3 with
      | Error e -> fail "getcwd: arena_load failed: %s" e
      | Ok b ->
          if Bytes.sub_string b 0 3 <> "/\x00\x00" then
            fail "getcwd: expected \"/\", got %S" (Bytes.to_string b)));
  (* a guest chdir moves the VIRTUAL cwd, and getcwd reports it *)
  Host_fs.set_cwd host.Host.fs [ "a"; "b" ];
  (match Host.arena_alloc host 64 1 with
  | Error e -> fail "getcwd: arena_alloc failed: %s" e
  | Ok p ->
      ignore (call_cwd p 64);
      (match Host.arena_load host p 6 with
      | Error e -> fail "getcwd: arena_load failed: %s" e
      | Ok b ->
          if Bytes.sub_string b 0 5 <> "/a/b\x00" then
            fail "getcwd: expected \"/a/b\", got %S" (Bytes.to_string b)));
  (* ERANGE when the buffer cannot hold the path plus NUL *)
  (match Host.arena_alloc host 2 1 with
  | Error e -> fail "getcwd: arena_alloc failed: %s" e
  | Ok p ->
      let r = call_cwd p 2 in
      if r <> -34 then fail "getcwd: undersized buffer returned %d (expected -ERANGE)" r);
  pass "getcwd writes the VIRTUAL cwd as a NUL-terminated string and reports ERANGE"

let check_dup () =
  let host = Host.create ~repo_root:"." ~argv:[||] in
  let r, w = Unix.pipe ~cloexec:false () in
  let gr = Host.register_guest_fd r in
  ignore (Unix.write w (Bytes.of_string "x") 0 1);
  let gd = syscall "__intrinsic_syscall1" host [| s64 32L; s64 (Int64.of_int gr) |] in
  if gd <= 2 then fail "dup: expected a fresh guest descriptor, got %d" gd;
  (match Host.arena_alloc host 4 1 with
  | Error e -> fail "dup: arena_alloc failed: %s" e
  | Ok p ->
      let n = Host.host_read_into host gd p 1 in
      if n <> 1 then fail "dup: reading through the duplicate returned %d" n;
      (match Host.arena_load host p 1 with
      | Ok b when Bytes.get b 0 = 'x' -> ()
      | _ -> fail "dup: the duplicate did not share the pipe stream"));
  let missing = syscall "__intrinsic_syscall1" host [| s64 32L; s64 999999L |] in
  if missing <> -9 then fail "dup: unknown fd returned %d (expected -EBADF)" missing;
  ignore (Host.unregister_guest_fd gd);
  ignore (Host.unregister_guest_fd gr);
  Unix.close w;
  pass "dup duplicates a guest descriptor (shared stream) and reports EBADF for an unknown fd"

let check_mmap () =
  let host = Host.create ~repo_root:"." ~argv:[||] in
  (* anonymous: fd = -1 -> a zeroed Raw region of the requested length *)
  let a =
    syscall "__intrinsic_syscall6" host
      [| s64 194L; s64 0L; s64 64L; s64 3L; s64 0x1002L; s64 (-1L); s64 0L |]
  in
  if a <= 0 then fail "mmap: anonymous mapping returned %d" a;
  let p = Vm_memory.pointer_of_int64 (Int64.of_int a) in
  (match Vm_memory.region_of host.Host.memory p with
  | Error e -> fail "mmap: mapped region missing: %s" (Vm_memory.mem_error_string e)
  | Ok _ -> ());
  (match Host.arena_load host p 64 with
  | Ok b when Bytes.to_string b = String.make 64 '\000' -> ()
  | Ok _ -> fail "mmap: the anonymous mapping is not zeroed"
  | Error e -> fail "mmap: %s" e);
  (* file-backed: the region carries the file's bytes at the offset, and
     the descriptor offset is unchanged (mmap never moves it) *)
  let path = Filename.temp_file "tg_host_mmap" ".bin" in
  let oc = open_out_bin path in
  output_string oc "hello";
  close_out oc;
  let fd = Host.host_open host path 0 0 in
  if fd < 0 then fail "mmap: host_open failed: %d" fd;
  let a2 =
    syscall "__intrinsic_syscall6" host
      [| s64 197L; s64 0L; s64 5L; s64 3L; s64 2L; s64 (Int64.of_int fd); s64 0L |]
  in
  if a2 <= 0 then fail "mmap: file-backed mapping returned %d" a2;
  let p2 = Vm_memory.pointer_of_int64 (Int64.of_int a2) in
  (match Host.arena_load host p2 5 with
  | Ok b when Bytes.to_string b = "hello" -> ()
  | Ok b -> fail "mmap: file-backed bytes are %S (expected \"hello\")" (Bytes.to_string b)
  | Error e -> fail "mmap: %s" e);
  if Host.host_lseek fd 0L 1 <> 0L then
    fail "mmap: the file-backed mapping moved the descriptor offset";
  ignore (Host.host_close_fd fd);
  Sys.remove path;
  (* a descriptor that is not a regular file has no mapping (ENODEV) *)
  let r, w = Unix.pipe ~cloexec:false () in
  let gr = Host.register_guest_fd r in
  let a3 =
    syscall "__intrinsic_syscall6" host
      [| s64 197L; s64 0L; s64 8L; s64 3L; s64 2L; s64 (Int64.of_int gr); s64 0L |]
  in
  if a3 <> -19 then fail "mmap: a pipe descriptor returned %d (expected -ENODEV)" a3;
  ignore (Host.unregister_guest_fd gr);
  Unix.close w;
  pass "mmap allocates a zeroed arena region anonymously and fills file-backed mappings from the offset without moving the descriptor"

let check_ioctl () =
  let host = Host.create ~repo_root:"." ~argv:[||] in
  let r, w = Unix.pipe ~cloexec:false () in
  let gr = Host.register_guest_fd r in
  (match Host.arena_alloc host 8 1 with
  | Error e -> fail "ioctl: arena_alloc failed: %s" e
  | Ok p ->
      (* the std TIOCGWINSZ request has no OCaml host primitive: ENOTTY,
         exactly the input the std/cli.tg (80, 24) fallback handles *)
      let rc =
        syscall "__intrinsic_syscall3" host
          [| s64 16L; s64 (Int64.of_int gr); s64 0x40087468L; addr_value p |]
      in
      if rc <> -25 then fail "ioctl: TIOCGWINSZ returned %d (expected -ENOTTY)" rc);
  let missing =
    syscall "__intrinsic_syscall3" host [| s64 16L; s64 999999L; s64 0L; s64 0L |]
  in
  if missing <> -9 then fail "ioctl: unknown fd returned %d (expected -EBADF)" missing;
  ignore (Host.unregister_guest_fd gr);
  Unix.close w;
  pass "ioctl reports ENOTTY for a known descriptor (the std fallback input) and EBADF for an unknown one"

(* Walk a getdirentries result buffer: BSD records are u32 d_ino, u16
   d_reclen, u8 d_type, u8 d_namlen, name at 8, padded to 4. *)
let parse_bsd_dirents (b : Bytes.t) (n : int) : string list =
  let names = ref [] in
  let pos = ref 0 in
  while !pos < n do
    let reclen = Int64.to_int (Raw_memory.u64_le b (!pos + 4) 2) in
    if reclen <= 0 then fail "getdirentries: zero d_reclen at %d" !pos;
    let namlen = Char.code (Bytes.get b (!pos + 7)) in
    names := Bytes.sub_string b (!pos + 8) namlen :: !names;
    pos := !pos + reclen
  done;
  List.rev !names

(* Walk a getdents64 result buffer: u64 d_ino, u64 d_off, u16 d_reclen,
   u8 d_type, NUL-terminated name at 19, padded to 8. *)
let parse_linux_dirents (b : Bytes.t) (n : int) : string list =
  let names = ref [] in
  let pos = ref 0 in
  while !pos < n do
    let reclen = Int64.to_int (Raw_memory.u64_le b (!pos + 16) 2) in
    if reclen <= 0 then fail "getdents64: zero d_reclen at %d" !pos;
    let end_ = ref (!pos + 19) in
    while !end_ < !pos + reclen && Bytes.get b !end_ <> '\000' do incr end_ done;
    names := Bytes.sub_string b (!pos + 19) (!end_ - (!pos + 19)) :: !names;
    pos := !pos + reclen
  done;
  List.rev !names

let check_getdents () =
  let host = Host.create ~repo_root:"." ~argv:[||] in
  let dir = Filename.temp_dir "tg_host_dents" "" in
  let touch name =
    let oc = open_out (Filename.concat dir name) in
    output_string oc "x";
    close_out oc
  in
  touch "b.txt";
  touch "a.txt";
  Unix.mkdir (Filename.concat dir "d") 0o755;
  let fd = Host.host_open host dir 0 0 in
  if fd < 0 then fail "getdents: host_open failed: %d" fd;
  (match (Host.arena_alloc host 4096 1, Host.arena_alloc host 8 1) with
  | Ok buf, Ok basep ->
      (* the audited macOS branch: getdirentries(fd, buf, nbytes, basep) *)
      let call () =
        syscall "__intrinsic_syscall4" host
          [|
            s64 193L; s64 (Int64.of_int fd); addr_value buf; s64 4096L;
            addr_value basep;
          |]
      in
      let n = call () in
      if n <= 0 then fail "getdirentries: nread %d" n;
      (match Host.arena_load host buf n with
      | Ok b ->
          let names = parse_bsd_dirents b n in
          if names <> [ "a.txt"; "b.txt"; "d" ] then
            fail "getdirentries: entries [%s]" (String.concat ", " names)
      | Error e -> fail "getdirentries: %s" e);
      (match Host.arena_load host basep 8 with
      | Ok b when Int64.to_int (Raw_memory.u64_le b 0 8) = 3 -> ()
      | Ok b ->
          fail "getdirentries: basep = %Ld (expected the next entry index 3)"
            (Raw_memory.u64_le b 0 8)
      | Error e -> fail "getdirentries: basep: %s" e);
      if call () <> 0 then fail "getdirentries: the exhausted directory did not return 0";
      (* the Linux branch: getdents64 over a fresh descriptor *)
      let fd2 = Host.host_open host dir 0 0 in
      let n2 =
        syscall "__intrinsic_syscall3" host
          [| s64 217L; s64 (Int64.of_int fd2); addr_value buf; s64 4096L |]
      in
      if n2 <= 0 then fail "getdents64: nread %d" n2;
      (match Host.arena_load host buf n2 with
      | Ok b ->
          let names = parse_linux_dirents b n2 in
          if names <> [ "a.txt"; "b.txt"; "d" ] then
            fail "getdents64: entries [%s]" (String.concat ", " names)
      | Error e -> fail "getdents64: %s" e);
      ignore (Host.host_close_fd fd2);
      (* a descriptor that is not a directory fails like the native call *)
      let r, w = Unix.pipe ~cloexec:false () in
      let gr = Host.register_guest_fd r in
      let bad =
        syscall "__intrinsic_syscall4" host
          [|
            s64 193L; s64 (Int64.of_int gr); addr_value buf; s64 4096L;
            addr_value basep;
          |]
      in
      if bad <> -9 then fail "getdirentries: a pipe descriptor returned %d" bad;
      ignore (Host.unregister_guest_fd gr);
      Unix.close w
  | _ -> fail "getdents: arena allocation failed");
  ignore (Host.host_close_fd fd);
  List.iter (fun n -> Sys.remove (Filename.concat dir n)) [ "a.txt"; "b.txt" ];
  Unix.rmdir (Filename.concat dir "d");
  Unix.rmdir dir;
  pass "getdirentries (BSD layout) and getdents64 (Linux layout) emit the directory's sorted entries with the basep cursor"

let () =
  Printf.printf "host closure self-check\n";
  check_declared_unbound ();
  check_declared_implemented ();
  check_independent_signature_mismatch ();
  check_vm_dispatch ();
  check_reachable_closure_boundary ();
  check_poll_adapter ();
  check_exit_adapter ();
  check_getcwd ();
  check_dup ();
  check_mmap ();
  check_ioctl ();
  check_getdents ();
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
