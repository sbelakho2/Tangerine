# Bootstrap preflight measurements (non-authorizing engineering log)

These are recorded measurements of the seed VM self-host preflight
(`scripts/profile_ocaml_bootstrap.sh`, standalone: the kernel checks
`tg_compiler/bootstrap_main.tg` over the pinned 45-source manifest closure).
They are NOT authorization evidence — the authorization gate still requires
a completed cold+warm pair and `BOOTSTRAP COMPLETE: PASS`.

## 1. Defects removed (with measured effect)

| Finding | Measurement |
|---|---|
| `apply_cfg_elimination` rebuilt the filtered AST by scanning a Vec of retained spans per item (O(items x retained), recursing into inline modules) | preflight `VM_B_SET_COPIES` 18.1e9 (pre-fix) -> ~1.5e6; `map_scans` 846e6 -> ~5.7e3 in the early phase |
| SHA-256 message schedule built with indexed writes (`w[wi] = ...`) went through `arr_set`, copying the whole array when the container is marked shared | schedule COW removed (`VM_B_SET_COPIES` 1.1e6 -> 89 in the fingerprint phase); permanent `SHA256_VECTOR_BATTERY` pins the FIPS 180-4 vectors |
| Realized scaling of the one-pass cfg elimination | `tg_cfg_scaling`: 256/512/1024/2048 items -> 28.7M / 53.8M / 104.1M / 206.1M VM steps (1.87x / 1.93x / 1.98x per doubling), predicate evals exactly 3n+2 |

## 2. Preflight cold runs (both policies, honestly INCOMPLETE)

Both runs were stopped because VM-step progress stalled while the OCaml
major GC marked an ever-growing live set; the recorded metric blocks carry
`STATUS=INCOMPLETE`, never a fabricated completion.

| Field | `OCAMLRUNPARAM=o=40` (pinned) | `OCAMLRUNPARAM=o=120` (experiment) |
|---|---|---|
| `VM_B_FINAL_STEPS` | 50,800,000,000 (still climbing) | 36,800,000,000 (still climbing) |
| `VM_B_PEAK_LIVE_MB` | 5,695 | 8,044 |
| `VM_B_PEAK_RSS_MIB` | 6,684 | 6,317 |
| `VM_B_SET_COPIES` | 1,486,266 | 1,060,329 |
| `VM_B_MARK_NODES` | 4.75e9 | 3.55e9 |
| last-beacon `dt` | 4.3 s / 100M steps, degrading | 2.8 s -> 16.4 s / 100M steps, degrading |

Phase breakdown (hot functions, cumulative steps): `tg_sha256_hex` ~9.97e9,
`tg_fingerprint_compose` ~6.07e9, `clone` ~2.3e9, `tokenize/lex` ~2.2e9;
the remainder is the checker itself across the closure.

## 3. Calibration provenance guarantees (recently tightened)

- **GC-policy binding**: `repin_bootstrap_limits.py --apply` requires the
  measured `RUN_GC_POLICY` (cold == warm) to equal the authorization
  gate's hard-pinned `OCAMLRUNPARAM`; a repin measured under another
  host-GC policy is refused.  Adopting a new policy is the deliberate,
  atomic `--adopt-gc-policy o=N` path (gate policy + budgets together).
- **Genuine cold/warm**: `profile_ocaml_bootstrap.sh --cold` removes the
  prepared-VM cache so the run rebuilds it; `--warm` requires the cache
  and FAILS unless the run reports `cache_hit=true`.  The metric blocks
  carry `RUN_CACHE_MODE=` and `VM_B_CACHE_HIT=`, and the repinner demands
  exactly one COLD/0 and one WARM/1 (warm/warm can no longer masquerade
  as cold+warm).
- **Outer timeout stays provisional**: standalone calibration (VM B only)
  does not repin `GATE_TIMEOUT_S`; only a completed aggregate run with
  `AGGREGATE_WALL_S` does, because the aggregate gate also runs VM A.
- **Conditioning the A/B**: for identical SHA/seed/manifest/target/closure
  fingerprint the host-GC policy must not change the guest instruction
  stream, so an A/B is only comparable once both runs COMPLETE (final
  steps, host calls, closure fingerprint, semantic outcome) with only
  wall time and peak RSS differing.

## 4. Phase attribution (instrumented runs, file-gated PHASE markers)

With `build/phase_trace.flag` present and
`TANGERINE_DEBUG_GUEST_STREAMS=1`, the check emits PHASE markers that
interleave with the VM beacons, attributing live-set growth to stages
(deterministic run; aarch64-apple-darwin, o=40):

| Marker | Steps | Live |
|---|---:|---:|
| `cfg-done` (guest parse + manifest merge + closure fingerprint + @cfg elimination all complete) | 26.2e9 | 1.57 GB |
| `macro-done` (macro expansion over the merged closure) | 32.0e9 | 3.96 GB |
| `resolve-done` | ~33e9 | ~4 GB |
| `typecheck-begin` → (wall) | 33e9 → 46e9+ | 4–5 GB |

Conclusions: the pre-analysis pipeline (guest parse + merge + the ~10e9-step
closure fingerprint + cfg) already costs 26.2e9 steps; macro expansion
alone adds ~5.8e9 steps and +2.4 GB of live data; and the TYPE CHECK is the
long pole (12e9+ steps and climbing at the wall) with the live set at
~5 GB, where major-GC marking consumes nearly all wall time.  The wall is
therefore inside the checker itself, not MIR/mono.

The completion attempt used `OCAMLRUNPARAM=o=200` (a 5x larger heap space
overhead) with a large RSS cap.  Result: the guest-trACKED live set grows to
17.7 GB (deferred collection) and the same mark-bound wall arrives at
46.9e9 steps — o=200 is WORSE than o=40 for this VM (a larger live set
makes every major cycle more expensive).  The GC-policy sweep is therefore
conclusive:

| Policy | wall reached at | peak guest live | peak RSS |
|---|---:|---:|---:|
| o=40 | 50.8e9 steps | 5.7 GB | 6.7 GiB |
| o=120 | 36.8e9 steps | 8.0 GB | 6.3 GiB |
| o=200 | 46.9e9 steps | 17.7 GB | 6.6 GiB |

No host-GC policy completes this preflight on a 16 GB machine: the wall is
the whole-closure live set (~5 GB at o=40) hitting a mark-bound regime
where GC marking consumes nearly all wall time.  Completion requires
reducing the guest's retained live data (macro expansion already adds
+2.4 GB) or an incremental VM marking strategy — compiler/VM work, not a
budget or policy change.  The outer gate timeout remains provisional.

## 5. Retention-reduction batch (commits 289a42d, 306f777, 8e899b7)

Semantics-preserving live-set/allocation reductions in the analysis path,
each verified by the full kernel battery (`tg_infer: PASS`,
`KERNEL_PARITY_BATTERY fails=0 cases=21`, `CFG_SCALING_BATTERY fails=0`,
`SHA256_VECTOR_BATTERY fails=0`, zero failure rows):

- `prepare_parsed` no longer clones the whole merged AST (in-place macro
  expansion via `expand_macros_inout`); `expand_program_pass` drains and
  writes back items instead of rebuilding a copied Program per pass; the
  per-expanded-item double copies are gone.
- `AnalyzedProgram` no longer carries duplicate deep copies of the AST and
  resolutions (they live once on `typed.ast`/`typed.resolutions`), and the
  duplicate `plan_typed` TypedProgram (its own AST + ~30 table clones) is
  merged away — one TypedProgram literal feeds the deinit-plan walk and is
  then extended with the finished plan table.
- The 11.3 MB closure snapshot is no longer deep-copied at ~13 use/lookup
  sites (read-only observers replace per-site copies; one load per entry).
- `type_env_release_analysis_channels` drops the 33 node-keyed check-only
  channels right after `analyze_program`; the retained readers
  (`env.resolutions`, `fn_class_claims`, `fn_class_names`) are untouched.
- `resource_check_owned(sink cfg, ...)` mutates the pipeline's CFG in place
  (no whole-program CFG copy); dead result snapshots and the duplicated
  DMA-facts table are removed; `access_check_with_snapshot` reuses the
  single engine snapshot instead of building a second one in the context.
- `MonoCache`/`MirBuilder` whole-AST clones were deliberately NOT converted
  (no reference types in the language, the O(1) store-sharing facility is
  module-private to resolver/types, and the AST must live across both
  lowering passes) — documented as deferred.

The pinned-`o=40` preflight completion attempt then re-runs on this batch;
its phase markers measure the new trajectory against the section-4
baseline.

## 6. Post-reduction staircase and the current frontier (428265b)

Re-run of the pinned-`o=40` standalone preflight on the retention batch
(with phase markers and the typechecker submarkers):

| Marker | pre-batch steps / live | post-batch steps / live |
|---|---:|---:|
| cfg-done | 26.2e9 / 1533 MB | 26.2e9 / 1533 MB |
| macro-done | 32.0e9 / 3962 MB | **29.1e9 / 2833 MB** |
| resolve-done | ~33e9 / ~4000 MB | **30.7e9 / 2909 MB** |
| typecheck-begin | ~33e9 | **30.7e9 / 2909 MB** |
| typecheck-bodies-done | not reached | not reached |

The macro-expansion reduction is measured: -2.9e9 steps and -1.13 GB live
at macro-done, and the typecheck now starts ~1.1 GB lower.  Throughput past
the old collapse point is stable (47.9e9 steps at dt=4.7s/100M where the
pre-batch run had collapsed to 20+s and then stalled), and live regions in
the typecheck are ~6.2M (was ~10.4M).

The frontier has nevertheless NOT moved past the typecheck: the run enters
the mark-bound stall at ~47.9e9 steps with live 4714 MB / 6.22M regions,
still before `typecheck-bodies-done` — i.e. inside the whole-closure body
checking itself.  The VM profile at the stall names `clone` (fn502,
1.9e9+ steps and growing) as the active hot function; `TANGERINE_DEBUG_STEPS`
now also dumps the flat `VM FN <index> <name>` map so that instance can be
identified exactly in the next run (several methods share the name
`clone`).

Next lever (staged process): identify fn502 from the next run's `VM FN`
map and attack that specific checker structure's clone/live cost — or
reduce the checker's accumulated per-node channel representation — before
any further measurement or repin.

`VM FN 502 clone` resolved: the dump shows fn502 is an unqualified small
`clone` in the derived-id/type-registration neighborhood
(`derived::TypeId::clone` 498/501, `ClosureId` 500, `TypeVarId` 503,
`GenericParamId` 504/505; layout helpers 508-510).  A small-id clone
consuming 1.9e9+ steps therefore runs on the order of 10^8 times — it is
transient garbage, not retained live: the wall persists because the
STALL's live set (~4.7 GB / 6.2M regions) is the checker's accumulated
whole-program typed channels, which the clone wave keeps feeding while the
major GC marks them.  Two levers remain, in order: (1) a caller-attributed
profile of fn502's call sites to remove the per-operation clone, and
(2) reducing the checker's accumulated per-node channel live.  The FN-map
run was stopped once the map was captured; its frontier matched the
previous run.  `cfg-done` being unchanged confirms the
dep-walk snapshot copies were not on the manifest-closed preflight path.

## 7. Typed-HIR arena conversion (56c442e) and the pre-arena endpoint

The audit identified the structural cause of the ~4.7 GB typecheck live set:
typed expressions, statements and patterns were each stored once in the
flat maps AND recursively embedded (owned copies) inside every ancestor
record, so a leaf was retained once per ancestor (O(depth^2) live).  Three
verified stages now reference children by NodeId instead — every typed
node exists exactly once in `typed_exprs` / `typed_stmts` /
`typed_patterns`; readers resolve ids (`typed_expr_at`, `typed_stmt_at`,
`typed_pattern_at`; missing record = ICE finding); all flat maps stay in
place; behavior is byte-identical (battery twice, plus a baseline-vs-final
guest-report diff showing only the accessors' added definitions).

Pre-arena endpoint measured by the progress trace (post-owner-interning,
before the arena): at item 8064/8334 the checker had recorded
`typed_exprs=507293 typed_stmts=73789 typed_patterns=65927
expr_types=581082 call_targets=74387`, live 4657 MB / 6.23M regions at
48.0e9 steps with dt=4.1s — i.e. the typecheck nearly completed before the
mark-bound cliff; the arena stages remove the per-ancestor duplication of
exactly those volumes.

The decisive post-arena pinned-`o=40` run measured: at item 8064/8334
(identical channel counts: 507070 exprs / 73780 stmts / 65927 patterns /
580843 expr_types), live 4108 MB vs 4657 MB pre-arena (-549 MB, -12%) and
5.98M regions vs 6.23M — the arena removes the per-ancestor duplication
but the whole-closure live set is dominated by the flat per-node channels
themselves.  The run then enters the SAME step-level freeze at ~47.9e9
steps (last typecheck items are the compiler's largest modules): CPU
advances for 25+ minutes with ZERO 100M-step beacon progress, in every
o=40 run regardless of the batch.  The remaining levers are now
(a) per-node channel allocation in the giant-function tail (the flat
map write and the typed record both clone the same values per expression —
migrating consumers to the typed node removes the duplicate writes) and
(b) seed-VM major-GC/mark behaviour on the ~6M-region live set; neither is
a budget or policy change.

## 8. Conclusion and next lever

The cfg quadratic is gone (structural and realized scaling guards enforce
it), and the remaining step cost is legitimate linear work.  The binding
constraint is now **seed-VM live-heap/GC scalability**: the whole-closure
check retains a live set that grows past ~10M regions / 5.7-8.0 GB, and
major-GC marking then consumes nearly all wall time with little VM-step
progress.  A looser GC policy only trades a smaller step count for a larger
heap; it does not remove the wall.

The next engineering step is therefore reducing the preflight's retained
per-item state (or processing the closure incrementally) in the kernel
checker — after which completed cold+warm runs can repin the budgets
(`scripts/repin_bootstrap_limits.py`), the aggregate gate can print
`BOOTSTRAP COMPLETE: PASS`, and the stage1 -> stage2 -> stage3 ladder can
run.
