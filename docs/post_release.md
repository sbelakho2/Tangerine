# Post-Release Hardening Loop — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §33 of the graphics/UI development checklist.

---

## 1. Telemetry and Regression Prioritization

### 1.1 Collection

- Crash reports and error telemetry are collected via the `FirstFailureContext` mechanism
  (see `std/diagnostics.tg` §27.8).
- Error codes (`ERROR_RANGE_*`) and correlation IDs enable automated triage.
- Backend name/version and platform fingerprint are included in every report.

### 1.2 Prioritization

| Severity | Criteria                                      | Response SLA |
|----------|-----------------------------------------------|-------------|
| P0       | Crash, data loss, security vulnerability       | 4 hours     |
| P1       | Incorrect rendering, ABI regression            | 24 hours    |
| P2       | Performance regression > 10 % of budget        | 72 hours    |
| P3       | Minor visual inconsistency, non-blocking       | Next sprint |

---

## 2. Post-Release Conformance Audit

After each release, run the full conformance suite against:
1. **Bundled backends** — must all pass.
2. **Third-party/community backends** — document deviations.
3. **Real-world plugins** — validate ABI forward-compatibility.

Audit results are published in the compatibility matrix (see `docs/release_engineering.md` §5).

---

## 3. Compatibility Matrix Updates

After each release cycle:
1. Add newly tested backends and platforms to the matrix.
2. Document any observed issues not caught by automated tests.
3. Update "Known Limitations" in `docs/backend_strategy.md`.
4. Archive the matrix snapshot alongside the release artifacts.

---

## 4. Lessons Learned → v0.2 Planning

### 4.1 Feedback Channels

- Post-release retrospective review (within 2 weeks of release).
- Issue tracker analysis — common failure patterns.
- Community/user feedback aggregation.

### 4.2 v0.2 Candidate Features

These are deferred features identified during v0.1 development:

| Feature                  | Status       | Priority | Notes                              |
|--------------------------|-------------|----------|------------------------------------|
| Event capture/bubble     | Deferred     | High     | Full event propagation model       |
| Extended GPU API         | Deferred     | Medium   | Compute shaders, advanced blending |
| Additional widgets       | Deferred     | Medium   | Tree, Table, Tabs, Menu            |
| Gradient mesh support    | Deferred     | Low      | Coons patch / mesh gradients       |
| Animation keyframes      | Deferred     | Low      | Multi-property keyframe tracks     |

### 4.3 Process Improvements

- Identify checklist items that were harder to verify than expected.
- Improve automated gates where manual verification was needed.
- Streamline the ABI conformance test authoring workflow.

---

## 5. Checklist Refresh for Next Edition

### 5.1 Preservation

- All completed evidence links are preserved in the v0.1 archive.
- The checklist markdown file is tagged alongside the release.

### 5.2 Refresh Process

1. Copy the current checklist as the v0.2 template.
2. Reset all `[x]` to `[ ]` for items that need re-verification.
3. Keep `[x]` for items that carry forward unchanged.
4. Add new sections for v0.2 features.
5. Remove deprecated/obsolete items with notation.
6. Update section numbers if needed; maintain stable IDs for cross-references.
