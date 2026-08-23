# Transcriber

**Private, offline transcription for the Mac.** Turn voice messages, videos, and live meetings into clean, speaker-attributed Markdown transcripts — without a single byte of audio leaving the machine.

- **Platform:** native macOS app (SwiftUI), Apple Silicon–optimized (Metal GPU + Neural Engine)
- **Status:** working v1, personal/local build
- **Repo:** `~/workspace/Transcriber` · installed at `/Applications/Transcriber.app`

---

## The product in one paragraph

People accumulate spoken content everywhere — Telegram/WhatsApp voice messages, meeting recordings, lecture videos — and it's all invisible to search, notes, and AI assistants. Transcriber converts any of it into Markdown files with YAML frontmatter (source, duration, speakers, languages, timing), which makes the content instantly usable in Obsidian/Notion-style knowledge bases, RAG pipelines, and local LLMs. Unlike cloud tools (Otter, Fireflies, ChatGPT voice), everything runs 100% locally: no subscriptions for compute, no privacy questions, no upload of a therapy session or a business call to someone else's server.

## Core features

| Feature | What it does |
|---|---|
| **File transcription** | Drop files or whole folders (scanned recursively). Handles voice-message formats (`.ogg`, `.opus`, `.m4a`, `.mp3`, …) and video (`.mp4`, `.mov`, `.mkv`, …) — anything ffmpeg can decode. |
| **Meeting recording** | One-click recording like the ChatGPT desktop app: pause/resume, live level meter, saved permanently as `.m4a`. |
| **System-audio capture** | Optional: records what you *hear* (the other side of an online call) via a native Core Audio process tap and mixes it with the mic. |
| **Speaker diarization** | Local pyannote-style CoreML models detect who spoke when. Output blocks: `**Speaker 1**` / `02:36` / text. One click to rename speakers to real names. |
| **Mixed-language meetings** | Unique: per-speaker-turn language detection. A meeting that drifts EN → RU mid-conversation is transcribed correctly in both scripts (`language: en, ru`). Cloud competitors largely fail at this. |
| **LLM-ready output** | Markdown + YAML frontmatter — designed to be indexed by local AI tooling. **Export** any transcript out (Save to Downloads, choose a folder, or rename it) whenever you need the file elsewhere. |
| **Projects & library** | Transcripts and a copy of their audio are kept privately inside the app and organised into projects (like ChatGPT/Claude projects): create a project with a name and notes, and file or move transcripts into it. Nothing is written elsewhere on your Mac; "Delete permanently" removes the app's copy and never touches your originals. |
| **Self-contained** | ffmpeg and whisper are bundled inside the app — no Homebrew needed on the machine that runs it. See [DISTRIBUTION.md](DISTRIBUTION.md). |
| **On-device summaries** | ✨ button (or auto) generates a summary + action items. Two on-device engines: Apple Intelligence (instant, no download, but no Russian/Ukrainian) and a downloadable GGUF model via llama.cpp (any language). "Automatic" picks the right one per transcript. Nothing leaves the Mac. |
| **Custom summary prompt** | Settings → Summary prompt: write your own instructions (any language) so summaries come out in exactly the shape you need. |
| **Rename transcripts / speakers** | Rename the output `.md` file, and rename detected "Speaker 1/2" to real names, from the job list. |
| **MCP server** | The app doubles as a local MCP server (`Transcriber --mcp`), so Claude Code / Claude Desktop / Codex can list, search and read your transcripts and queue new audio — over stdio, on your Mac, no uploads. One-click setup in Settings. See [INTEGRATIONS.md](INTEGRATIONS.md). |
| **Ask Claude / Ask ChatGPT** | Per-transcript hand-off (Linear-style): Claude Code opens in the transcript's folder and reads the file itself; ChatGPT gets the transcript on the clipboard. No API keys, no requests made by the app. |
| **Model management** | Whisper large-v3-turbo (quantized, default), full turbo, or small — downloaded in-app once, all offline afterwards. |

## How it works (architecture)

```
audio/video ──ffmpeg──▶ 16 kHz wav ──┬─▶ whisper.cpp (Metal) ──▶ timed segments ─┐
                                     │                                           ├─▶ merge ─▶ Markdown
                                     └─▶ FluidAudio diarizer (CoreML/ANE) ───────┘
Mixed-language mode: diarize first → cut at turns/pauses → per-chunk transcription
through a resident local whisper-server (model loaded once) with per-chunk language detection.
Recording: AVAudioEngine (mic) + Core Audio process tap (system audio) → ffmpeg amix.
```

- **App:** Swift Package, SwiftUI, no Xcode project needed. `Scripts/build-app.sh [--install]` produces the `.app`.
- **Engines:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT), ffmpeg, [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) for diarization.
- **Runs on:** macOS 14.2+, best on Apple Silicon. Whisper large-v3-turbo runs ~8–15× realtime on M-series.

## What makes it defensible / different

1. **Privacy as the product.** Therapy sessions, legal calls, medical notes, journalism — audiences that *cannot* use cloud transcription. "Your audio never leaves the Mac" is a checkable claim here, not marketing.
2. **No recurring compute cost.** Cloud competitors charge $10–20/user/month largely to pay for GPU time. Local inference means one-time pricing is economically viable where competitors can't follow.
3. **Code-switching support.** Per-turn language detection handles bilingual households/teams (EN+RU, EN+ES, EN+DE…) — a chronically underserved niche and a strong review-magnet feature.
4. **Owns the whole loop.** Record → diarize → transcript → Markdown knowledge base. Most tools do one piece; the Markdown/frontmatter output plugs straight into the local-LLM/Obsidian ecosystem where enthusiasm (and willingness to pay) is high.

## Monetization angles to explore

- **Paid app, one-time price** (Gumroad / Paddle / Mac App Store*): $20–40 one-time fits "no subscription, runs locally" positioning perfectly.
- **Freemium:** free = files + basic transcript; paid = recording, diarization, mixed-language mode, batch folders.
- **Pro/team tier ideas:** meeting summaries via a local LLM, Obsidian plugin, watch-folders, CLI/automations, calendar-triggered recording.
- **Comparables:** MacWhisper (one-time ~€25–59, very successful), Audio Hijack (~$77), Granola/Otter (subscriptions, cloud).

### Gaps to close before selling (*)

- **Distribution:** currently ad-hoc signed; needs an Apple Developer ID, notarization, and an update mechanism (e.g. Sparkle). Mac App Store would additionally require sandboxing — the system-audio tap and Homebrew-binary approach need rework for that (bundle ffmpeg/whisper libraries instead of calling brew binaries).
- **Licensing:** whisper.cpp (MIT), FluidAudio (Apache-2.0) and Whisper model weights (MIT) are commercial-friendly. **ffmpeg needs attention:** the Homebrew build includes GPL components — for a shipped product, bundle an LGPL-only ffmpeg build or link it dynamically and comply accordingly.
- **Polish:** app icon, onboarding (permissions walkthrough), crash reporting, localization (RU/DE/ES are natural first targets given the mixed-language angle).
- **Recording consent:** ship an in-app reminder; recording-consent law varies by jurisdiction.

## Speakers & mixed languages (tuning notes)

- **Speaker separation.** Diarization uses FluidAudio's offline pipeline. Its default clustering
  threshold (0.6) merged too aggressively on real online-meeting audio (band-limited,
  AAC-compressed remote voices) and collapsed a 4-person meeting into a single speaker. The app
  raises the AHC merge threshold to **0.80**, tuned empirically: it recovers all 4 speakers on a
  real meeting while still yielding 1 speaker for a one-person voice message and 2 for a
  two-person chat (no over-splitting). Lives in `Diarizer.defaultThreshold`.
- **Dominant-language cleanup (automatic).** Filler sounds ("Mm-hmm", "Ага", "Yes") and quiet
  moments make whisper hallucinate whole languages: a Russian therapy session came out tagged
  `ru, pl, en, fr, pt, uk`. After the first pass the app computes which language actually holds
  the bulk of the text, then re-transcribes anything that (a) belongs to a language with a
  negligible share (< 500 chars and < 10% of the text) or (b) is a very short chunk (< 40 chars)
  disagreeing with the dominant language. Measured on a real session: every false positive was
  ≤ 29 characters while the median real block was 61, so the split is clean. A genuine second
  language with real content is preserved.
- **Languages to detect (manual allow-list).** Settings → Speakers additionally lets you restrict
  detection to specific languages. Usually unnecessary now, but it's a hard guarantee if you know
  exactly which languages occur. Leave all off to allow any language.
- **Phantom-speaker merge.** Clustering can invent a speaker from a few stray segments (a real
  2-person session came out as 3 speakers, the phantom holding 0.5% of speech / 9 s). Speakers
  below 3% of speech *and* under 45 s are folded into whichever real speaker is adjacent in time.
  Verified safe: the quietest *genuine* speaker measured in a 4-person meeting had 7.4% / 140 s —
  a wide margin — and that meeting still yields 4 speakers.

## Recording reliability

A real session once lost one side of the conversation: the microphone capture died ~32 minutes in
while system audio kept going, and `amix` silently padded the gap. The recorder now watches both
captures, restarts the mic on device changes, compares the two track lengths on stop, warns in the
UI *and* in the transcript frontmatter, and keeps the isolated `.mic.m4a` / `.system.m4a` tracks.
Full incident analysis, fixes and the pending speaker-attribution redesign: [RECORDING.md](RECORDING.md).

## Using it today

1. `brew install ffmpeg whisper-cpp` (already done on this machine).
2. Open **Transcriber** from /Applications — drop files, or hit **Record** for meetings.
3. Settings (⌘,): model, language (Auto recommended), speaker detection, mixed-language mode, system-audio capture, custom vocabulary.
4. Transcripts land in the in-app library, organised into projects in the sidebar. Use a transcript's **Export** action to save a copy (Markdown for Obsidian/Copilot, or the audio) wherever you want.
5. To let Claude work with them: Settings → **Let Claude read your transcripts (MCP)** → *Add to Claude Code*, then restart Claude Code. Ask it things like "search my transcripts for the tax discussion" or "transcribe ~/Downloads/call.m4a".

## Development

```bash
cd ~/workspace/Transcriber
swift build            # debug build
Scripts/build-app.sh --install   # release .app → /Applications
```

Hidden test hooks (no GUI): `Transcriber --selftest-diarize <file>`, `Transcriber --selftest-multilingual <file>`,
`--selftest-mcp`, `--selftest-markdown`, `--selftest-heuristics`, `--selftest-history`, `--selftest-library`, `--selftest-llm-ab <transcript.md>`.

Build a self-contained `.app` (bundles ffmpeg + a statically-linked whisper via
`Scripts/build-whisper.sh` → `Scripts/bundle-tools.sh`): `Scripts/build-app.sh --install`.

The MCP server can be driven by hand:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | .build/debug/Transcriber --mcp
```
