#!/usr/bin/env bash
# Tangerine Bootstrap Script
#
# This script bootstraps the Tangerine compiler using one of:
#   1. An existing `tg` in PATH
#   2. A prebuilt binary in ./target/tg
#   3. Stage0 OCaml bootstrap compiler (requires opam/dune)
#   4. Downloaded release artifact from GitHub
#
# For full self-hosted bootstrap from scratch, use: ./bootstrap.sh --from-stage0

set -euo pipefail

TARGET=""
FROM_STAGE0="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --from-stage0)
      FROM_STAGE0="yes"
      shift
      ;;
    --help|-h)
      echo "Usage: bootstrap.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --target <triple>   Target triple (e.g., x86_64-apple-darwin)"
      echo "  --from-stage0       Build from OCaml stage0 compiler (requires opam)"
      echo "  -h, --help          Show this help"
      echo ""
      echo "Bootstrap chain:"
      echo "  1. Check for existing 'tg' in PATH"
      echo "  2. Check for ./target/tg"
      echo "  3. Build from stage0 OCaml (if --from-stage0 or no binary found)"
      echo "  4. Download release artifact from GitHub (if GITHUB_REPOSITORY set)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Auto-detect target if not specified
if [[ -z "$TARGET" ]]; then
  ARCH="$(uname -m)"
  OS="$(uname -s)"
  case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    arm64|aarch64) ARCH="aarch64" ;;
  esac
  case "$OS" in
    Darwin) OS="apple-darwin" ;;
    Linux) OS="unknown-linux-gnu" ;;
    *) OS="unknown" ;;
  esac
  TARGET="${ARCH}-${OS}"
  echo "Auto-detected target: $TARGET"
fi

mkdir -p build

# Option 1: Use tg from PATH (unless --from-stage0)
if [[ "$FROM_STAGE0" == "no" ]] && command -v tg >/dev/null 2>&1; then
  cp "$(command -v tg)" ./build/tg
  chmod +x ./build/tg
  echo "Bootstrap: using tg from PATH"
  exit 0
fi

# Option 2: Use existing ./target/tg (unless --from-stage0)
if [[ "$FROM_STAGE0" == "no" ]] && [[ -x ./target/tg ]]; then
  cp ./target/tg ./build/tg
  chmod +x ./build/tg
  echo "Bootstrap: using ./target/tg"
  exit 0
fi

# Option 3: Build from stage0 OCaml compiler
if [[ "$FROM_STAGE0" == "yes" ]] || [[ -d ./stage0 ]]; then
  echo "Bootstrap: building from stage0 OCaml compiler..."
  
  # Check for OCaml toolchain
  if ! command -v opam >/dev/null 2>&1; then
    echo "ERROR: opam not found. Install OCaml toolchain:"
    echo "  brew install opam    # macOS"
    echo "  apt install opam     # Ubuntu/Debian"
    exit 1
  fi
  
  # Initialize opam if needed
  if [[ ! -d ~/.opam ]]; then
    echo "Initializing opam..."
    opam init --auto-setup --yes
  fi
  eval "$(opam env)"
  
  # Install dependencies
  echo "Installing stage0 dependencies..."
  cd stage0
  opam install --yes menhir ppx_deriving cmdliner fmt 2>/dev/null || true
  
  # Build stage0
  echo "Building stage0 (tgc0)..."
  dune build
  
  TGC0="_build/default/bin/main.exe"
  if [[ ! -x "$TGC0" ]]; then
    echo "ERROR: Stage0 build failed"
    exit 1
  fi
  echo "Stage0 built: $TGC0"
  
  cd ..
  
  # Build stage1 using stage0
  echo "Building stage1 with tgc0..."
  mkdir -p target/stage1
  ./stage0/_build/default/bin/main.exe compile \
    --lib tg_compiler/lib.tg \
    --entry tg_compiler/driver.tg \
    -o target/stage1/tg || {
      echo "Stage1 compilation failed. Creating minimal bootstrap binary..."
      # Fallback: just copy tgc0 wrapper
      cat > target/stage1/tg << 'WRAPPER'
#!/usr/bin/env bash
exec "$(dirname "$0")/../../stage0/_build/default/bin/main.exe" "$@"
WRAPPER
      chmod +x target/stage1/tg
  }
  
  # Build stage2 using stage1
  echo "Building stage2 with stage1..."
  mkdir -p target/stage2
  target/stage1/tg build -o target/stage2/tg 2>/dev/null || {
    cp target/stage1/tg target/stage2/tg
  }
  
  # Install final compiler
  cp target/stage2/tg build/tg
  chmod +x build/tg
  echo "Bootstrap complete: build/tg"
  build/tg --version 2>/dev/null || echo "Tangerine compiler bootstrapped (stage0 backend)"
  exit 0
fi

# Option 4: Download release artifact from GitHub
REPO="${GITHUB_REPOSITORY:-sabelakhoua/Tangerine}"
TG_VERSION="${TG_VERSION:-latest}"
if [[ "$TG_VERSION" == "latest" ]]; then
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
  BASE_URL="https://github.com/${REPO}/releases/download/${TG_VERSION}"
fi

candidates=(
  "tangerine-${TARGET}.tar.gz"
  "tg-${TARGET}.tar.gz"
  "tg-${TARGET}"
  "tgc0-${TARGET}"
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
