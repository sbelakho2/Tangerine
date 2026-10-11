# Tangerine System Intelligence

A standalone, stdlib-only **semantic federation, persistence, history and
cross-repository query layer** that answers:

> **What is true about this system, how is it structured, what depends on what,
> what can break, and what must remain true when it changes?**

`system_intel/` is NOT the semantic analyzer. Semantic truth comes from
interchangeable **Semantic Providers**; `system_intel` federates them into one
versioned, queryable model and knows what it does not know.

```
Tangerine (knows systems) ──► neutral protocol ──► Faktor (decides), Kiwi (verifies)
        ▲
        │ providers
  tangerine-native (authoritative) · generic-static (fallback) · external SPI
```

## The provider inversion

Actual semantic truth comes from providers, ordered by authority:

| Provider | Intelligence | Completeness |
| --- | --- | --- |
| `tangerine-native` | typed + verified-MIR semantic snapshot of Tangerine code (never source scanning; indirect calls recorded as unknown; dependency-family completeness) | authoritative: complete/partial/unknown **per family** |
| `generic-static` | the zero-install stdlib scanner in `extract_core.py` (lexical/filesystem, regex definitions/imports, manifests, SQL, config, deployment) | entities complete at depth ≤1, relations partial, calls unavailable |
| external SPI | compiler/LSP/tree-sitter/runtime/history plugins | provider-declared |

A provider contract is `identity → capabilities → snapshot → query → delta →
completeness` (`system_intel/providers/base.py`). Every provider advertises,
for every relation/fact family, whether it is `complete`, `partial`,
`unavailable` or `unknown`. Queries return a **completeness verdict**: the
difference between "nothing depends on this" and "we do not know" is always
representable.

## Core principles

- **Standalone.** Python 3.12 standard library only. No third-party
  dependencies, no network access, no orchestration semantics.
- **Language-agnostic contract.** The graph, the query API and the protocol
  are language-agnostic — not "all languages understood at the lowest common
  denominator". Providers raise the semantic level; the fallback keeps the
  floor.
- **Repository-agnostic.** REPO identity is `repo_identity + source_revision +
  tree_digest + semantic_configuration + provider_set_digest`; `repo_root` is
  provenance metadata, never identity.
- **Orchestrator / verifier / model-agnostic.** It informs agents; it does not
  drive them.
- **API + CLI.** `Graph` + `python3 -m system_intel.cli` /
  `tools/system_intel.sh`.
- **Immutable snapshots.** A finalized snapshot is frozen truth. New
  observations create a NEW snapshot; staleness is a relation between
  revisions (`diff_snapshots`), never a mutation of history.
- **Graceful degradation.** Fewer layers may be populated than exist, and
  partial knowledge is explicitly labeled.

## Universal vocabulary (from `schema.sql`)

**Entity kinds (open-ended):** Repository, Project, Package, Module, File,
Symbol, Service, Resource, API, Contract, Schema, Event, Queue,
Configuration, Deployment, Test, Owner, Invariant, Incident, Change,
RuntimePath, DataFlow.

**Relation kinds (open-ended):** contains, imports, calls, reads, writes,
creates, deletes, publishes, subscribes, depends_on, implements, extends,
tests, deploys_with, owns, configured_by, constrained_by, compatible_with,
breaks_if_changed, flows_to.

The documented sets are conventions, not a closed enum: `kind` is a free
string so new ecosystems can be described without a schema migration.

## Epistemics: five orthogonal axes (schema v3)

Do not overload one ordinal. Every row records:

| Field | Values | Question it answers |
| --- | --- | --- |
| `epistemic_state` | observed / declared / inferred / historically_supported / uncertain / contradicted | how do we know it? |
| `analysis_depth` | 0 filesystem · 1 lexical/syntax · 2 symbols/types · 3 deps/calls/data-flow · 4 runtime · 5 federation | how deep was the analysis? |
| `completeness` | complete / partial / unavailable / unknown | are we sure it is exhaustive? |
| `confidence` | 0.0..1.0 (+ basis) | how strongly is it supported? |
| `provenance` (+ `provider`, `provider_version`) | free-form source class | who/what derived it? |

Runtime evidence maps to `epistemic_state=observed, analysis_depth=4` — never
to `inferred`. The provider's per-family verdicts ride every query result.

## Knowledge layers

| Layer | Tables | Meaning |
| --- | --- | --- |
| Structural facts | `entity`, `relation`, `fact` | What exists and how it is wired. |
| Unresolved claims | `unresolved_edge` | Observed edges whose target could not be resolved (raw target, candidates, provider, completeness) — never silently dropped. |
| Evidence / support | `evidence`, `support` | What each canonical row rests on; independent providers ACCUMULATE support instead of overwriting. |
| Provider records | `provider_record` | Which provider produced which family, and how completely. |
| Invariants / contracts | `invariant`, `contract` | Conditions that must remain true; compatibility boundaries. |
| Historical | `incident`, `change` | What broke before and what changed. |

## What this must NOT do

- No orchestration and no coding: it never edits the system it describes.
- No CI ownership: it reports, it does not gate or run pipelines.
- No correctness certification: confidence is evidence, not proof.
- No dependency on Faktor, Kiwi, or any other consumer or agent.
- No consumer-specific IDs or workflow concepts in the core schema.
- No second compiler model: for Tangerine code the native semantic snapshot
  is the authority; the regex adapter is a fallback, never the authority.

## CLI

```bash
# Extract a repository into the graph (delegates to system_intel.persist.scan)
python3 -m system_intel.cli scan /path/to/repo --db .tangerine-intel.db

# What depends on what (returns a completeness verdict with the closure)
python3 -m system_intel.cli dependencies .tangerine-intel.db \
    --kind Module --qualified-name shop.orders

# What can break
python3 -m system_intel.cli impact .tangerine-intel.db \
    --kind Module --qualified-name shop.orders

# Explain one node: entity + all edges + attached contracts/invariants
python3 -m system_intel.cli explain .tangerine-intel.db \
    --kind Module --qualified-name shop.orders

# Blast radius for changed files or symbols (file paths and qualified names)
python3 -m system_intel.cli blast-radius .tangerine-intel.db src/orders.py shop.orders

# Machine-readable output / neutral exchange
python3 -m system_intel.cli stats .tangerine-intel.db --json
python3 -m system_intel.cli protocol .tangerine-intel.db > exchange.json
```

The wrapper `tools/system_intel.sh` resolves the repository root from its own
location and sets `PYTHONPATH`, so it works from any directory. If `--db` is
omitted it falls back to `$TANGERINE_INTEL_DB`, then `./.tangerine-intel.db`.

## Python API

```python
from system_intel.graph import Graph

with Graph.open(".tangerine-intel.db") as graph:
    snap = graph.latest_finalized_snapshot()      # one deterministic snapshot
    orders = graph.find_entity("Module", "shop.orders")

    graph.impact(orders)            # reverse closure + completeness verdict
    graph.dependencies(orders)      # forward closure + completeness verdict
    graph.change_surface(["src/orders.py", "shop.orders"])
    graph.unresolved_edges()        # what could NOT be resolved
    graph.completeness(family="calls")
    graph.diff_snapshots(old_id, new_id)  # revision-relative staleness
```

Scanning a tree (atomic; idempotent per revision; providers optional):

```python
from system_intel.persist import scan
report = scan("/path/to/repo", ".tangerine-intel.db")            # generic-static
# scan(root, db, provider=native_provider, strict_clean=True)     # native/provider
```

Key methods: `latest_finalized_snapshot`, `snapshot_by_revision`,
`snapshot_for`, `begin_draft`, `finalize_snapshot`, `abort_draft`,
`upsert_entity(kind, name, stable_id, ...)`, `upsert_relation`,
`upsert_fact`, `add_unresolved_edge`, `accumulate_support`, `record_provider`,
`add_invariant`, `add_contract`, `add_incident`, `add_change`, `find_entity`,
`entity_row`, `neighbors`, `edges_by_type`, `entities_by_kind`, `find_path`,
`impact`, `dependencies`, `change_surface`, `completeness`, `diff_snapshots`,
`stats`, `export_json`.

## Interoperability protocol (neutral exchange schema)

Tangerine publishes its knowledge through a neutral, versioned vocabulary
documented independently of its internals: see **`PROTOCOL.md`**. A consumer
needs only that document, never the SQLite schema or this package's code. The
exchange carries stable subject IDs, the snapshot revision identity, provider
identities and per-family completeness, evidence references, unresolved
claims, counterexamples, and a symmetric **ingest** side so any verifier,
runtime collector, CI system or human tool can return evidence without
Tangerine knowing which product generated it.

```bash
python3 -m system_intel.cli protocol .tangerine-intel.db > exchange.json
```

```python
from system_intel.ingest import ingest_protocol
with Graph.open(".tangerine-intel.db") as graph:
    report = ingest_protocol(graph, doc, snapshot_id=draft_id,
                             provider_id="kiwi", provider_version="1.2.0")
```

## Snapshots, identity and staleness semantics

Identity has **three levels** (v3):

1. **SourceRevision** — repository identity + source tree + target/semantic
   configuration. `repo_root` is provenance metadata, never identity.
2. **ProviderObservation** — one provider's immutable observation over a
   source revision (static / runtime / verification / history), with a
   content-derived `observation_digest`, a scope, an authority and the
   separated enumeration/resolution completeness verdicts.
3. **FederatedSnapshot** — the immutable SET of observation ids. Its
   `observation_set_digest` makes a new runtime trace, Kiwi evidence or
   historical record a NEW federated revision even when the source is
   unchanged.

- A dirty git worktree is recorded as `worktree:<base-sha>:<tree-digest>`,
  never as the clean HEAD sha; non-git trees use `content:<tree-digest>`.
  `scan(..., strict_clean=True)` refuses anything that is not a clean,
  identified revision.
- The NORMAL `scan()` uses the provider registry automatically (native first
  when applicable, generic-static as the zero-install fallback), runs the
  providers BEFORE final identity selection (their semantic configuration and
  content digest participate in the revision), and accumulates every
  provider's observation in `support` — observations never overwrite each
  other.
- `scan()` builds a DRAFT snapshot in ONE transaction, runs extraction,
  resolution, completeness accounting and integrity checks, and finalizes
  only on success. A failure rolls back — no partial truth is ever visible.
  Symlinked files are never followed; the scan's own database is excluded
  from the repository tree digest.
- Finalized snapshots are **immutable**: every snapshot-owned table (entity,
  relation, fact, unresolved_edge, support, evidence, provider_record,
  invariant, contract, incident, change) is protected by BEFORE triggers, and
  the snapshot metadata row itself allows only draft → finalized (identity
  mutation, reversal and deletion abort). The revision digest is RECOMPUTED
  and re-verified at finalization/read.
- Re-scanning the same revision tuple with the same provider observations is
  a zero-write reuse.
- Removed entities/relations/facts are reported by `diff_snapshots(old, new)`
  — "stale" is revision-relative, not an in-place mutation flag.
- Unresolved edges are preserved forever as first-class claims.
- Support rows structurally validate their polymorphic subject
  (`subject_table`/`subject_id` must name a same-snapshot row) and their
  evidence (`evidence_id` must belong to the same snapshot).

**schema_version:** `schema.sql` seeds `schema_version.version = 3`;
`stats()`/`export_json()` report it.

## Layout

```
system_intel/
  INTERFACES.md     frozen v3 contract (identity levels, schema, API, SPI, protocol)
  graph.py          core Graph API (snapshots, entities, claims, queries)
  cli.py            argparse CLI, `python3 -m system_intel.cli`
  schema.sql        authoritative SQLite schema (v3)
  protocol.py       neutral exchange protocol v2 (stable IDs, completeness)
  PROTOCOL.md       standalone protocol specification
  ingest.py         symmetric ingest (evidence/support/unresolved claims)
  extract_core.py   generic-static extraction engine (zero-install fallback)
  persist.py        atomic scan/draft/finalize driver (providers optional)
  providers/        semantic provider SPI + tangerine-native + generic-static
  tools/system_intel.sh
  tests/            unittest suite + multi-language fixture repo
```
