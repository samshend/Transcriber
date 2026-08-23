#!/bin/bash
# Signs Transcriber.app with your Developer ID + hardened runtime, notarizes it with Apple,
# and staples the ticket — the result opens with a normal double-click on any Mac, no
# "damaged" warning and no Terminal step.
#
# PREREQUISITES (one-time, only you can do these):
#   1. Create a "Developer ID Application" certificate and install it in this Mac's keychain:
#        Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ + ▸
#        "Developer ID Application".  (Or download it from developer.apple.com/account →
#        Certificates.)  Verify with:  security find-identity -v -p codesigning
#   2. Store notarization credentials once under a profile name:
#        xcrun notarytool store-credentials transcriber-notary \
#          --apple-id "you@example.com" --team-id "ABCDE12345" \
#          --password "app-specific-password"        # from appleid.apple.com → App-Specific Passwords
#      (An App Store Connect API key works too: --key / --key-id / --issuer.)
#
# USAGE:
#   Scripts/build-app.sh                 # produce a self-contained build/Transcriber.app
#   Scripts/notarize.sh transcriber-notary
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-transcriber-notary}"
APP="build/Transcriber.app"
ENTITLEMENTS="Support/Transcriber.entitlements"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — run Scripts/build-app.sh first." >&2
    exit 1
fi

# Find the Developer ID Application identity (by its 40-char hash, unambiguous).
IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'[)"]' '/Developer ID Application/ {gsub(/ /,"",$2); print $2; exit}')"
if [[ -z "$IDENTITY" ]]; then
    echo "error: no 'Developer ID Application' certificate in the keychain." >&2
    echo "       Create one in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates (see header)." >&2
    exit 1
fi
echo "Signing identity: $IDENTITY"

SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")

# Inside-out: every bundled library and helper binary first, then the app itself. Everything
# gets the hardened runtime; only the app carries the microphone entitlement.
echo "Signing bundled libraries…"
find "$APP/Contents/Resources/lib" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 \
    | while IFS= read -r -d '' lib; do "${SIGN[@]}" "$lib"; done

echo "Signing bundled tools…"
for tool in "$APP/Contents/Resources/bin/"*; do
    [[ -f "$tool" ]] && "${SIGN[@]}" "$tool"
done

echo "Signing the app…"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"

echo "Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Submitting to Apple for notarization (this can take a few minutes)…"
ZIP="build/Transcriber-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"

echo "Stapling the ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo
echo "Done. $APP is signed and notarized. Zip it and send it — it opens with a double-click."
echo "Tip: distribute a .dmg or .zip; both preserve the stapled ticket."
