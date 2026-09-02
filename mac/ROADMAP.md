# Transcriber — Product Roadmap & Positioning

_Working doc for the first App Store release and beyond. Written 2026-07-29. Effort estimates are rough T-shirt sizes for a solo dev working with an AI pair — treat as planning aids, not commitments._

---

## 1. Positioning

### One-liner
**Record, transcribe, and understand every conversation — 100% on your Mac. No cloud, no subscription, no limits.**

### Headline options (pick one for the store)
1. **"Your conversations, transcribed privately on your Mac."** — leads with privacy.
2. **"Transcription that never leaves your Mac — so you can finally use it for work."** — leads with the confidentiality unlock.
3. **"Meetings and voice messages → searchable, AI-ready notes. Fully offline."** — leads with the outcome.
4. **"Own your transcripts. No cloud, no subscription, no meeting limits."** — leads against the competitor model.

Recommended primary: **#2** — it names the pain (you can't send work audio to a cloud) and the payoff (now you can) in one line. Keep #4 as the pricing sub-headline.

### What the product actually solves (pain points)
1. **You can't put confidential audio in someone else's cloud.** Client calls, legal/medical/HR conversations, NDA'd work meetings, internal strategy — cloud transcription (Otter, Fireflies, Blue Dot) is a non-starter for these. Transcriber runs entirely on-device, so **work material stays work material.** This is the core wedge.
2. **Voice messages pile up unheard.** Telegram/WhatsApp voice notes are a growing burden. Drop them in, get text — no forwarding audio to a web service.
3. **Meeting notes are manual work.** Auto transcript with speakers and timing, and (v1.0/1.1) an on-device summary with action items — no copy-pasting into ChatGPT afterwards.
4. **Subscription fatigue.** Competitors charge $14–39/user/month forever, largely to pay for cloud GPU time. On-device inference has no per-minute cost, so a one-time purchase is viable — **own it, don't rent it.**
5. **Bilingual conversations come out garbled.** Tools that assume one language per file mangle EN↔RU↔DE meetings. Transcriber detects language per speaker-turn.
6. **Vendor lock-in.** Your transcripts are plain Markdown files on your disk, not rows in a SaaS DB. Export is a no-op; you already own them.

### Who it's for
- Privacy-sensitive professionals: consultants, lawyers, therapists, doctors, journalists, founders discussing confidential material.
- Bilingual / multilingual teams and families.
- Heavy voice-message users.
- The Obsidian / local-LLM / "own your data" crowd.

### The moat (why this is defensible)
- **Offline is a capability competitors physically lack.** Blue Dot & co. have _no_ on-device mode — capture may be local but all transcription/AI is cloud. We can make claims they cannot.
- **No recurring compute cost** → one-time pricing they can't match without killing their margins.
- **Owned, portable output** (Markdown + frontmatter) that plugs into the user's own AI stack.

### The extra "selling" angle beyond privacy
Privacy + local is the foundation, but the thing that makes it exciting rather than just "a safe transcriber":

> **Transcriber turns your conversations into a private, searchable, AI-ready knowledge base that you own — and it can summarize and answer questions about them using on-device AI, with nothing ever leaving your Mac.**

Concretely that means: (a) **on-device summaries & action items** via Apple's Foundation Models (macOS 26), and (b) an **MCP bridge** so your own Claude/ChatGPT can chat with your meetings locally. That's Blue Dot's headline value — delivered without the cloud.

---

## 2. Current state (baseline — already built & verified)

- Local recording: microphone + optional system-audio capture (Core Audio process tap), pause/resume, level meter, discard.
- Offline transcription: whisper.cpp (large-v3-turbo, quantized), Metal GPU, in-app model download.
- Speaker diarization: FluidAudio (CoreML/ANE), clustering threshold tuned to 0.80 (recovers multi-speaker meetings without over-splitting single-speaker files).
- Mixed-language meetings: per-turn language detection + a language allow-list to suppress false positives.
- Output: Markdown + YAML frontmatter (source, duration, speakers, languages, timing), saved next to source or into one folder.
- Persistent history across restarts; moved/deleted files flagged gracefully.
- Rename speakers post-transcription; rename the transcript file.
- Import individual files or whole folders (ogg/opus/m4a/mp3/mp4/mov/mkv/…).
- On-device summaries + action items (Apple Intelligence *or* a downloadable GGUF via llama.cpp) with a custom prompt.
- **MCP server** (`Transcriber --mcp`): Claude Code / Claude Desktop / Codex can list, search, read transcripts and queue new audio. Verified connected from Claude Code 2026-07-30.
- **Ask Claude / Ask ChatGPT** per transcript (Claude Code session in the transcript's folder; clipboard hand-off for ChatGPT).

This is already a complete, useful transcriber. The gap to a _sellable v1.0_ is (a) one "understanding" feature so it's not just raw text, and (b) distribution/polish for the store.

---

## 3. MVP for App Store v1.0

**Goal:** ship the smallest thing that is clearly more than "a whisper wrapper" and is clean enough for the store. Lead with privacy, prove value with an on-device summary.

### In scope (v1.0)
| Item | Why it's in v1.0 | Effort |
|---|---|---|
| Everything in the current baseline | Already done | — |
| **On-device summary + action items** (Apple Foundation Models) | The flagship differentiator; makes it "understand," not just transcribe; still 100% local | **M** (3–6 d) + API spike |
| **Custom vocabulary** (names/jargon → whisper prompt) | Cheap, visibly boosts accuracy on real names; great demo | **S** (1–2 d) |
| **Search across transcripts** | Turns a folder of .md into a knowledge base; low effort since output is text | **S–M** (2–4 d) |
| **Onboarding + permissions walkthrough** (mic, system audio, model download) | First-run must not feel broken | **S–M** |
| **App icon + visual polish** | Table stakes for a paid store app | **S–M** |
| **Bundle LGPL ffmpeg + whisper libs; Developer ID; notarization; sandboxing** | Required to ship outside Homebrew users; the hard part | **L** (see §5) |

### Explicitly OUT of v1.0 (deliberately)
- Meeting bot that joins calls, CRM/ATS integrations, per-seat collaboration, sharing links, SSO/SOC2, mobile/watch, real-time transcription. These are cloud/team-inherent or large scope — see the parity analysis. Cutting them is a feature, not a gap.

### v1.0 launch positioning
Free trial (e.g. N minutes or a few files) → one-time unlock. Price anchor: MacWhisper (~€25–59 one-time) is the proven comparable. Undercut Blue Dot's "5 meetings lifetime" free tier by offering _unlimited_ local use.

---

## 4. Post-MVP roadmap

### v1.1 — "Talk to your meetings"
| Item | Value | Effort |
|---|---|---|
| ~~**MCP server over transcripts**~~ | **Shipped 2026-07-30** — see INTEGRATIONS.md. This is our answer to Blue Dot's AI chat, without building a chat UI | done |
| **One-shot "Ask about this transcript"** field | Measures whether anyone wants local Q&A before a full chat gets built | **S** |
| **Summary templates** (sales call, 1:1, standup, interview…) | Tailors the on-device summary; easy once summaries exist | **S** |
| **Auto-generated meeting titles** | Small quality-of-life win via on-device LLM | **S** |

### v1.2 — "Understand the conversation"
| Item | Value | Effort |
|---|---|---|
| **Speaker analytics** (talk ratio, longest monologue, questions asked) | Differentiating; data already comes from diarization | **S–M** |
| **Calendar auto-record** (EventKit) | Convenience parity with Blue Dot's auto-join, done locally | **M** |
| **Folders / collections** | Organize a growing library | **S–M** |

### Later / maybe
- Real-time transcription (whisper streaming) — questionable ROI for personal use.
- Watch-folder automation / CLI for power users.
- Highlight clips & shareable snippets.
- Other platforms (iOS) — large scope; only if traction justifies it.

---

## 5. App Store / distribution readiness (the real work before selling)

_Status update 2026-09-02: signing, notarization and TestFlight are **done**; the remaining
blockers for a *public* paid release are LGPL ffmpeg and the App Sandbox._

- **Signing & notarization:** ✅ done. Apple Developer Program active (Team `AUHHAT2Z56`), app
  signed + notarized (`Scripts/notarize.sh`) and uploaded to **TestFlight** (build 2) via the
  XcodeGen project. See DISTRIBUTION.md and the `transcriber-testflight` skill. Still to decide
  for direct sale: an updater (Sparkle) vs. staying Mac App Store–only.
- **Sandboxing (MAS requirement):** ❌ not yet — the biggest remaining technical lift. The
  binaries are already **bundled** (no Homebrew needed on the target Mac), but the Core Audio
  process tap must be re-validated under `com.apple.security.app-sandbox` with the audio-input
  and user-selected-file entitlements. (TestFlight/direct-notarized distribution avoids the
  sandbox; the public Mac App Store does not.)
- **ffmpeg licensing:** Homebrew's ffmpeg is GPL-enabled. Ship an **LGPL-only** ffmpeg build (no `--enable-gpl`); we only use audio paths, so nothing is lost. whisper.cpp (MIT), FluidAudio (Apache-2.0), Whisper weights (MIT) are all commercial-friendly.
- **Model download UX:** first-run downloads the whisper model (~574 MB) and diarization models. Needs clear progress, resumability, and a graceful offline/failed state.
- **Recording-consent notice:** in-app reminder; consent law varies by jurisdiction.
- **Privacy nutrition label:** trivially strong — "Data Not Collected." Lead with it.

---

## 5b. Summarization engine tiers (decided 2026-07-29)

**Problem found in testing:** Apple's on-device model supports only `da, de, en, es, fr, it, ja, ko, nb, nl, pt, sv, tr, vi, zh` — **no Russian, no Ukrainian**. Verified empirically: even asking for English output on Russian input throws `unsupportedLanguageOrLocale` (the guardrail inspects the input). Since Russian is a primary use case here, Apple FM alone cannot be the summarization story.

**Plan — three tiers, local-first:**

| Tier | Engine | Covers | Cost to user | Privacy |
|---|---|---|---|---|
| 1 (default when possible) | **Apple Foundation Models** | Apple's 15 languages | free, no download, instant | on-device |
| 2 (the Russian answer) | **llama.cpp + downloadable GGUF** | any language incl. RU/UK | one-time ~4–6 GB download | on-device |
| 3 (opt-in) | **Bring-your-own API key** (e.g. Claude) | any, best quality | user's API cost | ⚠️ leaves the Mac — must be explicit |

Tier 2 is architecturally the same trick already used for speech: shell out to a local server binary. `llama.cpp` is **MIT-licensed**, available via Homebrew, and ships `llama-server` with an OpenAI-compatible HTTP API — i.e. a near-copy of the existing `WhisperServer` actor, and `ModelManager` already knows how to download+track models. So tier 2 is mostly plumbing we've already written once.

**Model candidates** (verify at implementation time — this field moves fast):
- **Qwen 3.5 / 3.6** — Apache 2.0, strong multilingual (29+ languages incl. Russian), best WMT24++ scores at the small tiers.
- **Gemma 4** (E2B / E4B / 26B) — switched to **Apache 2.0** in April 2026, claims 140+ languages, and hands-on tests rate it the better *summarizer* at small sizes; E4B ≈ 6 GB, fits 16 GB Macs.
- **Russian-specific fine-tunes** (Vikhr / Saiga lineage) — worth benchmarking for RU specifically.
- **Quantization:** prefer **Q5_K_M**; for Qwen prefer *static* `Q4_K_M` over dynamic `UD-Q4_K_XL` (dynamic quants measured markedly worse: 9.7% vs 2.1% perplexity deviation). Aggressive quantization degrades non-English tokenization first — relevant for Russian.
- **Action:** download one Qwen and one Gemma GGUF at the target size and A/B them on real Russian transcripts before picking a default.

**Licensing note for shipping:** Apache 2.0 (Qwen, Gemma 4) is commercial-friendly; the user downloads weights themselves, which further reduces bundling burden. Avoid model families with usage-restricted licenses as the *default* download.

## 6. Open questions / decisions

1. **Summary engine for v1.0:** ✅ **Verified realizable & shipped as a first cut (2026-07-29).** The `FoundationModels` framework is present in the macOS 26 SDK; a standalone test compiled and ran on this machine, and the on-device summary path is now implemented (`Summarizer.swift`) with map-reduce chunking for long transcripts, gated on `SystemLanguageModel.availability`. Caveat: on this Mac availability returns `appleIntelligenceNotEnabled`, so **actual summary quality is not yet output-tested** — needs Apple Intelligence turned on (System Settings → Apple Intelligence & Siri) to validate. Still open: whether to add an optional bring-your-own Claude API key as a "pro quality" tier for older macOS / higher quality.
2. **Pricing:** one-time vs. freemium-with-one-time-pro. Lean one-time for the anti-subscription story.
3. **MAS vs. direct sale:** MAS = discovery + trust but sandbox pain and 15–30% cut; direct = full control, need own updater/payments. Could do both.
4. **Minimum macOS:** on-device summaries via Apple FM would raise the floor to macOS 26. Decide whether to gate summaries behind 26 while keeping transcription available lower.
