-- Tangerine System Intelligence — persistent graph schema (SQLite).
-- Standalone: no consumer-specific concepts (no Faktor/Kiwi identifiers)
-- live in the core.  Every fact/edge carries tier + provenance +
-- confidence + snapshot identity.  See README.md for the model.
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
INSERT INTO schema_version (version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);

CREATE TABLE IF NOT EXISTS snapshot (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  repo_root     TEXT NOT NULL,
  commit_sha    TEXT NOT NULL,
  created_utc   TEXT NOT NULL,
  schema_version INTEGER NOT NULL DEFAULT 1,
  UNIQUE (repo_root, commit_sha)
);

-- Universal graph entities.  `kind` is open-ended; the documented set is
-- Repository, Project, Package, Module, File, Symbol, Service, Resource,
-- API, Contract, Schema, Event, Queue, Configuration, Deployment, Test,
-- Owner, Invariant, Incident, Change, RuntimePath, DataFlow.
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
  UNIQUE (snapshot_id, kind, qualified_name)
);
CREATE INDEX IF NOT EXISTS entity_kind_idx ON entity (snapshot_id, kind);
CREATE INDEX IF NOT EXISTS entity_name_idx ON entity (snapshot_id, name);

-- Universal relationships.  `kind` is open-ended; the documented set is
-- contains, imports, calls, reads, writes, creates, deletes, publishes,
-- subscribes, depends_on, implements, extends, tests, deploys_with, owns,
-- configured_by, constrained_by, compatible_with, breaks_if_changed,
-- flows_to.
CREATE TABLE IF NOT EXISTS relation (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  src_id        INTEGER NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
  dst_id        INTEGER NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL,
  tier          INTEGER NOT NULL DEFAULT 0,
  provenance    TEXT NOT NULL DEFAULT 'inferred',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  last_verified TEXT,
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  attrs         TEXT NOT NULL DEFAULT '{}',
  UNIQUE (snapshot_id, src_id, dst_id, kind)
);
CREATE INDEX IF NOT EXISTS relation_src_idx ON relation (snapshot_id, src_id, kind);
CREATE INDEX IF NOT EXISTS relation_dst_idx ON relation (snapshot_id, dst_id, kind);

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
