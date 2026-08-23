#!/bin/bash
# Makes Transcriber.app self-contained by copying the command-line tools it shells out to
# (ffmpeg, ffprobe, whisper-cli, llama-server) plus their entire dynamic-library closure into the bundle,
# then rewriting every load path so nothing points at Homebrew. After this the app runs on a
# Mac that has never seen Homebrew.
#
# Layout produced:
#   Transcriber.app/Contents/Resources/bin/{ffmpeg,ffprobe,whisper-cli,llama-server}
#   Transcriber.app/Contents/Resources/lib/*.dylib        (shared libraries)
#   Transcriber.app/Contents/Resources/lib/*.so           (ggml compute backends, dlopen'd)
#
# whisper-cli loads its ggml backends (Metal/CPU/BLAS) at runtime by an absolute path baked
# into libggml, so the app must set GGML_BACKEND_PATH to Resources/lib when it spawns it.
#
# IMPORTANT (licensing): Homebrew's ffmpeg is a GPL build (it links x264/x265). Bundling it is
# fine for direct/personal distribution but is NOT permitted on the App Store. Before Store
# submission, rebuild ffmpeg with an LGPL-only configuration and re-run this script pointed at
# that binary. See DISTRIBUTION.md.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Transcriber.app}"
RES="$APP/Contents/Resources"
BIN="$RES/bin"
LIB="$RES/lib"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found. Run Scripts/build-app.sh first." >&2
    exit 1
fi

TOOLS=(ffmpeg ffprobe whisper-cli llama-server)

echo "Bundling tools into $APP"
rm -rf "$BIN" "$LIB"
mkdir -p "$BIN" "$LIB"

# --- locate whisper-cli and llama-server --------------------------------------------------
# Prefer a self-contained (statically-linked) build: $WHISPER_CLI/$LLAMA_SERVER, else the one
# vendored by Scripts/build-whisper.sh / Scripts/build-llama.sh, else whatever is on PATH
# (Homebrew's dynamic build — works, but then its ggml backends must also be bundled; see below
# and DISTRIBUTION.md).
WHISPER_SRC="${WHISPER_CLI:-}"
[[ -z "$WHISPER_SRC" && -x "vendor/bin/whisper-cli" ]] && WHISPER_SRC="vendor/bin/whisper-cli"
[[ -z "$WHISPER_SRC" ]] && WHISPER_SRC="$(command -v whisper-cli || true)"

LLAMA_SRC="${LLAMA_SERVER:-}"
[[ -z "$LLAMA_SRC" && -x "vendor/bin/llama-server" ]] && LLAMA_SRC="vendor/bin/llama-server"
[[ -z "$LLAMA_SRC" ]] && LLAMA_SRC="$(command -v llama-server || true)"

# --- locate the tools ---------------------------------------------------------------------
for tool in "${TOOLS[@]}"; do
    case "$tool" in
        whisper-cli)  path="$WHISPER_SRC" ;;
        llama-server) path="$LLAMA_SRC" ;;
        *)            path="$(command -v "$tool" || true)" ;;
    esac
    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "error: $tool not found — install it (or set \$WHISPER_CLI) before bundling." >&2
        exit 1
    fi
    cp "$path" "$BIN/$tool"
    echo "  tool: $tool  <- $path"
done

# --- ggml compute backends, only if whisper-cli is the dynamic Homebrew build --------------
# A static whisper-cli has Metal/CPU compiled in and links no libggml, so there is nothing to
# copy. The dynamic build dlopen's these .so files at runtime (invisible to otool -L).
if otool -L "$BIN/whisper-cli" "$BIN/llama-server" 2>/dev/null | grep -q "libggml"; then
    echo "  (dynamic build — bundling ggml backends; app must set GGML_BACKEND_PATH)"
    for so in /opt/homebrew/Cellar/ggml/*/libexec/libggml-*.so; do
        [[ -e "$so" ]] || continue
        cp "$so" "$LIB/"
        echo "  backend: $(basename "$so")"
    done
else
    echo "  (static tools — Metal/CPU compiled in, no backends to bundle)"
fi

# --- recursively copy the dylib closure ----------------------------------------------------
# A dependency must be vendored if it resolves to a file under Homebrew. That covers both
# absolute Homebrew paths (/opt/homebrew/opt/ggml/lib/libggml.dylib) and rpath-relative ones
# (@rpath/libwhisper.1.dylib, which whisper-cli uses). System libs (/usr/lib, /System) stay.
HOMEBREW_LIBDIRS=(/opt/homebrew/lib $(ls -d /opt/homebrew/opt/*/lib 2>/dev/null))

# Where a dependency reference actually points on this machine, or empty if it's a system lib.
locate() {
    local dep="$1"
    case "$dep" in
        /opt/homebrew/*|/usr/local/Cellar/*)
            readlink -f "$dep" 2>/dev/null || echo "$dep" ;;
        @rpath/*|@loader_path/*|@executable_path/*)
            # Resolve by basename against the Homebrew lib dirs the tools were built against.
            local base; base="$(basename "$dep")"
            for dir in "${HOMEBREW_LIBDIRS[@]}"; do
                if [[ -f "$dir/$base" ]]; then readlink -f "$dir/$base"; return; fi
            done ;;
        *) : ;;  # /usr/lib, /System — leave as system libraries
    esac
}

# Every dependency line of a Mach-O except its own LC_ID.
deps_of() { otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'; }

# Breadth-first over everything already in bin/ and lib/.
queue=()
for f in "$BIN"/* "$LIB"/*; do [[ -f "$f" ]] && queue+=("$f"); done

while [[ ${#queue[@]} -gt 0 ]]; do
    current="${queue[0]}"; queue=("${queue[@]:1}")
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        real="$(locate "$dep")"
        [[ -z "$real" || ! -f "$real" ]] && continue        # system lib or unresolved
        base="$(basename "$real")"
        if [[ ! -f "$LIB/$base" ]]; then
            cp "$real" "$LIB/$base"
            chmod u+w "$LIB/$base"
            queue+=("$LIB/$base")
            echo "  lib: $base"
        fi
    done < <(deps_of "$current")
done

# --- rewrite load paths so everything resolves inside the bundle ---------------------------
# Normalise every vendored reference to @loader_path so nothing relies on LC_RPATH surviving.
# Binaries in bin/ reach libraries at ../lib; libraries in lib/ reach siblings in the same dir.
relink() {
    local file="$1" prefix="$2"   # prefix is @loader_path/../lib or @loader_path
    install_name_tool -id "$prefix/$(basename "$file")" "$file" 2>/dev/null || true
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        local real; real="$(locate "$dep")"
        [[ -z "$real" ]] && continue                         # leave system libs untouched
        install_name_tool -change "$dep" "$prefix/$(basename "$real")" "$file" 2>/dev/null || true
    done < <(deps_of "$file")
}

for f in "$BIN"/*; do [[ -f "$f" ]] && relink "$f" "@loader_path/../lib"; done
for f in "$LIB"/*; do [[ -f "$f" ]] && relink "$f" "@loader_path"; done

# --- re-sign (modifying Mach-O invalidates the signature); sign libs before binaries -------
for f in "$LIB"/* "$BIN"/*; do
    [[ -f "$f" ]] && codesign --force --sign - "$f" 2>/dev/null || true
done

# --- verify no Homebrew paths remain anywhere ----------------------------------------------
echo
leaked=0
for f in "$BIN"/* "$LIB"/*; do
    [[ -f "$f" ]] || continue
    # Homebrew paths, or any @rpath/@executable_path dep we failed to normalise, mean the
    # bundle would try to load something outside itself.
    bad="$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' \
        | grep -E "/opt/homebrew|/usr/local/Cellar|^@rpath/|^@executable_path/" || true)"
    if [[ -n "$bad" ]]; then
        echo "  LEAK: $(basename "$f") still references outside the bundle:"
        echo "$bad" | sed 's/^/      /'
        leaked=1
    fi
done

count_lib=$(find "$LIB" -type f | wc -l | tr -d ' ')
count_bin=$(find "$BIN" -type f | wc -l | tr -d ' ')
echo "Bundled $count_bin tools and $count_lib libraries/backends."
if [[ $leaked -ne 0 ]]; then
    echo "error: some files still point at Homebrew — the bundle is not self-contained." >&2
    exit 1
fi
echo "Self-contained: no Homebrew references remain."
