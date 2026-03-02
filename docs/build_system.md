# Build System, Toolchain, and Reproducibility
## TG-GFX-UI-SPEC-001 v0.1 §20

---

## Toolchain Pinning

| Tool | Version | Purpose |
|------|---------|---------|
| `tg` | pinned via `Tangerine.toml` | Tangerine compiler / test runner |
| `python3` | ≥ 3.10 | Script tests, coverage merge, encoding checks |
| `make` | GNU Make ≥ 4.0 | Build orchestration |

All versions are recorded in `Tangerine.toml`. CI environments use the exact pinned versions.

## Clean Bootstrap

```bash
# From a fresh checkout:
make build          # Compile the Tangerine compiler
make test           # Run core test suites
make test-gfx-ui    # Run GFX/UI module tests
make ci             # Full CI pipeline (lint + fmt-check + test-all + coverage)
```

## Build Profiles

| Profile | Flag | Description |
|---------|------|-------------|
| Debug | `--debug` (default) | Assertions enabled, no optimization, debug symbols |
| Release | `--release` | Optimizations enabled, assertions optional, stripped |
| Sanitizer | `--sanitize=address,thread,undefined` | ASAN/TSAN/UBSAN where supported |

## Artifact Naming

| Artifact | Output Path |
|----------|-------------|
| Compiler binary | `build/tg` |
| Coverage data | `target/cqs/coverage/*.tgcov` |
| Documentation | `target/doc/` |
| Test results | `target/test-results/` |
| GFX/UI gate results | `target/gfx-ui-gates/` |

## Build Safety Rules

1. **Fail fast** on missing required capabilities/dependencies.
2. **Offline build** is supported once dependencies are fetched (documented in README).
3. **Forbidden stub markers** in release targets: automated scan via `make stub-scan`.
4. **Static analysis gates**: `make lint` runs type + dead-code + unreachable-code checks.
5. **Strict warnings**: Release builds treat warnings as errors.
6. **Deterministic build verification**: Same source + toolchain ⇒ matching artifact checksums.
7. **ABI layout regression**: `repr(c)` struct sizes verified in ABI conformance tests.
