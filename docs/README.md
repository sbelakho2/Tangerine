# Tangerine Documentation

## Layout

- **`docs/current/`** — the normative, current documents. The memory model
  (`memory_model.md`), the grammar (`grammar.md`), and the pipeline manifest
  (`pipeline_manifest.md`) are the authoritative trio for the self-hosted
  compiler; the remaining documents describe the current language surface,
  standard library, targets, and engineering process.
- **`docs/history/`** — **NON-NORMATIVE** material: migration records,
  audit chronology, and superseded design data (each file carries a
  conspicuous NON-NORMATIVE header). Nothing in `docs/history/` is a
  current design assumption; where a history document and a current
  document disagree, the current document wins.

## Document status policy

A document that narrates a migration, an audit, or a superseded design
belongs in `docs/history/` with the NON-NORMATIVE header. A document that
describes what the compiler implements today belongs in `docs/current/`.
