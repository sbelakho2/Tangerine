# Tangerine Implementation Checklist

**Source**: `needed.txt` — full specification for Human-First, Agent-Amplified design  
**Generated**: March 1, 2026  
**Status Legend**: `[ ]` = not started, `[~]` = in progress, `[x]` = done

---

## Design Constraint (every feature MUST satisfy all)

- [ ] Helps humans write better code
- [ ] Reduces friction
- [ ] Improves safety and completeness
- [ ] Dramatically reduces agent retries
- [ ] Increases effective context
- [ ] Prevents security drift
- [ ] Prevents partial implementations
- [ ] Does not feel bureaucratic

---

## 1. Progressive Strictness (Zero Bureaucracy, Maximum Power)

### 1.1 Mode System

- [ ] Implement four layered modes:
  - [ ] **Dev** — fast iteration, relaxed enforcement
  - [ ] **Strict** — team reliability, warnings escalate
  - [ ] **Production** — guarantees enforced, build gates
  - [ ] **Hardened** — security-critical environments, strictest enforcement
- [ ] Strictness scales automatically with project maturity
- [ ] Humans prototype freely in Dev mode
- [ ] Agents operate best in Strict/Hardened mode
- [ ] Mode is configurable in `Tangerine.toml`

---

## 2. Contracts That Feel Natural (Not Academic)

### 2.1 Lightweight Inline Contracts (`guard`)

- [ ] `guard` keyword compiles to preconditions
  ```tangerine
  def withdraw(account, amount)
    guard amount > 0
    guard account.balance >= amount
    ...
  end
  ```
- [ ] Reads naturally (no academic syntax)
- [ ] Generates test obligations from guards
- [ ] Guards exposed to agents via semantic metadata

### 2.2 Inferred Contracts

- [ ] Compiler infers contracts from patterns:
  - [ ] Non-null guarantees
  - [ ] Monotonic properties
  - [ ] Range bounds
- [ ] Compiler suggests promotion gently: _"You always check x > 0 before division. Promote to contract?"_
- [ ] Humans get helpful guidance; agents get formalized constraints

---

## 3. Security by Construction (Without Ceremony)

### 3.1 Capability-Based Core

- [ ] No implicit access to:
  - [ ] File I/O
  - [ ] Network
  - [ ] Process
  - [ ] Environment mutation
- [ ] Capabilities passed as parameters (dependency-injection style):
  ```tangerine
  def load_config(path, fs: FS)
  ```
- [ ] Feels like DI, not a burden

### 3.2 Default Secure Profiles

- [ ] Projects declare profile in `Tangerine.toml`:
  ```toml
  profile = "backend"
  ```
- [ ] **Backend profile**:
  - [ ] Allows network
  - [ ] Restricts process spawn
  - [ ] Sandboxes filesystem to project root
- [ ] Humans don't think about it; agents cannot escalate privileges

---

## 4. Stub & Incomplete Implementation Detection (Smart, Not Harsh)

### 4.1 Dev Mode

- [ ] Warn on detected patterns:
  - [ ] Constant returns
  - [ ] `unreachable`
  - [ ] Empty match arms
  - [ ] `TODO` comments

### 4.2 Strict Mode

- [ ] Public APIs must not contain:
  - [ ] Placeholder values
  - [ ] Untested branches
  - [ ] Silent fallthrough

### 4.3 Production Mode

- [ ] Compiler enforces completeness
- [ ] Agents can prototype; humans stay productive

---

## 5. Exhaustiveness Everywhere

- [ ] Pattern matching must be exhaustive:
  ```tangerine
  match result
  when Ok(v)
  when Err(e)
  end
  ```
- [ ] Compiler suggests missing variants automatically
- [ ] Agents can't forget error paths

---

## 6. Typed Effects (Without Pain)

- [ ] Functions can declare effects optionally:
  ```tangerine
  def handler(req)
  effects { net.read, db.read }
  ```
- [ ] If omitted: compiler infers and suggests
- [ ] Only enforced in Strict mode
- [ ] Prevents hidden side effects; agents understand impact

---

## 7. Error Handling Discipline (No Silent Failures)

- [ ] Errors must be:
  - [ ] Propagated (`?`)
  - [ ] Handled
  - [ ] Or explicitly ignored with reason:
    ```tangerine
    save().ignore("non-critical telemetry")
    ```
- [ ] `.ignore("reason")` documents intent
- [ ] Surfaces in audits
- [ ] Helps agents avoid swallowing failures

---

## 8. Context Widening: Make Structure First-Class

### 8.1 Symbol Graph Engine

- [ ] Compiler builds:
  - [ ] Call graph
  - [ ] Type graph
  - [ ] Trait graph
  - [ ] Contract graph
  - [ ] Effect graph
  - [ ] Capability graph
- [ ] Accessible via CLI:
  ```
  tg query callers handler
  tg query effects module:payments
  ```
- [ ] Agents retrieve structured semantic context (not raw text)
- [ ] Humans get better tooling

### 8.2 Context Packs (`tg ctx`)

- [ ] `tg ctx <handler>` returns:
  - [ ] Signature
  - [ ] Callers
  - [ ] Callees
  - [ ] Tests
  - [ ] Contracts
  - [ ] Budgets
  - [ ] Security profile
  - [ ] Recent errors
  - [ ] Ownership model
  - [ ] Known invariants
- [ ] Superior to copying files into prompts

---

## 9. Deterministic Replay & Observability

- [ ] Built-in structured, typed tracing:
  ```tangerine
  emit :payment_attempt, invoice_id: id
  ```
- [ ] Replay system:
  ```
  tg replay case_123
  ```
- [ ] Deterministic scheduler (optional)
- [ ] Agents debug without guesswork; humans reproduce bugs instantly

---

## 10. Budget Enforcement Without Anxiety

- [ ] `@budget time "<5ms"` annotation
- [ ] **Dev**: shows live stats
- [ ] **Strict**: warns on regression
- [ ] **Prod**: fails build
- [ ] Agents don't degrade performance invisibly

---

## 11. Secure Data Types (Prevent Injection by Design)

- [ ] Implement dedicated types:
  - [ ] `SqlQuery` type
  - [ ] `HtmlSafe` type
  - [ ] `Url` type
  - [ ] `Path` type (sandbox-aware)
- [ ] Impossible to pass raw string where structured type required
- [ ] Agents cannot generate SQL injection accidentally

---

## 12. FFI Taint Tracking

- [ ] All FFI-returned values marked "tainted"
- [ ] Must validate before use:
  ```tangerine
  input = c_get_input().validate_utf8()?
  ```
- [ ] Agents can't propagate unsafe memory blindly

---

## 13. Implementation Fullness Enforcement

- [ ] Public modules must include:
  - [ ] At least one integration test
  - [ ] No unexercised branches
  - [ ] No dead code
- [ ] Compiler detects unreachable public branches

---

## 14. Spec-Driven Modules

- [ ] Optional `@spec_module` annotation:
  ```tangerine
  @spec_module
  module Payments
  ```
- [ ] Compiler expects:
  - [ ] Property tests
  - [ ] Invariants
  - [ ] Example flows
- [ ] Humans benefit from structured thinking; agents get explicit targets

---

## 15. Semantic Refactor Primitives

- [ ] Agents call refactor commands (don't rewrite files):
  ```
  tg refactor rename Payment -> Invoice
  tg refactor extract calculate_tax
  ```
- [ ] Compiler guarantees correctness or refuses
- [ ] Humans benefit too

---

## 16. Secure Supply Chain

- [ ] Package manager enforces:
  - [ ] Signed packages
  - [ ] Lockfiles mandatory in prod
  - [ ] Reproducible builds
  - [ ] Dependency trust graph
- [ ] Agents cannot silently pull malicious code

---

## 17. Strong Defaults Against Partial APIs

- [ ] Public API rules in strict mode:
  - [ ] Must have doc example
  - [ ] Must have test
  - [ ] Must define error model
  - [ ] Must not expose raw pointers unless marked `unsafe`
- [ ] Prevents half-finished public surfaces

---

## 18. "Definition of Done" as Config

- [x] Project-level quality config in `Tangerine.toml`:
  ```toml
  [quality]
  require_contracts_for_pub = true
  require_tests_for_pub = true
  forbid_stub_patterns = true
  forbid_unsafe_without_reason = true
  require_budget_for_handlers = true
  ```
- [ ] Humans opt in gradually
- [ ] Agents obey deterministically

---

## 19. Compiler as Advisor, Not Police

- [ ] Compiler suggests (not demands):
  - [ ] Promoting guards to contracts
  - [ ] Consolidating repeated patterns
  - [ ] Adding property tests for complex logic
  - [ ] Security tightening if capability drift detected
- [ ] Feels like senior engineer feedback
- [ ] Agents benefit massively

---

## 20. Retry Reduction (structural guarantees)

- [ ] Intent explicit via contracts
- [ ] Effects visible
- [ ] Stubs detected
- [ ] Tests encouraged
- [ ] Security explicit
- [ ] Context graph queryable
- [ ] Replay deterministic
- [ ] Retries drop drastically

---

## 21. Human Ergonomics (non-negotiable)

- [ ] Dev mode is relaxed
- [ ] Syntax remains clean
- [ ] Guards feel natural
- [ ] Capabilities feel like DI
- [ ] Budgets feel like performance visibility
- [ ] Errors are helpful
- [ ] Tooling is powerful
- [ ] Target feel: _Ruby ergonomics with Rust safety and senior-engineer-level guardrails_

---

## 22. Final Principle

- [ ] Don't build "agent hacks" — build:
  - [ ] Structured
  - [ ] Deterministic
  - [ ] Explicit
  - [ ] Secure
  - [ ] Complete-by-default
  - [ ] Refactor-safe

---

---

# CQS — Completion & Quality System (Formal Specification v0.2)

## 23. CQS Scope & Properties

- [ ] Static detection of incomplete or risky implementations
- [ ] Context-aware interpretation of detections
- [ ] Deterministic scoring of implementation completeness
- [ ] Build-mode dependent enforcement rules
- [ ] Structured reporting for humans and agents
- [ ] CQS MUST:
  - [ ] Avoid AI or heuristic guesswork
  - [ ] Avoid rigid, one-size-fits-all rejection rules
  - [ ] Minimize false positives
  - [ ] Provide actionable feedback
  - [ ] Remain deterministic and reproducible

---

## 24. CQS Definitions

### 24.1 Symbol

- [ ] A function, method, struct, enum, trait, impl, or module

### 24.2 Surface Class (auto-classified at compile time)

- [ ] **PublicStable**: `pub`, not `@experimental`, not in `@experimental` module, referenced by ≥1 non-test external module or exported
- [ ] **PublicExperimental**: `pub` + `@experimental` (or module is `@experimental`)
- [ ] **InternalHotPath**: not public, referenced ≥N times (default N=5), or `@budget`, or `@hot`
- [ ] **InternalGlue**: not public, thin wrapper (<X statements), mostly forwards calls
- [ ] **TestOnly**: only referenced by test modules
- [ ] **PlatformShim**: `@platform(...)` or entirely gated by `cfg(...)`

### 24.3 Evidence Signals (categories)

- [ ] Control-flow signals
- [ ] Data-flow signals
- [ ] Error-handling signals
- [ ] Coverage signals
- [ ] Capability signals
- [ ] Future/Feature-gate signals

### 24.4 Completeness Score

- [ ] Numeric value in range [0, 100] computed per symbol

---

## 25. Evidence Signal Definitions

### 25.1 Control-Flow Signals

- [ ] **CF-1**: Unreachable Branch — entry block has no predecessor OR guard condition statically false
- [ ] **CF-2**: Non-Exhaustive Match — missing known variants without explicit `match_non_exhaustive`
- [ ] **CF-3**: Panic/Unreachable Exit — function exits via `panic`, `unreachable`, `@unimplemented`
- [ ] **CF-4**: Constant Return Dominance — return value is constant AND ≥1 parameter AND parameters not referenced in computation AND body has no side-effecting calls

### 25.2 Data-Flow Signals

- [ ] **DF-1**: Unused Parameter — parameter never read
- [ ] **DF-2**: Output Independent of Inputs — return value does not depend on any input parameters
- [ ] **DF-3**: Dead Assignment — variable assigned but never read
- [ ] **DF-4**: All Branches Return Same Literal — all return paths produce identical literal/constant

### 25.3 Error-Handling Signals

- [ ] **EH-1**: Ignored Result Without Justification — Result value discarded without `?`, `.ok!`, `.ignore("reason")`
- [ ] **EH-2**: Catch-All Without Action — wildcard `_` arm without re-throw, logging, or annotation
- [ ] **EH-3**: Broad Exception Boundary Swallowing — (only if exception interop modes exist)

### 25.4 Coverage Signals (execution-derived, requires `tg test --coverage`)

- [ ] **CV-1**: Unexecuted Public Branch — branch in PublicStable symbol with zero coverage
- [ ] **CV-2**: PublicStable Coverage Below Threshold
  - [ ] Dev: none
  - [ ] Strict: 60%
  - [ ] Production: 75%
  - [ ] Hardened: 85%

### 25.5 Capability Signals

- [ ] **CP-1**: Capability Drift — symbol requires capability not previously required
- [ ] **CP-2**: Unsafe Block Without Reason — missing `reason:` parameter
- [ ] **CP-3**: Tainted FFI Value Used Without Validation

### 25.6 Future Signals

- [ ] **FT-1**: `@future` Blocks — `@future(feature="x")` present; allowed only if feature disabled or config allows
- [ ] **FT-2**: `cfg(feature)` branch enabled but incomplete

---

## 26. CQS Completeness Scoring

### 26.1 Core Score Definition

- [ ] Score initialized at 100
- [ ] Signals subtract weighted penalties: `ScoreRaw(s) = 100 - Σ P(σ,s)`
- [ ] Final score: `Score(s) = clamp(ScoreRaw(s), 0, 100)`

### 26.2 Signal Penalty Model (general form)

- [ ] Each signal instance σ has:
  - [ ] `k`: signal kind (CF-1, DF-1, EH-1, etc.)
  - [ ] `sev`: normalized severity ∈ [0,1]
  - [ ] `n`: occurrence count (if count-based)
  - [ ] `suppr`: suppression decision (1 = suppressed)
- [ ] Each kind has configured parameters:
  - [ ] `w_k`: base weight
  - [ ] `α_k`: count scaling factor
  - [ ] `β_k`: severity exponent
  - [ ] `cap_k`: per-kind cap (optional)
- [ ] Penalty: `P(σ,s) = (1 - suppr) · min(w_k · (sev^β_k) · (1 + α_k · (n-1)), cap_k)`
- [ ] Binary signal defaults: `sev=1, n=1`
- [ ] Count-based defaults: `sev=sevCount(n), n=count`
- [ ] `cap_k` prevents infinite penalty on a single signal

### 26.3 Normalized Severity Functions

- [ ] Binary static signals (CF/DF/EH): `sev = 1` if present
- [ ] Count-based: `sevCount(n; n0, n1) = clamp((n - n0) / (n1 - n0), 0, 1)`
  - [ ] Saturates at `n1`; near-zero below `n0`

### 26.4 Coverage Penalty Normalization

- [ ] Branch coverage ratio: `r_b = branches_covered / branches_total`
- [ ] Threshold `τ_b` depends on surface class + mode
- [ ] Shortfall: `s_b = max(0, τ_b - r_b)`
- [ ] Normalized: `sevCov = s_b / τ_b`
- [ ] CV-2 severity: `sev = sevCov^γ_b`
  - [ ] `γ_b = 1` (Strict, Prod); `γ_b = 2` (Hardened)
- [ ] CV-1 uncovered fraction: `sevUncov(s)` with u0=0.05, u1=0.30

### 26.5 Output-Independence (DF-2) Normalization

- [ ] Dependency ratio: `r_d = |{p ∈ Π' : AffectsReturn(p)}| / |Π'|`
- [ ] Exclude context params (e.g., `fs: FS`, `net: Net`) by default
- [ ] DF-2 severity: `1 - r_d`

### 26.6 Constant-Return Dominance (CF-4) Normalization

- [ ] `c = constant_return_sites / total_return_sites`
- [ ] `k = distinct_constant_values`
- [ ] `sev = clamp((c - c0)/(1 - c0), 0, 1) * clamp(k0/k, 0, 1)`
- [ ] Defaults: `c0 = 0.80`, `k0 = 1`
- [ ] Only fires when ≥80% of returns are constant

---

## 27. CQS Mode Enforcement Matrix

- [ ] Implement mode × surface class enforcement:

| Surface | Dev | Strict | Production | Hardened |
|---|---|---|---|---|
| PublicStable | Warn <70 | Error <threshold | Error <threshold | Error <threshold+ |
| PublicExperimental | Warn only | Warn | Warn | Warn |
| InternalHotPath | Warn | Warn | Warn | Warn |
| InternalGlue | No enforcement | No enforcement | No enforcement | No enforcement |
| TestOnly | No enforcement | No enforcement | No enforcement | No enforcement |
| PlatformShim | Special rules | Special rules | Special rules | Special rules |

---

## 28. Context-Aware Relaxation Rules (Suppressions)

- [ ] Suppress signals if:
  - [ ] Symbol classified `TestOnly`
  - [ ] Branch guarded by `cfg(feature)` (inactive)
  - [ ] Branch marked `@future` (feature disabled)
- [ ] Constant return allowed if type is `Unit` or annotated `@pure_stub`
- [ ] No suppression in Hardened mode unless explicitly allowed
- [ ] Suppression function is deterministic:
  - [ ] `TestOnly` → suppress all signals
  - [ ] Inactive `cfg(feature)` regions → suppress
  - [ ] `@future(feature="x")` with x disabled → suppress
  - [ ] `PlatformShim` kind ∈ {CF-3, CF-4, DF-2} → suppress only if platform-cfg-guarded
- [ ] Hardened mode overrides:
  - [ ] `@future` does not suppress by default (configurable)
  - [ ] PlatformShim suppressions require explicit allowlist in `Tangerine.toml`

---

## 29. CQS Quality Report

### 29.1 Human-Readable Report (`tg quality`)

- [ ] Output per symbol:
  - [ ] Module name
  - [ ] Symbol name
  - [ ] Surface class
  - [ ] Score
  - [ ] Flags (with details)
  - [ ] Suggested actions

### 29.2 JSON Report (`tg quality --json`)

- [~] Machine-readable format for agents
- [~] Implements canonical JSON schema (see §33)

---

## 30. Context Pack Schema (`tg ctx <symbol>`)

- [ ] Returns:
  - [ ] SurfaceClass
  - [ ] CompletenessScore
  - [ ] EvidenceSignals
  - [ ] Callers
  - [ ] Callees
  - [ ] Guards/Contracts
  - [ ] Effects
  - [ ] Capabilities
  - [ ] CoverageSummary
  - [ ] SuggestedNextSteps
- [ ] All deterministic

---

## 31. Required Compiler Passes for CQS

- [ ] CFG builder
- [ ] Def-use analysis
- [ ] Exhaustiveness checker
- [ ] Borrow & lifetime validator
- [ ] Coverage instrumentation
- [ ] Capability usage graph
- [ ] Symbol graph database
- [ ] Surface classification pass
- [ ] Deterministic scoring engine

---

## 32. CQS Determinism Requirement

- [ ] Output MUST be:
  - [ ] Stable across builds
  - [ ] Stable across machines
  - [ ] Independent of timing
  - [ ] Independent of non-deterministic test order

---

## 33. CQS Human-Friendliness Guarantees

- [ ] Never require verbose annotations in Dev mode
- [ ] Never block InternalGlue code
- [ ] Never require tests for experimental APIs
- [ ] Provide actionable suggestions, not vague warnings
- [ ] Allow opt-in strictness via config

---

## 34. CQS Agent Optimization Guarantees

- [ ] Deterministic next actions
- [ ] Explicit structured diagnostics
- [ ] Reduced retry loops
- [ ] Context widening via structured metadata
- [ ] Prevention of incomplete public APIs in release builds

---

## 35. CQS Security Integration

- [ ] Hardened mode:
  - [ ] No capability drift without explicit review flag
  - [ ] No unsafe block without reason
  - [ ] No FFI tainted value may cross boundary without validation
  - [ ] All public branches must be covered by tests

---

---

# CQS Default Parameters (Normative)

## 36. Minimum CompletenessScore Thresholds (gate thresholds)

- [ ] Implement per surface class × mode:

| SurfaceClass | Dev | Strict | Production | Hardened |
|---|---|---|---|---|
| PublicStable | 0 | 75 | 85 | 92 |
| PublicExperimental | 0 | 0 | 0 | 0 |
| InternalHotPath | 0 | 0 | 70 | 80 |
| InternalGlue | 0 | 0 | 0 | 0 |
| TestOnly | 0 | 0 | 0 | 0 |
| PlatformShim | 0 | 0 | 0 | 0 |

- [ ] Dev never gates on score
- [ ] PublicExperimental never gated in v0.2 defaults

---

## 37. Branch Coverage Thresholds (τ_b)

- [ ] Implement per surface class × mode:

| SurfaceClass | Dev | Strict | Production | Hardened |
|---|---|---|---|---|
| PublicStable | 0.00 | 0.60 | 0.75 | 0.85 |
| PublicExperimental | 0.00 | 0.00 | 0.00 | 0.00 |
| InternalHotPath | 0.00 | 0.40 | 0.60 | 0.70 |
| Others | 0.00 | 0.00 | 0.00 | 0.00 |

### 37.1 Uncovered Branch Fraction Parameters (CV-1)

- [ ] `u0 = 0.05` — ≤5% has near-zero severity
- [ ] `u1 = 0.30` — ≥30% saturates

### 37.2 Coverage Shortfall Exponent (γ_b)

- [ ] Strict: `γ_b = 1`
- [ ] Production: `γ_b = 1`
- [ ] Hardened: `γ_b = 2` (punishes being below threshold harder)

---

## 38. Default Signal Parameter Table

### 38.1 Control-Flow Signals (CF)

| Kind | Meaning | w | α | β | cap |
|---|---|---|---|---|---|
| CF-1 | Unreachable branch/block | 8 | 0.15 | 1.0 | 20 |
| CF-2 | Non-exhaustive match | 15 | 0.0 | 1.0 | 30 |
| CF-3 | Panic/unreachable as normal exit | 18 | 0.0 | 1.0 | 40 |
| CF-4 | Constant-return dominance | 10 | 0.0 | 1.0 | 25 |

- [ ] CF-4 normalization defaults: `c0 = 0.80`, `k0 = 1`
- [ ] CF-4 severity: `sev = clamp((c-c0)/(1-c0), 0, 1) * clamp(k0/k, 0, 1)`

### 38.2 Data-Flow Signals (DF)

| Kind | Meaning | w | α | β | cap | norm |
|---|---|---|---|---|---|---|
| DF-1 | Unused parameter | 4 | 0.20 | 1.0 | 18 | sevCount(n; n0=0, n1=3) |
| DF-2 | Output independent of inputs | 10 | 0.0 | 1.0 | 25 | sev=1-r_d |
| DF-3 | Dead assignment | 3 | 0.15 | 1.0 | 15 | sevCount(n; n0=0, n1=5) |
| DF-4 | All branches return same literal | 8 | 0.0 | 1.0 | 20 | binary |

- [ ] DF-2: exclude `@context_param` parameters by default
- [ ] DF-2: treat `AffectsReturn` as def-use path to return or side-effecting operation for InternalGlue

### 38.3 Error-Handling Signals (EH)

| Kind | Meaning | w | α | β | cap |
|---|---|---|---|---|---|
| EH-1 | Ignored Result without justification | 12 | 0.20 | 1.0 | 30 |
| EH-2 | Catch-all without action/reason | 8 | 0.0 | 1.0 | 20 |
| EH-3 | Broad exception boundary swallowing | 14 | 0.0 | 1.0 | 30 |

- [ ] EH-3 applies only if Tangerine enables exception interop modes

### 38.4 Coverage Signals (CV)

| Kind | Meaning | w | α | β | cap |
|---|---|---|---|---|---|
| CV-1 | Uncovered public branches present | 10 | 0.0 | 1.0 | 20 |
| CV-2 | Coverage below threshold | 20 | 0.0 | 1.0 | 35 |

- [ ] CV-1 severity: `sevUncov(s)` formula with u0/u1
- [ ] CV-2 severity: `(sevCov(s))^γ_b`

### 38.5 Capability & Unsafe Signals (CP)

| Kind | Meaning | w | α | β | cap |
|---|---|---|---|---|---|
| CP-1 | Capability drift | 10 | 0.0 | 1.0 | 25 |
| CP-2 | Unsafe block without reason | 20 | 0.0 | 1.0 | 40 |
| CP-3 | Tainted FFI value without validation | 18 | 0.0 | 1.0 | 40 |

- [ ] CP-1 uses baseline file `.tg/baseline_caps.json` from last release build

### 38.6 Future/Feature Gating Signals (FT)

| Kind | Meaning | w | α | β | cap |
|---|---|---|---|---|---|
| FT-1 | `@future` block in enabled feature | 8 | 0.0 | 1.0 | 20 |
| FT-2 | `cfg(feature)` enabled but incomplete | 10 | 0.0 | 1.0 | 25 |

---

## 39. Default Suppression Policy (Deterministic)

- [ ] Always suppress: `TestOnly` → all signals
- [ ] Conditional suppressions:
  - [ ] Inactive `cfg(feature)` region → suppress
  - [ ] `@future(feature="x")` with x disabled → suppress
  - [ ] `PlatformShim` + kind ∈ {CF-3, CF-4, DF-2} → only if platform-cfg-guarded
- [ ] Hardened overrides:
  - [ ] `@future` does not suppress by default (configurable)
  - [ ] PlatformShim suppressions require explicit allowlist

---

## 40. Default sevCount Parameters by Kind

- [ ] DF-1 unused params: `n0=0, n1=3`
- [ ] DF-3 dead assigns: `n0=0, n1=5`
- [ ] CF-1 unreachable branches: `n0=0, n1=2`
- [ ] EH-1 ignored results: `n0=0, n1=2`

---

## 41. Module / Package Score Aggregation

### 41.1 Module Score

- [ ] Weighted mean over symbols: `Score_M = Σ(w_class(s) · Score(s)) / Σ(w_class(s))`
- [ ] Default symbol weights:
  - [ ] PublicStable: 4
  - [ ] PublicExperimental: 2
  - [ ] InternalHotPath: 3
  - [ ] InternalGlue/TestOnly: 1 (or 0 to ignore)
  - [ ] PlatformShim: 2

### 41.2 Package Score

- [ ] Same formula over all modules

---

---

# CQS JSON Schema (Normative)

## 42. Top-Level `tg quality --json` Object

- [ ] Required fields:
  - [ ] `schema_version` (string)
  - [ ] `tangerine.edition`, `tangerine.tgc_version`, `tangerine.target`, `tangerine.mode`
  - [ ] `config_hash` (SHA256 of effective CQS config)
  - [ ] `package` (name, version, source)
  - [ ] `summary`
  - [ ] `modules`

## 43. Summary Object

- [ ] `symbols_total`, `symbols_scored`
- [ ] `avg_score_weighted`, `min_score`
- [ ] `gated_failures`
- [ ] `signals_total`
- [ ] `top_signal_kinds` (array of {kind, count})

## 44. Module Array Items

- [ ] `module_path`
- [ ] `module_score_weighted`
- [ ] `symbols` array

## 45. Symbol Entry

- [ ] `symbol_id` — stable across builds for same edition and unchanged symbol
- [ ] `name`, `kind`
- [ ] `span` — {file, start, end}
- [ ] `surface_class`
- [ ] `score`, `score_raw`, `penalty_total`
- [ ] `coverage` — {branches_total, branches_covered, branch_ratio, threshold}
- [ ] `capabilities` — {required, drift}
- [ ] `signals` array
- [ ] `suggested_actions` array

## 46. Signal Entry

- [ ] Required: `kind`, `severity`, `count`, `suppressed`, `penalty`, `locations`
- [ ] `weight`, `alpha`, `beta`, `cap`
- [ ] `details` — required but may be `{}`

## 47. Suggested Action Entry

- [ ] Required: `action_id`, `priority`, `title`, `patches`, `tests_to_run`
- [ ] `patches` array: {type, format, payload}
  - [ ] `type = "ast_patch"`, `format = "tgc-ast-patch-v1"`
- [ ] `confidence` — derived from whether patch is semantics-preserving (deterministic rule, no AI)

---

## 48. Default CQS Config in Tangerine.toml

- [x] Implement CQS config section:
  ```toml
  [cqs]
  mode = "Production"

  [cqs.thresholds]
  public_stable_min_score = 85
  public_stable_branch_cov = 0.75

  [cqs.weights]
  CF_1 = 8
  CF_2 = 15
  CF_3 = 18
  CF_4 = 10
  DF_1 = 4
  DF_2 = 10
  DF_3 = 3
  DF_4 = 8
  EH_1 = 12
  EH_2 = 8
  CV_1 = 10
  CV_2 = 20
  CP_1 = 10
  CP_2 = 20
  CP_3 = 18
  FT_1 = 8
  FT_2 = 10
  ```

---

---

# CQS Signal Detection Algorithms (Normative)

## 49. IR Level and Determinism

- [ ] All CQS detection performed on typed MIR (preferred) or SSA after MIR verification, with source spans preserved
- [ ] CF/DF/EH signals: MIR-level normative
- [ ] Coverage mapping: MIR branch points normative
- [ ] Capability/taint: MIR call/effect metadata + type info
- [ ] Deterministic ordering:
  - [ ] Functions in stable symbol-id order
  - [ ] Basic blocks in numeric order
  - [ ] Statements in sequence order
  - [ ] Edges in sorted (from_bb, to_bb) order
  - [ ] Signals emitted sorted by (kind, file, start, end)

---

## 50. CFG Construction for CQS

### 50.1 Basic Blocks

- [ ] Maximal sequence of MIR statements ending in a terminator
- [ ] Entry block: `bb0`
- [ ] Terminators define outgoing edges:
  - [ ] `Goto(t)` → edge bb → t
  - [ ] `Branch(c, t, f)` → edges bb→t and bb→f
  - [ ] `SwitchInt`/`SwitchEnum` → edges bb→case_bb + optional other_bb
  - [ ] `Return`/`Panic`/`Unreachable` → no outgoing edges

### 50.2 Reachability

- [ ] Compute from entry: `Reach(bb0) = true`
- [ ] DFS/BFS using outgoing edges
- [ ] Block unreachable if `Reach(bb) = false`

---

## 51. Branch Point Definition (Coverage & CF Signals)

### 51.1 Branch Point Set

- [ ] Every `Branch(cond, t, f)` terminator → 1 branch point, 2 arms
- [ ] Every `SwitchInt` terminator → 1 branch point, N+1 arms (cases + other)
- [ ] Every `SwitchEnum` terminator → 1 branch point, N arms (variants)
- [ ] No other constructs count as branches

### 51.2 Branch Arm IDs (stable)

- [ ] `arm_id = hash(function_symbol_id, bb_id, terminator_index, arm_index, target_bb_id)`
- [ ] Ordering:
  - [ ] Branch: true=0, false=1
  - [ ] SwitchInt: cases in increasing value order; other last
  - [ ] SwitchEnum: variants in declaration order; other last

---

## 52. CF Signal Detection Algorithms

### 52.1 CF-1 Unreachable Branch/Block

- [ ] Emit if any block unreachable AND span maps to source not inside inactive `cfg`/disabled `@future`
- [ ] One signal per function: `count = unreachable_blocks_with_source_spans`
- [ ] Locations: first K=10 spans + count_total

### 52.2 CF-2 Non-Exhaustive Match

- [ ] SwitchEnum must have one arm per variant of closed enum, NO other arm
- [ ] Emit if missing tag cases OR `bb_other` exists and source match is not `match_non_exhaustive`
- [ ] MIR must record: `switch_origin = {kind: MatchExpr, explicit_non_exhaustive: bool}` + enum type + variant list

### 52.3 CF-3 Panic/Unreachable as Normal Exit

- [ ] Emit if reachable blocks contain: terminator `Panic` OR `Unreachable` OR `Assert(false, ...)` AND span not suppressed by PlatformShim+cfg or @future(disabled)
- [ ] `count = panic-like sites`

### 52.4 CF-4 Constant-Return Dominance

- [ ] Compute return sites as `Return(op?)` terminators in reachable blocks
- [ ] Compute ReturnForm per site:
  - [ ] `Const(value_kind, normalized_value)` for constant operands
  - [ ] Normalized structured constant (e.g., `Ok(Unit)`)
  - [ ] `NonConst` otherwise
- [ ] Normalization: numeric by exact bit pattern, strings by contents hash, `Ok(Unit)` as literal
- [ ] Metrics: `R = total return sites`, `C = constant-form sites`, `c = C/R`, `k = distinct constants`
- [ ] Emit CF-4 if: `R > 0` AND `c ≥ c0` (0.80) AND function has ≥1 non-context parameter or is PublicStable/InternalHotPath
- [ ] Payload includes `c` and `k`

---

## 53. DF Signal Detection Algorithms (Def-Use)

### 53.1 Build Def-Use Graph (per function)

- [ ] Definition = assignment to local/SSA temp or MIR local
- [ ] Use = reading an operand referencing that local
- [ ] MIR specifics:
  - [ ] `Assign(place, rvalue)` defines `place.base`
  - [ ] `Operand::Copy(place)` and `Operand::Move(place)` use `place.base`
  - [ ] `Rvalue::Ref(..., place)` uses `place.base`
  - [ ] Terminator arguments use locals similarly
- [ ] Build UseFromDef links via forward dataflow / SSA / reaching defs via dominance

### 53.2 DF-1 Unused Parameter

- [ ] Uses(p) empty → count as unused
- [ ] Exclude `@unused_ok` or `_`-prefixed names
- [ ] Exclude context params typed as capability types (FS, Net, Db) unless config overrides
- [ ] Emit DF-1: `count = unused_param_count`, locations = parameter spans

### 53.3 DF-3 Dead Assignment

- [ ] Assignment dead if defined value doesn't reach any use before overwrite/scope-exit
- [ ] SSA: value with zero uses; MIR: liveness analysis (backwards), LiveOut sets
- [ ] Emit DF-3: `count = dead_assigns`

### 53.4 DF-2 Output Independent of Inputs (AffectsReturn)

- [ ] Define observable sinks:
  - [ ] Return operand at `Return`
  - [ ] For InternalGlue: also side-effect calls (logging, IO, capability calls)
  - [ ] Side-effect calls identified by effect metadata
- [ ] Build dependency graph G over locals/SSA values:
  - [ ] Edge L1→L2 if L2 computed using L1
  - [ ] Add sink nodes for each observable sink
- [ ] `AffectsReturn(p) = true` if any sink reachable from p
- [ ] `r_d = |{p ∈ Π': AffectsReturn(p)}| / |Π'|` (excluding context params)
- [ ] Emit DF-2 if `r_d < 1.0`, severity = `1 - r_d`

---

## 54. EH Signal Detection Algorithms (Result Discipline)

### 54.1 Identify Result-Typed Expressions

- [ ] At MIR: every rvalue/operand has a type; detect `Result[T,E]`

### 54.2 EH-1 Ignored Result

- [ ] A Result is "ignored" if produced in statement position and NOT:
  - [ ] Propagated via `?` (Try lowering marker)
  - [ ] Consumed by `.ok!`
  - [ ] Consumed by `.ignore(reason)`
  - [ ] Matched/handled
- [ ] MIR must annotate: `result_handling = Propagate | OkBang | Ignore(reason_span) | Handled | Unknown`
- [ ] Fallback: call result assigned to temp and immediately dropped → ignored
- [ ] Emit EH-1: count + locations + suggested fix (`add ?` if function returns Result)

### 54.3 EH-2 Catch-All Without Action

- [ ] Wildcard `_` arm metadata from match lowering
- [ ] Emit if arm body does NOT: re-throw, log/emit trace, contain `ignore(reason)`, include `@default(reason="...")` annotation

---

## 55. Coverage Signal Mapping Rules

### 55.1 Instrumentation Points

- [ ] Instrument branch arms (§51): increment counter when control enters arm target block
- [ ] Counters stable, written to coverage artifact

### 55.2 Coverage Artifact Format (normative minimal)

- [ ] Per function symbol ID: total branch arms, hit count per arm ID

### 55.3 CV-1 and CV-2

- [ ] CV-1: uncovered fraction > u0 for PublicStable in Strict/Prod/Hardened
- [ ] CV-2: branch ratio < threshold τ_b
- [ ] Severity computed as specified

---

## 56. Capability Signal Detection Algorithms

### 56.1 Capability Set Extraction

- [ ] Direct caps: parameters typed as capability types (Net, FS, Proc, Db)
- [ ] Transitive caps: from callees' required caps
- [ ] Effect-to-cap mapping:
  - [ ] `net.read/write` → `NetCap`
  - [ ] `fs.read/write` → `FsCap` (or `FsReadCap` if reads only)
  - [ ] `process.spawn` → `ProcCap`
  - [ ] `ffi.call` → `FfiCap`
- [ ] Unsafe blocks → include `UnsafeCap`
- [ ] Optional allowlist exclusions for InternalGlue pass-through

### 56.2 CP-1 Capability Drift

- [ ] Drift set = current caps − baseline caps
- [ ] Emit if drift set non-empty
- [ ] Severity: `|drift| / max(|drift|, n_cap_max)` where `n_cap_max = 10`

### 56.3 CP-2 Unsafe Block Without Reason

- [ ] Unsafe blocks must be: `unsafe(reason: "...")`
- [ ] Lowering preserves `reason_span`
- [ ] Emit if missing or empty reason

### 56.4 CP-3 Tainted FFI Use Without Validation

- [ ] Taint sources:
  - [ ] Any extern call return (unless `@ffi(trusted=true)`)
  - [ ] Any pointer from FFI
  - [ ] Any string view from FFI
- [ ] Validation sinks (untaint via):
  - [ ] `.validate_utf8()?` for strings
  - [ ] `.checked_len(max)?` for slices
  - [ ] `.validate_enum(...)` for tags
  - [ ] `.assume_valid(reason)` inside unsafe block
- [ ] Emit CP-3 if tainted value reaches: parsing, file/network/process calls, SQL/HTML sinks without passing validator
- [ ] Uses same dependency reachability graph as DF-2

---

## 57. Future/Feature Signal Detection Algorithms

### 57.1 FT-1 `@future(feature="x")`

- [ ] Lowering tags spans as `Future(feature=x)`
- [ ] Emit FT-1 if feature x is enabled and future block is present

### 57.2 FT-2 `cfg(feature)` Incomplete

- [ ] Active cfg-gated region containing CF-3 or CF-4 → emit FT-2 as meta-signal

---

## 58. Special-Case False-Positive Reduction Rules

### 58.1 Wrapper Functions (InternalGlue)

- [ ] DF-2: observable sinks include side-effect calls
- [ ] CF-4: suppressed unless tagged `@hot` or `@budget`

### 58.2 Platform Shims

- [ ] CF-3 suppressed iff unreachable/panic inside platform-inactive branch

### 58.3 Unit-Returning Functions

- [ ] CF-4 constant-return dominance suppressed by default

---

## 59. Required CQS Conformance Test Suite (compiler must ship)

- [ ] CFG reachability golden tests
- [ ] Branch point enumeration stability golden tests
- [ ] Def-use dependency correctness golden tests
- [ ] Result ignore detection correctness golden tests
- [ ] Taint validation path correctness golden tests
- [ ] Match exhaustiveness detection golden tests
- [ ] Drift baseline correctness golden tests
- [ ] Each test MUST assert:
  - [ ] Emitted signal kinds + counts
  - [ ] Severity values (exact decimals; rational where possible)
  - [ ] Spans and symbol IDs stable

---

---

# Coverage Artifact Specification (Normative)

## 60. Coverage Artifact Purpose & Properties

- [ ] Records branch-arm hits for CQS canonical branch points
- [ ] Enables CV-1 and CV-2 signals
- [ ] Stable cross-run comparisons
- [ ] Stable mapping of hits to source locations
- [ ] Merging across parallel test runs
- [ ] Branch arms only (not statement coverage)

---

## 61. Artifact Identity & Location

### 61.1 File Name and Location

- [ ] Default output: `target/cqs/coverage/`
- [ ] Default name: `coverage.tgcov`
- [ ] Per-test: `coverage.<test_id>.tgcov`

### 61.2 Versioning Fields

- [ ] `schema_version` (string)
- [ ] `edition`
- [ ] `tgc_version`
- [ ] `target_triple`
- [ ] `branch_id_scheme` (string literal)
- [ ] `build_id` (hash of code + config + compiler)

---

## 62. Coverage Stable IDs

### 62.1 Symbol IDs

- [ ] Format: `sym:<module_path>::<name>#<stable_hash>`
- [ ] Hash from (edition, module path, symbol name, signature shape) — NOT from spans

### 62.2 Branch Point IDs

- [ ] Stable across builds if MIR control structure semantically unchanged + same compiler/edition
- [ ] `branch_id = SHA256("tg.branch.v1" ‖ sid ‖ bb ‖ ti ‖ kind)` (hex)

### 62.3 Arm IDs

- [ ] `arm_id = SHA256("tg.arm.v1" ‖ branch_id ‖ arm_index ‖ target_bb)` (hex)
- [ ] Arm ordering:
  - [ ] Branch: 0=true, 1=false
  - [ ] SwitchInt: cases sorted ascending; other last
  - [ ] SwitchEnum: declaration order; other last

---

## 63. Source Mapping

- [ ] Each branch arm record includes:
  - [ ] `span: {file, start, end}` for origin match/if expression
  - [ ] `arm_span: {file, start, end}` for arm body (best-effort)
- [ ] Spans may be omitted in optimized builds; `tg quality` must still compute ratios

---

## 64. Coverage File Format: tgcov (JSON Lines)

### 64.1 Header Object (line 1)

- [ ] `schema_version`, `edition`, `tgc_version`, `target`
- [ ] `branch_id_scheme`, `arm_id_scheme`
- [ ] `build_id`, `timestamp_utc`

### 64.2 Record Objects (lines 2..N)

- [ ] Required: `symbol_id`, `branch_id`, `arm_id`, `kind`, `arm_index`, `hits`
- [ ] Optional: `span`, `arm_span`, `target_bb`

---

## 65. Instrumentation Rules (Compiler Obligations)

### 65.1 Debug vs Release

- [ ] Available in `tg test --coverage` builds
- [ ] Optional in `tg run --coverage`
- [ ] MUST NOT change program semantics

### 65.2 Thread Safety

- [ ] Hit counters: atomic increments or thread-local counters merged on exit

### 65.3 Overhead Control

- [ ] May sample/compress; when enabled, semantics must match

---

## 66. Merging Coverage Artifacts

### 66.1 Merge Operator

- [ ] `hits(arm_id) = hitsA + hitsB`

### 66.2 Merge Constraints

- [ ] Merge only if `edition`, `tgc_version`, `target`, `build_id`, and ID schemes all identical
- [ ] Mismatch → hard error

### 66.3 Merge Output

- [ ] Same schema with summed hits

---

## 67. Computing Branch Coverage Ratio (Normative)

- [ ] Per function symbol:
  - [ ] `arms_total = |A(s)|` (all arm_ids expected by compiler)
  - [ ] `arms_covered = count(arm where hit ≥ 1)` (0 if absent)
  - [ ] `branch_ratio = arms_covered / arms_total` (or 1 if total=0)
- [ ] This is the canonical ratio for CV-2

---

---

# Capability Drift Baseline Artifact Specification (Normative)

## 68. Purpose

- [ ] Detect CP-1: when function/module begins requiring new capabilities vs baseline
- [ ] Prevents accidental security footprint expansion

---

## 69. Capability Vocabulary (v0.2)

- [ ] Normative capability IDs:
  - [ ] `NetCap` (network)
  - [ ] `FsCap` (filesystem read/write)
  - [ ] `FsReadCap` (read-only subset)
  - [ ] `ProcCap` (process spawn)
  - [ ] `EnvCap` (environment mutation)
  - [ ] `DbCap` (database access)
  - [ ] `ClockCap` (system time / nondeterminism)
  - [ ] `RandomCap` (cryptographic randomness)
  - [ ] `FfiCap` (calling extern)
  - [ ] `UnsafeCap` (unsafe blocks present)
- [ ] Custom caps must be namespaced: `MyOrg::SecretsCap`

---

## 70. Baseline File

### 70.1 Location

- [ ] Default: `.tg/cqs/baseline_caps.json`
- [ ] Generated by `tg quality --bless` (Production/Hardened) or `tg release`

### 70.2 JSON Format

- [ ] Required header: `schema_version`, `edition`, `tgc_version`, `target`, `build_id`, `generated_utc`
- [ ] `package`: {name, version}
- [ ] `symbols` array: each {symbol_id, surface_class, caps[]}
- [ ] `modules` array (optional): each {module_path, caps[]}

---

## 71. Capability Extraction Algorithm

- [ ] Direct caps: parameter types (Net, FS, Proc, Db) → cap IDs
- [ ] Transitive caps: union of callee caps
- [ ] Effect-to-cap mapping: `net.read/write→NetCap`, `fs.read/write→FsCap/FsReadCap`, `process.spawn→ProcCap`, `ffi.call→FfiCap`
- [ ] Unsafe blocks → `UnsafeCap`
- [ ] Optional allowlist exclusions for InternalGlue pass-through

---

## 72. Drift Detection (CP-1)

- [ ] Drift = current_caps − baseline_caps
- [ ] Emit CP-1 if drift non-empty
- [ ] Severity: `|drift| / max(|drift|, n_cap_max)` where `n_cap_max = 10`
- [ ] Details include new caps list and baseline caps list

---

## 73. Baseline Lifecycle Rules

### 73.1 Blessing

- [ ] Only updated by: `tg quality --bless` or `tg release`
- [ ] `--bless` requires clean build + tests + optional approval token

### 73.2 Matching Constraint

- [ ] Same edition, same target
- [ ] Compatible tgc_version range (default: exact match)
- [ ] Baseline `build_id` must match current graph (or `build_id_any=true` for flexible; default false)

### 73.3 Multi-Target Projects

- [ ] Separate baseline per target: `.tg/cqs/baseline_caps.<target>.json`

---

## 74. Integration Requirements for `tg quality`

- [ ] Consumes: symbol graph + CQS signals + optional coverage artifact(s) + optional baseline caps
- [ ] If coverage missing: coverage signals omitted, fields marked `available=false`
- [ ] If baseline missing: CP-1 omitted, marked `baseline_available=false`
- [ ] Non-annoying in dev

---

---

# Coverage Branch Enumeration Stability (Normative Addendum)

## 75. Branch Anchors (source-level, not IR-level)

- [ ] Every branch point assigned a `BranchAnchor` at HIR lowering time (before optimizations)
- [ ] BranchAnchor tuple:
  - [ ] `origin_kind` ∈ {IfExpr, WhileExpr, MatchExpr, ShortCircuit, Guard, Desugar}
  - [ ] `origin_span` = (file, start, end) of original syntactic construct
  - [ ] `path` = stable structural path within HIR AST: `[2, 0, 4, 1]` (child indices from root to node)
- [ ] `path` computed from desugared HIR tree using stable child ordering from grammar/spec

---

## 76. Stable Branch ID (source-anchored)

- [ ] Computed from BranchAnchor (not incidental block IDs)

---

## 77. Stable Arm IDs

- [ ] Discriminants:
  - [ ] If/while: `"then"`, `"else"`, `"body"`, `"exit"`
  - [ ] Match enum: `"Variant::<name>"` in declared enum order
  - [ ] Match int: `"case::<value>"` in sorted value order; `"other"` last
  - [ ] Short-circuit: `"lhs_true"`, `"lhs_false"`, etc. (spec-defined)

---

## 78. Optimization Preservation Rules (Compiler Obligations)

- [ ] All transformations MUST maintain an `AnchorMap`
- [ ] Duplicated branches (e.g., inlining): inherit same anchor only if same source span + HIR path; otherwise derived anchor with appended path suffix
- [ ] Merged branches: least common ancestor anchor only when semantics correspond to single original construct; otherwise `origin_kind=Desugar` + fresh anchor
- [ ] Eliminated branches: simply disappear; expected arm set computed from same anchoring pipeline → IDs remain stable

---

## 79. Coverage Correctness Contract

- [ ] `tgc` MUST compute expected arm set using same BranchAnchor rules
- [ ] CV-1/CV-2 operate on anchor-based IDs
- [ ] NO dependence on basic-block numbering

---

---

# `.tg/cqs/` Directory Layout Specification

## 80. Required Layout

```
.tg/
  cqs/
    version.json
    baselines/
      caps/
        baseline_caps.<target>.json
      quality/
        baseline_quality.<target>.json
    coverage/
      runs/
        <build_id>/
          coverage.merged.tgcov
          coverage.<test_id>.tgcov   (optional)
    reports/
      quality.<build_id>.json
      quality.<build_id>.txt
    cache/
      index.<build_id>.tgindex
      symbol_graph.<build_id>.bin
```

- [x] Implement all directories and file naming conventions
- [x] `version.json` contains `schema_version`, `edition`, `tgc_version`
- [x] `<target>` = toolchain target triple (e.g., `x86_64-unknown-linux-gnu`)

---

---

# Reference Implementation Behaviors

## 81. `tg cov merge` (Reference Behavior)

- [ ] Command: `tg cov merge --in <dir>/*.tgcov --out <merged>.tgcov`
- [ ] Read header of first file as canonical header H
- [ ] For each input file: validate `schema_version`, `edition`, `tgc_version`, `target`, `branch_id_scheme`, `arm_id_scheme`, `build_id` all equal H; mismatch → hard error
- [ ] For each record: key by `(symbol_id, arm_id)`, accumulate hits by integer addition
- [ ] Emit merged file with same header + `merged_from_count`
- [ ] Records sorted lexicographically by `(symbol_id, arm_id)`
- [ ] Complexity: O(N log N) for sorting

---

## 82. `tg quality --bless` (Reference Behavior)

- [ ] Verify clean working tree (unless `--allow-dirty`)
- [ ] Build with selected mode profile: `tg build --mode <mode>`
- [ ] If `--with-coverage`: run `tg test --coverage`, then `tg cov merge`
- [ ] Run CQS: `tg quality --json --out .tg/cqs/reports/quality.<build_id>.json`
- [ ] Enforce gating: if any gated failures → abort; no baseline written
- [ ] Write/update:
  - [ ] `.tg/cqs/baselines/caps/baseline_caps.<target>.json`
  - [ ] `.tg/cqs/baselines/quality/baseline_quality.<target>.json`
- [ ] Baseline files include: edition, tgc_version, target, build_id, config_hash, timestamp
- [ ] Optional (v0.3): sign baselines with `.sig` file

---

---

# Context Widening System (CWS) — Formal Specification

## 83. Canonical Project Graphs (built by `tg index`)

- [ ] Multi-graph G over symbols:
  - [ ] Call graph G_call: f→g if f calls g
  - [ ] Type graph G_type: f→T if f uses type T
  - [ ] Trait graph G_trait: T→Trait, Trait→impl
  - [ ] Effect/capability graph G_effect: f→cap, f→effect
  - [ ] Test graph G_test: test→f if test covers/targets f
  - [ ] File containment G_file: f→file
- [ ] All nodes have stable IDs; all edges deterministic

---

## 84. Seed Set Construction

- [ ] From compiler diagnostics: referenced symbol IDs in spans + immediate definitions
- [ ] From failing tests: failing test node + symbols on failure stack
- [ ] From CQS signals: symbols with gated failures
- [ ] From user prompt: explicitly named modules/types/functions (exact match)
- [ ] Deterministic

---

## 85. Program Slicing (Guaranteed Relevance)

- [ ] Per seed s:
  - [ ] Backward slice B(s): everything that can affect s's observable behavior
  - [ ] Forward slice F(s): everything s can affect
- [ ] Uses System Dependence Graph (SDG): nodes=statements/defs; edges=data+control dependence
- [ ] Slice computed by reachability; complexity O(V+E)
- [ ] Yields highly relevant symbols/spans, often far smaller than whole project

---

## 86. Context Selection as Optimization Problem

### 86.1 Candidate Items

- [ ] Symbol summary (signature/effects/contracts/tests)
- [ ] Minimal code excerpt spans (definition + key blocks)
- [ ] Relevant test excerpts
- [ ] Relevant trait/impl entries
- [ ] Each item i has: size c_i (bytes/tokens), coverage relation to needs

### 86.2 Needs Universe U

- [ ] Atomic needs:
  - [ ] "know signature of symbol x"
  - [ ] "know invariants/guards of x"
  - [ ] "know callee y called by x"
  - [ ] "know error enum variants"
  - [ ] "know capability requirements"
  - [ ] "know failing test expectation"

### 86.3 Utility Function (submodular, provable greedy)

- [ ] Weighted coverage: `F(S) = Σ_u w_u · 1[∃ item in S covering u]`
- [ ] Weights w_u prioritize: public stable APIs, failing tests, security boundaries
- [ ] F is monotone submodular

### 86.4 Budgeted Selection (knapsack submodular maximization)

- [ ] Greedy: repeatedly add item maximizing F(S ∪ {i}) − F(S) / c_i
- [ ] Guarantee: greedy achieves ≥ (1 − 1/e) of optimum (classic result)

---

## 87. Graph-Distance Weighting

- [ ] Distance d(v, Seeds) in unified symbol graph
- [ ] Relevance weight: `rel(v) = e^{−α · d(v, Seeds)}`
- [ ] Decays with distance but allows wide capture when budget permits

---

## 88. Two-Layer Context Pack

### 88.1 Layer 1: Symbol Summaries (cheap, wide)

- [ ] Top K relevant nodes include only:
  - [ ] Signature
  - [ ] Effects/caps
  - [ ] Contracts/guards
  - [ ] Error types
  - [ ] Direct callees/callers
  - [ ] Test links
- [ ] Compact and deterministic

### 88.2 Layer 2: Code Spans (expensive, selective)

- [ ] Small set selected by submodular optimizer:
  - [ ] Definition span
  - [ ] Slice-relevant blocks
  - [ ] Failing test span
- [ ] Agent "sees" whole project as summaries + full code only where it matters

---

## 89. Scaling & Incremental Maintenance

- [ ] `tg index` must be incremental
- [ ] Persistent symbol graph store (LMDB/SQLite)
- [ ] Per-file hashes; update only affected nodes/edges
- [ ] Slices: computed only for seed regions
- [ ] Distances: approximate via multi-source BFS truncated at radius R or landmark distances (deterministic)

---

## 90. CWS Output Formats

- [ ] `tg ctxpack` outputs:
  - [ ] `ctxpack.json` — graph + summaries + selected spans
  - [ ] `ctxpack.spans/` — exact file excerpts
  - [ ] `ctxpack.proofs/` — why each item included, slice membership, graph distance

---

---

# ctxpack.json Schema (Normative)

## 91. Top-Level Structure

- [ ] Required keys: `schema_version`, `tangerine`, `pack`, `inputs`, `budgets`, `graphs`, `selection`, `artifacts`, `items`, `spans`, `proof`
- [ ] Encoding: UTF-8 JSON
- [ ] Numbers: IEEE 754; costs as integers CU
- [ ] Arrays stably sorted as specified

---

## 92. `tangerine` (toolchain identity)

- [ ] `edition`, `tgc_version`, `tg_version`, `target` — all required

---

## 93. `pack` (pack identity & hashing)

- [ ] `pack_id`: SHA256 of canonicalized JSON of (inputs + effective CWS config + index hashes + chosen item IDs)
- [ ] `created_utc`
- [ ] `profile` (e.g., "backend")
- [ ] `mode` (e.g., "Production")
- [ ] `determinism`: { `sort_order`, `hash_scheme`, `branch_id_scheme`, `arm_id_scheme` }

---

## 94. `inputs` (what pack was built from)

- [ ] `query`: { `kind` ∈ {compile_error, failing_test, cqs_gate, manual}, `value`, `primary_spans` }
- [ ] `seed_symbols`: stable-sorted lex
- [ ] `index`: { `symbol_graph_id`, `sdg_id`, `coverage_id`, `caps_baseline_id` } — null if unavailable

---

## 95. `budgets` (enforced limits)

- [ ] `unit = "CU"` (1 CU = 4 bytes UTF-8)
- [ ] `total`, `summaries`, `code`
- [ ] `used`: { `total`, `summaries`, `code` }

---

## 96. `graphs` (graph metadata)

- [ ] `edge_costs`: { call: 1.0, type: 1.2, trait: 1.1, effect: 0.8, test: 0.9, file: 1.4 }
- [ ] `radius_caps`: per profile per graph (see §100)
- [ ] `limits`: { `max_candidate_symbols: 25000`, `max_expanded_edges: 250000`, `max_seeds: 300` }

---

## 97. `selection` (optimization model)

- [ ] `algorithm = "submodular_greedy_knapsack"` (v0.2)
- [ ] `objective = "weighted_need_coverage"`
- [ ] `alpha` (decay), `K` (max summaries)
- [ ] `needs_profile` (e.g., "backend")
- [ ] `weights`: at least canonical need categories present

---

## 98. `artifacts` (optional attachments)

- [ ] Links to quality report, merged coverage — project-relative paths

---

## 99. `items` (selected context items)

### 99.1 Item Base Schema

- [ ] Required: `item_id` (stable), `tier` ∈ {S, M, L}, `kind`, `cost_cu` (int), `covers[]`, `why`, `payload`
- [ ] Items sorted by: tier (S→M→L) then `item_id` lex

### 99.2 `why` (audit trail per item)

- [ ] `seed_distance`: { `min`, `avg`, `sources[]` with seed + dist + via }
- [ ] `slice_membership`: { `in_backward_slice`, `in_forward_slice`, `sdg_nodes` } — or `sdg_available: false`
- [ ] `marginal_gain`: { `delta_F`, `delta_per_cu` }
- [ ] `priority_tags[]`

### 99.3 Canonical Item Kinds

- [ ] **symbol_summary** (Tier S): symbol_id, surface_class, signature, effects, capabilities, contracts, errors, callers, callees, tests
- [ ] **definition_span** (Tier M): symbol_id, span_ref, includes[]
- [ ] **slice_span** (Tier L): symbol_id, span_refs[], slice direction, reason
- [ ] **test_summary** and **test_span**: summarizes/includes failing tests
- [ ] **trait_resolution_bundle** (Tier M/L): trait, receiver_type, candidates[], span_refs[]
- [ ] **capability_boundary_bundle**: cap footprints + drift evidence
- [ ] **taint_flow_bundle**: taint sources → validators → sinks paths

---

## 100. `spans` (actual code excerpts)

- [ ] Sorted by `span_ref` lex
- [ ] Schema: `span_ref`, `file`, `start`, `end`, `hash` (SHA256 of text bytes), `language`, `text`
- [ ] Uses byte offsets in UTF-8 (v0.2)

---

## 101. `proof` (global audit + optimization log)

- [ ] `needs_universe[]`: all needs with weights
- [ ] `candidates_considered`, `selected_count`
- [ ] `objective_value`: { `F_selected`, `F_upper_bound` }
- [ ] `greedy_trace[]`: step, picked_item_id, cost_cu, delta_F, delta_per_cu, budget_remaining_cu
  - [ ] At least first N=200 steps; may truncate with `trace_truncated=true`
- [ ] `F_upper_bound`: may be simple bound (sum of weights) if tighter not implemented
- [ ] `truncation`: { `candidate_cap_hit`, `edge_cap_hit`, `seed_cap_hit` }

---

## 102. Determinism Rules for ctxpack

- [ ] Candidate generation: stable-sorted by (node_id, edge_kind, neighbor_id)
- [ ] Greedy ties broken lexicographically by item_id
- [ ] Costs: `cost_cu = ceil(byte_len(payload_json)/4) + 10` (fixed overhead per item)
- [ ] Spans use byte offsets with stable file normalization
- [ ] Truncation MUST be recorded in proof.truncation

---

## 103. Minimal Compliance Levels

- [ ] **Level 1 (required v0.2)**: symbol graph, summaries, greedy selection, spans
- [ ] **Level 2 (recommended)**: SDG slicing, taint flow bundles, capability drift bundles
- [ ] **Level 3 (advanced)**: tighter objective bounds, replay trace integration, cross-package ctxpack merging

---

---

# CWS Default Parameters (Normative)

## 104. Context Budget B

- [x] 1 CU = 4 bytes UTF-8 (deterministic)
- [x] Default budgets by profile:

| Profile | B_total | Bytes | Summaries ratio (σ) |
|---|---|---|---|
| backend | 160,000 CU | 640 KB | 40% / 60% |
| cli | 120,000 CU | 480 KB | 45% / 55% |
| ui | 200,000 CU | 800 KB | 35% / 65% |

- [x] `B_summaries = σ · B_total`; `B_code = (1 − σ) · B_total`

---

## 105. Summary Breadth K

- [x] Max symbol summaries CWS will attempt to include (Layer 1):

| Profile | K |
|---|---|
| backend | 2,000 |
| cli | 1,500 |
| ui | 3,000 |

- [x] Priority hard limits (always included first):
  - [x] K_public: 300
  - [x] K_tests: 200
  - [x] K_security: 150
- [x] If priority limits exceed K, they still get priority; less important dropped

---

## 106. Graph-Distance Decay α

- [x] `rel(v) = e^{−α · d(v, Seeds)}`

| Profile | α |
|---|---|
| backend | 0.55 |
| cli | 0.70 |
| ui | 0.45 |

- [x] Backend: moderate radius
- [x] CLI: focuses closer to seeds
- [x] UI: deliberately widens (UI logic spread across event/render/layout)

---

## 107. Radius Caps (Candidate Generation)

- [x] Multi-source graph expansion from seeds, capped by radius per graph:

| Graph | backend | cli | ui |
|---|---|---|---|
| Call | 3.0 | 2.0 | 4.0 |
| Type-use | 2.5 | 2.0 | 3.0 |
| Trait/impl | 2.0 | 1.5 | 2.0 |
| Effects/caps | 2.0 | 2.0 | 2.5 |
| Test | 3.0 | 2.5 | 3.0 |
| File/module | 1.5 | 1.5 | 2.0 |

- [x] Global caps:
  - [x] MAX_CANDIDATE_SYMBOLS = 25,000
  - [x] MAX_EXPANDED_EDGES = 250,000
  - [x] MAX_SEEDS = 300 (downsampled by priority if exceeded)
- [x] If cap hit, expansion stops + records `truncated=true`

---

## 108. Edge Costs (Weighted Distance)

| Edge type | Cost |
|---|---|
| Call (f→g) | 1.0 |
| Type-use (f→T) | 1.2 |
| Trait (T→Trait / Trait→impl) | 1.1 |
| Test (test↔f) | 0.9 |
| Capability/effect (f→cap/eff) | 0.8 |
| File/module (f→file/mod) | 1.4 |

- [x] Security/effect and test connections are "closer" → preferentially included

---

## 109. Needs Universe & Weight Profiles

### 109.1 Canonical Need Categories

- [x] Correctness & failure:
  - [x] `U.compile_error_root`
  - [x] `U.compile_error_deps`
  - [x] `U.failing_test_root`
  - [x] `U.failing_test_assertion`
  - [x] `U.stacktrace_symbols`
- [x] API & semantics:
  - [x] `U.public_api_signature`
  - [x] `U.public_api_contracts`
  - [x] `U.error_types`
  - [x] `U.match_exhaustiveness_context`
  - [x] `U.trait_resolution_context`
- [x] Security:
  - [x] `U.capability_footprint`
  - [x] `U.capability_drift`
  - [x] `U.taint_sources_and_validators`
  - [x] `U.unsafe_blocks_and_reasons`
- [x] Performance:
  - [x] `U.budgets`
  - [x] `U.hot_path_callers_callees`
- [x] Project structure:
  - [x] `U.module_boundaries`
  - [x] `U.feature_flags_and_future_blocks`
  - [x] `U.config_schema`

### 109.2 Backend Profile Weights

| Need | Weight |
|---|---|
| compile_error_root | 10 |
| failing_test_root | 10 |
| failing_test_assertion | 9 |
| public_api_signature | 8 |
| public_api_contracts | 9 |
| error_types | 9 |
| trait_resolution_context | 7 |
| match_exhaustiveness_context | 7 |
| capability_footprint | 10 |
| capability_drift | 10 |
| taint_sources_and_validators | 10 |
| unsafe_blocks_and_reasons | 9 |
| budgets | 7 |
| hot_path_callers_callees | 6 |
| feature_flags_and_future_blocks | 6 |
| module_boundaries | 5 |
| config_schema | 6 |

### 109.3 CLI Profile Weights

| Need | Weight |
|---|---|
| compile_error_root | 10 |
| failing_test_root | 9 |
| failing_test_assertion | 8 |
| public_api_signature | 7 |
| public_api_contracts | 7 |
| error_types | 8 |
| trait_resolution_context | 6 |
| capability_footprint | 9 |
| capability_drift | 9 |
| taint_sources_and_validators | 8 |
| unsafe_blocks_and_reasons | 8 |
| budgets | 6 |
| hot_path_callers_callees | 5 |
| feature_flags_and_future_blocks | 5 |
| module_boundaries | 6 |
| config_schema | 9 |

- [x] Rationale: CLIs live/die by config/env/files/process correctness

### 109.4 UI Profile Weights

| Need | Weight |
|---|---|
| compile_error_root | 10 |
| failing_test_root | 9 |
| failing_test_assertion | 8 |
| public_api_signature | 7 |
| public_api_contracts | 7 |
| error_types | 7 |
| trait_resolution_context | 6 |
| match_exhaustiveness_context | 6 |
| capability_footprint | 8 |
| capability_drift | 8 |
| taint_sources_and_validators | 7 |
| unsafe_blocks_and_reasons | 8 |
| budgets | 10 |
| hot_path_callers_callees | 9 |
| feature_flags_and_future_blocks | 6 |
| module_boundaries | 6 |
| config_schema | 4 |

- [x] Rationale: UI dominated by frame budgets, event/render pipelines, hot paths

---

## 110. Default Candidate Item Mix (Tier Fractions of B_code)

| Profile | Tier M | Tier L |
|---|---|---|
| backend | 50% | 50% |
| cli | 60% | 40% |
| ui | 40% | 60% |

- [x] UI gets wider effective context: more deep code on hot paths

---

## 111. Seed Limits

- [x] MAX_SEEDS = 300
- [x] Seeds ranked by:
  1. Failing test roots
  2. Compiler error roots
  3. Gated CQS failures
  4. User-mentioned symbols
  5. Recently changed symbols (if VCS info available)
- [x] Downsampling: deterministic stable sort then take first N

---

## 112. Default CWS Config in Tangerine.toml

- [x] Implement CWS config section:
  ```toml
  [cws]
  profile = "backend"
  budget_total_cu = 160000
  summaries_ratio = 0.40
  K = 2000
  alpha = 0.55

  [cws.radius]
  call = 3.0
  types = 2.5
  traits = 2.0
  effects = 2.0
  tests = 3.0
  files = 1.5

  [cws.limits]
  max_candidate_symbols = 25000
  max_expanded_edges = 250000
  max_seeds = 300
  ```

---

---

## Verification Matrix

Each numbered section of `needed.txt` mapped to checklist coverage:

| needed.txt Section | Checklist § |
|---|---|
| 1. Progressive Strictness | §1 |
| 2. Contracts (guard, inferred) | §2 |
| 3. Security by Construction (caps, profiles) | §3 |
| 4. Stub & Incomplete Detection | §4 |
| 5. Exhaustiveness Everywhere | §5 |
| 6. Typed Effects | §6 |
| 7. Error Handling Discipline | §7 |
| 8. Context Widening (Symbol Graph, Context Packs) | §8 |
| 9. Deterministic Replay & Observability | §9 |
| 10. Budget Enforcement | §10 |
| 11. Secure Data Types | §11 |
| 12. FFI Taint Tracking | §12 |
| 13. Implementation Fullness | §13 |
| 14. Spec-Driven Modules | §14 |
| 15. Semantic Refactor Primitives | §15 |
| 16. Secure Supply Chain | §16 |
| 17. Strong Defaults Against Partial APIs | §17 |
| 18. "Definition of Done" as Config | §18 |
| 19. Compiler as Advisor | §19 |
| 20. Retry Reduction | §20 |
| 21. Human Ergonomics | §21 |
| 22. Final Principle | §22 |
| CQS Formal Spec v0.2 (§1–14) | §23–35 |
| CQS Scoring Math (normative) | §26 |
| CQS Default Parameters | §36–41, §48 |
| CQS Signal Detection Algorithms | §49–59 |
| Coverage Artifact Spec | §60–67 |
| Capability Drift Baseline Spec | §68–74 |
| Coverage Branch Enumeration Stability | §75–79 |
| .tg/cqs/ Directory Layout | §80 |
| Reference Implementation (merge, bless) | §81–82 |
| CWS Formal Spec (graphs, slicing, optimization) | §83–90 |
| ctxpack.json Schema | §91–103 |
| CWS Default Parameters | §104–112 |
