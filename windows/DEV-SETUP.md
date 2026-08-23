# Transcriber for Windows — development environment setup

The Windows app can only be built *on Windows* (WinUI 3 + MSIX packaging don't build on macOS).
This sets up the Windows laptop as the build machine. Once done, you develop there with Claude
Code the same way you do on the Mac, and the app you produce gives users the **same zero-friction
experience as the Mac build**: one installer, everything bundled, models downloaded on first run.

## What "same as the Mac" maps to on Windows

| Mac today | Windows target |
|---|---|
| Notarized `.app` in a DMG, drag to install | **MSIX installer** — double-click, signed |
| .NET/Swift runtime inside the app | .NET 9 published **self-contained** (user installs no runtime) |
| `bundle-tools.sh` bundles ffmpeg/whisper-cli into the app | `ffmpeg.exe` + `whisper-cli.exe` shipped inside the app package |
| Models download on first run | Same — download on first run |
| Developer ID + notarization | **Azure Trusted Signing** (~$120/yr) |

So the user never "downloads things around" — that's a *build-time* concern we handle in the
packaging step, exactly like `bundle-tools.sh` does on the Mac.

---

## Step 1 — Check Windows version

```powershell
winver
```

Need **Windows 11** (or Windows 10 build 19041+). Note the build number — build **20348+** is
needed later for per-process audio loopback, but not to start.

## Step 2 — Install the toolchain

Open **PowerShell as Administrator** and run these (`winget` ships with Windows 11):

```powershell
winget install Git.Git
winget install Microsoft.DotNet.SDK.9
winget install Microsoft.VisualStudio.2022.Community `
  --override "--add Microsoft.VisualStudio.Workload.ManagedDesktop --add Microsoft.VisualStudio.ComponentGroup.WindowsAppSDK.Cs --includeRecommended"
winget install OpenJS.NodeJS.LTS
winget install Gyan.FFmpeg
```

What each is for:

- **Git** — version control / syncing the Mac reference code.
- **.NET 9 SDK** — the language + build system the app is written in.
- **Visual Studio 2022 Community** with two pieces:
  - *ManagedDesktop* workload — .NET desktop development.
  - *WindowsAppSDK.Cs* component — the **WinUI 3** project templates and Windows App SDK.
  This is the smoothest WinUI experience; it also installs the MSIX packaging tooling.
- **Node.js LTS** — only needed to install Claude Code.
- **ffmpeg** (LGPL build) — used during development; later bundled into the app, same as on Mac.

Then install **Claude Code** so you develop on Windows like on the Mac:

```powershell
npm install -g @anthropic-ai/claude-code
claude        # sign in
```

## Step 3 — Verify everything

```powershell
dotnet --version      # 9.x.x
git --version
node --version
claude --version
```

In Visual Studio, confirm the WinUI template exists: **Create a new project** → search
"WinUI" → you should see **"Blank App, Packaged (WinUI 3 in Desktop)"**. If it's there, the
WinUI toolchain is complete.

## Step 4 — Get the Mac code over as reference (optional but recommended)

The Swift code won't build on Windows, but you'll port algorithms from it (`Engine.swift`,
`MarkdownWriter.swift`, `TranscriptIndex.swift`, `SelfTest.swift`). Only `Sources/` (~0.5 MB)
and the top-level `*.md` design docs matter — not the 2 GB of build output.

Cleanest: a **private GitHub repo** cloned on both machines. (Ask Claude on the Mac to set
this up — `git init` + a `.gitignore` for build output/models + push.) Then on Windows:

```powershell
git clone <private-repo-url> Transcriber-mac-ref
```

## Step 5 — First build smoke test

In Visual Studio: create a **"Blank App, Packaged (WinUI 3 in Desktop)"** project, press **F5**.
If a blank window opens, the environment is fully working and Phase 1 can start.

---

## Deferred — do NOT install yet

Building whisper.cpp from source with **Vulkan** (for Intel/AMD integrated-GPU speedup) needs
the Vulkan SDK + CMake + Visual Studio's **C++ workload**. Only do this if CPU transcription
turns out too slow. For everything up to a working pilot, the prebuilt `whisper-cli.exe` is
enough.
