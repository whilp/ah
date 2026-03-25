#!/bin/bash
# Build qemacs with cosmocc to produce an Actually Portable Executable.
# Usage: ./scripts/build-qemacs.sh [--tiny] [--assimilate]
#
# Output: o/qemacs/qe (APE binary, or native ELF if --assimilate)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/o/qemacs"
COSMOCC_DIR="$ROOT/o/cosmocc"
SRC="$BUILD/src"
TINY=0
ASSIMILATE=0

for arg in "$@"; do
    case "$arg" in
        --tiny) TINY=1 ;;
        --assimilate) ASSIMILATE=1 ;;
        *) echo "usage: $0 [--tiny] [--assimilate]" >&2; exit 1 ;;
    esac
done

# --- fetch cosmocc ---
if [ ! -x "$COSMOCC_DIR/bin/cosmocc" ]; then
    echo "==> fetching cosmocc"
    mkdir -p "$COSMOCC_DIR"
    curl -fsSL -o "$COSMOCC_DIR/cosmocc.zip" https://cosmo.zip/pub/cosmocc/cosmocc.zip
    (cd "$COSMOCC_DIR" && unzip -qo cosmocc.zip)
fi
export PATH="$COSMOCC_DIR/bin:$PATH"

# --- clone qemacs ---
if [ ! -d "$SRC" ]; then
    echo "==> cloning qemacs"
    git clone --depth 1 https://github.com/qemacs/qemacs.git "$SRC"
fi

cd "$SRC"

# --- configure ---
echo "==> configuring qemacs for cosmocc"
./configure \
    --cc=cosmocc \
    --disable-x11 \
    --disable-xv \
    --disable-xshm \
    --disable-html \
    --disable-plugins \
    --disable-ffmpeg \
    --prefix=/opt/cosmos

# --- build ---
# Build the unstripped version (*_g) since the system strip breaks APE
# format. The Makefile's strip uses the host strip which doesn't understand
# APE binaries. We copy the _g version and optionally assimilate it.
if [ "$TINY" -eq 1 ]; then
    echo "==> building tqe (tiny)"
    make -j"$(nproc 2>/dev/null || echo 2)" tqe
    cp tqe_g "$BUILD/qe"
else
    echo "==> building qe"
    make -j"$(nproc 2>/dev/null || echo 2)" qe
    cp qe_g "$BUILD/qe"
fi

# --- optional: assimilate to native ELF ---
# assimilate converts the APE polyglot into a native ELF for the current
# platform. This makes it directly executable without the APE loader but
# loses cross-platform portability.
if [ "$ASSIMILATE" -eq 1 ]; then
    echo "==> assimilating to native ELF"
    assimilate "$BUILD/qe"
fi

echo "==> done: $BUILD/qe"
ls -lh "$BUILD/qe"
file "$BUILD/qe" 2>/dev/null || true
