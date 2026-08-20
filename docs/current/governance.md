# Program Governance and Delivery Ownership
## TG-GFX-UI-SPEC-001 v0.1 §16

---

## Module Owners

| Namespace | Module File(s) | Owner Role |
|-----------|----------------|------------|
| `tg::errors` | `std/gfx_errors.tg` | Error-model lead |
| `tg::geom` | `std/geom.tg` | Geometry lead |
| `tg::app` | `std/app.tg` | Windowing / events lead |
| `tg::gfx` | `std/gfx.tg` | 2-D drawing lead |
| `tg::gfx::gpu` | `std/gfx_gpu.tg` | GPU lead |
| `tg::image` | `std/image.tg` | Image codec lead |
| `tg::text` | `std/text.tg` | Text / font lead |
| `tg::ui` | `std/ui_toolkit.tg` | Widget toolkit lead |
| `tg::platform` | `std/platform.tg` | Clipboard / IME / DnD lead |
| `tg::anim` | `std/anim.tg` | Animation lead |
| `tg::compositor` | `std/compositor.tg` | Compositor lead |
| `tg::assets` | `std/assets.tg` | Asset pipeline lead |
| `tg::a11y` | `std/accessibility.tg` | Accessibility lead |
| `tg::backend_abi`| `std/backend_abi.tg` | ABI / plugin lead |

## Cross-Cutting Owners

| Concern | Owner Role |
|---------|------------|
| Determinism & replay | Determinism lead |
| Performance budgets | Performance lead |
| Security & supply-chain | Security lead |
| Accessibility | Accessibility lead |
| Release engineering | Release lead |

## RACI Matrix

| Activity | Responsible | Accountable | Consulted | Informed |
|----------|-------------|-------------|-----------|----------|
| Implement spec section | Module owner | Release lead | Cross-cutting owners | All contributors |
| Review PR | Peer reviewer | Module owner | Cross-cutting owners | Release lead |
| Approve merge | Module owner | Release lead | Security lead (if ABI/FFI) | All |
| Sign-off milestone | Release lead | Project lead | All owners | All |
| Conformance audit | Conformance lead | Release lead | Module owners | All |
| Waiver approval | Release lead | Project lead | Module owner | Security lead |

## Milestone Definitions

| Milestone | Target | Entry Criteria | Exit Criteria |
|-----------|--------|----------------|---------------|
| **M1 — Tier A** | Core types + error model + geometry + app/events | Spec §4–§6 reviewed | All §4–§6 checklist items `[x]`, unit tests green |
| **M2 — Tier B** | 2-D drawing + image + text + UI + platform | M1 exit criteria met | All §7–§12 items `[x]`, integration tests green |
| **M3 — Tier C** | GPU subset | M2 exit criteria met | All §8 items `[x]`, GPU smoke test green |
| **M4 — Ancillary** | Anim + compositor + assets + a11y | M2 exit criteria met | All §13 items `[x]` |
| **M5 — ABI Hardening** | Backend plugin ABI | M4 exit criteria met | All §14 items `[x]`, ABI probe test green |
| **M6 — Gate Verification** | §15 completion gates | M5 exit criteria met | All gates pass |
| **RC — Release Candidate** | Full matrix green | M6 exit criteria met | §32 go/no-go approved |

## Consistency-Review SLA

- **Checklist drift findings**: Must be triaged within **2 business days** of discovery.
- **Implementation drift**: Must be resolved or waived within **5 business days**.
- **ABI consistency failures**: Treated as **P0** — must block merge until resolved.
- **Weekly cadence**: Consistency KPI dashboard published every Monday (see §38).
