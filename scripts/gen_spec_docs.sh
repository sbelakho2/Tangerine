#!/usr/bin/env bash
#
# scripts/gen_spec_docs.sh — the reviewer's item 34 generate-then-diff
# discipline: the manually maintained normative facts reduced to the
# machine-readable schemas (docs/current/language_spec.toml,
# target_capabilities.toml, abi_schema.toml, compiler_pipeline.toml,
# stdlib_contracts.toml) + the GENERATED docs.
#
# This script regenerates EVERYTHING derived from the schemas:
#
#   - the feature registry (features.toml -> feature_registry.md, via
#     scripts/gen_feature_registry.sh — which also regenerates the item-32
#     completeness model and the public-API manifest);
#   - the stdlib status (stdlib_contracts.toml -> stdlib_completeness.md,
#     via scripts/gen_stdlib_completeness.sh);
#   - the target matrix (target_capabilities.toml ->
#     docs/current/target_capabilities.md);
#   - the pipeline docs (compiler_pipeline.toml ->
#     docs/current/pipeline_stages.md);
#   - the ABI layout tables (abi_schema.toml -> docs/current/abi_layout.md);
#   - the stabilized layout tables (abi_schema.toml [layout.frozen] ->
#     docs/current/stabilized_layout_tables.md);
#   - the language spec tables (language_spec.toml ->
#     docs/current/language_spec.md);
#   - the exact test requirements (derived from all schemas ->
#     docs/current/test_requirements.md).
#
# MECHANICAL CHECKS (any failure exits non-zero, the docs are STILL written
# so the CI evidence-gate's `git diff --exit-code` can see the drift):
#   - every evidence artifact listed under a ✓ capability exists in the tree;
#   - the Object/Static-link/Dynamic-extern/Native-run chain is strictly
#     increasing per target (Native-run requires Dynamic-extern requires
#     Static-link requires Object);
#   - the front-end rows (Parse/Type/MIR) are true for EVERY target (the
#     front end is target-independent);
#   - every test requirement artifact exists in the tree.
#
# The CI evidence-gate job (the REQUIRED evidence-gate check) runs this
# script and then `git diff --exit-code` on the schemas + the generated
# docs: a STALE HAND-EDITED DOC CANNOT MERGE.
#
# Usage: scripts/gen_spec_docs.sh
# Runs without the bootstrap artifact (pure bash + python3).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$ROOT/docs/current"

if ! command -v python3 >/dev/null 2>&1; then
  echo "::error::gen_spec_docs.sh requires python3 (tomllib)" >&2
  exit 2
fi

# ── 1. The feature registry + the stdlib status (the existing generators) ──
if [ -x "$ROOT/scripts/gen_feature_registry.sh" ]; then
  bash "$ROOT/scripts/gen_feature_registry.sh" || {
    echo "::warning::gen_feature_registry.sh reported drift (the generated registry was still written — the diff gate decides)" >&2
  }
fi
if [ -x "$ROOT/scripts/gen_stdlib_completeness.sh" ]; then
  bash "$ROOT/scripts/gen_stdlib_completeness.sh" || {
    echo "::warning::gen_stdlib_completeness.sh reported drift (the generated completeness doc was still written — the diff gate decides)" >&2
  }
fi

# ── 2. The schema-rendered docs ──
python3 - "$ROOT" <<'PYEOF'
import os
import sys
import tomllib

ROOT = sys.argv[1]
DOCS = os.path.join(ROOT, "docs", "current")
FAILURES = []


def load(name):
    with open(os.path.join(DOCS, name), "rb") as f:
        return tomllib.load(f)


def exists(path):
    return os.path.exists(os.path.join(ROOT, path))


def fail(msg):
    FAILURES.append(msg)
    print("  FAIL  " + msg)


def md_cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def check_table(title, header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    for row in rows:
        lines.append("| " + " | ".join(md_cell(c) for c in row) + " |")
    return lines


lang = load("language_spec.toml")
caps = load("target_capabilities.toml")
abi = load("abi_schema.toml")
pipe = load("compiler_pipeline.toml")

# ─────────────────────────────────────────────────────────────
# target_capabilities.md — the target matrix (target_capabilities.toml)
# ─────────────────────────────────────────────────────────────
TARGETS = caps["target_order"]
CAPS = caps["capability_order"]

rows = []
for cap in CAPS:
    row = [cap]
    for t in TARGETS:
        row.append("✓" if caps["target"][t].get(cap) else "✗")
    rows.append(row)

t_lines = []
t_lines.append("# Tangerine Target Capability Matrix")
t_lines.append("")
t_lines.append("> **GENERATED EVIDENCE — do not edit by hand.** This matrix is")
t_lines.append("> rendered by `scripts/gen_spec_docs.sh` from")
t_lines.append("> [`target_capabilities.toml`](target_capabilities.toml), the")
t_lines.append("> machine-readable source of truth. The CI evidence-gate job")
t_lines.append("> regenerates it and runs `git diff --exit-code`, so a stale")
t_lines.append("> hand-edited matrix cannot merge.")
t_lines.append("")
t_lines.append("> The reviewer's item 14: per-target capability marks, HONEST — a")
t_lines.append("> capability is advertised with ✓ only when the CURRENT tree carries")
t_lines.append("> executed evidence for it. This tree has NOT run a bootstrap ladder")
t_lines.append("> or CI lane (the working tree is e1eb946 + the Wave-A work); the")
t_lines.append("> evidence column states exactly what exists, and a ✓ without a run")
t_lines.append("> is never claimed. Where the evidence is a committed artifact that")
t_lines.append("> HAS run on an earlier tree, the mark is the artifact's mark, not")
t_lines.append("> an observed run on this tree.")
t_lines.append("")
t_lines.append("## The capability legend")
t_lines.append("")
legend_rows = [[c, caps["capability"][c]["meaning"]] for c in CAPS]
t_lines += check_table("Capability | Meaning", ["Capability", "Meaning"], legend_rows)
t_lines.append("")
t_lines.append("## The matrix")
t_lines.append("")
t_lines += check_table("The matrix", ["Capability"] + TARGETS, rows)
t_lines.append("")
t_lines.append("## The evidence behind every mark")
t_lines.append("")
front_evidence = caps.get("front_end_evidence", [])
t_lines.append("**Parse / Type / MIR — every target (✓).** The front end is")
t_lines.append("target-independent: lexing, parsing, resolution, type/access/resource")
t_lines.append("checking, MIR lowering/verification and the completeness oracles run on the")
t_lines.append("host compiler before any target-specific backend decision. The MIR boundary")
t_lines.append("(`--target <triple>` with `tg check`) accepts any registered triple; the")
t_lines.append("triples below all parse through `parse_target_triple`. Evidence: the")
t_lines.append("front-end suites (`tests/canary`, `tests/canary_neg`, the CFG oracle lane")
t_lines.append("`tests/resource_cfg/`, the differential corpus `tests/differential/`).")
t_lines.append("None of the targets' front-end marks depend on a native run.")
t_lines.append("")
for t in TARGETS:
    tgt = caps["target"][t]
    yes = [c for c in CAPS if tgt.get(c)]
    no = [c for c in CAPS if not tgt.get(c)]
    head = "**%s: %s.**" % (t, (", ".join(yes) + " ✓" if yes else "no capabilities ✓") + (("; " + ", ".join(no) + " ✗") if no else ""))
    t_lines.append(head)
    t_lines.append("")
    ev = []
    if any(tgt.get(c) for c in ("Parse", "Type", "MIR")):
        ev = ev + front_evidence
    ev = ev + tgt.get("evidence", [])
    if ev:
        t_lines.append("Evidence: " + "; ".join("`" + e + "`" for e in ev) + ".")
        t_lines.append("")
    if tgt.get("notes"):
        t_lines.append(tgt["notes"])
        t_lines.append("")
if caps.get("target", {}).get("Debug-notes", {}).get("text"):
    t_lines.append(caps["target"]["Debug-notes"]["text"])
    t_lines.append("")
t_lines.append("## The rules this matrix follows")
t_lines.append("")
t_lines.append("1. A capability is ✓ only with a committed artifact that exercises it")
t_lines.append("   (the test/script/code path listed above). An artifact that exists but")
t_lines.append("   has not run on this tree is still a ✓ with the evidence column saying")
t_lines.append("   exactly that — a \"not run at this SHA\" ✓ is NOT the same as a run-")
t_lines.append("   observed ✓, and no row claims a run-observed status for this tree.")
t_lines.append("2. Object/Static-link/Dynamic-extern/Native-run are strictly increasing")
t_lines.append("   in difficulty: a row cannot advertise Native-run without Static-link,")
t_lines.append("   or Static-link without Object (the generator enforces the chain).")
t_lines.append("3. The front-end rows (Parse/Type/MIR) are target-independent; a target")
t_lines.append("   with a working backend inherits them automatically, and a target with")
t_lines.append("   NO backend still gets them — the marks say \"the front end accepts this")
t_lines.append("   target\", never \"the backend serves it\".")
t_lines.append("4. The matrix is regenerated from `target_capabilities.toml` together")
t_lines.append("   with feature_matrix.md's status vocabulary; where they disagree,")
t_lines.append("   feature_matrix.md's generated registry wins.")
t_lines.append("")
t_lines.append("---")
t_lines.append("")
t_lines.append("*Generated from `docs/current/target_capabilities.toml` — no ladder/CI")
t_lines.append("run has occurred on this tree; every ✓ is artifact-backed, not")
t_lines.append("run-observed-at-this-SHA.*")

# ─────────────────────────────────────────────────────────────
# pipeline_stages.md — the stage facts (compiler_pipeline.toml)
# ─────────────────────────────────────────────────────────────
p_lines = []
p_lines.append("# Tangerine Compiler Pipeline — the Stage Facts (generated)")
p_lines.append("")
p_lines.append("> **GENERATED EVIDENCE — do not edit by hand.** This document is")
p_lines.append("> rendered by `scripts/gen_spec_docs.sh` from")
p_lines.append("> [`compiler_pipeline.toml`](compiler_pipeline.toml), the machine-readable")
p_lines.append("> source of truth for the stage order, the stopping points, the")
p_lines.append("> single-authority rule per stage, the verifier's schema and the")
p_lines.append("> completeness oracles of the self-hosted compiler (`compile_file_core`")
p_lines.append("> in tg_compiler/compiler_core.tg). The CI evidence-gate job regenerates")
p_lines.append("> it and runs `git diff --exit-code` on both the schema and this doc —")
p_lines.append("> a stale hand-edited stage fact cannot merge. The prose companion is")
p_lines.append("> [`pipeline_manifest.md`](pipeline_manifest.md).")
p_lines.append("")
p_lines.append("## The canonical semantic pass")
p_lines.append("")
p_lines.append("Stages 4–9 run as ONE canonical API, `%s` (compiler_core.tg), over the"
% pipe["canonical_pass"])
p_lines.append("shared `Program` — the driver NEVER re-runs expansion or id assignment")
p_lines.append("(pre-pass duplication corrupts node-id identity). `analyze_source` (lex +")
p_lines.append("parse + the canonical pass) is the front door of `tg check` and")
p_lines.append("`lib::check`; `compile_file_core` performs the same canonical pass then")
p_lines.append("continues through MIR/mono/optimize/codegen.")
p_lines.append("")
p_lines.append("## Stage order and the single-authority rule")
p_lines.append("")
stage_rows = []
for s in pipe["stage"]:
    stage_rows.append([str(s["number"]), s["name"], "`" + s["entry"] + "`", "`" + s["source"] + "`", s["representation"], s["authority"], s["consumed_by"]])
p_lines += check_table("Stage table", ["#", "Stage", "Entry Point", "Source File", "Representation owning the invariant", "Single authority", "Consumed read-only by"], stage_rows)
p_lines.append("")
p_lines.append("## The stopping points")
p_lines.append("")
p_lines.append("**THE FACT (the contradiction resolved): `tg check` sets")
p_lines.append("`check_only = true; stop_after = StopAfter::Mir` and stops AFTER stage 11")
p_lines.append("— MIR lowered AND verified — before monomorphization and codegen. The")
p_lines.append("code comment says it exactly: \"`tg check` stops here: the program has")
p_lines.append("been lexed, parsed, dependencies resolved, macros expanded, type-checked,")
p_lines.append("access-checked, lowered to MIR and verified — without generating native")
p_lines.append("code.\" The old \"stops at StopAfter::Semantic\" wording is WRONG.**")
p_lines.append("")
sp_rows = []
for sp in pipe["stop_point"]:
    sp_rows.append([sp["name"], sp["stop_after"], str(sp["after_stage"]), sp["description"], "`" + sp["source"] + "`", sp.get("note", "")])
p_lines += check_table("Stop points", ["Stopping point", "StopAfter / mode", "After stage", "What completed", "Source", "Note"], sp_rows)
p_lines.append("")
p_lines.append("## The verifier's schema (the canonical-MIR lag resolved)")
p_lines.append("")
p_lines.append("`verify_mir` (mir.tg) enforces the SEVEN invariants below — this is the")
p_lines.append("live schema (canonical_ir_spec.md's INV-MIR-001..009 list is stale).")
p_lines.append("It runs at every boundary: " + "; ".join(pipe["verifier"]["runs"]) + ".")
p_lines.append("Return: " + pipe["verifier"]["return"] + ".")
p_lines.append("")
v_rows = []
for inv in pipe["verifier"]["invariant"]:
    v_rows.append([str(inv["id"]), inv["name"], inv["description"]])
p_lines += check_table("Verifier invariants", ["#", "Invariant", "Description"], v_rows)
p_lines.append("")
p_lines.append("## The completeness oracles (the reviewer's item 8)")
p_lines.append("")
p_lines.append("Two oracles implement the ICE distinction — USER MISTAKES get the stable")
p_lines.append("diagnostics (the checker's E-codes, recorded before either oracle runs);")
p_lines.append("the IMPOSSIBLE POST-TYPECHECK STATE (an accepted program with a residual")
p_lines.append("placeholder) is the internal invariant failure, recorded as an ICE-class")
p_lines.append("error that aborts compilation.")
p_lines.append("")
o_rows = []
for o in pipe["oracle"]:
    o_rows.append([o["name"], "`" + o["source"] + "`", o["when"], o["description"]])
p_lines += check_table("Oracles", ["Oracle", "Source", "Runs", "What it proves"], o_rows)
p_lines.append("")
p_lines.append("## The register-allocation fact (the wording contradiction resolved)")
p_lines.append("")
p_lines.append("Stage 14 (codegen) performs DIRECT emission with the inline per-function")
p_lines.append("register state (`RegAllocState` — `alloc_reg` / `free_reg` /")
p_lines.append("`alloc_reg_or_spill`, codegen.tg). There is NO standalone")
p_lines.append("register-allocation pass in the pipeline; \"register allocation\" in")
p_lines.append("pipeline prose means this register-targeted emission inside stage 14 —")
p_lines.append("matching invariants.md INV-OPT-006 (\"no register allocator exists —")
p_lines.append("codegen is direct stack-frame + register-targeted emission\").")
p_lines.append("")
p_lines.append("---")
p_lines.append("")
p_lines.append("*Generated from `docs/current/compiler_pipeline.toml`.*")

# ─────────────────────────────────────────────────────────────
# abi_layout.md — the FFI layout facts (abi_schema.toml)
# ─────────────────────────────────────────────────────────────
a_lines = []
a_lines.append("# Tangerine ABI Layout — the FFI C-Type Mapping Tables (generated)")
a_lines.append("")
a_lines.append("> **GENERATED EVIDENCE — do not edit by hand.** This document is")
a_lines.append("> rendered by `scripts/gen_spec_docs.sh` from")
a_lines.append("> [`abi_schema.toml`](abi_schema.toml), the machine-readable FFI/layout")
a_lines.append("> facts: the C type -> the Tangerine type -> size -> alignment ->")
a_lines.append("> direction. The CI evidence-gate job regenerates it and runs")
a_lines.append("> `git diff --exit-code` — a stale hand-edited layout fact cannot merge.")
a_lines.append("")
a_lines.append("## The direction legend")
a_lines.append("")
a_lines.append("- `in` — a C-argument crossing (C -> Tangerine)")
a_lines.append("- `out` — a C-return / export value crossing (Tangerine -> C)")
a_lines.append("- `in/out` — both directions legal")
a_lines.append("- `none` — NOT an FFI boundary type")
a_lines.append("")
a_lines.append("## The C type mappings")
a_lines.append("")
a_rows = []
for m in abi["ffi_mapping"]:
    a_rows.append(["`" + m["c_type"] + "`", m["tg_type"], m["size"], m["alignment"], m["direction"], m["note"]])
a_lines += check_table("FFI mapping", ["C type", "Tangerine type", "Size", "Alignment", "Direction", "Note"], a_rows)
a_lines.append("")
a_lines.append("## The FFI-safe rule")
a_lines.append("")
a_lines.append("`String` and `Array[T]`/`Vec[T]` are NOT FFI boundary types: the owned")
a_lines.append("String crosses as `FfiStr` and the heap vector crosses as `FfiSlice[T]`.")
a_lines.append("All data crossing FFI boundaries is auto-wrapped in `Tainted[T]` in the")
a_lines.append("strict/production/hardened modes (ffi_cheatsheet.md).")
a_lines.append("")
a_lines.append("---")
a_lines.append("")
a_lines.append("*Generated from `docs/current/abi_schema.toml`.*")

# ─────────────────────────────────────────────────────────────
# stabilized_layout_tables.md — the frozen tables (abi_schema.toml
# [layout.frozen], the Wave-A safe-view authority)
# ─────────────────────────────────────────────────────────────
s_lines = []
s_lines.append("# Stabilized Layout Tables — FROZEN (generated)")
s_lines.append("")
s_lines.append("> **GENERATED EVIDENCE — do not edit by hand.** These tables are rendered")
s_lines.append("> by `scripts/gen_spec_docs.sh` from the `[layout.frozen]` section of")
s_lines.append("> [`abi_schema.toml`](abi_schema.toml), the machine-readable layout facts")
s_lines.append("> (the layout authority: tg_compiler/layout_engine.tg + the Wave-A")
s_lines.append("> shared/pinned safe views in std/core.tg + std/collections.tg +")
s_lines.append("> memory_model.md §9). The CI evidence-gate job regenerates them and")
s_lines.append("> runs `git diff --exit-code` — a stale hand-edited frozen value cannot")
s_lines.append("> merge. The values MUST NOT change during stabilization (stabilized_subset.md")
s_lines.append("> change policy); any bug in these values is a bug in the layout engine.")
s_lines.append("")
s_lines.append("## F1: Primitive Sizes (FROZEN)")
s_lines.append("")
f1 = []
for p in abi["layout"]["frozen"]["primitive"]:
    f1.append([p["name"], p["size"], p["alignment"]])
s_lines += check_table("Primitives", ["Type", "Size (bytes)", "Alignment"], f1)
s_lines.append("")
s_lines.append("## F2: Container / Value ABI (FROZEN)")
s_lines.append("")
s_lines.append("One pointer-width handle (8 bytes) per container value, pointing at the")
s_lines.append("heap object listed. The sizes are the layout engine's")
s_lines.append("(`string_handle_layout_size` / `owned_string_object_size` /")
s_lines.append("`container_header_size` / `map_header_total_size`).")
s_lines.append("")
f2 = []
for c in abi["layout"]["frozen"]["container"]:
    f2.append([c["name"], c["handle_repr"], c["handle_size"], c["object_size"], c["object_fields"], c["ownership"], c["copy_op"], c["drop"], c["note"]])
s_lines += check_table("Containers", ["Type", "Handle ABI (Repr)", "Handle size", "Heap object size", "Fields", "Ownership", "Copy op", "Drop", "Note"], f2)
s_lines.append("")
s_lines.append("## F3: Enum Layout (FROZEN)")
s_lines.append("")
s_lines.append("- **Discriminant (tag)**: offset %s, size %s bytes" % (abi["layout"]["frozen"]["enum"]["tag_offset"], abi["layout"]["frozen"]["enum"]["tag_size"]))
s_lines.append("- **Payload**: starts at offset %s" % abi["layout"]["frozen"]["enum"]["payload_offset"])
s_lines.append("- **Alignment**: max of tag (8) and max payload field")
s_lines.append("- **Total size**: aligned to max alignment")
s_lines.append("- Rule: " + abi["layout"]["frozen"]["enum"]["rule"])
s_lines.append("")
s_lines.append("## F4: Pointer Sizes (FROZEN)")
s_lines.append("")
s_lines.append("Raw-pointer access is spelled `Ptr[T]` (immutable) and `PtrMut[T]`")
s_lines.append("(mutable); there is no `*const T` / `*mut T` spelling in the dialect.")
s_lines.append("")
f4 = []
for p in abi["layout"]["frozen"]["pointer"]:
    f4.append([p["name"], p["size"], p["ownership"], p["spelling"]])
s_lines += check_table("Pointers", ["Type", "Size", "Ownership", "Spelling"], f4)
s_lines.append("")
s_lines.append("## F5: The Fat-Value Forms (FROZEN)")
s_lines.append("")
s_lines.append("The 16-byte `{ptr, len}` fat value is the RAW VIEW form only"
" (`UnsafeSlice[T]` — `slice_view_layout`):")
s_lines.append("")
s_lines.append("```text")
s_lines.append("+------------------+------------------+")
s_lines.append("| Data Pointer (8) | Length (8)       |")
s_lines.append("+------------------+------------------+")
s_lines.append("^ offset 0         ^ offset 8")
s_lines.append("```")
s_lines.append("")
s_lines.append("The SAFE views (the Wave-A safe-view authority) are the Arc-class")
s_lines.append("handles to the pinned backings — 8-byte handles, NOT fat values:")
s_lines.append("")
s_lines.append("- `StrView` = `{ inner: ArcStrong[StrViewBacking] }` (8 bytes) -> the")
s_lines.append("  24-byte pinned `StrViewBacking` `{ ptr@0, len@8, offset@16 }`")
s_lines.append("  (std/core.tg). The view SURVIVES its source's drop and its String's")
s_lines.append("  growth (the Arc keeps the pinned backing alive).")
s_lines.append("- `SharedSlice[T]` = `{ inner: ArcStrong[SliceBacking[T]] }` (8 bytes) ->")
s_lines.append("  the 24-byte pinned `SliceBacking[T]` `{ ptr@0, len@8, offset@16 }`")
s_lines.append("  (std/collections.tg). The view SURVIVES its source's drop.")
s_lines.append("")
s_lines.append("## F6: Struct Layout Rules (FROZEN)")
s_lines.append("")
for r in abi["layout"]["frozen"]["struct"]["rules"]:
    s_lines.append("%d. %s" % (abi["layout"]["frozen"]["struct"]["rules"].index(r) + 1, r))
s_lines.append("")
s_lines.append("## F7: Fixed-Array Layout (FROZEN)")
s_lines.append("")
s_lines.append("`%s` — %s:" % (abi["layout"]["frozen"]["fixed_array"]["form"], abi["layout"]["frozen"]["fixed_array"]["storage"]))
s_lines.append("- Element stride = %s" % abi["layout"]["frozen"]["fixed_array"]["stride"])
s_lines.append("- Total size = %s" % abi["layout"]["frozen"]["fixed_array"]["total_size"])
s_lines.append("- Bit-copyable exactly when the element type is (%s)" % abi["layout"]["frozen"]["fixed_array"]["bit_copyable"])
s_lines.append("- Note: %s" % abi["layout"]["frozen"]["fixed_array"]["note"])
s_lines.append("")
s_lines.append("## The FFI-opaque alignment table (FROZEN)")
s_lines.append("")
s_lines.append("`%s`: %s" % (", ".join("`" + n + "`" for n in abi["layout"]["frozen"]["ffi_opaque"]["names"]), abi["layout"]["frozen"]["ffi_opaque"]["rule"]))
s_lines.append("")
s_lines.append("## The removed fallback (F8)")
s_lines.append("")
s_lines.append("The former \"unknown field offset = i * 8\" fallback is REMOVED: every field")
s_lines.append("offset is computed by the layout engine from the declared fields (F6);")
s_lines.append("an unknown/opaque type is an error at its use site — never a guess")
s_lines.append("(stabilized_subset.md F8).")
s_lines.append("")
s_lines.append("---")
s_lines.append("")
s_lines.append("*Generated from `docs/current/abi_schema.toml` (`[layout.frozen]`).*")

# ─────────────────────────────────────────────────────────────
# language_spec.md — the grammar facts (language_spec.toml)
# ─────────────────────────────────────────────────────────────
l_lines = []
l_lines.append("# Tangerine Language Spec — the Normative Grammar Facts (generated)")
l_lines.append("")
l_lines.append("> **GENERATED EVIDENCE — do not edit by hand.** This document is")
l_lines.append("> rendered by `scripts/gen_spec_docs.sh` from")
l_lines.append("> [`language_spec.toml`](language_spec.toml), the machine-readable")
l_lines.append("> normative grammar facts (the keywords, the operators, the precedence,")
l_lines.append("> the access conventions, the syntax forms). The CI evidence-gate job")
l_lines.append("> regenerates it and runs `git diff --exit-code` — a stale hand-edited")
l_lines.append("> grammar fact cannot merge. The facts are sourced from the compiler's")
l_lines.append("> own authority: tg_compiler/token.tg (`keyword_from_str`),")
l_lines.append("> tg_compiler/lexer.tg, grammar.md §4.1 (the precedence-climbing chain)")
l_lines.append("> and language.md §\"Access Conventions\".")
l_lines.append("")
l_lines.append("## Lexical facts")
l_lines.append("")
for k in ("identifier", "keywords", "newline", "comments"):
    l_lines.append("- **%s**: %s" % (k, lang["lexical"][k]))
l_lines.append("")
l_lines.append("## The keywords")
l_lines.append("")
kw_rows = []
for kw in lang["keyword"]:
    kw_rows.append(["`" + kw["name"] + "`", "`" + kw["token"] + "`", kw["category"]])
l_lines += check_table("Keywords", ["Keyword", "Token kind", "Category"], kw_rows)
l_lines.append("")
l_lines.append("## The expression precedence (lowest to highest)")
l_lines.append("")
pr_rows = []
for p in lang["precedence_level"]:
    pr_rows.append([str(p["level"]), "`" + p["constructs"] + "`", p["associativity"]])
l_lines += check_table("Precedence", ["Level", "Constructs", "Associativity"], pr_rows)
l_lines.append("")
l_lines.append("Assignment is **not** part of the expression grammar; it is a statement")
l_lines.append("form (grammar.md §6).")
l_lines.append("")
l_lines.append("## The operators")
l_lines.append("")
pos_rank = {"infix": 0, "prefix": 1, "postfix": 2, "statement": 3, "signature": 4, "declaration": 5, "path": 6}
op_rows = []
for op in sorted(lang["operator"], key=lambda o: (pos_rank.get(o["position"], 9), o.get("precedence", 0), o["symbol"])):
    op_rows.append(["`" + op["symbol"] + "`", op["name"], op["position"], str(op["precedence"]), op["associativity"], op["arity"]])
l_lines += check_table("Operators", ["Symbol", "Name", "Position", "Precedence", "Associativity", "Arity"], op_rows)
l_lines.append("")
l_lines.append("## The access conventions")
l_lines.append("")
ac_rows = []
for ac in lang["access_convention"]:
    ac_rows.append(["`" + ac["name"] + "`", "`" + ac["keyword"] + "`", ac["effect"], ac["meaning"]])
l_lines += check_table("Access conventions", ["Convention", "Keyword", "Typed effect", "Meaning"], ac_rows)
l_lines.append("")
l_lines.append("Every parameter and receiver carries an explicit access convention; the")
l_lines.append("default (no prefix) is `let` — the argument is **observed** (read-only")
l_lines.append("access, no move). The distinction is critical: **`let` observes; `sink`")
l_lines.append("moves.**")
l_lines.append("")
l_lines.append("### Access markers at call sites")
l_lines.append("")
am_rows = []
for am in lang["access_marker"]:
    am_rows.append(["`" + am["name"] + "`", am["meaning"], am.get("fact", "")])
l_lines += check_table("Access markers", ["Marker", "Meaning", "Fact"], am_rows)
l_lines.append("")
l_lines.append("## The syntax forms")
l_lines.append("")
sf_rows = []
for sf in lang["syntax_form"]:
    sf_rows.append(["`" + sf["name"] + "`", "`" + sf["form"] + "`", sf["meaning"]])
l_lines += check_table("Syntax forms", ["Form", "Spelling", "Meaning"], sf_rows)
l_lines.append("")
l_lines.append("---")
l_lines.append("")
l_lines.append("*Generated from `docs/current/language_spec.toml`.*")

# ─────────────────────────────────────────────────────────────
# test_requirements.md — the exact test requirements (all schemas)
# ─────────────────────────────────────────────────────────────
reqs = []
reqs.append(("the grammar acceptance (the keywords/operators/precedence/syntax forms of language_spec.toml)",
             "language_spec.toml",
             ["scripts/run_selfhost_grammar_gate.sh", "tests/grammar_gate_fulltree_test.tg", "tests/run_stdlib_e106_sweep.sh"]))
reqs.append(("the `tg check` stop point (StopAfter::Mir after stage 11) is exercised by every zero-diagnostics sweep",
             "compiler_pipeline.toml [stop_point.tg check]",
             ["tests/run_stdlib_e106_sweep.sh"]))
reqs.append(("the verifier's seven invariants + the verify-everything boundaries",
             "compiler_pipeline.toml [verifier]",
             ["tests/canary", "tests/canary_neg", "tests/differential"]))
reqs.append(("the completeness oracles (semantic + MIR layout availability)",
             "compiler_pipeline.toml [oracle]",
             ["tests/canary", "tests/canary_neg"]))
reqs.append(("the frozen layout facts of abi_schema.toml [layout.frozen] (the golden layout suite)",
             "abi_schema.toml [layout.frozen]",
             ["tests/layout_tests.tg", "tests/layout/differential_layout_test.tg"]))
reqs.append(("the FFI C-type mappings + the FFI-opaque alignment table",
             "abi_schema.toml [ffi_mapping] + [layout.frozen.ffi_opaque]",
             ["tests/pthread_abi_test.tg", "tests/layout_tests.tg"]))
reqs.append(("the per-target capability evidence (every ✓ artifact must exist — enforced by the generator)",
             "target_capabilities.toml [target.*]",
             ["tests/run_target_lane_canaries.sh", "tests/thread_local_drop_test.tg", "tests/db_async_pool_test.tg"]))
reqs.append(("the stdlib completeness linkage (stdlib_contracts.toml -> stdlib_completeness.md)",
             "stdlib_contracts.toml",
             ["tests/run_stdlib_completeness_gate.sh", "tests/run_stdlib_e106_sweep.sh"]))

r_lines = []
r_lines.append("# Tangerine Exact Test Requirements (generated)")
r_lines.append("")
r_lines.append("> **GENERATED EVIDENCE — do not edit by hand.** This document is rendered")
r_lines.append("> by `scripts/gen_spec_docs.sh` FROM THE SCHEMAS: every normative fact in")
r_lines.append("> the five machine-readable files carries its required test artifact(s).")
r_lines.append("> The generator MECHANICALLY verifies that every artifact below exists in")
r_lines.append("> the tree (a missing artifact FAILS the generation), and the CI")
r_lines.append("> evidence-gate job regenerates this document and runs `git diff --exit-code`.")
r_lines.append("")
r_lines.append("## The requirement map")
r_lines.append("")
rr = []
missing_any = False
for req, schema, arts in reqs:
    cells = []
    ok = True
    for a in arts:
        if exists(a):
            cells.append("`" + a + "` ✓")
        else:
            cells.append("`" + a + "` ✗")
            ok = False
            missing_any = True
    rr.append([req, schema, " ".join(cells)])
r_lines += check_table("Requirements", ["Requirement", "Schema fact", "Required artifacts"], rr)
if missing_any:
    fail("test_requirements.md: a required artifact is missing from the tree (the rendered table marks it ✗)")
r_lines.append("")
r_lines.append("## The per-target capability evidence (the ✓ marks' artifacts)")
r_lines.append("")
for t in TARGETS:
    tgt = caps["target"][t]
    ev = []
    if any(tgt.get(c) for c in ("Parse", "Type", "MIR")):
        ev = ev + front_evidence
    ev = ev + tgt.get("evidence", [])
    ev_ok = all(exists(e) for e in ev)
    if not ev_ok:
        fail("target_capabilities.toml: target '%s' lists a missing evidence artifact" % t)
    r_lines.append("- **%s** (%d ✓): %s" % (t, sum(1 for c in CAPS if tgt.get(c)),
                    " ".join("`" + e + "`" + (" ✓" if exists(e) else " ✗") for e in ev) if ev else "(no backend evidence — the front-end marks only)"))
r_lines.append("")
r_lines.append("## The mechanical gates the generator enforces")
r_lines.append("")
r_lines.append("- every evidence artifact under a ✓ capability exists in the tree;")
r_lines.append("- the Object -> Static-link -> Dynamic-extern -> Native-run chain is")
r_lines.append("  strictly increasing per target (no skipped link);")
r_lines.append("- the front-end rows (Parse/Type/MIR) are true for every target;")
r_lines.append("- every requirement artifact in the map above exists.")
r_lines.append("")
r_lines.append("---")
r_lines.append("")
r_lines.append("*Generated from `language_spec.toml`, `target_capabilities.toml`, `abi_schema.toml`,")
r_lines.append("`compiler_pipeline.toml` and `stdlib_contracts.toml`.*")

# ─────────────────────────────────────────────────────────────
# The mechanical checks (before writing — the docs are written even
# on failure so the CI diff gate can see the drift)
# ─────────────────────────────────────────────────────────────
print("gen_spec_docs.sh: rendering the schema docs...")

# (1) the front-end rows must be true for every target
for t in TARGETS:
    tgt = caps["target"][t]
    for c in ("Parse", "Type", "MIR"):
        if not tgt.get(c):
            fail("target_capabilities.toml: target '%s' must have %s ✓ (the front end is target-independent)" % (t, c))

# (2) the chain: Native-run -> Dynamic-extern -> Static-link -> Object
chain = [("Object", None), ("Static-link", "Object"), ("Dynamic-extern", "Static-link"), ("Native-run", "Dynamic-extern")]
for t in TARGETS:
    tgt = caps["target"][t]
    for cap, need in chain:
        if tgt.get(cap) and need and not tgt.get(need):
            fail("target_capabilities.toml: target '%s' advertises %s ✓ without %s ✓ (the strictly-increasing chain)" % (t, cap, need))

# (3) the evidence artifacts under a ✓ must exist
for t in TARGETS:
    tgt = caps["target"][t]
    ev = []
    if any(tgt.get(c) for c in ("Parse", "Type", "MIR")):
        ev = ev + front_evidence
    ev = ev + tgt.get("evidence", [])
    for e in ev:
        if not exists(e):
            fail("target_capabilities.toml: target '%s' lists missing evidence artifact '%s'" % (t, e))

# (4) the requirement artifacts must exist
for req, schema, arts in reqs:
    for a in arts:
        if not exists(a):
            fail("test requirements: '%s' requires '%s' which does not exist in the tree" % (req, a))

OUTS = {
    "target_capabilities.md": t_lines,
    "pipeline_stages.md": p_lines,
    "abi_layout.md": a_lines,
    "stabilized_layout_tables.md": s_lines,
    "language_spec.md": l_lines,
    "test_requirements.md": r_lines,
}
for name, lines in OUTS.items():
    path = os.path.join(DOCS, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("  wrote " + name)

if FAILURES:
    print("gen_spec_docs.sh: %d mechanical failure(s) — the docs were STILL written so the CI diff gate sees the drift" % len(FAILURES))
    sys.exit(1)
print("gen_spec_docs.sh: all mechanical checks held")
sys.exit(0)
PYEOF
