#!/bin/bash
# Xcode build-phase script: bundles the command-line tools the app shells out to
# (ffmpeg, whisper-cli) plus their dylib closure into the app being built, then signs
# each nested binary with the SAME identity Xcode is using, hardened runtime, and the
# sandbox `inherit` entitlement so they run inside the app's sandbox container.
#
# Runs as the LAST build phase, before Xcode seals the outer .app signature.
#
# Layout produced (matches Engine.swift's Bundle.main/Resources/bin lookup):
#   Transcriber.app/Contents/Resources/bin/{ffmpeg,whisper-cli}
#   Transcriber.app/Contents/Resources/lib/*.dylib
#
# LICENSING: Homebrew's ffmpeg is a GPL build (x264/x265). Fine for this pilot, NOT for
# a public App Store release — set $FFMPEG to an LGPL build before shipping. See DISTRIBUTION.md.
set -euo pipefail

APP="${CODESIGNING_FOLDER_PATH:-${1:-}}"
[[ -z "$APP" && -n "${BUILT_PRODUCTS_DIR:-}" && -n "${WRAPPER_NAME:-}" ]] && APP="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME"
if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "error: app bundle not found (CODESIGNING_FOLDER_PATH='$APP')" >&2
    exit 1
fi

SRC="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ENTS="$SRC/Support/Helper.entitlements"

# Identity Xcode resolved for this build; '-' (ad-hoc) for local Debug / signing-disabled.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -z "$IDENTITY" ]] && IDENTITY="-"
if [[ "$IDENTITY" == "-" ]]; then TS=(--timestamp=none); else TS=(--timestamp); fi

RES="$APP/Contents/Resources"
BIN="$RES/bin"
LIB="$RES/lib"
rm -rf "$BIN" "$LIB"; mkdir -p "$BIN" "$LIB"

# --- locate tool sources ------------------------------------------------------------------
FFMPEG_SRC="${FFMPEG:-$(command -v ffmpeg || true)}"
WHISPER_SRC="${WHISPER_CLI:-}"
[[ -z "$WHISPER_SRC" && -x "$SRC/vendor/bin/whisper-cli" ]] && WHISPER_SRC="$SRC/vendor/bin/whisper-cli"
[[ -z "$WHISPER_SRC" ]] && WHISPER_SRC="$(command -v whisper-cli || true)"

for pair in "ffmpeg:$FFMPEG_SRC" "whisper-cli:$WHISPER_SRC"; do
    name="${pair%%:*}"; path="${pair#*:}"
    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "error: $name not found (set \$FFMPEG / \$WHISPER_CLI or vendor it)" >&2
        exit 1
    fi
    cp "$path" "$BIN/$name"; chmod u+w "$BIN/$name"
    echo "  tool: $name <- $path"
done

# --- ggml compute backends (only if whisper-cli is a dynamic build) ------------------------
if otool -L "$BIN/whisper-cli" 2>/dev/null | grep -q "libggml"; then
    echo "  (dynamic whisper build — bundling ggml backends)"
    for so in /opt/homebrew/Cellar/ggml/*/libexec/libggml-*.so; do
        [[ -e "$so" ]] || continue
        cp "$so" "$LIB/"; echo "  backend: $(basename "$so")"
    done
fi

# --- recursively copy the dylib closure, skipping system libs ------------------------------
HOMEBREW_LIBDIRS=(/opt/homebrew/lib $(ls -d /opt/homebrew/opt/*/lib 2>/dev/null))
locate() {
    local dep="$1"
    case "$dep" in
        /opt/homebrew/*|/usr/local/Cellar/*) readlink -f "$dep" 2>/dev/null || echo "$dep" ;;
        @rpath/*|@loader_path/*|@executable_path/*)
            local base; base="$(basename "$dep")"
            for dir in "${HOMEBREW_LIBDIRS[@]}"; do
                [[ -f "$dir/$base" ]] && { readlink -f "$dir/$base"; return; }
            done ;;
        *) : ;;
    esac
}
deps_of() { otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'; }

queue=(); for f in "$BIN"/* "$LIB"/*; do [[ -f "$f" ]] && queue+=("$f"); done
while [[ ${#queue[@]} -gt 0 ]]; do
    current="${queue[0]}"; queue=("${queue[@]:1}")
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        real="$(locate "$dep")"; [[ -z "$real" || ! -f "$real" ]] && continue
        base="$(basename "$real")"
        if [[ ! -f "$LIB/$base" ]]; then
            cp "$real" "$LIB/$base"; chmod u+w "$LIB/$base"; queue+=("$LIB/$base")
            echo "  lib: $base"
        fi
    done < <(deps_of "$current")
done

# --- rewrite load paths so everything resolves inside the bundle ---------------------------
relink() {
    local file="$1" prefix="$2"
    install_name_tool -id "$prefix/$(basename "$file")" "$file" 2>/dev/null || true
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        local real; real="$(locate "$dep")"; [[ -z "$real" ]] && continue
        install_name_tool -change "$dep" "$prefix/$(basename "$real")" "$file" 2>/dev/null || true
    done < <(deps_of "$file")
}
for f in "$BIN"/*; do [[ -f "$f" ]] && relink "$f" "@loader_path/../lib"; done
for f in "$LIB"/*; do [[ -f "$f" ]] && relink "$f" "@loader_path"; done

# --- sign libraries first, then tools (inside-out); rewriting invalidated signatures -------
for f in "$LIB"/*; do
    [[ -f "$f" ]] || continue
    codesign --force --options runtime "${TS[@]}" --sign "$IDENTITY" "$f"
done
for f in "$BIN"/*; do
    [[ -f "$f" ]] || continue
    codesign --force --options runtime "${TS[@]}" --sign "$IDENTITY" --entitlements "$ENTS" "$f"
done

echo "Bundled $(find "$BIN" -type f | wc -l | tr -d ' ') tools, $(find "$LIB" -type f | wc -l | tr -d ' ') libraries — signed with '${IDENTITY}'."
