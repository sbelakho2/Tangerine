# Internal Consistency Reporting Cadence — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §38 of the graphics/UI development checklist.

---

## 1. Weekly Consistency KPI Set

The following metrics are tracked weekly:

| KPI                         | Source                              | Threshold     | Escalation              |
|-----------------------------|-------------------------------------|---------------|-------------------------|
| Interface drift count       | `tests/abi/test_abi_conformance.tg` | 0             | Any >0 → P1 issue       |
| Stub count (production)     | `make stub-scan`                     | 0             | Any >0 → merge block    |
| Conformance drift count     | `scripts/conformance_gates.tg`       | 0             | Any >0 → P1 issue       |
| Visual regression count     | `tests/golden/test_visual_regression.tg` | 0        | Any >0 → investigate    |
| Open consistency issues     | Issue tracker                        | Trending ↓    | Trending ↑ → review     |
| Test suite pass rate        | CI dashboard                         | 100 %         | <100 % → investigation  |
| Performance budget delta    | Benchmark CI job                     | Within ±10 %  | Exceeds → P2 issue      |

---

## 2. Weekly Consistency Dashboard

### 2.1 Dashboard Structure

```
┌──────────────────────────────────────────────────────┐
│ TG-GFX-UI Consistency Dashboard — Week of YYYY-MM-DD │
├──────────────────────────────────────────────────────┤
│ Interface Drift:    0  ✅                             │
│ Stub Count:         0  ✅                             │
│ Conformance Drift:  0  ✅                             │
│ Visual Regressions: 0  ✅                             │
│ Open Issues:        N  (↓ from last week)            │
│ CI Pass Rate:       100%  ✅                          │
│ Perf Budget Delta:  +2%  ✅                           │
├──────────────────────────────────────────────────────┤
│ Platforms:  macOS ✅  Linux ✅  Windows ✅             │
│ Backends:   Software ✅  Native ⏳                    │
├──────────────────────────────────────────────────────┤
│ Status: ON TRACK                                      │
└──────────────────────────────────────────────────────┘
```

### 2.2 Publication

- Generated automatically from CI results every Monday.
- Published to internal engineering channel (not external).
- Historical data archived for trend analysis.
- Dashboard link included in weekly engineering standup.

---

## 3. Milestone Burndown Tracking

### 3.1 Tracked Categories

| Category               | Metric                               |
|------------------------|--------------------------------------|
| Consistency findings   | Open → In Progress → Resolved        |
| Stub findings          | Identified → Removed → Verified      |
| Conformance gaps       | Identified → Implemented → Tested    |

### 3.2 Burndown Rules

- Each finding is assigned to a milestone (M1, M2, M3, or RC).
- Findings not resolved by their milestone deadline escalate to the next milestone.
- RC milestone has a hard freeze: no new findings accepted without waiver.
- Burndown chart updated weekly in the dashboard.

### 3.3 Escalation

| Condition                              | Action                              |
|----------------------------------------|-------------------------------------|
| Open findings increasing for 2+ weeks  | Review meeting with module owners   |
| >5 open findings at RC freeze          | Release delay discussion            |
| Any P0 finding at RC freeze            | Automatic release block             |
