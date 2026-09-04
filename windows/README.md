# Transcriber for Windows

Native Windows build for the legal/immigration market. Separate codebase from the macOS app,
sharing a **format contract** rather than code — see `FORMAT.md`.

See [FEATURE-GAPS.md](FEATURE-GAPS.md) for the source-audited macOS parity matrix and the
recording-first Windows delivery plan.

**Target user:** a client-facing consultant at a Spain immigration firm. Teams/Zoom/Meet calls
on her PC, no meeting tooling today, manual notes, client follow-up by email. What she needs,
in her words: an accurate verbatim record of *"что нам конкретно сказал клиент"* (clients say
one thing and later deny it), output that is easy to read (PDF) and clean Markdown she can
paste into her firm's licensed Copilot. Her senior manager decides at the end of August.

**Product thesis:** we are the accurate, private capture-and-transcript layer; their Copilot
is the AI layer. We feed it, we don't compete with it. So accuracy and readability get the
investment — not local summarisation.

## Status

| Piece | State |
|---|---|
| `Transcriber.Core` — pipeline, merging, whisper JSON, Markdown + HTML output | **done, tested on macOS** |
| Accuracy: VAD (silence-skipping), custom vocabulary, paragraph merging | **done** (`WhisperCommand`, `TranscriptMerger`) |
| **Projects & library** — `LibraryStore`, projects, ingest-copy-in, move, rename, export, delete, migration | **done, verified end-to-end** (transcribe → ingest → project) |
| `Transcriber.Cli` — headless driver (incl. `--library`/`--project`) | **done, verified on real audio** |
| Format parity with the macOS app | **verified** — output parses correctly through the Mac MCP server |
| `Transcriber.App` — WinUI 3 GUI (3-column: projects / list / detail + audio player + drag-drop) | **builds cleanly on Windows**; launch/UI testing in progress |
| Recording — WASAPI mic + loopback | **first vertical slice implemented and hardware-tested**; reliability hardening remains |
| Diarization (speaker labels) | **implemented:** count prompt, phantom cleanup, source-aware mic/remote attribution, mixed-audio utterance attribution |
| Transcription quality | **implemented:** persisted model choice, automatic missing-model download, profession/custom vocabulary hints |
| Onboarding | **implemented:** name, work area, and specialist vocabulary; name labels the local mic track |

**59 xUnit tests green** (`dotnet test`), covering merging, speaker attribution/renaming,
whisper flags/JSON, and the
full library lifecycle. The library layer is byte-compatible with the macOS app's `library.json`
model and transcript format (FORMAT contract), so the two products read each other's data.

## The WinUI app (`src/Transcriber.App`)

The GUI is written and now **compiles cleanly on Windows**. It is deliberately kept out of the
cross-platform solution so `dotnet test` remains portable; build it on Windows directly.

What it implements (all wired to the verified `Transcriber.Core`):
- Three-column layout: projects sidebar · transcript list · detail pane.
- **Import** a file → transcribe (Core pipeline) → filed into the selected project.
- **Detail pane**: title/metadata, transcript **text preview**, and an audio player
  (`MediaPlayerElement` transport controls) for the copied audio.
- **Drag** a transcript from the list onto a project (or Unsorted) in the sidebar to file it.
- Project **badges** in the "All" view, and per-item Export / Rename / Delete / Open.

Recording now captures default mic + system loopback, supports pause/resume/discard, retains
separate source tracks, asks for the participant count, finalizes through FFmpeg, and automatically
transcribes. The local user's name is assigned deterministically to the mic track; the system track
is diarized among the remaining participants. It still needs long-call/device-change reliability
hardening and validation with real retained 3+ participant tracks.

### Building it on Windows (inside the VM)

```powershell
cd Windows
dotnet build src\Transcriber.App\Transcriber.App.csproj -r win-x64
# then bundle ffmpeg + whisper into the output's bin\ / models\ (see scripts\fetch-assets.ps1)
```

### Build the friend-test installer

After fetching the native tools, build the self-contained x64 publish and installer with:

```powershell
.\scripts\build-friend-installer.ps1
```

The setup executable is written to `artifacts\friend-test`. AI models are deliberately excluded
from the executable: setup asks for a transcription quality, downloads only that model plus the
required VAD/diarization models, and verifies every download with SHA-256. Use `-SkipPublish` to
recompile only the installer after editing its script or handoff notes.

### ⚠️ Expect a compile-fix pass on the first Windows build

This code was written without a compiler. Likely first-build fixes, in rough order of probability:
- **Package versions** — `Microsoft.WindowsAppSDK` / `Microsoft.Windows.SDK.BuildTools` /
  `CommunityToolkit.Mvvm` versions in the `.csproj` are best-guess; `dotnet restore` will tell
  you the right ones to pin.
- **Unpackaged bootstrapper** — self-contained unpackaged WinUI may need the Windows App SDK
  bootstrap auto-init property; if the app won't launch, that's the first thing to check.
- **XAML/API names** — `MediaPlayerElement.Source`, `DragEventArgs.DragUIOverride`, the
  `FileSavePicker`/`FileOpenPicker` + `WinRT.Interop.InitializeWithWindow` interop, and the
  `x:Bind` converter wiring (`BoolToVisibilityConverter`, already added) are the spots to verify.
- Tools/models are located beside the app via `ToolPaths.FromAppDirectory` (`bin\`, `models\`).

Verified numbers from the real pipeline on macOS (M4 Max, 2:16 Russian voice message):
35 recognition segments merged into 2 readable paragraphs, 35× realtime.

## Why a Windows VM is required

WinUI 3 **cannot be built on macOS**. Microsoft is explicit: *"Generally, no. WinUI and the
Windows App SDK require MSBuild, which is why Visual Studio is a prerequisite."* Everything in
`Transcriber.Core` is plain `net10.0` and therefore builds and tests on macOS — which is why
the pipeline lives there and the UI is kept thin.

### Setting up the VM (do this on the Mac, interactively)

1. **Hypervisor.** VMware Fusion is free for personal use and gained Windows 11 ARM support in
   October 2025 (requires a Broadcom account). UTM is free with no registration. Parallels is
   paid but fully automates the install.
2. **Windows 11 ARM64 image.** Official ISO: <https://www.microsoft.com/en-us/software-download/windows11arm64>
   (~5.5 GB; the generated link expires after 24 hours). Easier alternative: **CrystalFetch**
   from the Mac App Store, free, with Apple Silicon selected. Do **not** use the x64 ISO.
   Windows 11 installs and runs unactivated for development, with a watermark.
3. **Inside the VM:** Visual Studio 2026 with the **WinUI application development** workload,
   and the .NET 10 SDK. Verify the exact winget package ID before scripting it
   (`winget search "Visual Studio"`) — do not assume the 2022 ID pattern still applies.
4. **Assets:** from the repo's `Windows` folder run
   `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-assets.ps1`.
5. **Smoke test:** `dotnet run --project src\Transcriber.Cli -- <some.m4a> --language ru`.
   This exercises the whole pipeline with no UI, so it isolates tool/asset problems from UI ones.

Windows 11 on ARM emulates x64, so the shipping x64 build can also be launched in the VM.
What the VM **cannot** tell us is real performance: ARM-under-emulation numbers say nothing
about the Intel/AMD laptops our buyers actually own. That still needs a physical x64 machine.

## Testing the pipeline from macOS

`Transcriber.Core` and `Transcriber.Cli` target `net10.0` and run anywhere. Point them at
Homebrew's binaries to exercise the real code path:

```bash
export PATH="$HOME/.dotnet:$PATH"
cd Windows && dotnet test          # 27 tests, no Windows needed

M="$HOME/Library/Application Support/Transcriber/models"
dotnet run --project src/Transcriber.Cli -- ~/some-call.m4a --language ru \
  --ffmpeg /opt/homebrew/bin/ffmpeg --whisper /opt/homebrew/bin/whisper-cli \
  --model "$M/ggml-large-v3-turbo-q5_0.bin" --vad "$M/ggml-silero-v5.1.2.bin"
```

## Accuracy decisions, and the evidence for them

- **VAD is mandatory, not optional.** Measured on a real recording whose microphone had died:
  in one 3:38 silent window, **6 of 8 segments were fabricated text** that was never spoken
  (`Субтитры создавал DimaTorzok`, `Спасибо за субтитры Алексею Дубровскому!`). With
  `--vad --suppress-nst` the same window produced 3 segments, all real speech. For a product
  sold as evidence of what a client said, invented sentences are disqualifying. VAD also makes
  transcription much faster, since silence is never decoded (75× realtime on a 44-minute track).
- **Paragraph merging.** Whisper's 10–30 s segments must be merged or a single two-minute answer
  renders as thirteen repeated speaker headers. Thresholds match the macOS app: 3 s gap, ~120 s
  cap, and the cap only applies at a sentence boundary.
- **Custom vocabulary is a hint, not a guarantee.** Onboarding combines a selected work-area preset
  with user-entered names and jargon and passes it through `--prompt`. It should be evaluated on
  domain-specific samples because an irrelevant prompt can reduce quality.

## Known gaps

Hardware-specific CPU/CUDA measurements and repeatable benchmark rules are documented in
[PERFORMANCE.md](PERFORMANCE.md).

- **Diarization still needs 3+ participant validation.** The native sherpa-onnx pipeline, pyannote
  segmentation, 3D-Speaker embeddings, expected-count constraint, phantom-speaker cleanup,
  source-track attribution, timed utterance attribution, and rename UI are implemented. The
  supplied mixed two-person sample now stays at two speakers when the known count is selected;
  retained separate mic/system tracks were not available on this machine for the stronger
  source-aware validation. The sherpa-onnx code is
  Apache-2.0; model-weight redistribution licensing must be confirmed before commercial bundling.
- **No Vulkan whisper build.** whisper.cpp ships no prebuilt Vulkan binary for Windows, and
  Vulkan is the entire integrated-GPU story for GPU-less laptops (upstream claims ~12× over CPU
  on Intel/AMD iGPUs). Compiling it with `-DGGML_VULKAN=ON` is a real build step, not a download.
- **Performance on buyer hardware is unmeasured.** A GPU-less business laptop is expected around
  1× realtime for large-v3-turbo versus 8–15× on Apple Silicon. Acceptable for post-call batch
  work, but it must be measured on a physical x64 machine.
- **PDF is currently print-to-PDF from the HTML.** A real PDF writer (MigraDoc/PdfSharp, MIT —
  verify QuestPDF's revenue-capped licence before choosing it) comes with the UI.
