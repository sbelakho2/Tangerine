#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# scripts/mutation_detectors.sh — the per-mutation SOURCE-INTEGRITY
# detector library for the bounded mutation harness
# (scripts/run_mutation_tests.sh).
#
# THE RE-ROLE (the reviewer's mandate): the structural detectors are the
# SOURCE-INTEGRITY CHECKS — they verify the mutation was applied at the
# INTENDED SITE (the canonical semantic form of the site is destroyed on
# the mutated copy, confirming the transformation landed where the
# catalog says). They NEVER classify a kill. THE KILL CLASSIFICATION IS
# BEHAVIORAL ONLY (the semantic mutation protocol):
#   mutate -> BUILD the mutated kernel with a usable current-grammar
#   compiler binary -> RUN the per-mutation behavioral suite under the
#   mutated compiler -> the mutation is KILLED iff the behavioral suite
#   FAILS.
#
# Every detector below asserts the CANONICAL SEMANTIC FORM of one
# mutation target site: the form the checker/verifier/layout/async code
# MUST state for the compiler's accepted/rejected sets, layouts, emitted
# code, or wake/ordering arms to be correct. A mutation destroys its own
# site's canonical form, so the detector fires on the mutated copy and
# holds on the pristine tree.
#
# The G13 group of scripts/verify_invariants.sh encodes the same
# assertions as permanent tree-wide source-integrity invariants; this
# library is the per-mutation entry point the harness calls for the
# direct application confirmation.
#
# Usage: detect_mutation <mutation-id> <tree-root>
#   on the PRISTINE tree: exit 0 = the site is intact (the canonical
#            form holds);
#   on a MUTATED copy:    exit 1 = the site is broken (the detector
#            FIRED — the mutation IS present at its intended site).
#   The harness REQUIRES the detector to FIRE on the mutated copy: a
#   detector that does NOT fire means the mutation is not observable at
#   its target site — an application/drift error, NEVER a kill signal.
# ———————————————————————————————————————————————————————————————

detect_mutation() {
  local id="$1" root="$2"
  case "$id" in
    mut-invert-comparison)
      grep -qF "if fid.index >= 0 && fid.index < fields.len() then" "$root/tg_compiler/types.tg" \
        || { echo "the field-index bounds check is not the canonical '>= 0 && < len()' form (a valid index is rejected)"; return 1; }
      ;;
    mut-delete-diagnostic)
      grep -qF "extern function carries unknown ABI classification" "$root/tg_compiler/mir.tg" \
        || { echo "the extern-ABI classification diagnostic site is gone (an unknown ABI tag no longer fails verification)"; return 1; }
      [ "$(grep -c "extern function carries unknown ABI classification" "$root/tg_compiler/mir.tg")" -eq 1 ] \
        || { echo "the extern-ABI classification diagnostic site count is not the canonical 1 (the expected substring is missing from the ABI-classification block)"; return 1; }
      [ "$(grep -c "non-extern function carries ABI classification" "$root/tg_compiler/mir.tg")" -eq 1 ] \
        || { echo "the ABI-classification block's non-extern arm is missing (the two-arm diagnostic block drifted)"; return 1; }
      ;;
    mut-consume-to-read)
      grep -qF "if bp.action == AccessEffect::Consume then" "$root/tg_compiler/types.tg" \
        || { echo "the partial-move binder no longer classifies AccessEffect::Consume (a moving binding is treated as read-only)"; return 1; }
      grep -q "canary_neg_access_sink_twice.tg.*consumed twice" "$root/tests/canary_neg/MANIFEST" \
        || { echo "the sink-twice negative canary's expected text 'consumed twice' is missing from the manifest"; return 1; }
      ;;
    mut-modify-to-read)
      grep -qF "when AccessConvention::Inout then AccessEffect::Modify" "$root/tg_compiler/mir.tg" \
        || { echo "the inout access convention no longer maps to AccessEffect::Modify (an inout parameter is treated as read-only)"; return 1; }
      grep -q "canary_neg_access_inout_dup.tg.*conflicting accesses" "$root/tests/canary_neg/MANIFEST" \
        || { echo "the inout-dup negative canary's expected text 'conflicting accesses' is missing from the manifest"; return 1; }
      ;;
    mut-remove-drop-mark)
      grep -qF "ext.insert(path.clone(), PlaceMoveState::Consumed)" "$root/tg_compiler/types.tg" \
        || { echo "the partial-move registry no longer marks the consumed place (the MIR partial-drop chain never sees the Consumed state)"; return 1; }
      grep -q "canary_neg_resource_use_after_consume.tg.*consumed" "$root/tests/canary_neg/MANIFEST" \
        || { echo "the use-after-consume negative canary's expected text is missing from the manifest"; return 1; }
      ;;
    mut-duplicate-drop)
      grep -qF "if !deinit_instances.contains(&inst_key) && !drop_glue_fns.contains_key(&inst_key) then" "$root/tg_compiler/mir.tg" \
        || { echo "the MirDeinit identity guard is gone (a duplicate/unregistered deinit instance no longer fails verification)"; return 1; }
      [ "$(grep -c "collect_deinit_plan_instances(&dp, &mut deinit_instances)" "$root/tg_compiler/mir.tg")" -eq 1 ] \
        || { echo "the deinit-instance registration site count drifted from the canonical 1 (the deinit-count invariant broke)"; return 1; }
      ;;
    mut-skip-verifier)
      local firewall=1
      grep -q "verify_function_v2(&type_index" "$root/tg_compiler/mir.tg" || firewall=0
      if [ "$(awk '/^def verify_mir\(/{f=1; next} f && /^def /{f=0} f && /return Vec::new\(\)/{n++} END{print n+0}' "$root/tg_compiler/mir.tg")" -ne 0 ]; then
        firewall=0
      fi
      [ "$firewall" -eq 1 ] \
        || { echo "the MIR firewall is broken (verify_mir no longer calls verify_function_v2 at every boundary and/or early-returns an empty error list)"; return 1; }
      ;;
    mut-field-offset)
      grep -qE "field_name == \"key_stride\".*then Option::Some\(24\)" "$root/tg_compiler/layout_engine.tg" \
        || { echo "the Map header key_stride offset is not the canonical 24 (the MAP_HEADER_FIELDS table drifted)"; return 1; }
      ;;
    mut-enum-tag)
      grep -qF "tag_size: 8" "$root/tg_compiler/layout_engine.tg" \
        || { echo "the TaggedUnion layout record no longer pins tag_size 8 (F3: tag at 0, payload at 8)"; return 1; }
      grep -qF "payload_offset: 8" "$root/tg_compiler/layout_engine.tg" \
        || { echo "the TaggedUnion payload offset is no longer 8 (F3: payload at 8)"; return 1; }
      ;;
    mut-remove-overflow-check)
      grep -qF "if b > 9223372036854775807 - a then" "$root/tg_compiler/layout_engine.tg" \
        || { echo "layout_checked_add's fail-closed overflow guard is gone (an overflowed size/offset would wrap instead of panicking)"; return 1; }
      ;;
    mut-branch-target)
      [ "$(awk '/^def verify_function_v2\(/{f=1} f && /if func.is_extern then return end/{n++} f && /^def / && !/^def verify_function_v2/{f=0} END{print n+0}' "$root/tg_compiler/mir.tg")" -eq 1 ] \
        || { echo "the verify_function_v2 early-return edge no longer points at extern functions only (non-extern functions return unverified)"; return 1; }
      grep -qF "if !func.is_extern then return end" "$root/tg_compiler/mir.tg" \
        && { echo "the inverted extern early-return branch target is present"; return 1; }
      ;;
    mut-remove-wake)
      grep -qF "      exec.wake_task(self.task_id)" "$root/std/async.tg" \
        || { echo "the waker's wake_task dispatch site is gone (a woken task is never dispatched to the executor)"; return 1; }
      [ "$(grep -c "wake_task" "$root/std/async.tg")" -eq 10 ] \
        || { echo "the async waiter-wake site count drifted from the canonical 10"; return 1; }
      ;;
    mut-remove-atomic-ordering)
      grep -qF "emit8(&mut ctx.text, 0x05)   # cmp edx, 5 (SeqCst)" "$root/tg_compiler/codegen.tg" \
        || { echo "the x86 SeqCst store ordering branch is gone (a SeqCst store would emit the weak MOV path)"; return 1; }
      grep -q "a64_ldaddal" "$root/tg_compiler/codegen.tg" && grep -q "a64_casal" "$root/tg_compiler/codegen.tg" \
        || { echo "the a64 ordering arms (ldaddal/casal) are missing from the atomic emitter"; return 1; }
      ;;
    mut-equality-to-permissive)
      grep -qF "if keys.len() == 1 then" "$root/tg_compiler/types.tg" \
        || { echo "the depth-1 projection check is no longer the exact equality '== 1' (the permissive '>= 1' widened the accepted set)"; return 1; }
      grep -qF "if keys.len() >= 1 then" "$root/tg_compiler/types.tg" \
        && { echo "the permissive '>= 1' form appears at the depth-1 projection site"; return 1; }
      grep -qF "if !(cpt.convention == ipt.convention) then" "$root/tg_compiler/types.tg" \
        || { echo "the E0225-class exact convention-equality site is gone (a permissive convention comparison would pass mismatched conventions)"; return 1; }
      grep -q "canary_neg_conv_convention_inout_let.tg.*access convention mismatch" "$root/tests/canary_neg/MANIFEST" \
        || { echo "the E0225-class negative canary's expected text 'access convention mismatch' is missing from the manifest"; return 1; }
      grep -q "canary_neg_conv_convention_let_inout.tg.*access convention mismatch" "$root/tests/canary_neg/MANIFEST" \
        || { echo "the E0225-class negative canary's expected text 'access convention mismatch' is missing from the manifest"; return 1; }
      ;;
    *)
      echo "detect_mutation: unknown mutation id: $id" >&2
      return 2
      ;;
  esac
  return 0
}

detector_name() {
  case "$1" in
    mut-invert-comparison)      echo "detect_mutation mut-invert-comparison (G13.1)" ;;
    mut-delete-diagnostic)      echo "detect_mutation mut-delete-diagnostic (G13.2)" ;;
    mut-consume-to-read)        echo "detect_mutation mut-consume-to-read (G13.3)" ;;
    mut-modify-to-read)         echo "detect_mutation mut-modify-to-read (G13.4)" ;;
    mut-remove-drop-mark)       echo "detect_mutation mut-remove-drop-mark (G13.5)" ;;
    mut-duplicate-drop)         echo "detect_mutation mut-duplicate-drop (G13.6)" ;;
    mut-skip-verifier)          echo "detect_mutation mut-skip-verifier (G13.7)" ;;
    mut-field-offset)           echo "detect_mutation mut-field-offset (G13.8)" ;;
    mut-enum-tag)               echo "detect_mutation mut-enum-tag (G13.9)" ;;
    mut-remove-overflow-check)  echo "detect_mutation mut-remove-overflow-check (G13.10)" ;;
    mut-branch-target)          echo "detect_mutation mut-branch-target (G13.11)" ;;
    mut-remove-wake)            echo "detect_mutation mut-remove-wake (G13.12)" ;;
    mut-remove-atomic-ordering) echo "detect_mutation mut-remove-atomic-ordering (G13.13)" ;;
    mut-equality-to-permissive) echo "detect_mutation mut-equality-to-permissive (G13.14)" ;;
    *)                          echo "$1" ;;
  esac
}
