# System Intelligence Protocol v2

A neutral, versioned exchange format for software-system intelligence. It is
defined here independently of any implementation: any tool can produce or
consume a document without knowing Tangerine's storage, and Tangerine never
assumes which product produced one. No orchestration identifiers, task
formats, agent names or workflow state appear in the protocol.

## Envelope

```json
{
  "protocol_version": 2,
  "generated_utc": "2026-10-10T22:00:00+00:00",
  "snapshot": {
    "revision_digest": "sha256:...",
    "repo_identity": "remote:github.com/acme/shop | path:...",
    "source_revision": "git sha | worktree:<base>:<digest> | content:<digest>",
    "tree_digest": "sha256:...",
    "semantic_configuration": {"target": "aarch64-apple-darwin", "...": "..."},
    "target": "aarch64-apple-darwin",
    "provider_set_digest": "sha256:...",
    "observation_set_digest": "sha256:...",
    "source_revision_digest": "sha256:...",
    "state": "finalized"
  },
  "provider_set": [
    {"provider": "tangerine-native", "version": "…", "capabilities": {"calls": "complete", "runtime": "unknown"}}
  ],
  "completeness": {"entities": "complete", "relations": "partial", "calls": "unknown"},
  "relations_completeness": {"site": "complete", "target_resolution": "partial"},
  "provider_scopes": {"tangerine-native": {"observations": [{"authority": "native", "enumeration_completeness": "complete", "resolution_completeness": "partial", "observation_digest": "sha256:..."}]}},
  "semantic_digest": "sha256:...",
  "records": { "...": [] }
}
```

A document describes EXACTLY ONE snapshot revision. Producers MUST NOT mix
records from different revisions; consumers MUST reject or flag documents
that claim otherwise.

`semantic_digest` is a canonical digest of the document's MEANING: it
excludes `generated_utc`, database row ids and filesystem provenance
(`repo_root`, row timestamps). Two independently produced databases with the
same logical content MUST yield the same `semantic_digest`, and a consumer
may use it to deduplicate observations across transports.

The three identity levels are explicit: the snapshot's source revision
(level 1), the `Observation` records (level 2 — one immutable observation per
provider, with its content-derived `observation_digest`), and the federated
snapshot (level 3 — `observation_set_digest` over the observation set). New
runtime/verification/history observations therefore change the revision
digest even when the source tree is unchanged.

## Record common fields

Every record carries, where meaningful:

| Field | Meaning |
| --- | --- |
| `id` | stable record id: `<Kind>:<stable_id>` (never a database row id) |
| `stable_id` | the subject's stable identity (namespace-qualified) |
| `epistemics.epistemic_state` | `observed` / `declared` / `inferred` / `historically_supported` / `uncertain` / `contradicted` |
| `epistemics.analysis_depth` | `0` filesystem · `1` lexical/syntax · `2` symbols/types · `3` deps/calls/data-flow · `4` runtime · `5` federation |
| `epistemics.completeness` | `complete` / `partial` / `unavailable` / `unknown` |
| `confidence` | `{ value: 0..1, basis: [...] }` |
| `provenance` | `{ kind, provider, provider_version, derived_from, last_verified, uncertainty }` |
| `evidence` | `[{ id, digest, ref }]` references to `Evidence` records |

Runtime observations MUST use `epistemic_state=observed`, `analysis_depth=4`
— never `inferred`.

## Record kinds

- **Requirement** — `{id, statement, status: open|met|unknown, refs[]}`.
  A thing that must hold for the system.
- **Entity** — `{stable_id, kind, name, qualified_name, file, line,
  epistemics, confidence, provenance}`. The object a `Relationship` or
  `Fact` stable_id DENOTES; without it consumers cannot tell what
  `src_key`/`dst_key` name. Identity is `(kind, stable_id)`; display names
  are attributes and are never used for resolution.
- **Observation** — `{provider, provider_version, observation_kind:
  static|runtime|verification|history, observation_digest, authority:
  native|compiler|fallback|external, scope,
  enumeration_completeness, resolution_completeness}`. One immutable
  observation backing the federated snapshot. `observation_digest` is
  content-derived, never a row id.
- **Fact** — `{subject, predicate, object, ...}`. Observed/declared/inferred
  structural truth. Fact identity is `fact:<sha256(stable_subject,
  predicate, object)>`, so several facts about one subject never share an
  id.
- **Claim** — a checkable assertion re-expressing a fact or invariant.
- **Invariant** — a condition that must remain true (`statement`, optional
  `component`).
- **Contract** — a compatibility boundary (`kind`, `name`, `component`,
  optional `format`).
- **Risk** — an uncertain claim or a historical incident, with `evidence`.
- **Change** — `{commit_sha, summary, files[], outcome}`.
- **Evidence** — what a claim/risk rests on: `{kind, ref, digest, summary,
  provider}`; `kind` is producer-defined (`trace`, `test-run`, `incident`,
  `counterexample`, `requirement`, ...).
- **Counterexample** — `{claim_id, description, evidence[]}`; a concrete
  refutation of a claim.
- **UnresolvedClaim** — `{src_key, raw_target, kind, candidates[], confidence,
  completeness, evidence[]}`. An observed edge whose target could not be
  resolved. First-class: "unknown" must never be indistinguishable from
  "nothing depends on this".
- **Relationship** — `{src_key, dst_key, kind, resolved}`; typed endpoint
  keys, never naked display names.
- **Provider** — `{provider, version, capabilities: {family: verdict},
  invoked}`.

## Completeness

`complete` — the family was exhaustively enumerated for this revision.
`partial` — enumerated with known gaps.
`unavailable` — the producer cannot answer this family at all.
`unknown` — the producer has not established whether it can.

Consumers SHOULD treat `unknown` conservatively (like "may be anything") and
MUST NOT read `unknown` as "nothing".

## Ingest

The protocol is symmetric. A consumer (verifier, runtime collector, CI,
human tool) MAY return a document to a producer. Ingest:

1. validates `protocol_version`;
2. targets a MUTABLE (draft) revision — finalized revisions are immutable
   truth; ingesting into a finalized revision must fail;
3. persists `Entity`, `Evidence`, `UnresolvedClaim`, `Counterexample`,
   `Requirement` records, accumulating `support` for subjects that resolve
   locally; entities are upserted by `(kind, stable_id)`, never by display
   name;
4. attributes everything to `provider`/`provider_version`;
5. records the ingested document as an IMMUTABLE observation: the document's
   canonical `semantic_digest` becomes an `observation_digest` on a linked
   `Observation` (kind `verification` by default, or the declared
   `observations` records), so the federated revision that includes it can
   never be confused with the source-only revision. Creating the observation
   is a PRECONDITION: if it fails, the ingest reports the error and writes
   NOTHING (no provenance-less evidence or support), and every support row it
   does write pins that exact `observation_id`;
6. counts and skips unknown record kinds — never crashes on future records.

This is how a verifier makes the system model smarter without the model
depending on the verifier.

## Versioning

- `protocol_version` is an integer; incompatible changes bump it.
- New record kinds may be added within a major version; consumers must
  tolerate unknown kinds (skip-and-count).
- Field additions within a version are optional for producers and consumers
  alike.

## Example

```json
{
  "protocol_version": 2,
  "generated_utc": "2026-10-10T22:00:00+00:00",
  "snapshot": {"revision_digest": "sha256:9f2c…", "state": "finalized"},
  "provider_set": [{"provider": "tangerine-native", "version": "0.4.0",
                    "capabilities": {"calls": "complete", "runtime": "unknown"}}],
  "completeness": {"entities": "complete", "calls": "complete", "runtime": "unknown"},
  "records": {
    "unresolved": [{
      "record": "UnresolvedClaim",
      "id": "UnresolvedClaim:unresolved:tg_compiler::runtime::emit:call:dynamic#B3#T",
      "src_key": "native:fn:tg_compiler::runtime::emit",
      "raw_target": "<indirect>",
      "kind": "calls",
      "candidates": [],
      "completeness": "unknown",
      "confidence": {"value": 0.3, "basis": []},
      "provenance": {"kind": "source_scan", "provider": "tangerine-native",
                     "provider_version": "0.4.0", "derived_from": [], "last_verified": null, "uncertainty": null},
      "evidence": []
    }],
    "evidence": [{
      "record": "Evidence",
      "id": "Evidence:ci-run-4711",
      "kind": "test-run",
      "ref": "https://ci.example/run/4711",
      "digest": "sha256:aa…",
      "summary": "regression suite exercised capture retry",
      "provider": "external-ci",
      "epistemics": {"epistemic_state": "observed", "analysis_depth": 4, "completeness": "complete"}
    }]
  }
}
```
