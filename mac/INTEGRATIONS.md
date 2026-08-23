# Integrations spec — MCP server, "Ask Claude / Ask ChatGPT", recording-save feedback

_Written 2026-07-30. This is the design that the code in this repo implements; read it as the
spec + the operating manual._

The three pieces below share one premise, stated in `FEATURE-PARITY-BlueDot.md`: **we don't build
our own chat.** The user already pays for a frontier model. Our job is to make transcripts
reachable from that model with as little friction as possible.

---

## 1. MCP server

### Goal

Let Claude (Code / Desktop) or Codex read the transcripts this app produced, search across them,
and queue new files for transcription — without the user copying Markdown around.

### Shape

The MCP server is **the app binary itself**, run with a flag:

```
/Applications/Transcriber.app/Contents/MacOS/Transcriber --mcp
```

Rationale for not shipping a second executable: the server needs the same frontmatter parsing,
the same history file and the same settings as the app. A separate target would mean either
duplicating that code or extracting a shared library (and annotating everything `public`).
The flag costs one line in `TranscriberApp.init()` and zero duplication. `--mcp` returns
`Never` — the GUI is never created.

Transport is **stdio, newline-delimited JSON-RPC 2.0** (MCP's local transport). Protocol version
advertised: `2025-06-18`. Implemented by hand (~350 lines) rather than pulling in a Swift MCP SDK,
because the surface we need is small and a dependency-free build keeps the app easy to ship.

stdout carries **only** JSON-RPC frames, written with an unbuffered `FileHandle` write. All logs go
to stderr.

### Tools

| Tool | Arguments | Returns |
|---|---|---|
| `list_transcripts` | `limit` (≤200, default 20), `query`, `since` (`YYYY-MM-DD`) | JSON array: title, path, date, duration, languages, speakers, `has_summary`, characters, preview |
| `search_transcripts` | `query` (required), `limit`, `matches_per_transcript` | JSON array of hits: transcript, speaker, timestamp, snippet |
| `get_transcript` | `path` **or** `title`, `include_summary`, `max_characters` (default 60000), `offset` | Markdown text; paginates with a `next_offset` note when truncated |
| `get_summary` | `path` or `title` | The stored summary block, or a note that there isn't one |
| `transcribe_file` | `path` (or `paths[]`) | Queues media into the app (see inbox below) |
| `get_jobs` | `limit` | Current queue + recent history with states |

`title` matching is case-insensitive substring, so "psycholog" finds
`Психолог сессия 29.07.2026.md`. Ambiguous titles return the candidate list instead of guessing.

Resources are exposed too (`resources/list` / `resources/read`, `file://` URIs, `text/markdown`),
so Claude Desktop's attach-a-resource flow works without a tool call.

### Where transcripts come from

Union of, deduped by path, existing files only:

1. every `done` output path in `~/Library/Application Support/Transcriber/history.json`;
2. a recursive scan of the transcripts output folder and the recordings folder.

Transcripts written "next to the original file" in arbitrary locations are found through history
only — that's the documented limitation. Moving one inside a scanned folder keeps it findable.

### Writing back: the inbox

MCP runs as a **separate short-lived process**, so it cannot call into the running app. For
`transcribe_file` it drops a request JSON into

```
~/Library/Application Support/Transcriber/inbox/<uuid>.json
```

and asks Launch Services to open the app bundle in the background (`open -g`, a no-op if it's
already running). The app polls that folder every 3 s, adds the files to its queue, deletes the
request, and shows a toast. Polling beats FSEvents here: the folder is empty 99.9% of the time and
3 s of latency is irrelevant for a transcription job.

This keeps the invariant that **only the app writes transcripts** — the MCP process never runs
whisper. A 30-minute file would otherwise block a tool call past any client's timeout.

### Setup

Claude Code (one command, from Settings → Integrations, or by hand):

```
claude mcp add --scope user transcriber -- /Applications/Transcriber.app/Contents/MacOS/Transcriber --mcp
```

Claude Desktop — `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "transcriber": {
      "command": "/Applications/Transcriber.app/Contents/MacOS/Transcriber",
      "args": ["--mcp"]
    }
  }
}
```

Codex CLI — `~/.codex/config.toml`:

```toml
[mcp_servers.transcriber]
command = "/Applications/Transcriber.app/Contents/MacOS/Transcriber"
args = ["--mcp"]
```

**ChatGPT (web/desktop) cannot use this.** Its connectors are remote HTTP/SSE servers; it has no
local-stdio MCP client. Reaching ChatGPT needs either a remote bridge (which defeats the whole
local-first premise) or the hand-off in §2. Don't promise ChatGPT MCP support in marketing copy.

### Verify

```
Transcriber --selftest-mcp        # drives initialize → tools/list → each tool over a pipe
```

---

## 2. "Ask Claude" / "Ask ChatGPT" hand-off

### Goal

From a finished transcript row, open a fresh assistant session that is already about that
transcript — the Linear desktop pattern.

### Behaviour

**Ask Claude** (preferred path — the CLI is installed):

1. Write a throwaway `.command` script to the temp dir:
   `cd <transcript folder>` then `exec claude "<prompt>\n\nTranscript file: @<name>"`.
2. Open it with Terminal (or whatever handles `.command`).
3. Claude Code starts interactive, in the right folder, and **reads the file itself** — so a
   90-minute meeting costs nothing at hand-off and isn't truncated by a URL or clipboard limit.

The prompt is passed through a quoted heredoc with a UUID sentinel, so no shell escaping bugs.
The script is deleted 60 s later.

Fallback when `claude` isn't on the machine: copy prompt + transcript to the clipboard, open
Claude.app (or claude.ai), toast "Transcript copied — paste it into Claude (⌘V)".

**Ask ChatGPT:** clipboard + activate ChatGPT.app (`com.openai.chat`, else `chatgpt.com`) + the
same toast. There is no supported way to inject text into the ChatGPT app, and
`https://chatgpt.com/?q=` breaks on transcript-sized input. Copy-and-paste is the honest option;
don't fake a deeper integration.

Both entry points live in the row's ⋯ menu **and** the row's context menu. Frontmatter is stripped
from the clipboard payload; the summary, speaker labels and timestamps are kept.

### The prompt

Editable in Settings → Integrations, default:

> This is a transcript of a recorded conversation, with speaker labels and timestamps. Help me
> work with it: answer my questions, pull out decisions and action items, and cite the timestamps
> you used.

### Deliberately not doing

- No API keys, no billing, no requests from the app. The hand-off starts a session in a tool the
  user already has.
- No "one-shot ask" box yet. It's the next step in the parity doc's staged plan, and it only makes
  sense once these buttons show whether people reach for an assistant at all.

---

## 3. Recording-save feedback

### The bug

Stopping a 30-minute recording with system audio captured left the window **silent for tens of
seconds**: `AudioRecorder.finish()` sets `isRecording = false` (bar disappears) and only appends
the job after ffmpeg has finished mixing the mic and system tracks. Nothing on screen, nothing in
the list — indistinguishable from "the app lost my meeting".

### The fix

`AudioRecorder` gains `isFinishing` and `finishProgress`. Mixing progress is real, not fake: the
`time=HH:MM:SS.ss` lines ffmpeg writes to stderr are parsed and divided by the recording length we
already know from the level meter. While that runs, the recording bar is replaced by a **Saving
bar** — spinner, determinate progress, elapsed length, "keep the app open" note — and the queued
job appears the moment the file exists.

Failure stays visible too: if mixing fails, the mic-only track is kept (existing behaviour) and the
warning is surfaced in the same bar instead of vanishing with it.
