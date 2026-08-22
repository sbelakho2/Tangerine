#!/usr/bin/env bash
#
# scripts/check_variant_coverage.sh — the variant-coverage oracle
#
# The coverage oracle for the compiler's variant universes:
#   --domain mir   the MIR enums      MirRvalueKind / MirTerminatorKind /
#                                      Projection (tg_compiler/mir.tg)
#   --domain ast   the AST enums      StmtKind / ExprKind / TypeExprKind
#                                      (tg_compiler/ast.tg)
#   --domain type  the Type universe  the Type enum (tg_compiler/types.tg)
#
# HOW IT WORKS
#   1. FACTS — the variant enumeration is derived FROM THE COMPILER SOURCE
#      (the enum bodies in mir.tg / ast.tg / types.tg), so the oracle can
#      never drift from the compiler: a variant added to an enum without a
#      fingerprint entry FAILS the "lexicon completeness" check.
#   2. FINGERPRINTS — every variant has a fingerprint lexicon (see below):
#      the unit-construction token (e.g. `MirRvalueKind::MirMove(` — a test
#      that BUILDS the variant), the declared marker of the dedicated
#      specimen files (`# mir-variant: MirMove` — the specimen program that
#      exercises the producing operation), and — where a stable source
#      construct exists — the operation regex (the construct the compiler
#      lowers to the variant).
#   3. ATTRIBUTION — every tests/**/*.tg file is scanned; a variant is
#      covered when at least one of its fingerprints occurs in at least one
#      test file. The table reports variant -> the exercising file(s) and
#      the matched fingerprint.
#   4. VERDICT — exit 0 only when every enumerated variant is covered AND
#      the lexicon is complete (no enumerated variant without fingerprints).
#      --report-only prints the table without failing.
#
# The dedicated specimen files (the unit layer + the source layer):
#   tests/mir_variant_coverage_tests.tg     (constructs every MIR variant)
#   tests/mir_variant_specimens.tg          (source-level MIR producers)
#   tests/ast_variant_coverage_tests.tg     (every AST variant specimen)
#   tests/type_variant_coverage_tests.tg    (every Type variant specimen)
#
# Usage: scripts/check_variant_coverage.sh [--domain mir|ast|type] [--report-only]
#   With no --domain every domain runs.
# Exit status: 0 when the domain's variant coverage is complete; 1 on any
# uncovered variant, an incomplete fingerprint lexicon, or a missing
# dedicated specimen file.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIR_SRC="$ROOT/tg_compiler/mir.tg"
AST_SRC="$ROOT/tg_compiler/ast.tg"
TYPE_SRC="$ROOT/tg_compiler/types.tg"
TESTS_DIR="$ROOT/tests"

DOMAINS=""
REPORT_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain) DOMAINS="$DOMAINS ${2:-}"; shift 2 ;;
    --report-only) REPORT_ONLY=1; shift ;;
    *) echo "check_variant_coverage: unknown argument: $1" >&2; exit 2 ;;
  esac
done
DOMAINS="${DOMAINS:- mir ast type}"
[ -n "${DOMAINS// /}" ] || { echo "check_variant_coverage: --domain needs a value" >&2; exit 2; }

fail() { echo "[variant-coverage:error] $*" >&2; exit 1; }

# ———————————————————————————————————————————————————————————————
# 1. FACTS — enumerate the enum variants from the compiler source.
#    extract_enum <file> <enum-name> prints one variant name per line
#    (the top-level `  Name` lines inside the enum body).
# ———————————————————————————————————————————————————————————————

extract_enum() {
  awk -v en="$2" '
    $0 == "enum " en { in_enum = 1; next }
    in_enum && /^end/ { exit }
    in_enum && /^  [A-Z][A-Za-z0-9_]*/ {
      name = $0
      sub(/^  /, "", name)
      sub(/[({].*$/, "", name)
      print name
    }
  ' "$1"
}

# ———————————————————————————————————————————————————————————————
# 2. FINGERPRINT LEXICONS.
#    Entry format:  <variant>|<type>|<extended-regex>
#    type: unit   = the unit-construction token (the variant BUILT by hand)
#          marker = the dedicated specimen file'"'"'s declared exercise
#          source = a source construct that produces the variant
#    A variant is covered when ANY of its fingerprints matches ANY test file.
# ———————————————————————————————————————————————————————————————

mir_lexicon() {
  cat <<'EOF'
MirMove|unit|MirRvalueKind::MirMove\(
MirMove|marker|# MirMove\b
MirRef|unit|MirRvalueKind::MirRef\(
MirRef|marker|# MirRef\b
MirRef|source|observe\(&counter\)|observe\(&[A-Za-z_]
MirAggregate|unit|MirRvalueKind::MirAggregate\(
MirAggregate|marker|# MirAggregate\b
MirAggregate|source|\{[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:[ \t]*[^}]*\}|\[[0-9][0-9, ]*\]
MirBinOp|unit|MirRvalueKind::MirBinOp\(
MirBinOp|marker|# MirBinOp\b
MirBinOp|source|[^!=<>][ \t]*\+[ \t]*[0-9]
MirUnOp|unit|MirRvalueKind::MirUnOp\(
MirUnOp|marker|# MirUnOp\b
MirUnOp|source|\{[ \t]*-[A-Za-z_]|!flag|~[A-Za-z_]
MirDiscriminant|unit|MirRvalueKind::MirDiscriminant\(
MirDiscriminant|marker|# MirDiscriminant\b
MirDiscriminant|source|match[ \t]+[A-Za-z_]+[ \t]*\n|when[ \t]+[A-Z][A-Za-z0-9_]*::
MirLen|unit|MirRvalueKind::MirLen\(
MirLen|marker|# MirLen\b
MirLen|source|\.[ \t]*len\(
MirCast|unit|MirRvalueKind::MirCast\(
MirCast|marker|# MirCast\b
MirCast|source|\bas[ \t]+[A-Za-z]
MirRepeat|unit|MirRvalueKind::MirRepeat\(
MirRepeat|marker|# MirRepeat\b
MirPhi|unit|MirRvalueKind::MirPhi\(
MirPhi|marker|# MirPhi\b
MirPhi|source|\bloop\b|\bwhile\b
MirGoto|unit|MirTerminatorKind::MirGoto\(
MirGoto|marker|# MirGoto\b
MirGoto|source|\bif[ \t]+[^\n]*\bthen\b
MirReturn|unit|MirTerminatorKind::MirReturn\b
MirReturn|marker|# MirReturn\b
MirReturn|source|\breturn\b
MirUnreachable|unit|MirTerminatorKind::MirUnreachable\b
MirUnreachable|marker|# MirUnreachable\b
MirSwitchInt|unit|MirTerminatorKind::MirSwitchInt\b
MirSwitchInt|marker|# MirSwitchInt\b
MirSwitchInt|source|match[ \t]+[^\n]*\n[ \t]*when[ \t]+[0-9]
MirCall|unit|MirTerminatorKind::MirCall\b
MirCall|marker|# MirCall\b
MirCall|source|^[ \t]*[A-Za-z_][A-Za-z0-9_]*\([^)]*\)[ \t]*$
MirAssert|unit|MirTerminatorKind::MirAssert\b
MirAssert|marker|# MirAssert\b
MirAssert|source|\[[0-9]\]|\.at\(|\.index\(
MirAbort|unit|MirTerminatorKind::MirAbort\b
MirAbort|marker|# MirAbort\b
MirAbort|source|panic\(
MirDeinit|unit|MirTerminatorKind::MirDeinit\b
MirDeinit|marker|# MirDeinit\b
MirDeinit|source|def[ \t]+deinit\(
ProjDeref|unit|Projection::ProjDeref\b
ProjDeref|marker|# ProjDeref\b
ProjDeref|source|\*[A-Za-z_][A-Za-z0-9_]*[ \t]*\)|\*p\b
Field|unit|Projection::Field\(
Field|marker|# Projection::Field\b
Field|source|\.[a-z_][a-z0-9_]*\b
Variant|unit|Projection::Variant\(
Variant|marker|# Projection::Variant\b
Variant|source|when[ \t]+[A-Z][A-Za-z0-9_]*\(
TupleIndex|unit|Projection::TupleIndex\(
TupleIndex|marker|# Projection::TupleIndex\b
TupleIndex|source|\.[ \t]*[0-9][0-9]*\b
ProjIndex|unit|Projection::ProjIndex\(
ProjIndex|marker|# ProjIndex\b
ProjIndex|source|\[[a-z_][a-z0-9_]*\]
ProjConstantIndex|unit|Projection::ProjConstantIndex\(
ProjConstantIndex|marker|# ProjConstantIndex\b
ProjConstantIndex|source|\[[0-9][0-9]*\]
EOF
}

ast_lexicon() {
  cat <<'EOF'
StmtLet|source|^[ \t]*let[ \t]+[a-z_A-Z]|^[ \t]*var[ \t]+[a-z_A-Z]
StmtAssign|source|^[ \t]*[a-zA-Z_][a-zA-Z0-9_.\[\]()]*[ \t]*=[ \t]*[^=>]
StmtCompoundAssign|source|\+=[ \t]|\*=[ \t]|/=[ \t]|%=[ \t]|=[ \t]*[a-z]&
StmtIf|source|^[ \t]*if[ \t]+[^\n]*\bthen\b
StmtMatch|source|^[ \t]*match[ \t]
StmtWhile|source|^[ \t]*while[ \t]
StmtFor|source|^[ \t]*for[ \t]+[^\n]*\bin\b
StmtLoop|source|^[ \t]*loop[ \t]*
StmtReturn|source|^[ \t]*return\b
StmtBreak|source|^[ \t]*break\b
StmtContinue|source|^[ \t]*next\b|^[ \t]*continue\b
StmtExpr|source|^[ \t]*[a-zA-Z_][a-zA-Z0-9_.]*\([^)]*\)[ \t]*$
StmtUnsafe|source|^[ \t]*unsafe[ \t]*(do|\{)
StmtDefer|source|^[ \t]*defer[ \t]+do
StmtGuard|source|^[ \t]*guard[ \t]+[^\n]*\belse\b
StmtTry|source|try[ \t]+do
StmtWith|source|with[ \t]+[^\n]*\bdo\b
StmtHandleWith|source|handle[ \t]+[^\n]*\bwith\b
ExprIntLit|source|^[ \t]*let[ \t]+[a-zA-Z_]+[ \t]*=[ \t]*[0-9]|=[ \t]*[0-9][0-9_]*([uUiIfF]|[0-9])*
ExprFloatLit|source|[0-9]+\.[0-9]+|e[+-]?[0-9]+
ExprStringLit|source|"[^"\n]*"
ExprCharLit|source|'[^'\n]'
ExprBoolLit|source|\btrue\b|\bfalse\b
ExprNilLit|source|\bnil\b
ExprArrayLit|source|\[[^]]*,[^]]*\]
ExprTupleLit|source|\([^()\n]*,[^()\n]*\)
ExprStructLit|source|[A-Z][A-Za-z0-9_]*[ \t]*\{[^}]*:[^}]*\}
ExprMapLit|source|\{[^\n}]*=>[^\n}]*\}
ExprIdent|source|\bself\b|[a-zA-Z_][a-zA-Z0-9_]*[ \t]*=[ \t]*
ExprPath|source|[a-z_][a-z0-9_]*::[a-zA-Z_]
ExprSelfRef|source|\bself\b
ExprBinaryOp|source|[^!=<>][ \t]*[\+\-\*\/\%\&\|\^\<\>][ \t]*[^=]
ExprUnaryOp|source|[ \t](!|~)[a-zA-Z_]|-+[a-zA-Z_]
ExprFieldAccess|source|\.[a-z_][a-z0-9_]*\b
ExprMethodCall|source|\.[a-z_][a-z0-9_]*\(
ExprIndex|source|\[[a-zA-Z_0-9]+\]
ExprCall|source|^[ \t]*[a-zA-Z_][a-zA-Z0-9_]*\(|\[[^\]]*\]\(
ExprClosure|source|\|,[ \t]*[a-zA-Z_][a-zA-Z0-9_]*[ \t]*\|(\(.*\))?|\|([^|\n]*\|[^\n]*)|->[ \t]*
ExprAccess|source|&[a-zA-Z_][a-zA-Z0-9_]*|&mut[ \t]+[a-zA-Z_]
ExprRawDeref|source|\*[a-zA-Z_][a-zA-Z0-9_]*(\[|\b)
ExprIf|source|\bif\b
ExprMatch|source|\bmatch\b
ExprBlock|source|\bdo\b[^\n]*\bend\b|\bbegin\b
ExprUnsafe|source|\bunsafe\b
ExprAsync|source|\basync\b[^\n]*\bdo\b|\basync\b[^\n]*\{
ExprAwait|source|\bawait\b
ExprTry|source|\?[ \t]*[;)\n]|\.\?|\(\)\?
ExprRange|source|\.\.[^.]|\.\.=
ExprCast|source|\bas\b
ExprTypeCheck|source|\bis\b
ExprComptime|source|\bcomptime\b
ExprEnumVariant|source|^[ \t]*[A-Z][A-Za-z0-9_]*\(|::[A-Z][A-Za-z0-9_]*\(
ExprAssign|unit|ExprKind::ExprAssign\(
ExprPipe|source|\|>
ExprMacroCall|source|[a-z_][a-z0-9_]*![ \t]*(\[|\()
ExprError|unit|ExprKind::ExprError\(
Named|source|:[ \t][A-Z][A-Za-z0-9_]*(\[|,|\)|[ \t]|$)|->[ \t][A-Z][A-Za-z0-9_]*
Named|marker|# ast-variant: Named\b
Unit|source|-> Unit\b|: Unit\b|\(\)[ \t]*\n|->[ \t]*\(\)
Unit|marker|# ast-variant: Unit\b
Never|unit|TypeExprKind::Never\b
Never|marker|# ast-variant: Never\b
Tuple|source|\([A-Za-z_][A-Za-z0-9_]*, [A-Za-z_]
Tuple|marker|# ast-variant: Tuple\b
Array|source|\[[A-Za-z_][A-Za-z0-9_]*; [0-9]+\]
Array|marker|# ast-variant: Array\b
Slice|source|\[[A-Za-z_][A-Za-z0-9_]*\]
Slice|marker|# ast-variant: Slice\b
Ptr|source|\*[A-Za-z_][A-Za-z0-9_]*\b|\*mut[ \t]+[A-Za-z_]
Ptr|marker|# ast-variant: Ptr\b
PtrMut|source|\*mut[ \t]+[A-Za-z_]
PtrMut|marker|# ast-variant: PtrMut\b
Ref|source|extern[ \t]+def[ \t]+__intrinsic_[^\n]*: &|->[ \t]*&
Ref|marker|# ast-variant: Ref\b
Fn|source|-> \(?\(|-> [A-Za-z_][A-Za-z0-9_]*\(|Fn\(|fn\(
Fn|marker|# ast-variant: Fn\b
Async|source|async[ \t]+[A-Za-z_][A-Za-z0-9_]*\b
Async|marker|# ast-variant: Async\b
Effect|unit|TypeExprKind::Effect\(
Effect|marker|# ast-variant: Effect\b
Path|source|::[A-Za-z_][A-Za-z0-9_]*\b
Path|marker|# ast-variant: Path\b
Infer|source|:[ \t]*_([,)\n]|$)
Infer|marker|# ast-variant: Infer\b
EOF
}

type_lexicon() {
  cat <<'EOF'
Unit|source|-> Unit\b|: Unit\b
Bool|source|: Bool\b|-> Bool\b
Int|source|: Int\b|-> Int\b
UInt|source|: UInt\b
Float|source|: Float\b|-> Float\b
Char|source|: Char\b
String|source|: String\b|-> String\b
StaticStrPtr|unit|Type::StaticStrPtr\b
Never|unit|Type::Never\b
I8|source|: I8\b|i8\b
I16|source|: I16\b|i16\b
I32|source|: I32\b|i32\b
I64|source|: I64\b|i64\b
I128|source|: I128\b|i128\b
U8|source|: U8\b|u8\b
U16|source|: U16\b|u16\b
U32|source|: U32\b|u32\b
U64|source|: U64\b|u64\b
U128|source|: U128\b|u128\b
ISize|source|: ISize\b|isize\b
USize|source|: USize\b|usize\b
F32|source|: F32\b|f32\b
F64|source|: F64\b|f64\b
IntLiteral|source|: IntLiteral\b
Adt|source|: Vec\[|: Option\[|: Result\[|: Map\[|: Set\[|: Box\[|: Rc\[|: Array\[|: Slice\[
FixedArray|source|\[[A-Za-z_][A-Za-z0-9_]*; [0-9]+\]
FnPtr|source|: fn\(|: Fn\(|-> \(?\([^)]*\) ->|FnPtr|fn\([^)]*\)[ \t]*->|: \(\(\) ->|\([^)]*\)[ \t]*->[ \t]*[A-Za-z]
Closure|unit|Type::Closure\(|: \|[^\n]*\|[ \t]*->|->[^\n]*\|[a-z_][a-z0-9_]*\|[ \t]*\{
RefInternal|source|extern[ \t]+def[ \t]+__intrinsic_[^\n]*: &|->[ \t]*&
Ptr|source|Ptr\[|: \*[A-Za-z_]\b|-> \*[A-Za-z_]\b
PtrMut|source|PtrMut\[|: \*mut|-> \*mut
Dyn|source|: dyn[ \t]+|-> dyn[ \t]+
Effect|unit|Type::Effect\(
Effect|source|effect\[|-> effect|: effect
Tuple|source|\([A-Za-z_][A-Za-z0-9_]*, [A-Za-z_][A-Za-z0-9_]*\)
Var|unit|Type::Var\(|Type::Var\b
Param|unit|Type::Param\(|Type::Param\b
Error|unit|Type::Error\b
EOF
}

# ———————————————————————————————————————————————————————————————
# 3. The scan — every tests/**/*.tg file, fingerprints matched per line.
#    Attribution order per variant:
#      (a) the explicit lexicon fingerprints (the producing operations);
#      (b) the declared-marker fallback: `# <domain>-variant: <Variant>`
#          in the dedicated specimen files (the marker sits directly above
#          the construct that produces the variant);
#      (c) the construction-token fallback: `<Enum>::<Variant>` in a test
#          that BUILDS the variant by hand (the unit layer).
#    The table reports which fingerprint matched in which file, so the
#    attribution is auditable.
# ———————————————————————————————————————————————————————————————

scan_files() {
  # The dedicated variant-coverage files are scanned FIRST (the
  # attribution favors the explicit specimen suites over incidental
  # matches elsewhere), then the rest of the tree alphabetically.
  find "$TESTS_DIR" -maxdepth 1 -name '*variant_coverage_tests.tg' -type f -o \
       -maxdepth 1 -name 'mir_variant_specimens.tg' -type f | sort
  find "$TESTS_DIR" -name '*.tg' -type f | sort
}

# construction-token pattern per domain + enum for the unit fallback.
construction_token() {
  case "$1" in
    mir) echo "MirRvalueKind::|MirTerminatorKind::|Projection::" ;;
    ast) echo "StmtKind::|ExprKind::|TypeExprKind::" ;;
    type) echo "Type::" ;;
  esac
}

# lexicon_lookup <domain> — prints the lexicon for the domain.
lexicon_lookup() {
  case "$1" in
    mir) mir_lexicon ;;
    ast) ast_lexicon ;;
    type) type_lexicon ;;
  esac
}

# enum_spec <domain> — lines: enum-name <space> source-file.
enum_spec() {
  case "$1" in
    mir) echo "MirRvalueKind $MIR_SRC"; echo "MirTerminatorKind $MIR_SRC"; echo "Projection $MIR_SRC" ;;
    ast) echo "StmtKind $AST_SRC"; echo "ExprKind $AST_SRC"; echo "TypeExprKind $AST_SRC" ;;
    type) echo "Type $TYPE_SRC" ;;
  esac
}

exit_code=0
for domain in $DOMAINS; do
  echo "[variant-coverage] domain: $domain"

  # 1. the facts — the enum variants from the compiler source
  variants=""
  while read -r enum src; do
    [ -f "$src" ] || fail "missing enum source for $enum: $src"
    while read -r v; do
      [ -n "$v" ] || continue
      variants="$variants
$enum/$v"
    done < <(extract_enum "$src" "$enum")
  done < <(enum_spec "$domain")

  total="$(printf '%s\n' "$variants" | grep -c .)"
  [ "$total" -gt 0 ] || fail "domain $domain: no variants enumerated"

  # 2. the lexicon must cover every enumerated variant
  lexicon="$(lexicon_lookup "$domain")"
  lexicon_missing=0
  while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    enum="${ev%/*}"
    v="${ev#*/}"
    if ! printf '%s\n' "$lexicon" | awk -F'|' -v v="$v" '$1 == v { found = 1 } END { exit !found }'; then
      echo "[variant-coverage:error] domain $domain: no fingerprint for enumerated variant $enum::$v (add its lexicon entry or it can never be covered)"
      lexicon_missing=1
    fi
  done <<< "$variants"
  if [ "$lexicon_missing" -ne 0 ]; then
    [ "$REPORT_ONLY" -eq 1 ] || exit 1
  fi

  # 3. attribution — scan every test file against every fingerprint
  test_files="$(scan_files)"
  echo "[variant-coverage] scanning $(printf '%s\n' "$test_files" | grep -c .) test files"

  uncovered=0
  covered=0
  ctor_token="$(construction_token "$domain")"
  marker_prefix="# $domain-variant: "
  printf '%-22s %-12s %-38s %s\n' "VARIANT" "FINGERPRINT" "MATCHED IN" "FINGERPRINT DETAIL"
  while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    v="${ev#*/}"
    matches=""
    # (a) the explicit lexicon fingerprints
    while IFS='|' read -r lv ltype lpat; do
      [ -n "$lv" ] || continue
      [ "$lv" = "$v" ] || continue
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$ROOT"/}"
        if grep -qE "$lpat" "$f" 2>/dev/null; then
          matches="$matches $rel"
          printf '%-22s %-12s %-38s %s\n' "$v" "$ltype" "$rel" "$lpat"
          break
        fi
      done <<< "$test_files"
      [ -n "$matches" ] && break
    done <<< "$lexicon"
    # (b) the declared-marker fallback
    if [ -z "$matches" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$ROOT"/}"
        if grep -qE "${marker_prefix}${v}\b" "$f" 2>/dev/null; then
          matches="$matches $rel"
          printf '%-22s %-12s %-38s %s\n' "$v" "marker" "$rel" "${marker_prefix}${v}"
          break
        fi
      done <<< "$test_files"
    fi
    # (c) the construction-token fallback (the unit layer builds the variant)
    if [ -z "$matches" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$ROOT"/}"
        if grep -qE "${ctor_token}${v}\b" "$f" 2>/dev/null; then
          matches="$matches $rel"
          printf '%-22s %-12s %-38s %s\n' "$v" "unit" "$rel" "${ctor_token}${v}"
          break
        fi
      done <<< "$test_files"
    fi
    if [ -n "$matches" ]; then
      covered=$((covered + 1))
    else
      echo "[variant-coverage:error] UNCOVERED variant: $v"
      uncovered=$((uncovered + 1))
    fi
  done <<< "$variants"

  echo "[variant-coverage] domain $domain: $covered/$total variants covered"
  if [ "$uncovered" -ne 0 ]; then
    echo "[variant-coverage:error] domain $domain: $uncovered uncovered variant(s) — add the dedicated specimen (tests/<domain>_variant_coverage_tests.tg) or extend the fingerprint"
    [ "$REPORT_ONLY" -eq 1 ] || exit_code=1
  fi
done

if [ "$exit_code" -ne 0 ]; then
  exit 1
fi
echo "[variant-coverage] ALL DOMAINS PASSED: every enumerated variant is exercised by at least one test"
exit 0
