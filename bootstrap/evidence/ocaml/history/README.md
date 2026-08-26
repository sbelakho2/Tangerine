# OCaml stage0 evidence — exact-HEAD artifacts, not current state

This directory holds EXACT-HEAD EVIDENCE RECORDS only (audit P1 item 3:
checked-in evidence may remain only as explicitly named
fixtures/history, never as "current state").

## Policy

- Each `*.json` record is the machine-verified output of
  `scripts/ocaml_seed_evidence.sh` for one tested commit. The schema
  the script writes is exact: every record carries a `git_commit`
  field (the tested SHA), the toolchain from
  `bootstrap/ocaml-toolchain.lock`, the unit-test inventory, the
  selfcheck results, and the bootstrap-check debt/gates. A record
  without a `git_commit` field does not belong here.
- A record describes the commit it names — nothing more. It is a
  FIXTURE OF THAT HEAD, never the current state of the seed.
- CURRENT evidence is NOT committed here: it is produced by
  `scripts/ocaml_seed_evidence.sh` against each tested SHA (and by the
  CI `ocaml-seed-health` job's runs). Run the script to get the
  up-to-date record for the working tree.
- Files that are neither exact-HEAD schema records nor documentation
  are moved under `history/` (e.g. the pre-schema `.evidence` text
  dumps from 2026-08-25). `history/` is explicitly named history and
  is not current state either.
