#!/bin/bash
# Builds Transcriber.app into ./build and optionally installs it to /Applications.
# Usage: Scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building release binary…"
swift build -c release

APP=build/Transcriber.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Transcriber "$APP/Contents/MacOS/Transcriber"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle ffmpeg/whisper/llama-server + their libraries so the app needs no Homebrew (unless --no-bundle,
# e.g. a fast dev rebuild that will run against system tools). Bundling signs the nested
# binaries; the outer app is signed afterwards so the whole thing verifies inside-out.
if [[ "${1:-}" != "--no-bundle" && "${2:-}" != "--no-bundle" ]]; then
    Scripts/bundle-tools.sh "$APP"
fi

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Transcriber.app
    cp -R "$APP" /Applications/Transcriber.app
    echo "Installed to /Applications/Transcriber.app"
fi
