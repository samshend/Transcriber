import Foundation

/// Minimal MCP (Model Context Protocol) server over stdio, so Claude Code / Claude Desktop /
/// Codex can read the transcripts this app produced, search them, and queue new files.
///
/// Started as:  Transcriber --mcp
///
/// Transport is newline-delimited JSON-RPC 2.0. stdout carries *only* protocol frames —
/// everything human-readable goes to stderr.
enum MCPServer {
    static let serverName = "transcriber"
    static let serverVersion = "0.1.0"
    static let preferredProtocol = "2025-06-18"
    static let supportedProtocols = ["2024-11-05", "2025-03-26", "2025-06-18"]

    /// Injection point for `--selftest-mcp`, which points the index at a fixture folder.
    static var defaults: UserDefaults = .standard

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--mcp") else { return }
        run()
    }

    static func run() -> Never {
        log("transcriber MCP server ready on stdio")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                log("ignoring unparseable message")
                continue
            }
            if let reply = response(for: message) {
                send(reply)
            }
        }
        exit(0)
    }

    // MARK: - Dispatch

    /// Pure function from request to response — `nil` for notifications.
    /// Kept separate from the I/O loop so `--selftest-mcp` can drive it directly.
    static func response(for message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        let id = message["id"]
        let wantsReply = id != nil && !(id is NSNull)

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = supportedProtocols.contains(requested ?? "") ? requested! : preferredProtocol
            return result(id, [
                "protocolVersion": version,
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["listChanged": false, "subscribe": false],
                ],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": """
                Transcriber stores meeting and voice-message transcripts as Markdown with speaker \
                labels and MM:SS timestamps. Use search_transcripts to find something across all \
                of them, get_transcript to read one, and transcribe_file to hand a new audio or \
                video file to the app. Quote timestamps when you answer questions about a meeting.
                """,
            ])

        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
            return nil

        case "ping":
            return result(id, [:])

        case "tools/list":
            return result(id, ["tools": toolDefinitions])

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return result(id, call(tool: name, arguments: arguments))

        case "resources/list":
            let resources = TranscriptIndex.all(defaults: defaults).prefix(200).map { entry -> [String: Any] in
                var descriptionParts: [String] = []
                if let duration = entry.duration { descriptionParts.append(duration) }
                if !entry.speakers.isEmpty { descriptionParts.append("\(entry.speakers.count) speakers") }
                if !entry.languages.isEmpty { descriptionParts.append(entry.languages.joined(separator: "/")) }
                return [
                    "uri": entry.url.absoluteString,
                    "name": entry.title,
                    "mimeType": "text/markdown",
                    "description": descriptionParts.joined(separator: " · "),
                ]
            }
            return result(id, ["resources": Array(resources)])

        case "resources/read":
            guard let uri = params["uri"] as? String,
                  let url = URL(string: uri),
                  url.isFileURL,
                  let content = try? String(contentsOf: url, encoding: .utf8)
            else {
                return error(id, -32602, "Cannot read resource: \(params["uri"] as? String ?? "<missing uri>")")
            }
            return result(id, ["contents": [[
                "uri": uri,
                "mimeType": "text/markdown",
                "text": content,
            ]]])

        default:
            guard wantsReply else { return nil }
            return error(id, -32601, "Unknown method: \(method)")
        }
    }

    // MARK: - Tools

    static var toolDefinitions: [[String: Any]] {
        [
            tool(
                "list_transcripts",
                "List transcripts produced by Transcriber, newest first, with their metadata.",
                [
                    "limit": ["type": "integer", "description": "How many to return (default 20, max 200)."],
                    "query": ["type": "string", "description": "Optional filter — matched against the title and the transcript text."],
                    "since": ["type": "string", "description": "Only transcripts from this date onwards (YYYY-MM-DD)."],
                ]
            ),
            tool(
                "search_transcripts",
                "Search the text of all transcripts. Returns matching speaker turns with their timestamps.",
                [
                    "query": ["type": "string", "description": "Text to look for (case- and accent-insensitive)."],
                    "limit": ["type": "integer", "description": "Maximum number of matches (default 20)."],
                    "matches_per_transcript": ["type": "integer", "description": "Cap per transcript (default 3)."],
                ],
                required: ["query"]
            ),
            tool(
                "get_transcript",
                "Read one transcript in full. Identify it by path or by (part of) its title.",
                [
                    "path": ["type": "string", "description": "Absolute path to the .md file."],
                    "title": ["type": "string", "description": "Title or part of it, e.g. 'Recording 2026-07-24'."],
                    "include_summary": ["type": "boolean", "description": "Include the stored summary, if any (default true)."],
                    "max_characters": ["type": "integer", "description": "Truncate the transcript text (default 60000)."],
                    "offset": ["type": "integer", "description": "Character offset, for reading long transcripts in parts."],
                ]
            ),
            tool(
                "get_summary",
                "Return the on-device summary stored inside a transcript, if it has one.",
                [
                    "path": ["type": "string", "description": "Absolute path to the .md file."],
                    "title": ["type": "string", "description": "Title or part of it."],
                ]
            ),
            tool(
                "transcribe_file",
                "Hand an audio or video file to the Transcriber app to transcribe. Queues it (and "
                    + "launches the app if needed); transcription happens in the app, not here.",
                [
                    "path": ["type": "string", "description": "Absolute path to one media file."],
                    "paths": ["type": "array", "items": ["type": "string"], "description": "Several media files."],
                ]
            ),
            tool(
                "get_jobs",
                "Current transcription queue and recent history, newest first.",
                ["limit": ["type": "integer", "description": "How many jobs to return (default 20)."]]
            ),
        ]
    }

    static func call(tool name: String, arguments: [String: Any]) -> [String: Any] {
        switch name {
        case "list_transcripts": return listTranscripts(arguments)
        case "search_transcripts": return searchTranscripts(arguments)
        case "get_transcript": return getTranscript(arguments)
        case "get_summary": return getSummary(arguments)
        case "transcribe_file": return transcribeFile(arguments)
        case "get_jobs": return getJobs(arguments)
        default: return failure("Unknown tool: \(name)")
        }
    }

    private static func listTranscripts(_ arguments: [String: Any]) -> [String: Any] {
        let limit = min(max(int(arguments["limit"]) ?? 20, 1), 200)
        var entries = TranscriptIndex.all(defaults: defaults)

        if let since = date(string(arguments["since"])) {
            entries = entries.filter { $0.sortDate >= since }
        }
        if let query = string(arguments["query"]), !query.isEmpty {
            let needle = TranscriptIndex.fold(query)
            entries = entries.filter {
                TranscriptIndex.fold($0.title).contains(needle)
                    || TranscriptIndex.fold($0.body).contains(needle)
            }
        }

        let payload = entries.prefix(limit).map { describe($0, previewCharacters: 240) }
        return success(json([
            "matched": entries.count,
            "returned": payload.count,
            "transcripts": Array(payload),
        ]))
    }

    private static func searchTranscripts(_ arguments: [String: Any]) -> [String: Any] {
        guard let query = string(arguments["query"]), !query.isEmpty else {
            return failure("`query` is required.")
        }
        let limit = min(max(int(arguments["limit"]) ?? 20, 1), 100)
        let perTranscript = min(max(int(arguments["matches_per_transcript"]) ?? 3, 1), 20)
        let matches = TranscriptIndex.search(
            query: query,
            limit: limit,
            matchesPerTranscript: perTranscript,
            defaults: defaults
        )
        guard !matches.isEmpty else {
            return success("No transcript contains \"\(query)\".")
        }
        let payload = matches.map { match -> [String: Any] in
            var item: [String: Any] = [
                "transcript": match.entry.title,
                "path": match.entry.url.path,
                "text": match.snippet,
            ]
            if let speaker = match.speaker { item["speaker"] = speaker }
            if let time = match.time { item["time"] = time }
            return item
        }
        return success(json(["query": query, "matches": payload]))
    }

    private static func getTranscript(_ arguments: [String: Any]) -> [String: Any] {
        let candidates = TranscriptIndex.resolve(
            path: string(arguments["path"]),
            title: string(arguments["title"]),
            defaults: defaults
        )
        switch candidates.count {
        case 0:
            return failure(notFoundMessage(arguments))
        case 1:
            break
        default:
            let titles = candidates.prefix(20).map { "- \($0.title) → \($0.url.path)" }
            return failure("\(candidates.count) transcripts match. Pass an exact `path`:\n"
                + titles.joined(separator: "\n"))
        }

        let entry = candidates[0]
        let includeSummary = bool(arguments["include_summary"]) ?? true
        let maxCharacters = min(max(int(arguments["max_characters"]) ?? 60_000, 500), 400_000)
        let offset = max(int(arguments["offset"]) ?? 0, 0)

        var document = "# \(entry.title)\n"
        document += "Path: \(entry.url.path)\n"
        if let date = entry.transcribed ?? entry.modified {
            document += "Recorded/transcribed: \(ISO8601DateFormatter().string(from: date))\n"
        }
        if let duration = entry.duration { document += "Duration: \(duration)\n" }
        if !entry.speakers.isEmpty { document += "Speakers: \(entry.speakers.joined(separator: ", "))\n" }
        if !entry.languages.isEmpty { document += "Languages: \(entry.languages.joined(separator: ", "))\n" }
        document += "\n"

        if includeSummary, let summary = entry.summary {
            document += "## Summary stored in the file\n\n\(summary)\n\n---\n\n"
        }

        let body = entry.body
        let start = min(offset, body.count)
        let slice = String(body.dropFirst(start).prefix(maxCharacters))
        document += "## Transcript\n\n\(slice)"

        let consumed = start + slice.count
        if consumed < body.count {
            document += "\n\n[Truncated: \(consumed) of \(body.count) characters shown. "
                + "Call get_transcript again with offset=\(consumed) for the rest.]"
        }
        return success(document)
    }

    private static func getSummary(_ arguments: [String: Any]) -> [String: Any] {
        let candidates = TranscriptIndex.resolve(
            path: string(arguments["path"]),
            title: string(arguments["title"]),
            defaults: defaults
        )
        guard let entry = candidates.first else { return failure(notFoundMessage(arguments)) }
        guard let summary = entry.summary else {
            return success("\"\(entry.title)\" has no stored summary. Read it with get_transcript "
                + "and summarize it yourself, or generate one on-device from the app's job list.")
        }
        return success("Summary of \(entry.title):\n\n\(summary)")
    }

    private static func transcribeFile(_ arguments: [String: Any]) -> [String: Any] {
        var requested: [String] = []
        if let single = string(arguments["path"]) { requested.append(single) }
        if let many = arguments["paths"] as? [Any] {
            requested.append(contentsOf: many.compactMap { $0 as? String })
        }
        guard !requested.isEmpty else { return failure("Pass `path` or `paths`.") }

        var accepted: [String] = []
        var rejected: [String] = []
        for path in requested {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if !FileManager.default.fileExists(atPath: expanded) {
                rejected.append("\(path) — no such file")
            } else if !MediaTypes.all.contains(url.pathExtension.lowercased()) {
                rejected.append("\(path) — not a supported audio/video type")
            } else {
                accepted.append(expanded)
            }
        }
        guard !accepted.isEmpty else {
            return failure("Nothing to queue:\n" + rejected.joined(separator: "\n"))
        }

        do {
            try Inbox.submit(paths: accepted)
        } catch {
            return failure("Could not write the request: \(error.localizedDescription)")
        }
        launchApp()

        var message = "Queued \(accepted.count) file(s) in Transcriber:\n"
            + accepted.map { "- \($0)" }.joined(separator: "\n")
            + "\n\nThe app picks these up within a few seconds and transcribes them there "
            + "(this can take minutes for long recordings). Poll get_jobs for the state, then "
            + "get_transcript once a job is done."
        if !rejected.isEmpty {
            message += "\n\nSkipped:\n" + rejected.joined(separator: "\n")
        }
        return success(message)
    }

    private static func getJobs(_ arguments: [String: Any]) -> [String: Any] {
        let limit = min(max(int(arguments["limit"]) ?? 20, 1), 200)
        let jobs = HistoryStore.loadPersisted().reversed().prefix(limit)
        guard !jobs.isEmpty else { return success("No jobs yet.") }
        let payload = jobs.map { job -> [String: Any] in
            var item: [String: Any] = [
                "source": (job.sourcePath as NSString).lastPathComponent,
                "source_path": job.sourcePath,
                "state": job.state,
            ]
            if let output = job.outputPath { item["transcript"] = output }
            if let message = job.message { item["error"] = message }
            if let finished = job.finishedAt {
                item["finished"] = ISO8601DateFormatter().string(from: finished)
            }
            if let duration = job.duration {
                item["duration"] = MarkdownWriter.formatDuration(duration)
            }
            return item
        }
        return success(json(["jobs": Array(payload)]))
    }

    // MARK: - Helpers

    private static func describe(_ entry: TranscriptEntry, previewCharacters: Int) -> [String: Any] {
        var item: [String: Any] = [
            "title": entry.title,
            "path": entry.url.path,
            "characters": entry.body.count,
            "has_summary": entry.hasSummary,
        ]
        if let date = entry.transcribed ?? entry.modified {
            item["date"] = ISO8601DateFormatter().string(from: date)
        }
        if let duration = entry.duration { item["duration"] = duration }
        if let source = entry.sourceName { item["source"] = source }
        if !entry.languages.isEmpty { item["languages"] = entry.languages }
        if !entry.speakers.isEmpty { item["speakers"] = entry.speakers }
        if previewCharacters > 0 {
            let flat = entry.body
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
            item["preview"] = String(flat.prefix(previewCharacters))
        }
        return item
    }

    private static func notFoundMessage(_ arguments: [String: Any]) -> String {
        let asked = string(arguments["path"]) ?? string(arguments["title"]) ?? "<nothing>"
        return "No transcript matched \"\(asked)\". Call list_transcripts to see what exists."
    }

    /// Opens the app bundle in the background so it can drain the inbox.
    /// A no-op when it's already running, or when this binary isn't inside a bundle.
    private static func launchApp() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", bundle.path]
        try? process.run()
    }

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ],
        ]
    }

    static func success(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": false]
    }

    static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func result(_ id: Any?, _ payload: [String: Any]) -> [String: Any]? {
        guard let id, !(id is NSNull) else { return nil }
        return ["jsonrpc": "2.0", "id": id, "result": payload]
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any]? {
        guard let id, !(id is NSNull) else { return nil }
        return ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        ) else { return }
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("[transcriber-mcp] \(message)\n".utf8))
    }

    // Argument coercion — MCP clients are loose about types.
    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return text == "true" }
        return nil
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        if let date = formatter.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// Copy-paste configuration for the clients that can talk to `--mcp`.
enum MCPSetup {
    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    static var claudeCodeCommand: String {
        "claude mcp add --scope user transcriber -- \"\(executablePath)\" --mcp"
    }

    static var claudeDesktopConfig: String {
        """
        {
          "mcpServers": {
            "transcriber": {
              "command": "\(executablePath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    static var codexConfig: String {
        """
        [mcp_servers.transcriber]
        command = "\(executablePath)"
        args = ["--mcp"]
        """
    }

    static var claudeDesktopConfigURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
    }

    static var claudeCLI: URL? { Tools.find("claude") }

    /// Registers the server with Claude Code (user scope). Reversible with
    /// `claude mcp remove transcriber`.
    static func addToClaudeCode() async throws -> String {
        guard let claude = claudeCLI else {
            throw SetupError(message: "The `claude` CLI wasn't found. Copy the command instead.")
        }
        let result = try await runProcess(claude, [
            "mcp", "add", "--scope", "user", "transcriber", "--", executablePath, "--mcp",
        ])
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            throw SetupError(message: output.isEmpty ? "claude mcp add failed (\(result.status))" : output)
        }
        return output.isEmpty ? "Added to Claude Code." : output
    }

    struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
