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

## 4. Conclusion and next lever

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
