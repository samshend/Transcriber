import Foundation

struct TranscriptBlock {
    let speaker: String
    let start: Double
    var end: Double
    var text: String
}

/// Combines whisper segments (what was said, when) with diarization segments
/// (who spoke, when) into speaker-attributed transcript blocks.
enum TranscriptMerger {
    /// Pause long enough to count as a break in the same speaker's turn. Whisper segments a
    /// continuous turn every 10–30 s, and the old 1.5 s limit meant an ordinary breath started
    /// a new block: one real 2-minute turn came out as 13 repeated `**Speaker 1**` headers.
    static let maxGap: Double = 3.0

    /// Cap on a single block, so timestamps still appear often enough to quote from and a
    /// monologue does not become one unreadable wall of text.
    static let maxBlockDuration: Double = 120

    static func merge(whisper: [WhisperSegment], speakers: [SpeakerSegment]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for segment in whisper {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = attribute(segment, speakers: speakers, fallback: blocks.last?.speaker)

            // Coalesce consecutive segments of the same speaker into one readable paragraph.
            if var last = blocks.last,
               last.speaker == speaker,
               segment.start - last.end < maxGap,
               segment.end - last.start < maxBlockDuration || !endsSentence(last.text) {
                last.text += " " + text
                last.end = segment.end
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(TranscriptBlock(speaker: speaker, start: segment.start, end: segment.end, text: text))
            }
        }
        return blocks
    }

    /// Once a block is over the duration cap it keeps absorbing segments until the text
    /// reaches a sentence end, so blocks never split mid-sentence.
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return true }
        return ".!?…:;".contains(last)
    }

    private static func attribute(
        _ segment: WhisperSegment,
        speakers: [SpeakerSegment],
        fallback: String?
    ) -> String {
        var overlaps: [String: Double] = [:]
        for candidate in speakers {
            let overlap = min(segment.end, candidate.end) - max(segment.start, candidate.start)
            if overlap > 0 {
                overlaps[candidate.speaker, default: 0] += overlap
            }
        }
        if let best = overlaps.max(by: { $0.value < $1.value }) {
            return best.key
        }
        // No overlap (e.g. whisper hallucinated timing) — use the nearest speaker segment.
        let midpoint = (segment.start + segment.end) / 2
        let nearest = speakers.min {
            distance(from: midpoint, to: $0) < distance(from: midpoint, to: $1)
        }
        return nearest?.speaker ?? fallback ?? "Speaker 1"
    }

    private static func distance(from point: Double, to segment: SpeakerSegment) -> Double {
        if point < segment.start { return segment.start - point }
        if point > segment.end { return point - segment.end }
        return 0
    }
}
