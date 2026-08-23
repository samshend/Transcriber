import Foundation
import FluidAudio

struct SpeakerSegment {
    let speaker: String
    let start: Double
    let end: Double
}

/// Wraps FluidAudio's offline diarization pipeline (pyannote-style models on CoreML).
/// Models are downloaded once on first use, then everything runs locally.
final class Diarizer {
    static let shared = Diarizer()

    /// AHC merge threshold. FluidAudio's default (0.6) merges too aggressively and can
    /// collapse a multi-speaker meeting to one speaker (compressed/band-limited call audio
    /// makes voice embeddings sit close together). Higher = stricter = more speakers.
    /// Tuned empirically against real meeting recordings: at 0.6 a 4-person meeting
    /// collapsed to 1 speaker; 0.80 recovered all 4 while still giving 1 for single-speaker
    /// voice messages and 2 for a two-person conversation (no over-splitting).
    static let defaultThreshold = 0.80

    private var manager: OfflineDiarizerManager?
    private var managerThreshold: Double?

    /// Jobs run strictly one at a time from AppState's queue, so no locking needed.
    func diarize(
        wavURL: URL,
        threshold: Double = Diarizer.defaultThreshold,
        minSpeakers: Int? = nil,
        maxSpeakers: Int? = nil
    ) async throws -> [SpeakerSegment] {
        // Rebuild the manager if the tuning changed (cheap; models stay cached on disk).
        if manager == nil || managerThreshold != threshold {
            let config = OfflineDiarizerConfig(
                clustering: OfflineDiarizerConfig.Clustering(
                    threshold: threshold,
                    warmStartFa: 0.07,
                    warmStartFb: 0.8,
                    minSpeakers: minSpeakers,
                    maxSpeakers: maxSpeakers,
                    numSpeakers: nil
                )
            )
            let fresh = OfflineDiarizerManager(config: config)
            try await fresh.prepareModels()
            manager = fresh
            managerThreshold = threshold
        }
        guard let manager else { throw DiarizerUnavailable() }

        let samples = try AudioConverter().resampleAudioFile(wavURL)
        let result = try await manager.process(audio: samples)

        let ordered = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let raw = ordered.map {
            RawSegment(
                speakerKey: String(describing: $0.speakerId),
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds)
            )
        }
        let cleaned = Self.mergePhantomSpeakers(raw)

        var displayNames: [String: String] = [:]
        var segments: [SpeakerSegment] = []
        for segment in cleaned {
            if displayNames[segment.speakerKey] == nil {
                displayNames[segment.speakerKey] = "Speaker \(displayNames.count + 1)"
            }
            segments.append(SpeakerSegment(
                speaker: displayNames[segment.speakerKey]!,
                start: segment.start,
                end: segment.end
            ))
        }
        return segments
    }

    struct RawSegment {
        var speakerKey: String
        var start: Double
        var end: Double
        var duration: Double { end - start }
    }

    /// Clustering sometimes invents a speaker out of a handful of stray segments (a real
    /// 2-person session came out as 3 speakers, the phantom holding 0.5% of speech / 9s).
    /// Speakers with a negligible share are folded into whichever real speaker is adjacent
    /// in time. Thresholds leave a wide margin over genuinely quiet participants
    /// (measured: the quietest real speaker in a 4-person meeting had 7.4% / 140s).
    static func mergePhantomSpeakers(
        _ segments: [RawSegment],
        maxShare: Double = 0.03,
        maxDuration: Double = 45
    ) -> [RawSegment] {
        guard segments.count > 1 else { return segments }

        var durations: [String: Double] = [:]
        for segment in segments {
            durations[segment.speakerKey, default: 0] += segment.duration
        }
        guard durations.count > 2 else { return segments }  // nothing to fold into

        let total = durations.values.reduce(0, +)
        guard total > 0 else { return segments }

        let phantoms = Set(durations.filter { _, duration in
            duration / total < maxShare && duration < maxDuration
        }.keys)
        // Never collapse below two speakers.
        guard !phantoms.isEmpty, durations.count - phantoms.count >= 2 else { return segments }

        var result = segments
        for index in result.indices where phantoms.contains(result[index].speakerKey) {
            var previous: (key: String, gap: Double)?
            var next: (key: String, gap: Double)?
            var backward = index - 1
            while backward >= 0 {
                if !phantoms.contains(result[backward].speakerKey) {
                    previous = (result[backward].speakerKey, result[index].start - result[backward].end)
                    break
                }
                backward -= 1
            }
            var forward = index + 1
            while forward < result.count {
                if !phantoms.contains(result[forward].speakerKey) {
                    next = (result[forward].speakerKey, result[forward].start - result[index].end)
                    break
                }
                forward += 1
            }
            switch (previous, next) {
            case let (p?, n?):
                result[index].speakerKey = p.gap <= n.gap ? p.key : n.key
            case let (p?, nil):
                result[index].speakerKey = p.key
            case let (nil, n?):
                result[index].speakerKey = n.key
            case (nil, nil):
                break
            }
        }
        return result
    }
}

struct DiarizerUnavailable: LocalizedError {
    var errorDescription: String? { "Speaker detection models are not available." }
}
