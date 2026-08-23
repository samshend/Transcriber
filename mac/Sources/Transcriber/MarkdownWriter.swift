import Foundation

enum MarkdownWriter {
    /// Writes a speaker-attributed transcript:
    ///
    /// **Speaker 1**
    /// 02:36
    /// Text of what was said…
    static func writeDiarized(
        blocks: [TranscriptBlock],
        source: URL,
        duration: Double?,
        modelID: String,
        language: String,
        directory: URL,
        extraFrontmatter extra: String = ""
    ) throws -> URL {
        let speakers = orderedSpeakers(in: blocks)
        var extraFrontmatter = "speakers: [" + speakers.map { "\"\($0)\"" }.joined(separator: ", ") + "]\n"
        extraFrontmatter += "diarized: true\n"
        extraFrontmatter += extra
        return try write(
            text: diarizedBody(blocks: blocks),
            source: source,
            duration: duration,
            modelID: modelID,
            language: language,
            directory: directory,
            extraFrontmatter: extraFrontmatter
        )
    }

    static func diarizedBody(blocks: [TranscriptBlock]) -> String {
        blocks.map { block in
            "**\(block.speaker)**\n\(timeLabel(block.start))\n\(block.text)"
        }
        .joined(separator: "\n\n")
    }

    /// Zero-padded block timestamp: "02:36", or "1:02:36" past an hour.
    static func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func orderedSpeakers(in blocks: [TranscriptBlock]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for block in blocks where !seen.contains(block.speaker) {
            seen.insert(block.speaker)
            ordered.append(block.speaker)
        }
        return ordered
    }

    static func write(
        text: String,
        source: URL,
        duration: Double?,
        modelID: String,
        language: String,
        directory: URL,
        extraFrontmatter: String = ""
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = source.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(counter).md")
            counter += 1
        }

        var frontmatter = "---\n"
        frontmatter += "source: \"\(source.lastPathComponent)\"\n"
        frontmatter += "source_path: \"\(source.path)\"\n"
        frontmatter += "type: \(MediaTypes.videoExtensions.contains(source.pathExtension.lowercased()) ? "video" : "audio")\n"
        if let duration {
            frontmatter += "duration: \"\(formatDuration(duration))\"\n"
        }
        frontmatter += "transcribed: \(ISO8601DateFormatter().string(from: Date()))\n"
        frontmatter += "model: whisper-\(modelID)\n"
        frontmatter += "language: \(language)\n"
        frontmatter += extraFrontmatter
        frontmatter += "---\n\n"

        let content = frontmatter + "# \(base)\n\n" + text + "\n"
        try content.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    static let summaryStart = "<!-- SUMMARY:START -->"
    static let summaryEnd = "<!-- SUMMARY:END -->"

    /// Inserts (or replaces) an AI summary block just below the `# Title` heading.
    static func insertSummary(_ summary: String, into fileURL: URL) throws {
        var content = try String(contentsOf: fileURL, encoding: .utf8)
        content = removingSummary(from: content)

        let block = "\n\(summaryStart)\n\(summary)\n\(summaryEnd)\n"
        if let headingRange = content.range(of: #"(?m)^#\s.*$"#, options: .regularExpression) {
            let insertionPoint = content.index(after: headingRange.upperBound)
            if insertionPoint <= content.endIndex {
                content.insert(contentsOf: block, at: content.index(headingRange.upperBound, offsetBy: 1, limitedBy: content.endIndex) ?? headingRange.upperBound)
            }
        } else {
            content = block + "\n" + content
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func removingSummary(from content: String) -> String {
        guard let start = content.range(of: summaryStart),
              let end = content.range(of: summaryEnd) else { return content }
        var result = content
        // Remove the block plus any surrounding blank lines it introduced.
        let lower = start.lowerBound
        let upper = end.upperBound
        if lower < upper {
            result.removeSubrange(lower..<upper)
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    /// Reads the `language:` codes from the YAML frontmatter (e.g. "ru, en" -> ["ru","en"]).
    static func declaredLanguages(from content: String) -> [String] {
        guard let range = content.range(of: #"(?m)^language:\s*(.+)$"#, options: .regularExpression) else {
            return []
        }
        let line = String(content[range])
        guard let colon = line.firstIndex(of: ":") else { return [] }
        return line[line.index(after: colon)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "auto" }
    }

    /// Returns the transcript text with the YAML frontmatter and any existing summary
    /// stripped — the input for summarization.
    static func transcriptBody(from content: String) -> String {
        contentWithoutFrontmatter(removingSummary(from: content))
    }

    /// Drops the leading `--- … ---` block, keeping everything else (summary included).
    /// This is what gets handed to an external assistant: metadata is noise there, but the
    /// summary, speaker labels and timestamps are not.
    static func contentWithoutFrontmatter(_ content: String) -> String {
        var text = content
        if text.hasPrefix("---") {
            let searchStart = text.index(text.startIndex, offsetBy: 3)
            if let end = text.range(of: "\n---", range: searchStart..<text.endIndex) {
                text = String(text[end.upperBound...])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
