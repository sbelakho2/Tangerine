# Artifact Policy

This repository distinguishes **source-of-truth artifacts** from **generated runtime outputs**.

## Tracked (allowed in git)

- Source code and docs (`std/`, `tg_compiler/`, `docs/`, `golden/`, etc.)
- Stable baseline data intentionally versioned for quality gates:
  - `.tg/cqs/baselines/**`
  - `.tg/cqs/baseline_caps.json`
  - `.tg/cqs/version.json`
- Directory placeholders (`.gitkeep`) where needed for expected layout.

## Untracked (must not be committed)

- Generated caches and indexes:
  - `.tg/cqs/cache/**`
- Generated reports and merged outputs:
  - `.tg/cqs/reports/*.json`
  - `.tg/cqs/reports/*.txt`
  - `.tg/cqs/coverage/runs/**`
- Editor build/package artifacts:
  - `tangerine-vscode/out/**`
  - `tangerine-vscode/*.vsix`

## Fixture policy

- Binary fixtures under `golden/` are allowed only when they are explicit test fixtures and documented by name.
- New binary fixtures should include a short rationale in the PR description.

## Enforcement

- CI should run hygiene checks before merge.
- Generated outputs should be reproducible from source and regenerated in CI where feasible.
