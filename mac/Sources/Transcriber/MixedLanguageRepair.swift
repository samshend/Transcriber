import Foundation

/// Repairs mixed-language transcripts where whisper picked one language for a chunk and
/// *transliterated* the other — e.g. Russian speech with German words comes out as
/// "натюрлих" (for *natürlich*) or "Струдель и Брецель". Chunking splits only at silences,
/// so a pause-less code-switch inside one sentence can't be separated at transcription time.
///
/// The repair is **audio-grounded**: an LLM never writes replacement text, it only *locates*
/// the transliterated words. We then re-transcribe exactly that audio span forcing the named
/// language, and splice the native spelling back in. Nothing is invented — every repaired
/// word comes from whisper re-reading the original audio.
///
/// The pipeline is expensive (per-block re-transcription + an LLM pass), so it runs only on
/// demand behind a button, not on every transcript.
enum MixedLanguageRepair {
    /// A contiguous run of words the LLM flagged as transliterated foreign speech, plus the
    /// language it should have been transcribed as. Indices are into the block's word list.
    struct Span: Equatable {
        let from: Int
        let to: Int
        let language: String
    }

    struct Result {
        let blocks: [TranscriptBlock]
        /// How many spans were actually re-transcribed and spliced — 0 means the transcript
        /// was already clean (or nothing could be located), so nothing is rewritten.
        let repairedSpanCount: Int
    }

    /// Runs the repair over `blocks`. Every step that touches a model or the disk is injected,
    /// so the splice/merge logic below is unit-testable without whisper, the LLM, or ffmpeg.
    ///
    /// - `findCandidates`: a cheap first pass — given all blocks, return the indices likely to
    ///   contain transliteration. Monolingual blocks are skipped so we never re-transcribe them.
    /// - `wordsForBlock`: re-transcribe one block's audio and return its words with timestamps
    ///   in **absolute** seconds (the block's own offset already added).
    /// - `locateSpans`: given a block's numbered words, return the transliterated spans.
    /// - `retranscribeSpan`: re-transcribe the audio in `[start, end]` forcing `language`,
    ///   returning the native-spelling text.
    static func repair(
        blocks: [TranscriptBlock],
        findCandidates: ([TranscriptBlock]) async throws -> [Int],
        wordsForBlock: (Int) async throws -> [WhisperServer.Word],
        locateSpans: ([WhisperServer.Word]) async throws -> [Span],
        retranscribeSpan: (_ start: Double, _ end: Double, _ language: String) async throws -> String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> Result {
        let candidates = try await findCandidates(blocks).filter { blocks.indices.contains($0) }
        guard !candidates.isEmpty else {
            onProgress?(1.0)
            return Result(blocks: blocks, repairedSpanCount: 0)
        }

        var repaired = blocks
        var repairedCount = 0
        for (step, index) in candidates.enumerated() {
            let words = try await wordsForBlock(index)
            guard !words.isEmpty else {
                onProgress?(Double(step + 1) / Double(candidates.count))
                continue
            }
            let spans = validSpans(locateSpans: try await locateSpans(words), wordCount: words.count)
            if !spans.isEmpty {
                var replacements: [String] = []
                for span in spans {
                    let native = try await retranscribeSpan(words[span.from].start, words[span.to].end, span.language)
                    replacements.append(native)
                }
                repaired[index].text = rebuild(words: words, spans: spans, replacements: replacements)
                repairedCount += spans.count
            }
            onProgress?(Double(step + 1) / Double(candidates.count))
        }
        return Result(blocks: repaired, repairedSpanCount: repairedCount)
    }

    /// Drops spans an LLM might return that are out of range, inverted, or overlapping a
    /// previously-kept span. Kept spans are non-overlapping and ordered, so `rebuild` can walk
    /// the word list once.
    static func validSpans(locateSpans spans: [Span], wordCount: Int) -> [Span] {
        var kept: [Span] = []
        var lastEnd = -1
        for span in spans.sorted(by: { $0.from < $1.from }) {
            guard span.from >= 0, span.to < wordCount, span.from <= span.to,
                  !span.language.trimmingCharacters(in: .whitespaces).isEmpty,
                  span.from > lastEnd else { continue }
            kept.append(span)
            lastEnd = span.to
        }
        return kept
    }

    /// Rebuilds a block's text from its word list, replacing each flagged span with its
    /// re-transcribed native text. Untouched words keep whisper's own spacing (word tokens
    /// carry a leading space), so punctuation and layout survive around the repair.
    ///
    /// `spans` must be valid (see `validSpans`): non-overlapping, in range, ordered by `from`.
    static func rebuild(words: [WhisperServer.Word], spans: [Span], replacements: [String]) -> String {
        var replacementByStart: [Int: (to: Int, text: String)] = [:]
        for (span, text) in zip(spans, replacements) {
            replacementByStart[span.from] = (span.to, text)
        }
        var out = ""
        var i = 0
        while i < words.count {
            if let repair = replacementByStart[i] {
                // Whisper returns one line per segment, so a multi-segment span arrives with
                // embedded newlines. Fold all internal whitespace to single spaces so the splice
                // reads as one clause instead of injecting line breaks mid-block.
                let native = repair.text
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                if !out.isEmpty, !out.hasSuffix(" ") { out += " " }
                out += native
                i = repair.to + 1
            } else {
                out += words[i].text
                i += 1
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rewrites a transcript file in place with a repaired block body, preserving the YAML
    /// frontmatter, the `# Title` heading, and any summary block. Only the speaker-turn region
    /// (from the first `**Speaker**` header to end of file) is replaced, and a
    /// `mixed_language_repair: applied` marker is stamped into the frontmatter.
    static func rewriteBody(_ newBody: String, in fileURL: URL) throws {
        var content = try String(contentsOf: fileURL, encoding: .utf8)
        content = withRepairMarker(content)

        // Only look for the first block header *past* the frontmatter and any summary, so a
        // **bold** span inside the summary can't be mistaken for a speaker header.
        var searchStart = content.startIndex
        if let end = content.range(of: MarkdownWriter.summaryEnd) {
            searchStart = end.upperBound
        } else if content.hasPrefix("---"),
                  let fmEnd = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) {
            searchStart = fmEnd.upperBound
        }
        if let header = content.range(of: #"(?m)^\*\*.+\*\*$"#, options: .regularExpression, range: searchStart..<content.endIndex) {
            content.replaceSubrange(header.lowerBound..<content.endIndex, with: newBody + "\n")
        } else {
            content = content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + newBody + "\n"
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Inserts (or refreshes) the `mixed_language_repair: applied` line inside the frontmatter.
    static func withRepairMarker(_ content: String) -> String {
        let line = "mixed_language_repair: applied"
        if let existing = content.range(of: #"(?m)^mixed_language_repair:.*$"#, options: .regularExpression) {
            var c = content
            c.replaceSubrange(existing, with: line)
            return c
        }
        guard content.hasPrefix("---"),
              let fmEnd = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) else {
            return content
        }
        var c = content
        c.insert(contentsOf: "\n" + line, at: fmEnd.lowerBound)
        return c
    }

    /// Parses a transcript block timestamp ("02:36" or "1:02:36") to seconds. Nil if malformed.
    static func seconds(fromLabel label: String) -> Double? {
        let parts = label.split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let nums = parts.compactMap { $0 }
        switch nums.count {
        case 2: return Double(nums[0] * 60 + nums[1])
        case 3: return Double(nums[0] * 3600 + nums[1] * 60 + nums[2])
        default: return nil
        }
    }
}
