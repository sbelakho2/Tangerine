#!/usr/bin/env bash
# Darwin regression for the bootstrap code-signing determinism contract:
# the same unsigned image signed through the SAME identifier/timestamp
# inputs must be byte-identical, independent of the output filename.
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "codesign identifier: SKIP (not Darwin)"
  exit 0
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg_codesign.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cp /usr/bin/true "$TMP/name-a"
cp /usr/bin/true "$TMP/name-b"
for p in "$TMP/name-a" "$TMP/name-b"; do
  chmod u+w "$p"
  /usr/bin/codesign --force --identifier org.tangerine.bootstrap --timestamp=none -s - "$p" >/dev/null
  /usr/bin/codesign --verify "$p" >/dev/null
done
if cmp -s "$TMP/name-a" "$TMP/name-b"; then
  echo "codesign identifier: PASS (byte-identical across filenames)"
else
  echo "codesign identifier: FAIL (signature depends on the filename)" >&2
  exit 1
fi
