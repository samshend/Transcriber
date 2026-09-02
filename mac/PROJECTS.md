# Projects & local library

> **Status: ✅ implemented and shipped.** This started as a design spec; the feature is now live
> — `LibraryStore` (`Sources/Transcriber/Library.swift`) is wired into `AppState`, the sidebar
> UI is in `LibraryView.swift`, and the MCP read path reads `library.json` directly. Read the
> rest as the design record, not a to-do. (One leftover: the old `OutputMode` enum still exists
> in `AppState.swift` as dead code and could be removed.) The "FORMAT contract" referenced below
> is not yet written as `FORMAT.md`; the format lives in `MarkdownWriter.swift`.

Reshapes storage from "files scattered next to their sources" into a **managed library the app
owns**, organised into **projects** (like ChatGPT/Claude Desktop projects). Confirmed decisions:

- **The library is the source of truth.** New transcripts and a copy of their audio live inside
  the app's storage. The old "save alongside / output folder" auto-write is removed; getting a
  file out is now an explicit **Export** (Save to Downloads / choose folder / rename on the way out).
- **Imported audio is copied in.** Dropping a file copies it into the library; the user's original
  is never touched. On-disk duplicates are acceptable.
- **"Delete permanently"** removes the library's stored copy (audio + transcript) after
  confirmation. It never deletes anything outside the library.
- **Existing transcripts are migrated** on first launch into an "Unsorted" project (copied in;
  originals left where they are).

## On-disk layout

```
~/Library/Application Support/Transcriber/
  Library/
    library.json              # index: schema version, projects[], items[]
    <itemUUID>/
      transcript.md           # the transcript (same format as today — see FORMAT contract)
      audio.<ext>             # the copied source audio (optional)
```

## Data model  (`Sources/Transcriber/Library.swift`)

```
Project:     id, name, notes, created
LibraryItem: id, projectID?, title, transcriptFile, audioFile?, created, modified,
             + denormalised metadata for list display without opening the file:
               durationSeconds?, language?, speakers[], hasSummary, recordingWarning?, sourceName?
```
`projectID == nil` ⇒ the built-in **Unsorted** bucket.

## `LibraryStore` (ObservableObject, injectable root for tests)

CRUD projects (delete moves its items to Unsorted); `ingest(transcript:audio:)` copies files into
`Library/<id>/` and denormalises metadata via `TranscriptIndex.load`; `move(item:to:)`,
`setTitle`, `deleteItem` (rm the item folder), `export(item:kind:to:)`, `migrate(...)`.

## Build order

1. **Foundation (this pass, headless-testable):** the model, `LibraryStore` with all CRUD +
   export + migration logic, and `--selftest-library`. No UI, app still builds and runs as-is.
2. **Integration:** `AppState.process` writes into the library instead of `outputDirectory`;
   remove `OutputMode`/output-folder settings; run migration on first launch.
3. **UI:** replace the flat job list with a `NavigationSplitView` — sidebar (All / Unsorted /
   projects, with add/rename/notes), detail (items in the selected project). Per-item menu:
   Open, Export ▸ (Downloads / Choose folder… / Rename…), Move to ▸, Rename, Delete permanently,
   plus the existing Summarize / Ask / Rename speakers.
4. **MCP:** point `TranscriptIndex` at the library; expose `project` in tool output; a
   `move`/`list_projects` tool can come later.

## Notes / risks

- The active-transcription **queue** (jobs) stays for progress/failures; on success a job becomes
  a library item. Jobs and items are different lifecycles.
- Migration must be idempotent (a marker file so it runs once) and must never move/delete originals.
- MCP reads the library after step 2, so steps 2 and 4 should land together to avoid a stale view.
