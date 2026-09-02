import AVFoundation
import Foundation

/// Pure-Swift replacements for the two ffmpeg operations (`extract`, `silences`) that never
/// actually needed ffmpeg — both only ever run on audio the app already decoded (a WAV) or
/// recorded itself (`.mic.m4a`/`.system.m4a`), both formats `AVAudioFile` reads natively.
/// Keeping these off ffmpeg means multilingual re-chunking and dual-track speaker attribution
/// keep working even when no ffmpeg is configured at all.
enum PCMAnalysis {
    /// Extracts a time slice of an audio file (with a little padding), for chunked
    /// transcription. Exact — a frame-position slice, no filter — unlike ffmpeg's `-c copy`,
    /// which this replaces.
    static func extract(
        from url: URL,
        start: Double,
        end: Double,
        padding: Double = 0.12
    ) async throws -> URL {
        let source = try AVAudioFile(forReading: url)
        let sampleRate = source.processingFormat.sampleRate
        let from = max(0, start - padding)
        let to = end + padding
        let startFrame = AVAudioFramePosition(from * sampleRate)
        let endFrame = min(AVAudioFramePosition(to * sampleRate), source.length)
        let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-chunk-\(UUID().uuidString).wav")
        let destination = try AVAudioFile(forWriting: output, settings: source.fileFormat.settings)

        guard frameCount > 0 else { return output }
        source.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frameCount) else {
            return output
        }
        try source.read(into: buffer, frameCount: frameCount)
        try destination.write(from: buffer)
        return output
    }

    /// Finds silences (for splitting speech into language-consistent chunks, and for judging
    /// whether a recorded track carries real speech). Mirrors ffmpeg's
    /// `silencedetect=noise=-35dB:d=0.35` as a short-time RMS/dBFS sliding window — the defaults
    /// match that filter's, tuned against it on real recordings before this replaced it
    /// everywhere (see the plan's comparison-harness step).
    static func silences(
        in url: URL,
        noiseFloorDB: Double = -35,
        minDuration: Double = 0.35,
        windowSeconds: Double = 0.05
    ) async -> [(start: Double, end: Double)] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let sampleRate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        guard sampleRate > 0, channels > 0, file.length > 0 else { return [] }
        let windowFrames = AVAudioFrameCount(max(1, windowSeconds * sampleRate))
        // dBFS -> linear amplitude threshold (full scale = 1.0).
        let threshold = Float(pow(10, noiseFloorDB / 20))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: windowFrames) else {
            return []
        }

        var silences: [(start: Double, end: Double)] = []
        var silenceStart: Double?
        var framePosition: AVAudioFramePosition = 0

        while framePosition < file.length {
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: windowFrames)) != nil, buffer.frameLength > 0 else { break }

            let time = Double(framePosition) / sampleRate
            if rms(of: buffer, channels: channels) < threshold {
                if silenceStart == nil { silenceStart = time }
            } else if let start = silenceStart {
                if time - start >= minDuration { silences.append((start, time)) }
                silenceStart = nil
            }
            framePosition += AVAudioFramePosition(buffer.frameLength)
        }
        if let start = silenceStart {
            let end = Double(framePosition) / sampleRate
            if end - start >= minDuration { silences.append((start, end)) }
        }
        return silences
    }

    private static func rms(of buffer: AVAudioPCMBuffer, channels: Int) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var sumSquares: Float = 0
        let frameLength = Int(buffer.frameLength)
        for channel in 0..<channels {
            let samples = data[channel]
            for i in 0..<frameLength {
                sumSquares += samples[i] * samples[i]
            }
        }
        let count = frameLength * channels
        guard count > 0 else { return 0 }
        return sqrt(sumSquares / Float(count))
    }
}
