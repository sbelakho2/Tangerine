# Release Engineering and Operations — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §31 of the graphics/UI development checklist.

---

## 1. Versioning Scheme

### 1.1 Components

| Component             | Format         | Example    | Notes                                     |
|-----------------------|----------------|------------|-------------------------------------------|
| Runtime               | SemVer         | `0.1.0`    | Major.Minor.Patch                         |
| Interface ABI         | `major.minor`  | `0.1`      | Major = breaking; Minor = additive only   |
| Plugin packages       | SemVer         | `0.1.0`    | Must declare compatible ABI range         |
| Spec document         | `vMajor.Minor` | `v0.1`     | Matches ABI major.minor                   |

### 1.2 Rules

- ABI major version change = full migration required.
- ABI minor version change = backward-compatible; old plugins continue to work.
- Runtime patch versions may fix bugs without ABI changes.
- Plugin packages declare `min_abi_version` and `max_abi_version` in manifest.

---

## 2. Signed Release Artifacts

### 2.1 Signing Process

1. CI builds produce unsigned artifacts.
2. Release pipeline signs artifacts using project key.
3. Signatures are published alongside artifacts (detached `.sig` files).
4. Consumers verify signatures before installation.

### 2.2 Artifact Types

| Artifact               | Signed | Format                  |
|------------------------|--------|-------------------------|
| Runtime library        | Yes    | `.so` / `.dylib` / `.dll` |
| Backend plugins        | Yes    | `.so` / `.dylib` / `.dll` |
| Header files           | No     | `.h`                    |
| Documentation archive  | No     | `.tar.gz`               |
| SBOM                   | Yes    | `.json`                 |

---

## 3. Release Notes Generation

### 3.1 Sources

Release notes are generated from:
1. Merged PR titles and descriptions (tagged with checklist sections).
2. Closed issues linked to the release milestone.
3. Checklist completion delta since previous release.
4. Known issues and limitations from docs/current/backend_strategy.md.

### 3.2 Format

```
# Tangerine GFX/UI v0.1.0

## Highlights
- Initial release of TG-GFX-UI-SPEC-001
- ...

## New Features
- (auto-generated from PRs)

## Bug Fixes
- (auto-generated from issues)

## Breaking Changes
- See docs/current/migration.md for full migration guide

## Known Issues
- (from backend_strategy.md §Known Limitations)

## Compatibility Matrix
- (from feature matrix)
```

---

## 4. Release Candidate Checklist

| Gate                              | Required | Verification Method               |
|-----------------------------------|----------|-----------------------------------|
| All Tier A gates pass             | Yes      | `scripts/conformance_gates.tg`    |
| All Tier B gates pass             | Yes      | `scripts/conformance_gates.tg`    |
| ABI gates pass                    | Yes      | `scripts/conformance_gates.tg`    |
| Zero stubs in production paths    | Yes      | `make stub-scan`                  |
| All CI matrix green               | Yes      | GitHub Actions dashboard          |
| Performance budgets met           | Yes      | Benchmark results vs §23 targets  |
| Security review completed         | Yes      | Sign-off from security owner      |
| Accessibility checks passed       | Yes      | Accessibility test suite           |
| Documentation updated             | Yes      | `docs/` review                    |
| All platforms tested              | Yes      | macOS + Linux + Windows           |

---

## 5. Manifest and Compatibility Matrix Publication

Each release includes a published compatibility matrix:

| Backend         | Platform    | Required Interfaces | Optional Interfaces | Deterministic | Status   |
|-----------------|-------------|---------------------|---------------------|---------------|----------|
| Software ref    | All         | All 3               | image, clipboard    | Yes           | Stable   |
| macOS native    | macOS       | All 3               | All                 | Partial¹      | Beta     |
| Linux native    | Linux       | All 3               | image, clipboard    | Yes           | Beta     |
| Windows native  | Windows     | All 3               | All                 | Partial¹      | Beta     |

¹ GPU paths are non-deterministic.

---

## 6. Rollback Procedure

### 6.1 Backend/Plugin Regression

1. **Detect:** CI or user report identifies regression.
2. **Isolate:** Determine if regression is in host runtime or backend plugin.
3. **Rollback plugin:** Replace plugin binary with previous known-good version.
4. **Rollback runtime:** If runtime regression, issue hotfix (see §7) or revert to previous release.
5. **Verify:** Re-run conformance suite after rollback.

### 6.2 Timeline

- Critical regression: rollback within 4 hours.
- Non-critical regression: rollback within 24 hours.

---

## 7. Hotfix Process

### 7.1 Criteria

Hotfixes are issued for:
- Critical consistency regressions (ABI break, incorrect rendering, data loss).
- Critical security vulnerabilities.
- Critical stub regressions (stub re-introduced in production path).

### 7.2 Workflow

1. Branch from release tag: `hotfix/v0.1.1`.
2. Fix must be minimal — no feature additions.
3. Full CI run required (all platforms, all test suites).
4. Security owner sign-off required for security fixes.
5. Release as patch version (e.g., `v0.1.1`).

---

## 8. Release Consistency Bar

### 8.1 Pass/Fail Criteria

| Criterion                          | Pass                                | Fail                                     |
|------------------------------------|-------------------------------------|------------------------------------------|
| Conformance gates                  | All 10 gates green                  | Any gate red                             |
| Stub count                         | 0 in production paths               | >0 stubs                                 |
| ABI layout check                   | Matches reference                   | Any mismatch                             |
| Performance budgets                | p95 within §23 targets              | p95 exceeds target by >10%               |
| Security findings                  | 0 critical, 0 high                  | Any critical or high finding             |
| Consistency drift                  | 0 interface mismatches              | Any mismatch between code/docs/tests     |

### 8.2 Exception Process

Exceptions require:
1. ADR documenting the exception and rationale.
2. Sign-off from module owner + release owner.
3. Time-bounded remediation plan (max 1 release cycle).

---

## 9. Release-Candidate Burn-In

- Minimum burn-in duration: 72 hours.
- During burn-in: no new changes merged to release branch.
- Automated soak tests run continuously during burn-in.
- Any new failure during burn-in resets the timer.

---

## 10. Required Sign-Offs

| Owner                | Sign-Off Scope                               |
|----------------------|----------------------------------------------|
| Conformance owner    | All gates pass; no consistency drift          |
| Security owner       | Security review complete; no critical findings|
| Infra owner          | CI green; build reproducible; artifacts signed|
| Release owner        | All above + release notes + compatibility matrix |

---

## 11. Reproducible Build Verification

- Final release artifacts are built twice from the same source + toolchain.
- Binary checksums (SHA-256) must match.
- Any mismatch blocks the release until root-caused and resolved.
- Verification results are archived alongside the release.
