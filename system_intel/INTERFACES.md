# system_intel v3 — pinned interfaces (contract for parallel workstreams)

This file is the FROZEN contract for the v3 federation inversion. Do not edit
it without coordinating; code against it exactly.

The inversion (user directive, 2026-10-10): `system_intel` is a
language-neutral **semantic federation + persistence + history + cross-repo
query** layer. Semantic truth comes from interchangeable **providers**.
The native Tangerine provider is authoritative for Tangerine code; the
stdlib-only scanner is the zero-install fallback, never the authority.

v3 (2026-10-11) makes the observation model explicit and closes the
federation/protocol integrity findings: three identity levels, full snapshot
immutability, structural support/evidence integrity, a provider registry that
the NORMAL scan path always uses, and a completeness algebra that separates
scope/authority/enumeration/resolution.

TERMINOLOGY: "v3" names the System Intelligence FEDERATION/SCHEMA model
(schema_version=3). The wire protocol is still `protocol_version = 2`: the
changes are additive record kinds/optional fields within its major version
(Entity, Observation, source_revision_digest), exactly as PROTOCOL.md's
versioning policy allows. There is no "protocol v3".

## 0. Enumerations (single source of truth)

```text
epistemic_state : observed | declared | inferred | historically_supported
                  | uncertain | contradicted
analysis_depth  : 0 filesystem | 1 lexical/syntax | 2 symbols/types
                  | 3 deps/calls/data-flow | 4 runtime | 5 federation
completeness    : complete | partial | unavailable | unknown
provenance_kind : source_scan | compiler | runtime_trace | history | caller
observation_kind: static | runtime | verification | history      (level 2)
authority       : native | compiler | fallback | external        (level 2)
```

`provenance` (existing column semantics) stays the free-form derivation
source; the above are separate columns/fields. `runtime` provenance maps to
`epistemic_state=observed, analysis_depth=4`, never to `inferred`.

## 1. Identity — three levels (v3)

```text
LEVEL 1  source_revision
repo_identity            : stable identity of the repository (e.g. remote URL
                           digest or root-path digest for local-only repos)
source_revision          : git HEAD sha, or "worktree:<base-sha>:<tree-digest>"
                           when the worktree is dirty, or
                           "content:<tree-digest>" for non-git trees
tree_digest              : sha256 of the canonical (path,size,mode,content)
                           manifest of extracted files (symlinks recorded by
                           target string, never followed; scan output paths
                           excluded)
target                   : the codegen target triple when known ('' otherwise)
semantic_configuration   : canonical JSON of target/features/options, default "{}"
revision_digest          : sha256 over (repo_identity, source_revision,
                           tree_digest, target, semantic_configuration)

LEVEL 2  provider_observation
provider + provider_version + source_revision_id + observation_kind
(static|runtime|verification|history) + observation_digest (CONTENT-derived:
sorted typed keys of the provider snapshot, never a DB row id) + scope +
authority (native|compiler|fallback|external) + enumeration_completeness +
resolution_completeness

LEVEL 3  FederatedSnapshot (snapshot row)
provider_set_digest      : sha256 over sorted (provider_id, provider_version)
observation_set_digest   : sha256 over the sorted observation digests
revision_digest          : sha256 over (repo_identity, source_revision,
                           tree_digest, semantic_configuration,
                           provider_set_digest, observation_set_digest)
```

Rules:
- `repo_root` is provenance metadata, never identity.
- A dirty git worktree MUST NOT be recorded as the clean HEAD sha. Default is
  the `worktree:<base>:<digest>` revision; a strict mode fails instead.
- Non-git trees MUST get `content:<tree-digest>`, never a constant.
- One revision tuple → at most one snapshot.
- A NEW observation over the SAME source (runtime trace, verification
  evidence, history, a different target) changes the observation-set digest
  and therefore produces a NEW federated revision — source-level reuse can
  never mask observation freshness.
- `finalize_snapshot` RECOMPUTES the observation-set and revision digests from
  the linked observations and the frozen identity fields; the integrity gate
  re-verifies them on read.

## 2. Schema v3 (schema.sql, schema_version=3)

Level-1/2 tables and federation links:

```sql
source_revision(
  id INTEGER PRIMARY KEY,
  repo_identity TEXT NOT NULL, source_revision TEXT NOT NULL,
  tree_digest TEXT NOT NULL, target TEXT NOT NULL DEFAULT '',
  semantic_configuration TEXT NOT NULL DEFAULT '{}',
  revision_digest TEXT NOT NULL UNIQUE, created_utc TEXT,
  UNIQUE (repo_identity, source_revision, tree_digest, target,
          semantic_configuration)
)  -- append-only: UPDATE/DELETE abort

provider_observation(
  id INTEGER PRIMARY KEY,
  provider TEXT NOT NULL, provider_version TEXT NOT NULL DEFAULT '',
  source_revision_id INTEGER NOT NULL REFERENCES source_revision(id),
  observation_kind TEXT NOT NULL CHECK (... static|runtime|verification|history),
  observation_digest TEXT NOT NULL,
  scope TEXT NOT NULL DEFAULT '{}',
  semantic_configuration TEXT NOT NULL DEFAULT '{}',
  authority TEXT NOT NULL CHECK (... native|compiler|fallback|external),
  enumeration_completeness TEXT NOT NULL DEFAULT 'unknown',
  resolution_completeness TEXT NOT NULL DEFAULT 'unknown',
  created_utc TEXT,
  UNIQUE (provider, provider_version, source_revision_id, observation_kind,
          observation_digest)
)  -- append-only: UPDATE/DELETE abort

snapshot_observation(
  snapshot_id INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  observation_id INTEGER NOT NULL REFERENCES provider_observation(id),
  PRIMARY KEY (snapshot_id, observation_id)
)

snapshot( ... v2 columns ...,
  observation_set_digest TEXT NOT NULL DEFAULT '',
  source_revision_id INTEGER REFERENCES source_revision(id),
  UNIQUE (repo_identity, source_revision, tree_digest,
          semantic_configuration, provider_set_digest, observation_set_digest)
)
```

Changes over v1/v2 (exact column names; earlier columns remain unless noted):

```sql
snapshot(
  id INTEGER PRIMARY KEY,
  repo_root TEXT,                      -- provenance only
  repo_identity TEXT NOT NULL,
  source_revision TEXT NOT NULL,
  tree_digest TEXT NOT NULL,
  semantic_configuration TEXT NOT NULL DEFAULT '{}',
  provider_set_digest TEXT NOT NULL DEFAULT '',
  revision_digest TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','finalized')),
  created_utc TEXT, finalized_utc TEXT,
  UNIQUE (repo_identity, source_revision, tree_digest,
          semantic_configuration, provider_set_digest)
)

entity(
  ... v1 columns ...,
  stable_id TEXT NOT NULL,             -- namespace-qualified, e.g.
                                       -- file:<path>, sym:<lang>:<path>::<name>,
                                       -- module:<path>, test:<path>::<name>
  epistemic_state TEXT NOT NULL DEFAULT 'observed',
  analysis_depth INTEGER NOT NULL DEFAULT 0,
  completeness TEXT NOT NULL DEFAULT 'partial',
  provider TEXT NOT NULL DEFAULT '',
  provider_revision TEXT NOT NULL DEFAULT '',
  UNIQUE (snapshot_id, stable_id),
  UNIQUE (id, snapshot_id)             -- enables composite FKs below
)

relation(
  ... v1 columns ...,
  src_key TEXT NOT NULL DEFAULT '',    -- stable_id of the source
  dst_key TEXT NOT NULL DEFAULT '',    -- stable_id of the target ('' if unresolved)
  resolved INTEGER NOT NULL DEFAULT 1,
  epistemic_state TEXT NOT NULL DEFAULT 'inferred',
  analysis_depth INTEGER NOT NULL DEFAULT 0,
  completeness TEXT NOT NULL DEFAULT 'partial',
  site_completeness TEXT NOT NULL DEFAULT 'unknown',
  target_resolution_completeness TEXT NOT NULL DEFAULT 'unknown',
  provider TEXT NOT NULL DEFAULT '',
  provider_revision TEXT NOT NULL DEFAULT '',
  FOREIGN KEY (src_id, snapshot_id) REFERENCES entity (id, snapshot_id),
  FOREIGN KEY (dst_id, snapshot_id) REFERENCES entity (id, snapshot_id)
  -- dst_id NULL allowed ONLY when resolved=0; enforce with a CHECK
)
-- site_completeness and target_resolution_completeness are SEPARATE axes:
-- all call sites may be enumerated while some indirect targets stay unknown.

unresolved_edge(
  id INTEGER PRIMARY KEY,
  snapshot_id INTEGER NOT NULL REFERENCES snapshot (id),
  src_key TEXT NOT NULL,
  dst_raw TEXT NOT NULL,               -- the raw target as observed
  kind TEXT NOT NULL,
  provider TEXT NOT NULL,
  provider_revision TEXT NOT NULL DEFAULT '',
  candidates TEXT NOT NULL DEFAULT '[]',   -- JSON array of stable_ids
  confidence REAL NOT NULL DEFAULT 0.3,
  completeness TEXT NOT NULL DEFAULT 'unknown',
  evidence TEXT NOT NULL DEFAULT '[]',     -- JSON array of evidence refs
  created_utc TEXT
)

support(                                -- observations supporting canonical rows
  id INTEGER PRIMARY KEY,
  snapshot_id INTEGER NOT NULL REFERENCES snapshot (id),
  subject_table TEXT NOT NULL,          -- 'relation' | 'fact' | 'entity' | ...
  subject_id INTEGER NOT NULL,
  provider TEXT NOT NULL,
  provider_revision TEXT NOT NULL DEFAULT '',
  confidence REAL NOT NULL DEFAULT 1.0,
  evidence_id INTEGER,
  detail TEXT,
  observed_utc TEXT,
  UNIQUE (snapshot_id, subject_table, subject_id, provider, evidence_id),
  -- evidence must belong to the SAME snapshot; the (subject_table,
  -- subject_id) pair must name a same-snapshot row of a known table
  -- (triggers support_subject_valid_*/support_evidence_same_snapshot_*).
  FOREIGN KEY (evidence_id, snapshot_id) REFERENCES evidence (id, snapshot_id)
)

evidence(
  id INTEGER PRIMARY KEY,
  snapshot_id INTEGER NOT NULL REFERENCES snapshot (id),
  kind TEXT NOT NULL,
  ref TEXT NOT NULL,
  digest TEXT,
  summary TEXT NOT NULL DEFAULT '',
  payload TEXT,                         -- JSON, provider-defined
  provider TEXT NOT NULL DEFAULT '',
  created_utc TEXT,
  UNIQUE (id, snapshot_id)              -- enables the support composite FK
)

provider_record(
  id INTEGER PRIMARY KEY,
  snapshot_id INTEGER NOT NULL REFERENCES snapshot (id),
  provider TEXT NOT NULL,
  provider_version TEXT NOT NULL,
  capabilities TEXT NOT NULL,           -- JSON {family: 'complete'|'partial'|'unavailable'|'unknown'}
  scope TEXT NOT NULL DEFAULT '{}',
  authority TEXT NOT NULL DEFAULT 'fallback',
  invoked INTEGER NOT NULL DEFAULT 1,
  UNIQUE (snapshot_id, provider)
)

fact(... v1 ... + epistemic_state, analysis_depth, completeness, provider,
     provider_revision, stable_subject TEXT NOT NULL DEFAULT '',
     stable_id TEXT NOT NULL DEFAULT '')
     -- stable_id = 'fact:' + sha256(stable_subject, predicate, object), so two
     -- facts about the same subject never collide.
```

Immutability triggers (P0-4 + staleness redesign + v3 completion): once
`snapshot.state = 'finalized'`, INSERT/UPDATE/DELETE on
entity/relation/fact/unresolved_edge/support/evidence/provider_record AND
invariant/contract/incident/change for that snapshot_id MUST RAISE(ABORT)
(BEFORE triggers). The snapshot metadata row itself is frozen the same way:
the ONLY legal `snapshot` UPDATE is draft → finalized; deletion and identity
mutation of a finalized snapshot abort. Draft snapshots are mutable; scan()
finalizes inside ONE transaction. Failure → rollback; no partial truth is
ever visible.

## 3. Core Graph API v2 additions (graph.py)

```python
class SnapshotError(Exception): ...

Graph.open(path, create=True)
Graph.latest_finalized_snapshot() -> dict | None      # deterministic
Graph.snapshot_by_revision(revision_digest) -> dict | None
Graph.snapshot_for(identity: dict) -> dict | None
Graph.begin_draft(identity: dict) -> int              # inserts state='draft'
Graph.finalize_snapshot(snapshot_id) -> None          # draft -> finalized
Graph.abort_draft(snapshot_id) -> None                # delete all draft rows
Graph.export_json(snapshot_id=None) -> dict
    # snapshot_id None -> latest finalized; NEVER a union across snapshots;
    # raises SnapshotError when there is no finalized snapshot
Graph.stats(snapshot_id=None) -> dict                 # same resolution rule
Graph.add_unresolved_edge(snapshot_id, src_key, dst_raw, kind, *,
    provider, provider_revision='', candidates=(), confidence=0.3,
    completeness='unknown', evidence=()) -> int
Graph.completeness(snapshot_id=None, family=None) -> dict
    # -> {'snapshot': revision_digest, 'families': {family: verdict},
    #     'provider_scopes': {provider: {observations: [{authority, scope,
    #         enumeration_completeness, resolution_completeness, ...}]}},
    #     'relations_completeness': {'site': verdict,
    #         'target_resolution': verdict, ...}, ...}
Graph.verify_snapshot_digest(snapshot_id) -> bool     # self-enforcing digest
Graph.upsert_source_revision(identity) -> int         # level 1, append-only
Graph.source_revision_row(source_revision_id) -> dict | None
Graph.add_provider_observation(source_revision_id, provider, *,
    provider_version='', observation_kind='static', observation_digest='',
    scope=None, semantic_configuration='{}', authority='fallback',
    enumeration_completeness='unknown',
    resolution_completeness='unknown') -> int         # level 2, append-only
Graph.link_snapshot_observation(snapshot_id, observation_id) -> None
Graph.observations(snapshot_id=None) -> list[dict]    # level 3 set
Graph.accumulate_support(snapshot_id, subject_table, subject_id, *,
    provider, provider_revision='', confidence=1.0, evidence_id=None,
    detail=None) -> int
Graph.record_provider(snapshot_id, provider, provider_version,
    capabilities: dict, invoked=True) -> int
Graph.diff_snapshots(old_id, new_id) -> dict
    # {added: [...stable_ids], removed: [...], changed: [...],
    #  unresolved_added: [...], completeness_delta: {...}}
# stale_sweep() is REMOVED from the operating model (finalized snapshots are
# immutable); keep the method only if trivially expressible as a draft-time
# helper, and mark it deprecated in a docstring.
```

Determinism: `export_json`/`stats`/`protocol`/`impact` etc. MUST resolve one
deterministic snapshot (latest finalized by default); the two-snapshot/reopen
regression test must prove no cross-snapshot mixing.

## 4. Entity stable IDs + typed endpoints (P0-6)

- Relations are created from **typed keys** `(kind, stable_id)`; the resolver
  maps `src_key`/`dst_key` exactly. Ambiguous suffix matching may only be
  used as an explicitly recorded resolution step with its evidence.
- Generic scanner IDs: `file:<relpath>`, `module:<relpath>`,
  `sym:<lang>:<relpath>::<name>`, `test:<relpath>::<name>`, `pkg:<relpath>`,
  `schema:<relpath>::<table>`, `config:<relpath>::<KEY>`, `repo:.`.
- The generic test extractor MUST NOT emit `tests(rel, rel)`: emit a typed
  relation `test:<relpath>` → target (the file/symbol it exercises) or an
  unresolved edge when the target is unknown. The Tangerine generic adapter
  MUST emit a `tests` relation for `@test` functions to their target when
  resolvable, else an unresolved edge.
- `impact()`/`_closure()` must validate the SOURCE KIND of `tests` edges
  instead of accepting any source.

## 5. Provider SPI (P0-7) — `system_intel/providers/`

```python
# base.py
class ProviderCapability(NamedTuple):      # or dataclass
    family: str          # 'entities'|'relations'|'facts'|'calls'|'contracts'
                         # |'invariants'|'tests'|'runtime'|'history'|'ownership'
    verdict: str         # 'complete'|'partial'|'unavailable'|'unknown'
    note: str = ''

class SemanticProvider(Protocol):
    provider_id: str
    provider_version: str
    def identity(self, root) -> dict: ...          # section 1 identity fields
    def capabilities(self) -> list[ProviderCapability]: ...
    def snapshot(self, root, *, commit_sha=None) -> 'ProviderSnapshot': ...
    # ProviderSnapshot: entities[], relations[], facts[], unresolved[],
    #   evidence[], providers[], semantic_configuration dict
    def query(self, snapshot, operation: str, **kwargs) -> dict: ...
    def delta(self, old_snapshot, new_snapshot) -> dict: ...
    def completeness(self, family: str) -> str: ...
```

FEDERATION POLICY (claim-scoped, never winner-takes-all): providers are
projected in authority order (primary first), and authority is per CLAIM, not
per provider. Every provider contributes its UNIQUE knowledge with its own
authority/completeness (generic-static's Docker/SQL/config entities survive
even when tangerine-native is primary). The same typed assertion keeps the
higher-authority canonical row, adds one `support` observation per provider,
and PRESERVES any disagreement in the support detail (`conflict:<json>`)
instead of overwriting it.

EVERY valid provider invocation is an immutable ProviderObservation —
including degraded/unavailable/evidence-only snapshots. "Usable" only decides
which snapshot supplies canonical rows; a failure ("artifact corrupt",
"compiler absent") is knowledge and carries its own revision identity, so a
changed failure reason is a NEW federated revision. `scope` carries the
provider's semantic scope (target/features, module sets, test globs,
platform/horizon) — completeness without scope is meaningless. The
provider-set digest is computed AFTER the final invoked set is known
(including an appended fallback).

CONTRACT BRIDGE (one canonical representation): the documented neutral
convention is a fact `predicate='contract_ref'` with
`object='contract:<kind>:<name>'` and the holder/referenced symbol as the
subject. Federation materializes each such assertion into the dedicated
`contract` table exactly once (stable component identity, provider and
observation provenance via support); Contract entities and `constrained_by`
relations are DERIVED views, never competing sources of truth.

COMPLETENESS IS ASSERTED, NEVER INFERRED: `complete` comes only from an
authoritative producer's capability record under its scope. Rows in storage
prove existence and yield at most `partial`; the absence of an unresolved
row never proves closed-world enumeration.

- `providers/generic_static.py`: wraps `extract_core` (renamed semantics:
  the zero-install fallback). Capabilities: entities complete (Tier 0/1),
  relations partial, calls unavailable, runtime unknown.
- `providers/tangerine_native.py`: authoritative for Tangerine.
  - Pipeline: run the native compiler with `TANGERINE_SNAPSHOT=<artifact>`
    (artifact `<path>` + `<path>.lineages`) and/or `tg server
    --snapshot-only --snapshot=<path>` (framed §39 protocol: 4-byte BE
    length prefix per frame; request fields protocol_version, request_id,
    operation, payload; response fields protocol_version, request_id, ok
    ('true'/'false'), kind, keys-count, keys..., error).
  - The provider must discover the compiler binary through ONE discovery
    authority: the release compiler is `build/tg` (materialized by the
    bootstrap ladder), with the repo-root `build/tg` as the second candidate
    and `TANGERINE_NATIVE_COMPILER` as the explicit override. It MUST degrade
    to `unavailable` capabilities (never fabricate) when the binary/artifact
    is absent. `build/bootstrap/tg` is NOT an authority.
  - Native stable IDs must use the artifact's persistent declaration/lineage
    digest (never a bare textual key); the textual key/name/module are
    attributes. A fallback to the textual key is allowed ONLY when the
    artifact carries no persistent digest, and must be recorded as degraded
    identity.
  - Project: symbols→Symbol/Module, types→Symbol, calls→calls relations,
    indirect_calls→unresolved edges with completeness 'unknown',
    contracts→Contract rows, tests→Test + tests relations, effects/
    capabilities/ownership→facts with analysis_depth 3, runtime facts→4.
  - Capability verdicts must mirror the native snapshot's own
    completeness fields (never claim complete for an Unknown family).
- `providers/registry.py`: `register(provider)`, `default_providers()`,
  `provider_set_digest()`, `select_for(root)`.

## 6. Protocol v2 + ingest (SA2)

- Stable record IDs: `<record_kind>:<stable_id>` (never SQLite row ids).
- Envelope: `{protocol_version: 2, snapshot: {revision_digest, identity
  fields}, provider_set: [...], completeness: {family: verdict},
  records: {...}}`.
- Every record carries: `stable_id`, `provider`, `provider_version`,
  `epistemic_state`, `analysis_depth`, `completeness`, `confidence`
  `{value, basis}`, `provenance` `{kind, derived_from, last_verified,
  uncertainty}`, and `evidence` references (ids + digests).
- Relations carry typed endpoint keys and a `resolved` flag; unresolved
  edges are exported as `UnresolvedClaim` records with raw target,
  candidates, resolver evidence.
- Requirements are first-class stored records (new `requirement` table is
  OUT OF SCOPE for v2 — accept caller-supplied and preserve them through
  ingest), counterexamples link claims to evidence (`Counterexample`
  records with `claim_id` + `evidence`), `Runtime` provenance supported.
- Symmetric ingest: `ingest_protocol(graph, doc, *, snapshot_id,
  provider_id, provider_version) -> dict` — validate + persist evidence/
  support/unresolved claims; never required to understand the producing
  consumer.
- `PROTOCOL.md`: standalone specification (no Tangerine internals needed).

## 7. CI gate (SA4)

- `Makefile`: `system-intel-test` (runs the unittest suite + CLI smoke) and
  `system-intel-gate` (test + protocol two-snapshot regression + provider
  conformance).
- `.woodpecker/system-intel-generic.yaml` (the compiler-free Python lane;
  steps `system-intel-test`, `system-intel-gate`) and
  `.woodpecker/system-intel-native.yaml` (Darwin/arm64; consumes the
  bootstrap-materialized `build/tg`, asserts `tangerine-native` is selected
  and a real SemanticSnapshot is consumed, and fails closed when `build/tg`
  is missing). BOTH carry release-required steps and are listed in
  `.woodpecker/gate.yaml` `depends_on` and
  `.woodpecker/release_required_jobs.txt` (the exact-set verifier must stay
  green: `scripts/check_ci_required_jobs.sh`).
- The gate MUST include: multi-snapshot protocol determinism (two independent
  DBs → equal `semantic_digest`), failed-transaction rollback, dirty-worktree
  identity, unresolved-edge preservation, typed endpoint collisions, runtime
  provenance, cross-snapshot FK rejection, zero-entity rescan, stale/removed
  relation+fact behavior (now via `diff_snapshots`), observation freshness,
  full snapshot immutability, support/evidence structural integrity, symlink
  handling, DB self-contamination exclusion, provider conformance.

## 8. Validation commands (all workstreams)

```bash
cd "$(git rev-parse --show-toplevel)"
python3 -m unittest discover -s system_intel/tests -v
bash system_intel/tools/system_intel.sh --help
bash system_intel/tools/system_intel.sh scan system_intel/tests/fixtures/mini_repo --db /tmp/intel_v2.db
bash system_intel/tools/system_intel.sh protocol /tmp/intel_v2.db | head
python3 - <<'PY'
from system_intel.graph import Graph
with Graph.open('/tmp/intel_v2.db', create=False) as g:
    print(g.latest_finalized_snapshot()['revision_digest'])
PY
```
