# Tangerine System Intelligence

A standalone, stdlib-only knowledge graph that answers:

> **What is true about this system, how is it structured, what depends on what,
> what can break, and what must remain true when it changes?**

`system_intel/` turns a repository (any repository, any language) into a
queryable SQLite graph of entities, relationships, facts, invariants,
contracts and history. It is designed to be consumed by humans, by other
tools, and by orchestrator/verifier agents — without owning any of them.

## Core principles

- **Standalone.** Python 3.12 standard library only (`sqlite3`, `json`,
  `argparse`, `pathlib`, `unittest`, `datetime`, ...). No third-party
  dependencies, no network access.
- **Language-agnostic.** Extraction emits the same universal vocabulary
  regardless of the source language.
- **Repository-agnostic.** No project-specific concepts in the core. The same
  schema describes a compiler, a web service or a data pipeline.
- **Orchestrator / verifier / model-agnostic.** The graph is data plus a
  query API. It does not drive agents, models or verification; it informs
  whatever does.
- **API + CLI.** Everything is available as a Python API (`Graph`) and as
  `python3 -m system_intel.cli` / `tools/system_intel.sh`.
- **Incremental.** Snapshots are pinned to `(repo_root, commit_sha)`; upserts
  are idempotent and unenumerated entities are marked stale, never deleted.
- **Graceful degradation.** Fewer layers may be populated than exist. Facts
  without invariants, runtime without contracts, and history without runtime
  are all valid states.

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

## Knowledge layers

| Layer | Tables | Meaning |
| --- | --- | --- |
| Structural facts | `entity`, `relation`, `fact` | What exists and how it is wired. |
| Invariants | `invariant` | Conditions that must remain true. |
| Contracts | `contract` | Compatibility boundaries (api / schema / event / cli / config / format). |
| Runtime | entity/relation rows with runtime provenance | Observed behavior, not just static structure. |
| Historical | `incident`, `change` | What broke before and what changed. |

## Tiers, provenance, confidence

`tier` records how far knowledge is from direct observation:

- **0 — Observed static:** parsed from source/config at the pinned commit.
- **1 — Derived static:** computed from tier-0 knowledge (call graphs,
  dependency closures).
- **2 — Cross-boundary inference:** heuristics spanning packages, services or
  repositories.
- **3 — Declared:** asserted by humans, docs or configuration.
- **4 — Runtime observed:** telemetry, traces, live topology.
- **5 — Historical:** derived from incident/change history.

`provenance` names the source class: `observed`, `inferred`, `declared`,
`runtime`, `historically_supported`. `confidence` is `0.0..1.0`. Every row
carries both, plus optional `derived_from` (row references or external
evidence) and `uncertainty` (free-text caveat). Never present inferred
knowledge as observed: the columns are always there to tell them apart.

Note: in schema v1 the `incident` and `change` tables carry provenance and
confidence but no `tier`/`last_verified` columns; historical rows are
implicitly tier 5.

## What this must NOT do

- No orchestration and no coding: it never edits the system it describes.
- No CI ownership: it reports, it does not gate or run pipelines.
- No correctness certification: confidence is evidence, not proof.
- No dependency on Faktor, Kiwi, or any other consumer or agent.
- No consumer-specific IDs or workflow concepts in the core schema.

## CLI

```bash
# Extract a repository into the graph (delegates to system_intel.persist.scan)
python3 -m system_intel.cli scan /path/to/repo --db .tangerine-intel.db --commit HEAD_SHA

# What depends on what
python3 -m system_intel.cli dependencies .tangerine-intel.db \
    --kind Module --qualified-name shop.orders

# What can break
python3 -m system_intel.cli impact .tangerine-intel.db \
    --kind Module --qualified-name shop.orders

# Explain one node: entity + all edges + attached contracts/invariants
python3 -m system_intel.cli explain .tangerine-intel.db \
    --kind Module --qualified-name shop.orders

# Invariants, optionally scoped to a component
python3 -m system_intel.cli invariant-list .tangerine-intel.db --component shop.orders

# Blast radius for changed files or symbols (file paths and qualified names)
python3 -m system_intel.cli blast-radius .tangerine-intel.db src/orders.py shop.orders

# Machine-readable output
python3 -m system_intel.cli stats .tangerine-intel.db --json
python3 -m system_intel.cli export .tangerine-intel.db > snapshot.json
```

The wrapper `tools/system_intel.sh` resolves the repository root from its own
location and sets `PYTHONPATH`, so it works from any directory:

```bash
system_intel/tools/system_intel.sh --help
```

If `--db` is omitted it falls back to `$TANGERINE_INTEL_DB`, then
`./.tangerine-intel.db`. `scan` creates the file and parent directories on
demand.

## Python API

```python
from system_intel.graph import Graph

with Graph.open(".tangerine-intel.db") as graph:
    snapshot = graph.ensure_snapshot("/path/to/repo", "HEAD_SHA")

    orders = graph.upsert_entity("Module", "orders", "shop.orders",
                                 file="src/orders.py", tier=0,
                                 provenance="observed")
    db = graph.upsert_entity("Resource", "orders-db", "infra.orders_db")
    graph.upsert_relation(orders, db, "depends_on", tier=1,
                          provenance="inferred", confidence=0.7)
    graph.upsert_fact("shop.orders", "publishes", "OrderCreated")
    graph.add_invariant("Order totals never negative", component_qn="shop.orders")
    graph.add_contract("api", "OrdersAPI-v1", component_qn="shop.orders",
                       format="openapi", provenance="declared")

    report = graph.impact(db)          # reverse closure: what breaks
    deps = graph.dependencies(orders)  # forward closure
    surface = graph.change_surface(["src/orders.py", "shop.orders"])
    graph.stale_sweep(snapshot, {"Module": {"shop.orders"}})
```

Key methods: `ensure_snapshot`, `upsert_entity`, `upsert_relation`,
`upsert_fact`, `add_invariant`, `add_contract`, `add_incident`, `add_change`,
`mark_entity_stale/fresh`, `stale_sweep`, `find_entity`, `entity_row`,
`neighbors`, `edges_by_type`, `entities_by_kind`, `find_path`, `impact`,
`dependencies`, `change_surface`, `stats`, `export_json`.

## Interoperability protocol (neutral exchange schema)

Tangerine can publish its knowledge through a neutral record vocabulary that is
documented independently of its internals: a consumer needs only the record
description below, never the SQLite schema or this package's code.

```text
Requirement  — a thing that must hold for the system (caller-supplied)
Fact         — observed/declared/inferred subject–predicate–object statement
Claim        — a fact or invariant re-expressed as a checkable assertion
Invariant    — a condition that must remain true
Contract     — a compatibility boundary (api / schema / event / cli / config / format)
Risk         — an uncertain fact or a historical incident, with evidence
Change       — a commit/change with files and outcome
Evidence     — what a claim or risk rests on (incident, trace, test, ...)
Counterexample — a concrete refutation of a claim (reserved; empty in schema v1)
Confidence   — { value: 0..1, basis: [...] }
Provenance   — { source, derived_from, last_verified, uncertainty }
state        — observed | declared | inferred | historically_supported |
               uncertain | contradicted | stale
```

Export one snapshot with:

```bash
python3 -m system_intel.cli protocol .tangerine-intel.db > exchange.json
```

```python
from system_intel.protocol import export_protocol, protocol_json

with Graph.open(".tangerine-intel.db") as graph:
    doc = export_protocol(graph)              # JSON-ready dict
    text = protocol_json(graph)               # indented JSON string
```

The envelope is `{protocol_version, generated_utc, snapshot, records}`.
No consumer-specific identifier (task IDs, agent names, orchestration state)
appears anywhere in the exchange; consumers may ignore any record kind they do
not understand.

## Incremental and versioning semantics

- A **snapshot** is identified by `(repo_root, commit_sha)` and created once —
  `ensure_snapshot` is idempotent.
- All writes are **upserts keyed by natural identity** (e.g.
  `(snapshot_id, kind, qualified_name)` for entities, `(snapshot_id, src_id,
  dst_id, kind)` for relations). Re-running extraction updates rows in place,
  including tier/provenance/confidence/attrs, and clears `stale`.
- `stale_sweep(snapshot_id, seen_by_kind)` marks every non-stale entity of a
  kind stale when its qualified name was not seen. Only sweep a kind when the
  extraction **enumerated that kind fully**; otherwise omit the kind, or real
  entities will be flagged stale. Stale rows are retained for history and can
  be resurrected by the next upsert.
- Snapshot rows reference each other through `src_id`/`dst_id`; old snapshots
  remain queryable side by side. `export_json(snapshot_id)` dumps one snapshot
  (or the current one) as JSON-ready data with `derived_from`/`attrs`/`files`
  parsed from their JSON strings.

**schema_version:** `schema.sql` seeds `schema_version.version = 1`, and
`stats()`/`export_json()` report it. Consumers must check this number before
assuming table or column shapes; future schema changes bump it.

## Layout

```
system_intel/
  graph.py          core Graph API (entities/relations/facts/invariants/contracts)
  cli.py            argparse CLI, `python3 -m system_intel.cli`
  schema.sql        authoritative SQLite schema (v1)
  protocol.py       neutral exchange protocol (facts/claims/invariants/...)
  extract_core.py   Tier 0/1 extraction engine + adapter registry
  persist.py        scan/upsert driver (CLI `scan` delegates here)
  tools/system_intel.sh
  tests/            unittest suite + multi-language fixture repo
```
