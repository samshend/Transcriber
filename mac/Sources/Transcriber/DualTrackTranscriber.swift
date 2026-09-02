import Foundation

/// Transcribes a call that was recorded with isolated per-speaker tracks — `mic` (the person
/// running the app) and `system` (the far side) — and merges them onto one timeline.
///
/// Because each track physically contains a single voice, attribution is *deterministic*: no
/// clustering, no speaker-flip errors, and simultaneous speech is fully recovered (each side
/// keeps its own words instead of one being discarded on the mix). This replaces the
/// mixed-file + `Diarizer` path for app-recorded two-party calls; imported/mixed files with no
/// sibling tracks still take the diarization path.
enum DualTrackTranscriber {
    struct Output {
        let blocks: [TranscriptBlock]
        let languages: [String]
    }

    /// `transcribeTrack(wav, speaker, onProgress)` transcribes one isolated track and returns
    /// its blocks (all attributed to `speaker`) plus the languages it detected. The two tracks
    /// are transcribed sequentially — they share one whisper-server / the CPU — then merged.
    /// Each track drives the first/second half of the overall progress bar.
    static func transcribe(
        micWav: URL,
        systemWav: URL,
        micSpeaker: String = "Speaker 1",
        systemSpeaker: String = "Speaker 2",
        onProgress: ((Double) -> Void)? = nil,
        transcribeTrack: (_ wav: URL, _ speaker: String, _ onProgress: @escaping (Double) -> Void) async throws -> (blocks: [TranscriptBlock], languages: [String])
    ) async throws -> Output {
        let mic = try await transcribeTrack(micWav, micSpeaker) { onProgress?($0 * 0.5) }
        let system = try await transcribeTrack(systemWav, systemSpeaker) { onProgress?(0.5 + $0 * 0.5) }
        onProgress?(1.0)
        let merged = mergeByTimeline(mic.blocks, system.blocks)
        let languages = mergeLanguages(
            mic: mic.blocks, micLangs: mic.languages,
            system: system.blocks, systemLangs: system.languages
        )
        return Output(blocks: merged, languages: languages)
    }

    /// Interleaves two single-speaker block lists onto one timeline. Both tracks were recorded
    /// concurrently off the same clock, so `start` is directly comparable. Overlaps (both
    /// sides talking at once) stay as two separate blocks — nothing is dropped.
    static func mergeByTimeline(_ a: [TranscriptBlock], _ b: [TranscriptBlock]) -> [TranscriptBlock] {
        (a + b).sorted { $0.start < $1.start }
    }

    /// Union of the two sides' languages. Blocks don't carry a per-block language, so we order
    /// by which side carries more text (that side's ranked list first, then the other side's
    /// remaining languages). Good enough for the frontmatter list; downstream only relies on
    /// the first entry being the dominant language to write summaries in.
    static func mergeLanguages(
        mic: [TranscriptBlock], micLangs: [String],
        system: [TranscriptBlock], systemLangs: [String]
    ) -> [String] {
        let micChars = mic.reduce(0) { $0 + $1.text.count }
        let systemChars = system.reduce(0) { $0 + $1.text.count }
        let primary = micChars >= systemChars ? micLangs : systemLangs
        let secondary = micChars >= systemChars ? systemLangs : micLangs
        var ordered: [String] = []
        for language in primary + secondary where !ordered.contains(language) {
            ordered.append(language)
        }
        return ordered
    }
}
