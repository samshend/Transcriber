import Foundation

/// One-way request channel from short-lived helper processes (currently the MCP server)
/// into the running app.
///
/// The MCP server can't call into the app — it's a separate process — and it must not run
/// whisper itself, or a 30-minute file would block a tool call past any client's timeout.
/// So it drops a request file here and the app picks it up.
/// True when the binary was started as a CLI (`--mcp`, `--selftest…`) rather than as the app.
/// SwiftUI's `@StateObject` default value is lazy, so `AppState` normally isn't built in those
/// modes — but nothing should *depend* on that: a second process draining the inbox or writing
/// history.json would fight the real app.
enum LaunchMode {
    static var isHeadless: Bool {
        CommandLine.arguments.contains { $0 == "--mcp" || $0.hasPrefix("--selftest") }
    }
}

enum Inbox {
    /// Set by `--selftest-mcp` so a test run never queues fixtures into the real app.
    static var folderOverride: URL?

    static var folder: URL {
        folderOverride ?? AppPaths.support.appendingPathComponent("inbox", isDirectory: true)
    }

    struct Request: Codable {
        var paths: [String]
        var created: Date
        var origin: String
    }

    /// Writes a transcription request. Returns the request file for logging.
    @discardableResult
    static func submit(paths: [String], origin: String = "mcp") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = Request(paths: paths, created: Date(), origin: origin)
        let url = folder.appendingPathComponent("\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(to: url, options: .atomic)
        return url
    }

    /// Reads and deletes every pending request, returning the media files to enqueue.
    static func drain() -> [URL] {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
            defer { try? manager.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let request = try? decoder.decode(Request.self, from: data) else { continue }
            // Ignore anything stale enough to be a leftover from a crash.
            guard Date().timeIntervalSince(request.created) < 3600 else { continue }
            urls.append(contentsOf: request.paths.map { URL(fileURLWithPath: $0) })
        }
        return urls
    }
}
