# Distributing Transcriber

How to get the app onto someone else's Mac — today (direct hand-off) and eventually
(TestFlight / App Store). Read the ffmpeg section before you ship anything publicly.

## Current state

- **Signing:** ad-hoc only (`codesign --sign -`). No Apple Developer ID on this machine
  (`security find-identity -v -p codesigning` → none). An ad-hoc app is **rejected by
  Gatekeeper** on any other Mac (`spctl -a` → rejected).
- **Self-contained:** yes, as of `Scripts/bundle-tools.sh`. ffmpeg, ffprobe and whisper-cli
  plus their entire dylib closure are copied into `Transcriber.app/Contents/Resources/{bin,lib}`
  and every load path is rewritten off Homebrew. Verified: the bundled binaries transcribe in
  a scrubbed (`env -i`) environment with Homebrew hidden.
- **Models:** downloaded on first run into Application Support (not bundled) — keeps the app
  small and is fine for both distribution paths.

## 🔴 ffmpeg is the blocker for the App Store

Homebrew's ffmpeg is a **GPL** build — it links `x264` and `x265`, both GPL. Two consequences:

1. **The App Store forbids GPL software** (the App Store Terms are incompatible with the GPL's
   restrictions). A bundle containing this ffmpeg **will be rejected**, and even for direct
   distribution the GPL obliges you to offer the corresponding source.
2. **The fix:** build a minimal **LGPL** ffmpeg — drop `--enable-gpl` and the GPL-only encoders
   (x264/x265/etc.), which we don't need. We only *decode* (mp3/opus/aac/pcm + mov/mp4/mkv/ogg
   demuxers) and resample to 16 kHz mono WAV. A configure roughly like:

   ```
   ./configure --disable-gpl --disable-nonfree --enable-shared --disable-static \
     --disable-programs --enable-ffmpeg \
     --disable-encoders --enable-encoder=pcm_s16le \
     --disable-muxers  --enable-muxer=wav \
     --disable-decoders --enable-decoder=aac,mp3,opus,vorbis,pcm_s16le,flac,ac3 \
     --disable-demuxers --enable-demuxer=mov,matroska,ogg,wav,mp3,aac,flac \
     --disable-devices --disable-filters --enable-filter=aresample,aformat,anull
   ```

   Then re-run `Scripts/bundle-tools.sh` — it relocates whatever binaries are on PATH, so it
   handles the LGPL build unchanged. **Until this is done, the bundle is direct-distribution
   only, never the Store.**

whisper.cpp (MIT) and the Whisper models (MIT) are already fine to ship. As of the static
build step (below) whisper links only system libraries, so its bundling is clean.

## whisper.cpp: build from source, static

Homebrew's whisper loads its ggml compute backends (Metal/CPU) from a path compiled into the
library, which does not exist on another Mac, and its `GGML_BACKEND_PATH` override only accepts
a single backend file — so the Homebrew build can't cleanly use Metal from inside a bundle.
Building whisper.cpp with the backends compiled in removes the problem entirely:

```
cmake -B build -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BACKEND_DL=OFF -DBUILD_SHARED_LIBS=OFF -DGGML_OPENMP=OFF \
  -DWHISPER_BUILD_TESTS=OFF
cmake --build build -j --config Release       # -> build/bin/whisper-cli, one file
```

Point `Scripts/bundle-tools.sh` at that binary instead of Homebrew's.

## Path A — direct hand-off (available now, e.g. to Olya)

Good enough for a trusted tester; not for strangers.

1. `Scripts/build-app.sh && Scripts/bundle-tools.sh` → self-contained `build/Transcriber.app`.
2. Zip it, send it (AirDrop / Drive / etc.).
3. Because it's not notarized, macOS quarantines it and shows **"Transcriber is damaged and
   can't be opened."** She removes the quarantine flag once, in Terminal:
   ```
   xattr -dr com.apple.quarantine /Applications/Transcriber.app
   ```
   Then it opens normally. (Not elegant — Path B removes this step.)
4. First launch downloads the speech model (~574 MB).

**Better even for direct hand-off — notarize (recommended, you have the account):**
A notarized app opens with a normal double-click, no "damaged" warning, no Terminal. One-time
setup, then it's a single command — automated in `Scripts/notarize.sh`:

1. **Create a "Developer ID Application" certificate** and install it in this Mac's keychain:
   Xcode ▸ Settings ▸ Accounts ▸ *(your team)* ▸ Manage Certificates ▸ **+** ▸
   *Developer ID Application*. Confirm: `security find-identity -v -p codesigning`.
2. **Store notarization credentials once** (app-specific password from appleid.apple.com):
   ```
   xcrun notarytool store-credentials transcriber-notary \
     --apple-id "you@example.com" --team-id "YOURTEAMID" --password "abcd-efgh-ijkl-mnop"
   ```
3. **Build, sign, notarize, staple:**
   ```
   Scripts/build-app.sh          # self-contained build/Transcriber.app
   Scripts/notarize.sh transcriber-notary
   ```
   The script signs the app and every bundled binary/dylib with your Developer ID + hardened
   runtime (entitlements in `Support/Transcriber.entitlements`), submits to Apple, waits, and
   staples the ticket. Then zip `build/Transcriber.app` and send it — double-click, done.

## Path B — TestFlight / App Store

Needs things only you can set up:

1. **Apple Developer Program** — $99/year. Gives the Developer ID + App Store Connect.
2. **LGPL ffmpeg** — see above. Non-negotiable for the Store.
3. **App sandbox** — the Store requires it. The app shells out to bundled binaries, records
   the mic, captures system audio via a Core Audio process tap, and reads/writes user-chosen
   folders. Each needs the right entitlement (`com.apple.security.app-sandbox`, audio-input,
   user-selected-file read/write) and the process-tap approach must be re-validated under the
   sandbox — this is the biggest unknown and should be spiked early.
4. **App Store Connect record** — bundle ID, screenshots, privacy nutrition labels (easy here:
   "no data collected — everything stays on device").
5. **Upload** a signed, notarized build (Xcode Organizer or `xcrun altool`/`notarytool`), then
   invite testers to TestFlight.

## Troubleshooting: "ffmpeg … moov atom not found" on a recording

This looks like an ffmpeg problem but **it is not** — ffmpeg ran fine; the recording it was
handed had *no audio in it*. An AAC/`.m4a` file that captured zero frames is header-only (no
`moov` atom), so ffmpeg can't open it. Seen on a fresh Mac where the microphone delivered no
buffers (wrong/muted input device, or another app holding the mic).

What the app does about it now (as of the empty-capture fix in `AudioRecorder.finish`):

- If **nothing** was captured, recording stops with *"No audio was captured. Check that your
  microphone works…"* instead of silently producing an unreadable file.
- If only one side of a call had audio, that side becomes the recording (the dead track is
  never allowed to win), and a mix failure keeps whichever track actually has sound.
- Any empty/corrupt file that still reaches transcription now reports *"This file has no
  readable audio…"* rather than the raw `moov atom not found`.

If a user still sees "no audio was captured": System Settings → Privacy & Security →
**Microphone** must list Transcriber and be enabled, and the correct input device must be
selected in **Sound**. Note the default is **microphone-only**; to capture the *other* side of
a Meet/Zoom/Teams call, turn on system-audio capture in Settings (needs Screen & System Audio
Recording permission).

## Quick reference

| | Direct (now) | TestFlight/Store |
|---|---|---|
| Apple Developer account | not strictly needed | required ($99/yr) |
| ffmpeg | GPL bundle tolerable | **LGPL rebuild required** |
| Sandbox | no | required |
| First-run friction | one Terminal command (or notarize) | none |
| Reaches | trusted testers | anyone |
