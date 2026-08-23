#!/bin/bash
# Builds a self-contained whisper-cli into vendor/bin — Metal + CPU backends compiled in, no
# dynamic ggml backend loading, static libs. The result links only system frameworks, so
# Scripts/bundle-tools.sh can drop it straight into the app. See DISTRIBUTION.md.
#
# Run once (and whenever bumping the whisper version). Requires cmake (brew install cmake).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

VERSION="${1:-v1.9.2}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Building whisper.cpp $VERSION (static, Metal embedded)…"
git clone --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp "$WORK/whisper.cpp"
cmake -S "$WORK/whisper.cpp" -B "$WORK/whisper.cpp/build" \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BACKEND_DL=OFF -DBUILD_SHARED_LIBS=OFF -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_TESTS=OFF
cmake --build "$WORK/whisper.cpp/build" -j --config Release

mkdir -p "$REPO_ROOT/vendor/bin"
cp "$WORK/whisper.cpp/build/bin/whisper-cli" "$REPO_ROOT/vendor/bin/whisper-cli"
[[ -f "$WORK/whisper.cpp/build/bin/whisper-server" ]] && \
    cp "$WORK/whisper.cpp/build/bin/whisper-server" "$REPO_ROOT/vendor/bin/whisper-server"

echo "Done -> vendor/bin/whisper-cli"
echo "Linkage (should be system frameworks only):"
otool -L "$REPO_ROOT/vendor/bin/whisper-cli" | tail -n +2 | grep -v "/System\|/usr/lib" \
    && echo "WARNING: non-system dependency above — not self-contained" \
    || echo "  clean (system frameworks only)"
