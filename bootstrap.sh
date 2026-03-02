#!/usr/bin/env bash
set -euo pipefail

TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Usage: bootstrap.sh --target <target-triple>" >&2
  exit 2
fi

mkdir -p build

if command -v tg >/dev/null 2>&1; then
  cp "$(command -v tg)" ./build/tg
  chmod +x ./build/tg
  echo "Bootstrap: using tg from PATH"
  exit 0
fi

if [[ -x ./target/tg ]]; then
  cp ./target/tg ./build/tg
  chmod +x ./build/tg
  echo "Bootstrap: using ./target/tg"
  exit 0
fi

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
  echo "Bootstrap failed: no tg in PATH, no ./target/tg, and GITHUB_REPOSITORY is not set for release download." >&2
  exit 1
fi

TG_VERSION="${TG_VERSION:-0.1.0}"
BASE_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/v${TG_VERSION}"

candidates=(
  "tg-${TARGET}.tar.gz"
  "tg-${TARGET}.tgz"
  "tangerine-${TARGET}.tar.gz"
  "tg-${TARGET}"
)

echo "Bootstrap: attempting release download for ${TARGET} (v${TG_VERSION})"

for artifact in "${candidates[@]}"; do
  url="${BASE_URL}/${artifact}"
  tmp="$(mktemp -d)"
  file="${tmp}/${artifact}"

  if curl -fsSL "$url" -o "$file"; then
    case "$artifact" in
      *.tar.gz|*.tgz)
        tar -xzf "$file" -C "$tmp"
        if [[ -f "$tmp/tg" ]]; then
          cp "$tmp/tg" ./build/tg
          chmod +x ./build/tg
          rm -rf "$tmp"
          echo "Bootstrap: downloaded ${artifact}"
          exit 0
        fi
        ;;
      *)
        cp "$file" ./build/tg
        chmod +x ./build/tg
        rm -rf "$tmp"
        echo "Bootstrap: downloaded ${artifact}"
        exit 0
        ;;
    esac
  fi

  rm -rf "$tmp"
done

echo "Bootstrap failed: unable to obtain bootstrap compiler for ${TARGET}." >&2
echo "Tried: tg in PATH, ./target/tg, and release artifacts under ${BASE_URL}." >&2
exit 1
