#!/bin/bash
# Builds a self-contained llama-server into vendor/bin — Metal + CPU backends compiled in, no
# dynamic ggml backend loading, static libs, no libcurl/openssl. The result links only system
# frameworks, so Scripts/bundle-tools.sh can drop it straight into the app and the summarization
# feature works on a Mac that has never seen Homebrew. See DISTRIBUTION.md.
#
# Mirrors build-whisper.sh: same ggml/cmake flags, same "run once (and whenever bumping the
# version)" model. Requires cmake (brew install cmake).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# A specific tag keeps the shipped binary reproducible; override by passing one as $1.
# TODO: pin the default to a specific llama.cpp release tag (e.g. b#### ) instead of "master",
# so shipped builds are reproducible. Currently tracks master, which can drift between builds.
VERSION="${1:-master}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Building llama.cpp $VERSION (static, Metal embedded, no curl/SSL)…"
if [[ "$VERSION" == "master" ]]; then
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$WORK/llama.cpp"
else
    git clone --depth 1 --branch "$VERSION" https://github.com/ggml-org/llama.cpp "$WORK/llama.cpp"
fi
echo "  commit: $(git -C "$WORK/llama.cpp" rev-parse --short HEAD)"

cmake -S "$WORK/llama.cpp" -B "$WORK/llama.cpp/build" \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BACKEND_DL=OFF -DBUILD_SHARED_LIBS=OFF -DGGML_OPENMP=OFF \
    -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=ON -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_SERVER_SSL=OFF -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON
cmake --build "$WORK/llama.cpp/build" -j --config Release --target llama-server

mkdir -p "$REPO_ROOT/vendor/bin"
cp "$WORK/llama.cpp/build/bin/llama-server" "$REPO_ROOT/vendor/bin/llama-server"

echo "Done -> vendor/bin/llama-server"
echo "Linkage (should be system frameworks only):"
otool -L "$REPO_ROOT/vendor/bin/llama-server" | tail -n +2 | grep -v "/System\|/usr/lib" \
    && echo "WARNING: non-system dependency above — not self-contained" \
    || echo "  clean (system frameworks only)"
