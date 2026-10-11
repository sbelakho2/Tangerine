-- Tangerine System Intelligence — persistent graph schema (SQLite), v3.
-- Standalone: no consumer-specific concepts live in the core.  Three identity
-- levels (P0 observation model):
--
--   source_revision       level 1: repository identity + source tree +
--                         target/semantic configuration inputs
--   provider_observation  level 2: ONE provider's immutable observation over
--                         a source revision (static/runtime/verification/
--                         history), carrying scope, authority and the
--                         enumeration/resolution completeness verdicts
--   snapshot              level 3 (FederatedSnapshot): the immutable set of
--                         provider_observation ids that answers queries
--
-- Every snapshot-owned row is bound to a snapshot; finalized snapshots are
-- IMMUTABLE (BEFORE triggers abort every INSERT/UPDATE/DELETE against the
-- snapshot-owned tables while the owning snapshot state is 'finalized';
-- "nothing inside a finalized snapshot becomes stale" — removed content is
-- represented by newer snapshots and `diff_snapshots`, never by mutating
-- history).  The snapshot metadata row itself is frozen once finalized:
-- only the draft -> finalized transition is permitted.
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
INSERT INTO schema_version (version)
  SELECT 3 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
UPDATE schema_version SET version = 3 WHERE version < 3;

-- ── level 1: source revision ─────────────────────────────────────────────
-- source_revision is the SOURCE + CONFIGURATION identity.  The same source
-- commit under a different target/feature set is a DIFFERENT revision.
-- repo_root is provenance metadata, never identity.
CREATE TABLE IF NOT EXISTS source_revision (
  id                     INTEGER PRIMARY KEY AUTOINCREMENT,
  repo_identity          TEXT NOT NULL,
  source_revision        TEXT NOT NULL,
  tree_digest            TEXT NOT NULL,
  target                 TEXT NOT NULL DEFAULT '',
  semantic_configuration TEXT NOT NULL DEFAULT '{}',
  revision_digest        TEXT NOT NULL UNIQUE,
  created_utc            TEXT,
  UNIQUE (repo_identity, source_revision, tree_digest, target,
          semantic_configuration)
);

-- ── level 2: provider observation ────────────────────────────────────────
-- ONE provider's immutable observation over a source revision.  A new
-- runtime trace / Kiwi verification / historical record is a NEW row; the
-- observation_digest is content-derived (never a DB row id) and the
-- federated set digest changes, so freshness can never be masked by
-- source-revision reuse.
CREATE TABLE IF NOT EXISTS provider_observation (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  provider              TEXT NOT NULL,
  provider_version      TEXT NOT NULL DEFAULT '',
  source_revision_id    INTEGER NOT NULL REFERENCES source_revision(id),
  observation_kind      TEXT NOT NULL DEFAULT 'static'
                        CHECK (observation_kind IN
                               ('static','runtime','verification','history')),
  observation_digest    TEXT NOT NULL,
  scope                 TEXT NOT NULL DEFAULT '{}',
  semantic_configuration TEXT NOT NULL DEFAULT '{}',
  authority             TEXT NOT NULL DEFAULT 'fallback'
                        CHECK (authority IN
                               ('native','compiler','fallback','external')),
  enumeration_completeness TEXT NOT NULL DEFAULT 'unknown',
  resolution_completeness  TEXT NOT NULL DEFAULT 'unknown',
  created_utc           TEXT,
  UNIQUE (provider, provider_version, source_revision_id, observation_kind,
          observation_digest)
);

-- ── level 3: federated snapshot ──────────────────────────────────────────
-- The immutable set of provider observations.  The identity tuple is
-- (source revision, provider set, observation set); one tuple maps to at
-- most one snapshot.
CREATE TABLE IF NOT EXISTS snapshot (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  repo_root             TEXT,
  repo_identity         TEXT NOT NULL,
  source_revision       TEXT NOT NULL,
  tree_digest           TEXT NOT NULL,
  semantic_configuration TEXT NOT NULL DEFAULT '{}',
  provider_set_digest   TEXT NOT NULL DEFAULT '',
  observation_set_digest TEXT NOT NULL DEFAULT '',
  source_revision_id    INTEGER REFERENCES source_revision(id),
  revision_digest       TEXT NOT NULL,
  state                 TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','finalized')),
  created_utc           TEXT,
  finalized_utc         TEXT,
  UNIQUE (repo_identity, source_revision, tree_digest,
          semantic_configuration, provider_set_digest, observation_set_digest)
);
CREATE UNIQUE INDEX IF NOT EXISTS snapshot_revision_digest_uniq
  ON snapshot (revision_digest);

-- The federated observation set (append-only while draft; frozen when the
-- snapshot finalizes).
CREATE TABLE IF NOT EXISTS snapshot_observation (
  snapshot_id    INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  observation_id INTEGER NOT NULL REFERENCES provider_observation(id),
  PRIMARY KEY (snapshot_id, observation_id)
);

-- Universal graph entities.  `kind` is open-ended; the documented set is
-- Repository, Project, Package, Module, File, Symbol, Service, Resource,
-- API, Contract, Schema, Event, Queue, Configuration, Deployment, Test,
-- Owner, Invariant, Incident, Change, RuntimePath, DataFlow.  Identity is
-- (snapshot_id, stable_id); qualified_name is display/resolution metadata
-- and is deliberately NOT unique (typed endpoint collisions are resolved by
-- stable_id).
CREATE TABLE IF NOT EXISTS entity (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id    INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL,
  name           TEXT NOT NULL,
  qualified_name TEXT NOT NULL,
  file           TEXT,
  line           INTEGER,
  tier           INTEGER NOT NULL DEFAULT 0,
  provenance     TEXT NOT NULL DEFAULT 'observed',
  confidence     REAL NOT NULL DEFAULT 1.0,
  derived_from   TEXT NOT NULL DEFAULT '[]',
  last_verified  TEXT,
  uncertainty    TEXT,
  stale          INTEGER NOT NULL DEFAULT 0,
  attrs          TEXT NOT NULL DEFAULT '{}',
  stable_id      TEXT NOT NULL,
  epistemic_state TEXT NOT NULL DEFAULT 'observed',
  analysis_depth INTEGER NOT NULL DEFAULT 0,
  completeness   TEXT NOT NULL DEFAULT 'partial',
  provider       TEXT NOT NULL DEFAULT '',
  provider_revision TEXT NOT NULL DEFAULT '',
  UNIQUE (snapshot_id, stable_id),
  UNIQUE (id, snapshot_id)             -- enables the composite FKs below
);
CREATE INDEX IF NOT EXISTS entity_kind_idx ON entity (snapshot_id, kind);
CREATE INDEX IF NOT EXISTS entity_name_idx ON entity (snapshot_id, name);

-- Universal relationships.  `kind` is open-ended; the documented set is
-- contains, imports, calls, reads, writes, creates, deletes, publishes,
-- subscribes, depends_on, implements, extends, tests, deploys_with, owns,
-- configured_by, constrained_by, compatible_with, breaks_if_changed,
-- flows_to.  Endpoints are resolved by typed (kind, stable_id) keys; an
-- unresolved target keeps a first-class unresolved_edge row plus a relation
-- row with resolved=0 / dst_id NULL.  The composite foreign keys make a
-- cross-snapshot relation structurally impossible.
--
-- `site_completeness` and `target_resolution_completeness` are SEPARATE:
-- all call sites may be enumerated while some indirect targets stay
-- unknown.
CREATE TABLE IF NOT EXISTS relation (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  src_id        INTEGER NOT NULL,
  dst_id        INTEGER,
  kind          TEXT NOT NULL,
  tier          INTEGER NOT NULL DEFAULT 0,
  provenance    TEXT NOT NULL DEFAULT 'inferred',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  last_verified TEXT,
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  attrs         TEXT NOT NULL DEFAULT '{}',
  src_key       TEXT NOT NULL DEFAULT '',
  dst_key       TEXT NOT NULL DEFAULT '',
  resolved      INTEGER NOT NULL DEFAULT 1,
  epistemic_state TEXT NOT NULL DEFAULT 'inferred',
  analysis_depth INTEGER NOT NULL DEFAULT 0,
  completeness  TEXT NOT NULL DEFAULT 'partial',
  site_completeness TEXT NOT NULL DEFAULT 'unknown',
  target_resolution_completeness TEXT NOT NULL DEFAULT 'unknown',
  provider      TEXT NOT NULL DEFAULT '',
  provider_revision TEXT NOT NULL DEFAULT '',
  FOREIGN KEY (src_id, snapshot_id) REFERENCES entity (id, snapshot_id),
  FOREIGN KEY (dst_id, snapshot_id) REFERENCES entity (id, snapshot_id),
  -- exact biconditional: resolved=1 <=> the endpoint is bound
  CHECK ((dst_id IS NOT NULL AND resolved = 1)
         OR (dst_id IS NULL AND resolved = 0))
);
CREATE INDEX IF NOT EXISTS relation_src_idx ON relation (snapshot_id, src_id, kind);
CREATE INDEX IF NOT EXISTS relation_dst_idx ON relation (snapshot_id, dst_id, kind);
CREATE UNIQUE INDEX IF NOT EXISTS relation_resolved_uniq
  ON relation (snapshot_id, src_id, dst_id, kind) WHERE dst_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS relation_unresolved_uniq
  ON relation (snapshot_id, src_id, dst_key, kind) WHERE dst_id IS NULL;

-- Unresolved targets observed by a provider: raw target kept verbatim plus
-- candidate stable_ids and evidence.  First-class truth, not an error state.
CREATE TABLE IF NOT EXISTS unresolved_edge (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot (id),
  src_key       TEXT NOT NULL,
  dst_raw       TEXT NOT NULL,
  kind          TEXT NOT NULL,
  provider      TEXT NOT NULL,
  provider_revision TEXT NOT NULL DEFAULT '',
  candidates    TEXT NOT NULL DEFAULT '[]',
  confidence    REAL NOT NULL DEFAULT 0.3,
  completeness  TEXT NOT NULL DEFAULT 'unknown',
  resolution_completeness TEXT NOT NULL DEFAULT 'unknown',
  evidence      TEXT NOT NULL DEFAULT '[]',
  created_utc   TEXT
);
CREATE INDEX IF NOT EXISTS unresolved_edge_snapshot_idx ON unresolved_edge (snapshot_id, kind);

-- Observations supporting canonical rows.  The (subject_table, subject_id)
-- pair is structurally validated against the same snapshot (triggers
-- below) and evidence_id must belong to the SAME snapshot (composite FK).
CREATE TABLE IF NOT EXISTS support (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot (id),
  subject_table TEXT NOT NULL,
  subject_id    INTEGER NOT NULL,
  provider      TEXT NOT NULL,
  provider_revision TEXT NOT NULL DEFAULT '',
  confidence    REAL NOT NULL DEFAULT 1.0,
  evidence_id   INTEGER,
  observation_id INTEGER REFERENCES provider_observation (id),
  detail        TEXT,
  observed_utc  TEXT,
  UNIQUE (snapshot_id, subject_table, subject_id, provider, observation_id,
          evidence_id),
  FOREIGN KEY (evidence_id, snapshot_id) REFERENCES evidence (id, snapshot_id)
);

CREATE TABLE IF NOT EXISTS evidence (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot (id),
  kind          TEXT NOT NULL,
  ref           TEXT NOT NULL,
  digest        TEXT,
  summary       TEXT NOT NULL DEFAULT '',
  payload       TEXT,
  provider      TEXT NOT NULL DEFAULT '',
  created_utc   TEXT,
  UNIQUE (id, snapshot_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS evidence_id_snapshot_uniq
  ON evidence (id, snapshot_id);

CREATE TABLE IF NOT EXISTS provider_record (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot (id),
  provider      TEXT NOT NULL,
  provider_version TEXT NOT NULL,
  capabilities  TEXT NOT NULL,
  scope         TEXT NOT NULL DEFAULT '{}',
  authority     TEXT NOT NULL DEFAULT 'fallback',
  invoked       INTEGER NOT NULL DEFAULT 1,
  UNIQUE (snapshot_id, provider)
);

-- Minimal subject/predicate/object facts ("checkout publishes OrderCreated").
CREATE TABLE IF NOT EXISTS fact (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  subject       TEXT NOT NULL,
  predicate     TEXT NOT NULL,
  object        TEXT NOT NULL,
  tier          INTEGER NOT NULL DEFAULT 0,
  provenance    TEXT NOT NULL DEFAULT 'observed',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  last_verified TEXT,
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  epistemic_state TEXT NOT NULL DEFAULT 'observed',
  analysis_depth INTEGER NOT NULL DEFAULT 0,
  completeness  TEXT NOT NULL DEFAULT 'partial',
  provider      TEXT NOT NULL DEFAULT '',
  provider_revision TEXT NOT NULL DEFAULT '',
  stable_subject TEXT NOT NULL DEFAULT '',
  stable_id     TEXT NOT NULL DEFAULT '',
  UNIQUE (snapshot_id, subject, predicate, object)
);

-- Invariants: conditions that must remain true.  May be declared or
-- inferred; both keep provenance/confidence.
CREATE TABLE IF NOT EXISTS invariant (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  statement     TEXT NOT NULL,
  component_qn  TEXT,
  tier          INTEGER NOT NULL DEFAULT 0,
  provenance    TEXT NOT NULL DEFAULT 'declared',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  last_verified TEXT,
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  UNIQUE (snapshot_id, statement, component_qn)
);

-- Contracts: compatibility boundaries (api/schema/event/cli/config/format).
CREATE TABLE IF NOT EXISTS contract (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL,
  name          TEXT NOT NULL,
  component_qn  TEXT,
  format        TEXT,
  tier          INTEGER NOT NULL DEFAULT 0,
  provenance    TEXT NOT NULL DEFAULT 'declared',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  last_verified TEXT,
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  attrs         TEXT NOT NULL DEFAULT '{}',
  stable_id     TEXT NOT NULL DEFAULT '',
  UNIQUE (snapshot_id, kind, name)
);

-- Historical model: incidents, changes, failures, rollbacks.
CREATE TABLE IF NOT EXISTS incident (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  summary       TEXT NOT NULL,
  component_qn  TEXT,
  occurred_utc  TEXT,
  severity      TEXT,
  provenance    TEXT NOT NULL DEFAULT 'historically_supported',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  attrs         TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS change (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  commit_sha    TEXT,
  summary       TEXT NOT NULL,
  files         TEXT NOT NULL DEFAULT '[]',
  outcome       TEXT,
  provenance    TEXT NOT NULL DEFAULT 'historically_supported',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  attrs         TEXT NOT NULL DEFAULT '{}'
);

-- ── source/observation immutability (append-only, never mutated) ─────────
CREATE TRIGGER IF NOT EXISTS source_revision_no_update
BEFORE UPDATE ON source_revision
BEGIN SELECT RAISE(ABORT, 'source_revision is append-only and immutable'); END;

CREATE TRIGGER IF NOT EXISTS source_revision_no_delete
BEFORE DELETE ON source_revision
BEGIN SELECT RAISE(ABORT, 'source_revision is append-only and immutable'); END;

CREATE TRIGGER IF NOT EXISTS provider_observation_no_update
BEFORE UPDATE ON provider_observation
BEGIN SELECT RAISE(ABORT, 'provider_observation is append-only and immutable'); END;

CREATE TRIGGER IF NOT EXISTS provider_observation_no_delete
BEFORE DELETE ON provider_observation
BEGIN SELECT RAISE(ABORT, 'provider_observation is append-only and immutable'); END;

-- ── snapshot metadata freeze ─────────────────────────────────────────────
-- A finalized snapshot's identity fields/state are frozen: the only legal
-- snapshot UPDATE is the draft -> finalized transition.  Deletion is
-- reserved for explicit DB-level maintenance tooling (which must disable
-- the trigger), never for normal operation.
CREATE TRIGGER IF NOT EXISTS snapshot_no_update_finalized
BEFORE UPDATE ON snapshot
WHEN OLD.state = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: metadata is immutable'); END;

CREATE TRIGGER IF NOT EXISTS snapshot_no_delete_finalized
BEFORE DELETE ON snapshot
WHEN OLD.state = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: immutable'); END;

CREATE TRIGGER IF NOT EXISTS snapshot_observation_no_insert_finalized
BEFORE INSERT ON snapshot_observation
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: observation set is immutable'); END;

CREATE TRIGGER IF NOT EXISTS snapshot_observation_no_update_finalized
BEFORE UPDATE ON snapshot_observation
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: observation set is immutable'); END;

CREATE TRIGGER IF NOT EXISTS snapshot_observation_no_delete_finalized
BEFORE DELETE ON snapshot_observation
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: observation set is immutable'); END;

-- ── support structural integrity ─────────────────────────────────────────
-- The polymorphic (subject_table, subject_id) pair must name a row of a
-- known snapshot-owned table in the SAME snapshot; a bad pair can never be
-- written through the public API.
CREATE TRIGGER IF NOT EXISTS support_subject_valid_insert
BEFORE INSERT ON support
WHEN NEW.subject_table NOT IN
       ('entity','relation','fact','unresolved_edge','invariant','contract','incident','change')
  OR (NEW.subject_table = 'entity' AND NOT EXISTS
        (SELECT 1 FROM entity WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'relation' AND NOT EXISTS
        (SELECT 1 FROM relation WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'fact' AND NOT EXISTS
        (SELECT 1 FROM fact WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'unresolved_edge' AND NOT EXISTS
        (SELECT 1 FROM unresolved_edge WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'invariant' AND NOT EXISTS
        (SELECT 1 FROM invariant WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'contract' AND NOT EXISTS
        (SELECT 1 FROM contract WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'incident' AND NOT EXISTS
        (SELECT 1 FROM incident WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'change' AND NOT EXISTS
        (SELECT 1 FROM change WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
BEGIN
  SELECT RAISE(ABORT, 'support subject is not a same-snapshot row of a known table');
END;

CREATE TRIGGER IF NOT EXISTS support_subject_valid_update
BEFORE UPDATE ON support
WHEN NEW.subject_table NOT IN
       ('entity','relation','fact','unresolved_edge','invariant','contract','incident','change')
  OR (NEW.subject_table = 'entity' AND NOT EXISTS
        (SELECT 1 FROM entity WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'relation' AND NOT EXISTS
        (SELECT 1 FROM relation WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'fact' AND NOT EXISTS
        (SELECT 1 FROM fact WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'unresolved_edge' AND NOT EXISTS
        (SELECT 1 FROM unresolved_edge WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'invariant' AND NOT EXISTS
        (SELECT 1 FROM invariant WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'contract' AND NOT EXISTS
        (SELECT 1 FROM contract WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'incident' AND NOT EXISTS
        (SELECT 1 FROM incident WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
  OR (NEW.subject_table = 'change' AND NOT EXISTS
        (SELECT 1 FROM change WHERE id = NEW.subject_id AND snapshot_id = NEW.snapshot_id))
BEGIN
  SELECT RAISE(ABORT, 'support subject is not a same-snapshot row of a known table');
END;

-- Evidence referenced by a support row must belong to the SAME snapshot
-- (the composite FK covers fresh databases; these triggers also cover
-- databases created before the composite FK existed).
-- A support row's level-2 observation must be LINKED to the same snapshot.
CREATE TRIGGER IF NOT EXISTS support_observation_same_snapshot_insert
BEFORE INSERT ON support
WHEN NEW.observation_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM snapshot_observation so
      WHERE so.snapshot_id = NEW.snapshot_id
        AND so.observation_id = NEW.observation_id)
BEGIN
  SELECT RAISE(ABORT, 'support observation is not linked to the same snapshot');
END;

CREATE TRIGGER IF NOT EXISTS support_observation_same_snapshot_update
BEFORE UPDATE ON support
WHEN NEW.observation_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM snapshot_observation so
      WHERE so.snapshot_id = NEW.snapshot_id
        AND so.observation_id = NEW.observation_id)
BEGIN
  SELECT RAISE(ABORT, 'support observation is not linked to the same snapshot');
END;

CREATE TRIGGER IF NOT EXISTS support_evidence_same_snapshot_insert
BEFORE INSERT ON support
WHEN NEW.evidence_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM evidence WHERE id = NEW.evidence_id AND snapshot_id = NEW.snapshot_id)
BEGIN
  SELECT RAISE(ABORT, 'support evidence does not belong to the same snapshot');
END;

CREATE TRIGGER IF NOT EXISTS support_evidence_same_snapshot_update
BEFORE UPDATE ON support
WHEN NEW.evidence_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM evidence WHERE id = NEW.evidence_id AND snapshot_id = NEW.snapshot_id)
BEGIN
  SELECT RAISE(ABORT, 'support evidence does not belong to the same snapshot');
END;

-- ── snapshot-owned immutability (all families) ───────────────────────────
CREATE TRIGGER IF NOT EXISTS entity_no_insert_finalized
BEFORE INSERT ON entity
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: entity is immutable'); END;

CREATE TRIGGER IF NOT EXISTS entity_no_update_finalized
BEFORE UPDATE ON entity
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: entity is immutable'); END;

CREATE TRIGGER IF NOT EXISTS entity_no_delete_finalized
BEFORE DELETE ON entity
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: entity is immutable'); END;

CREATE TRIGGER IF NOT EXISTS relation_no_insert_finalized
BEFORE INSERT ON relation
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: relation is immutable'); END;

CREATE TRIGGER IF NOT EXISTS relation_no_update_finalized
BEFORE UPDATE ON relation
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: relation is immutable'); END;

CREATE TRIGGER IF NOT EXISTS relation_no_delete_finalized
BEFORE DELETE ON relation
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: relation is immutable'); END;

CREATE TRIGGER IF NOT EXISTS fact_no_insert_finalized
BEFORE INSERT ON fact
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: fact is immutable'); END;

CREATE TRIGGER IF NOT EXISTS fact_no_update_finalized
BEFORE UPDATE ON fact
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: fact is immutable'); END;

CREATE TRIGGER IF NOT EXISTS fact_no_delete_finalized
BEFORE DELETE ON fact
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: fact is immutable'); END;

CREATE TRIGGER IF NOT EXISTS unresolved_edge_no_insert_finalized
BEFORE INSERT ON unresolved_edge
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: unresolved_edge is immutable'); END;

CREATE TRIGGER IF NOT EXISTS unresolved_edge_no_update_finalized
BEFORE UPDATE ON unresolved_edge
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: unresolved_edge is immutable'); END;

CREATE TRIGGER IF NOT EXISTS unresolved_edge_no_delete_finalized
BEFORE DELETE ON unresolved_edge
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: unresolved_edge is immutable'); END;

CREATE TRIGGER IF NOT EXISTS support_no_insert_finalized
BEFORE INSERT ON support
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: support is immutable'); END;

CREATE TRIGGER IF NOT EXISTS support_no_update_finalized
BEFORE UPDATE ON support
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: support is immutable'); END;

CREATE TRIGGER IF NOT EXISTS support_no_delete_finalized
BEFORE DELETE ON support
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: support is immutable'); END;

CREATE TRIGGER IF NOT EXISTS evidence_no_insert_finalized
BEFORE INSERT ON evidence
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: evidence is immutable'); END;

CREATE TRIGGER IF NOT EXISTS evidence_no_update_finalized
BEFORE UPDATE ON evidence
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: evidence is immutable'); END;

CREATE TRIGGER IF NOT EXISTS evidence_no_delete_finalized
BEFORE DELETE ON evidence
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: evidence is immutable'); END;

CREATE TRIGGER IF NOT EXISTS provider_record_no_insert_finalized
BEFORE INSERT ON provider_record
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: provider_record is immutable'); END;

CREATE TRIGGER IF NOT EXISTS provider_record_no_update_finalized
BEFORE UPDATE ON provider_record
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: provider_record is immutable'); END;

CREATE TRIGGER IF NOT EXISTS provider_record_no_delete_finalized
BEFORE DELETE ON provider_record
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: provider_record is immutable'); END;

CREATE TRIGGER IF NOT EXISTS invariant_no_insert_finalized
BEFORE INSERT ON invariant
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: invariant is immutable'); END;

CREATE TRIGGER IF NOT EXISTS invariant_no_update_finalized
BEFORE UPDATE ON invariant
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: invariant is immutable'); END;

CREATE TRIGGER IF NOT EXISTS invariant_no_delete_finalized
BEFORE DELETE ON invariant
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: invariant is immutable'); END;

CREATE TRIGGER IF NOT EXISTS contract_no_insert_finalized
BEFORE INSERT ON contract
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: contract is immutable'); END;

CREATE TRIGGER IF NOT EXISTS contract_no_update_finalized
BEFORE UPDATE ON contract
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: contract is immutable'); END;

CREATE TRIGGER IF NOT EXISTS contract_no_delete_finalized
BEFORE DELETE ON contract
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: contract is immutable'); END;

CREATE TRIGGER IF NOT EXISTS incident_no_insert_finalized
BEFORE INSERT ON incident
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: incident is immutable'); END;

CREATE TRIGGER IF NOT EXISTS incident_no_update_finalized
BEFORE UPDATE ON incident
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: incident is immutable'); END;

CREATE TRIGGER IF NOT EXISTS incident_no_delete_finalized
BEFORE DELETE ON incident
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: incident is immutable'); END;

CREATE TRIGGER IF NOT EXISTS change_no_insert_finalized
BEFORE INSERT ON change
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: change is immutable'); END;

CREATE TRIGGER IF NOT EXISTS change_no_update_finalized
BEFORE UPDATE ON change
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: change is immutable'); END;

CREATE TRIGGER IF NOT EXISTS change_no_delete_finalized
BEFORE DELETE ON change
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: change is immutable'); END;
