import Foundation

/// Filesystem locations shared by the app and the MCP server (which runs as a
/// separate, short-lived process out of the same binary).
enum AppPaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber", isDirectory: true)
    }

    static func recordingsFolder(defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: "recordingsFolderPath"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Transcriber Recordings", isDirectory: true)
    }

    /// The "everything into one folder" transcript destination, when configured.
    static func outputFolder(defaults: UserDefaults = .standard) -> URL? {
        guard defaults.string(forKey: "outputMode") == "folder",
              let path = defaults.string(forKey: "outputFolderPath"), !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// A transcript `.md` file on disk plus the metadata parsed out of its YAML frontmatter.
struct TranscriptEntry {
    let url: URL
    var sourceName: String?
    var sourcePath: String?
    var mediaKind: String?
    var duration: String?
    var transcribed: Date?
    var model: String?
    var languages: [String] = []
    var speakers: [String] = []
    var summary: String?
    /// Transcript text with the frontmatter and the summary block removed.
    var body: String = ""
    var modified: Date?

    var title: String { url.deletingPathExtension().lastPathComponent }
    var hasSummary: Bool { summary != nil }
    var sortDate: Date { transcribed ?? modified ?? .distantPast }
}

/// One speaker turn (or plain paragraph) inside a transcript.
struct TranscriptBlockRef {
    var speaker: String?
    var time: String?
    var text: String
}

/// A search hit, with enough context to quote it.
struct TranscriptMatch {
    let entry: TranscriptEntry
    let speaker: String?
    let time: String?
    let snippet: String
}

/// Finds and reads the transcripts this app produced.
///
/// Deliberately independent of `AppState`: the MCP server needs the same data from a
/// process that never builds any UI.
enum TranscriptIndex {
    /// Set by `--selftest-mcp` so a test run only ever sees its own fixtures.
    static var historyURLOverride: URL?

    /// The managed library folder. Overridable so a test run can point at an empty dir instead
    /// of the real user's library.
    static var libraryRootOverride: URL?
    static var libraryRoot: URL {
        libraryRootOverride ?? AppPaths.support.appendingPathComponent("Library", isDirectory: true)
    }

    /// Transcript `.md` files stored in the managed library (the source of truth for finished
    /// transcripts). The MCP server runs in its own process, so it reads `library.json` directly.
    static func libraryTranscripts() -> [URL] {
        let indexURL = libraryRoot.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? { () -> LibraryIndex in
                  let decoder = JSONDecoder()
                  decoder.dateDecodingStrategy = .iso8601
                  return try decoder.decode(LibraryIndex.self, from: data)
              }() else { return [] }
        return index.items.map {
            libraryRoot
                .appendingPathComponent($0.id.uuidString, isDirectory: true)
                .appendingPathComponent($0.transcriptFile)
        }
    }

    // MARK: - Discovery

    /// Folders scanned in addition to the paths recorded in history.json.
    static func searchFolders(defaults: UserDefaults = .standard) -> [URL] {
        var folders = [AppPaths.recordingsFolder(defaults: defaults)]
        if let output = AppPaths.outputFolder(defaults: defaults) {
            folders.append(output)
        }
        return folders
    }

    static func candidateFiles(defaults: UserDefaults = .standard) -> [URL] {
        var seen: Set<String> = []
        var files: [URL] = []

        func add(_ url: URL) {
            guard url.pathExtension.lowercased() == "md" else { return }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard !seen.contains(path),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            seen.insert(path)
            files.append(url)
        }

        // Everything the app has ever produced, wherever it was saved.
        for job in HistoryStore.loadPersisted(from: historyURLOverride ?? HistoryStore.url)
        where job.state == "done" {
            if let output = job.outputPath {
                add(URL(fileURLWithPath: output))
            }
        }

        // The managed library — where finished transcripts now live.
        for url in libraryTranscripts() { add(url) }

        // Plus anything sitting in the known folders (moved, renamed, hand-written).
        for folder in searchFolders(defaults: defaults) {
            let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let entry = enumerator?.nextObject() as? URL {
                add(entry)
            }
        }
        return files
    }

    /// All transcripts, newest first.
    static func all(defaults: UserDefaults = .standard) -> [TranscriptEntry] {
        candidateFiles(defaults: defaults)
            .compactMap { load($0) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    /// Resolves a user-supplied `path` or `title`. Returns every candidate so callers can
    /// report ambiguity instead of silently picking one.
    static func resolve(
        path: String?,
        title: String?,
        defaults: UserDefaults = .standard
    ) -> [TranscriptEntry] {
        if let path, !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let entry = load(url) { return [entry] }
            return []
        }
        guard let title, !title.isEmpty else { return [] }
        let needle = fold(title)
        let entries = all(defaults: defaults)
        if let exact = entries.first(where: { fold($0.title) == needle }) { return [exact] }
        return entries.filter { fold($0.title).contains(needle) }
    }

    // MARK: - Parsing

    static func load(_ url: URL) -> TranscriptEntry? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var entry = TranscriptEntry(url: url)
        entry.modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date

        let fields = frontmatter(content)
        entry.sourceName = fields["source"]
        entry.sourcePath = fields["source_path"]
        entry.mediaKind = fields["type"]
        entry.duration = fields["duration"]
        entry.model = fields["model"]
        if let transcribed = fields["transcribed"] {
            entry.transcribed = ISO8601DateFormatter().date(from: transcribed)
        }
        entry.languages = (fields["language"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "auto" }
        // Renaming two speakers to the same person leaves duplicates in the frontmatter.
        var seenSpeakers: Set<String> = []
        entry.speakers = parseList(fields["speakers"]).filter { seenSpeakers.insert($0).inserted }
        entry.summary = summary(in: content)
        entry.body = MarkdownWriter.transcriptBody(from: content)
        return entry
    }

    /// Parses the leading `--- … ---` YAML block into flat key/value pairs.
    /// Only the shapes this app writes are supported (scalars and one-line arrays).
    static func frontmatter(_ content: String) -> [String: String] {
        guard content.hasPrefix("---") else { return [:] }
        var fields: [String: String] = [:]
        let lines = content.components(separatedBy: "\n")
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count > 1 {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            fields[key] = value
        }
        return fields
    }

    /// `["Speaker 1", "Speaker 2"]` → `["Speaker 1", "Speaker 2"]`.
    static func parseList(_ raw: String?) -> [String] {
        guard var value = raw else { return [] }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
    }

    static func summary(in content: String) -> String? {
        guard let start = content.range(of: MarkdownWriter.summaryStart),
              let end = content.range(of: MarkdownWriter.summaryEnd),
              start.upperBound < end.lowerBound
        else { return nil }
        let text = String(content[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Splits a transcript body into speaker turns. Diarized blocks look like
    /// `**Speaker 1**` / `02:36` / text; anything else comes back as plain text.
    static func blocks(in body: String) -> [TranscriptBlockRef] {
        body.components(separatedBy: "\n\n").compactMap { chunk in
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("# ") else { return nil }
            let lines = trimmed.components(separatedBy: "\n")
            if lines.count >= 3,
               lines[0].hasPrefix("**"), lines[0].hasSuffix("**"), lines[0].count > 4,
               lines[1].range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
                return TranscriptBlockRef(
                    speaker: String(lines[0].dropFirst(2).dropLast(2)),
                    time: lines[1],
                    text: lines.dropFirst(2).joined(separator: "\n")
                )
            }
            return TranscriptBlockRef(speaker: nil, time: nil, text: trimmed)
        }
    }

    // MARK: - Search

    /// Case- and diacritic-insensitive substring search across transcript bodies.
    static func search(
        query: String,
        limit: Int = 20,
        matchesPerTranscript: Int = 3,
        entries: [TranscriptEntry]? = nil,
        defaults: UserDefaults = .standard
    ) -> [TranscriptMatch] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        var results: [TranscriptMatch] = []

        for entry in entries ?? all(defaults: defaults) {
            guard fold(entry.body).contains(needle) else { continue }
            var found = 0
            for block in blocks(in: entry.body) {
                guard let range = fold(block.text).range(of: needle) else { continue }
                results.append(TranscriptMatch(
                    entry: entry,
                    speaker: block.speaker,
                    time: block.time,
                    snippet: snippet(block.text, around: range, in: fold(block.text))
                ))
                found += 1
                if found >= matchesPerTranscript || results.count >= limit { break }
            }
            if results.count >= limit { break }
        }
        return results
    }

    /// A window of ~360 characters centred on the hit. The folded string has the same
    /// length as the original for the scripts we handle, so offsets carry over.
    private static func snippet(_ text: String, around range: Range<String.Index>, in folded: String) -> String {
        let window = 180
        let hit = folded.distance(from: folded.startIndex, to: range.lowerBound)
        guard hit <= text.count else { return String(text.prefix(window * 2)) }
        let start = max(0, hit - window)
        let end = min(text.count, hit + window)
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        var result = String(text[lower..<upper])
        if start > 0 { result = "…" + result }
        if end < text.count { result += "…" }
        return result
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
