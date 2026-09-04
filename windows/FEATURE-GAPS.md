# Windows feature gaps against macOS

_Implementation audit, updated 2026-09-04. The macOS source is the product reference; the Windows
source was inspected as the implementation truth. Roadmap claims are not counted as shipped._

## Executive summary

The Windows build now has a first **record-and-transcribe vertical slice**. It captures the default
communications microphone and default system output into separate WAV tracks, mixes them into an
M4A, transcribes it, and ingests it into the library. This is developer-tested but not yet approved
for unsupervised real client meetings: long-call and device-failure reliability work remains.

Meeting recording is the first priority because it is the primary user journey for the Windows
pilot: capture a Teams/Zoom/Meet/client call, preserve an accurate record, transcribe it locally,
and provide readable Markdown/HTML for the firm's licensed Copilot.

The red **Record** button visible on macOS is only the entry point. Parity requires a recording
engine, mic and system-audio capture, controls and live status, reliable finalization, automatic
ingest/transcription, and failure warnings. Adding a button before these pieces exist would create
a false sense that meetings are being captured safely.

## Current Windows baseline

Verified on this Windows 11 machine:

- .NET 10 and WinUI project build successfully with zero warnings.
- All 59 `Transcriber.Core.Tests` tests pass.
- The WinUI application launches.
- FFmpeg, whisper.cpp, the large-v3-turbo model, and Silero VAD work end to end.
- Import -> transcription -> Markdown/HTML -> managed library is implemented.
- Projects, Unsorted/All views, drag-to-project, rename, delete, transcript/audio export,
  transcript preview, and audio playback are implemented.
- Recorded M4A audio is decoded to a cached PCM WAV for reliable playback on Windows systems
  without a working AAC media codec. WinUI's native transport controls provide play/pause,
  volume, elapsed/remaining time, and a seekable progress bar.

## Feature matrix

| Area | macOS reference | Windows today | Gap / decision |
|---|---|---|---|
| Meeting recording | Mic plus optional system audio | **Implemented:** default mic + system loopback | P0 validation remains |
| Recording controls | Record, stop/save, pause/resume, discard confirmation | **Implemented** | UI/device testing remains |
| Recording status | Timer, mic level meter, source status, saving progress | **Implemented first cut** | Saving progress is textual, not percentage |
| Capture reliability | Mic watchdog, device-change recovery, dropped-buffer tracking | Partial: liveness warning; no recovery/counters | **P0 before real client calls** |
| Source preservation | Separate mic/system tracks retained; warnings are durable | **Implemented** | Add management/cleanup policy |
| Track finalization | FFmpeg mix with clipping protection and mismatch handling | **Implemented and policy-tested** | Long-call validation remains |
| Record -> transcribe | Finished recording automatically enters queue/library | **Implemented and hardware-tested** | Cancellation/progress polish remains |
| Meeting-end assistance | Browser/app meeting detection, silence fallback, notification, optional auto-stop | Missing | P2 |
| Meeting-start assistance | Detect call and suggest recording | Missing | P2 |
| File import | Files and folders, recursive scanning, drag/drop | File picker and audio drag/drop | Folder/batch import remains P1 |
| Processing queue | Multiple jobs, explicit start/stop, per-stage rows, cancellation | One import processed immediately; global busy state | P1 |
| Local transcription | Whisper, auto language, VAD, timestamps, vocabulary | Three quality models; onboarding/settings supply profession and custom vocabulary hints | Language UI remains P1 |
| Speaker diarization | FluidAudio/CoreML speaker labels | Native sherpa-onnx; asks for count; source-aware mic/remote attribution; mixed-audio phantom cleanup and utterance boundaries | Validate 3+ participants/model licensing |
| Mixed-language mode | Per-turn detection and cleanup | Missing | P2 unless pilot calls require code-switching |
| Rename speakers | Edit Speaker 1/2 labels | **Implemented:** context-menu form rewrites body/frontmatter and refreshes library | Validate UX on multi-speaker transcript |
| Projects/library | Create/edit/delete projects with notes; move items | Core supports all; UI creates projects and drag-moves items, but has no edit/delete/notes UI | P1 |
| Transcript detail | Metadata, warnings, rich readable transcript, audio controls | Metadata, durable warning, plain Markdown text, and native player with volume/time/seek progress | P1 transcript-rendering polish |
| Export | Transcript/audio to Downloads or chosen location | Implemented for transcript; audio has Downloads action but no Save As action | Small P1 gap |
| PDF/readable report | macOS centers on Markdown; Windows product requires easy PDF | HTML produced; user must print to PDF | P1 for pilot handoff |
| Summaries/action items | Apple/local llama engines, auto-summary, custom prompt | Missing | P3 for Windows thesis; firm's Copilot is the AI layer |
| Search | Transcript indexing/search architecture | No Windows search UI/index | P2 |
| Ask Claude/ChatGPT | Per-transcript handoff | Missing | P3; Copilot handoff matters more on Windows |
| MCP server | List/search/read/queue transcripts | Missing | P3 |
| Model management | Select/download models in app | Installer downloads the selected model; changing quality later downloads the missing model in-app | Add pause/resume/recovery polish |
| Settings | Models, language, VAD, vocabulary, speakers, recording, summaries, integrations | Quality, user name, work area, and custom vocabulary persist; first-run onboarding collects them | P1 remaining settings |
| Background presence | Menu-bar controls and background monitoring | Missing | P2; Windows equivalent is tray icon |
| Distribution | Bundled local tools in app build | Debug unpackaged build only; assets bundled into output | P1 after pilot usability |

Priority meanings:

- **P0** — required before recording a real client meeting.
- **P1** — required for a credible first pilot build.
- **P2** — valuable parity after the capture path is proven.
- **P3** — intentionally deferred or lower value for the Windows product thesis.

## P0: meeting recording specification

### Implementation status (2026-08-24)

The first vertical slice is implemented with NAudio 3's supported `WasapiRecorder` API and the
bundled FFmpeg/Whisper tools. Automated hardware tests recorded both sources, retained separate
WAVs, produced an M4A, correctly recognized spoken microphone test phrases, ingested the
transcript/audio, and left the WinUI app responsive. Pause/resume and confirmed discard were also
exercised. Saved audio playback, codec-independent WAV preparation, and the native seek/progress
control have been exercised on this machine. The test suite now contains 59 tests.

This proves the architecture, not production reliability. The 60-90 minute soak test, endpoint
changes, suspend/lock, low disk, and forced-source-failure cases below remain open.

### User flow

1. User opens Transcriber and presses a prominent red **Record** button.
2. The app captures the selected microphone and, by default, Windows system output so both sides
   of Teams, Zoom, Google Meet, and browser calls are present.
3. The UI shows elapsed time, microphone activity, and whether system audio is active.
4. The user can pause/resume, stop and save, or discard after confirmation.
5. Stop finalizes the recording without freezing or presenting an empty window.
6. The app asks how many people participated; the known count constrains diarization.
7. The recording is copied into the managed library, filed into the selected project, and
   transcribed automatically.
8. The detail view exposes both the recording and transcript. Any capture anomaly is shown in the
   UI and persisted in transcript frontmatter.

### Capture architecture

Windows should use WASAPI for both capture sources:

- **Microphone:** capture from the chosen input endpoint.
- **Other side of call:** WASAPI loopback capture from the chosen output endpoint.
- Write each source to its own temporary/lossless working track while recording.
- Do not depend on the meeting application's API or inject a meeting bot.
- On stop, use the bundled LGPL FFmpeg to normalize/encode the final audio and retain the isolated
  tracks at least until finalization and validation succeed.

The implementation uses NAudio 3 over WASAPI. Its microphone and loopback support is working on
the development laptop; endpoint-change behavior and long-recording stability still require the
pilot reliability tests below.

### Required recording state

The application needs an explicit state machine rather than several independent booleans:

```text
Idle -> Starting -> Recording <-> Paused -> Finalizing -> Transcribing -> Complete
                     |                         |
                     +-> Faulted <-------------+
```

Window close, device changes, exceptions, and cancellation must have defined behavior in every
state. A recording must never silently disappear because the UI closed.

### Reliability requirements inherited from macOS

These are product requirements, not optional polish. They come from a real macOS incident where
the microphone died partway through a 67-minute meeting while system audio continued.

- Detect that mic/system buffers have stopped arriving independently of silence.
- Observe default audio-device and format changes; either recover or show a persistent warning.
- Track dropped/failed buffers instead of swallowing errors.
- Compare final mic and system track lengths. A material mismatch must say which track ended and
  approximately when.
- Keep recoverable source tracks whenever capture or mixing is questionable.
- Persist a `recording_warning` in Markdown/library metadata so evidence of a partial recording is
  not lost after dismissing a dialog.
- Avoid clipping when mixing mic and loopback audio.
- Prevent sleep while recording, and define behavior for lock, suspend, and shutdown.
- Finalize safely after long meetings and low-disk conditions; report failure plainly.

### P0 acceptance criteria

- Record mic-only for at least 10 minutes and play the saved audio.
- Record mic + loopback during a real Teams/Zoom/Meet call and hear both sides.
- Pause/resume without losing or shifting either track.
- Stop creates a playable file, adds it to the library, and starts transcription.
- Discard removes only the new recording and never touches existing/original files.
- Unplug/reconnect a headset during recording: capture recovers or the UI clearly warns.
- Change the default input/output device during recording: no silent failure.
- Simulate one source ending early: warning is visible and stored in transcript metadata.
- A 60-90 minute soak recording completes without unbounded memory growth or corrupt output.
- Closing the main window while recording cannot silently terminate capture.

## Recommended delivery sequence

### Phase 1 — first recordable build (P0 foundation)

- **Complete:** Windows default audio endpoint discovery and actionable startup errors.
- **Complete:** microphone capture to a dedicated source track.
- **Complete:** WASAPI loopback capture to a dedicated source track.
- **Complete:** recording state machine and cancellation/finalization semantics.
- **Complete:** main Record button and in-window timer/source/level/control bar.
- **Complete:** finalization and clipping-safe mix through bundled FFmpeg.
- **Complete:** managed-library ingest and automatic local transcription.
- **Complete:** policy/unit coverage for naming, mismatch detection, warnings, and finalization.
- **Complete:** reliable playback through a cached PCM WAV and WinUI native transport controls,
  including a seekable progress bar.

Exit achieved: a developer can record, transcribe, play, and seek through a two-sided recording.

### Phase 2 — safe pilot build (P0 reliability + essential P1)

- Device-change monitoring, liveness watchdogs, dropped-buffer counters, and durable warnings.
- Source selector and recording/transcription settings.
- Long-session, suspend, headset-switch, disk-full, and forced-failure tests.
- Project edit/delete/notes UI and audio Save As.
- Folder/drag-drop import and processing cancellation/progress.
- A simple PDF export or a clearly guided print-to-PDF action.

Exit: safe enough for supervised pilot meetings, with explicit limitations documented.

### Phase 3 — conversation readability

- **Implemented:** Windows diarization, speaker-count prompt, phantom-cluster cleanup, and speaker
  rename workflow.
- **Implemented:** source-aware attribution for app recordings. The named local user is fixed to
  the mic track; the loopback track is diarized among the remaining participants. Mixed-file
  imports use word timing grouped into short utterances to reduce boundary label swaps.
- Validate source-aware attribution on retained two-track recordings and real 3+ participant calls.
- Mixed-language support if real pilot material demonstrates the need.
- Search and transcript rendering polish.

Exit: long multi-party calls are easy to read and attribute.

### Phase 4 — convenience and distribution

- Meeting-start suggestion and meeting-end detection.
- Tray/background recording controls.
- First-run model download and recovery UX.
- Signed installer, update mechanism, license notices, onboarding, and recording-consent reminder.

## Explicit non-goals for the first Windows pilot

- Cloud transcription or a meeting bot.
- Local summaries/chat competing with the firm's licensed Copilot.
- MCP or Claude/ChatGPT-specific integrations.
- Vulkan optimization before baseline correctness and buyer-hardware performance are measured.
- Full macOS visual parity where it does not serve capture accuracy or pilot workflow.

## Immediate next implementation task

Harden the working WASAPI vertical slice for a real pilot:

1. add input/output endpoint selection and persist the choices;
2. follow or recover from default-device changes while recording;
3. count capture gaps/dropped buffers and persist them in warnings;
4. prevent sleep and define suspend/lock behavior; and
5. run the full 60-90 minute soak/failure matrix on real meeting applications.

The Record button is now suitable for supervised development tests, but it must not be represented
as safe for unattended client meetings until these cases pass.
