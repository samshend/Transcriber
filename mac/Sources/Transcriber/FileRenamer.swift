import Foundation

enum FileRenamer {
    struct RenameError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Renames a file, keeping its extension and directory. `newBaseName` is the desired
    /// name without extension; illegal path characters are stripped. Fails if the target
    /// already exists.
    @discardableResult
    static func rename(_ url: URL, toBaseName newBaseName: String) throws -> URL {
        let cleaned = sanitize(newBaseName)
        guard !cleaned.isEmpty else {
            throw RenameError(message: "Please enter a name.")
        }
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var destination = directory.appendingPathComponent(cleaned)
        if !ext.isEmpty { destination = destination.appendingPathExtension(ext) }

        if destination.path == url.path { return url }  // no-op
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RenameError(message: "A file named \"\(destination.lastPathComponent)\" already exists.")
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return trimmed.components(separatedBy: illegal).joined(separator: "-")
    }
}
