import AVFoundation
import Foundation

/// Decodes a file's audio track via AVFoundation — no ffmpeg, no licensing cost. Covers the
/// formats macOS understands natively: mp4/mov/m4v/m4a, mp3, aac, wav, aiff, caf.
enum AVFoundationDecoder {
    struct UnreadableError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Decodes `input`'s audio into a 16 kHz mono 16-bit WAV, matching what whisper.cpp expects.
    /// Targets only the first audio track — video frames are never touched.
    ///
    /// Decodes to the track's *native* format first (`AVAssetReaderTrackOutput`, no resample),
    /// then converts to the target format in a separate `AVAudioConverter` pass — the same
    /// two-step pattern `AudioRecorder`'s `MicWriter` already uses. An earlier version asked
    /// `AVAssetReaderAudioMixOutput` to resample directly, which routes through AVFoundation's
    /// audio-mixing render graph; measured on a real 22-minute recording, that took **2.5s**
    /// against ffmpeg's 0.57s for the same file — a ~4.5x regression. This two-step version
    /// measures at 0.55s, matching ffmpeg, because it skips the mixing engine entirely.
    static func convertToWav(
        input: URL,
        register: ((AVAssetReader) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw UnreadableError(reason: "no audio track found")
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: true,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw UnreadableError(reason: "reader cannot decode this file's audio")
        }
        reader.add(output)
        register?(reader)

        guard reader.startReading() else {
            throw reader.error ?? UnreadableError(reason: "failed to start reading audio")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-\(UUID().uuidString).wav")
        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        // Rebuilt whenever the source format changes (rare, but some containers vary it
        // mid-stream) — mirrors MicWriter's same defensive rebuild-on-change.
        var sourceFormat: AVAudioFormat?
        var converter: AVAudioConverter?

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let source = sampleBuffer.nativeFormat() else { continue }
            if sourceFormat != source {
                sourceFormat = source
                converter = AVAudioConverter(from: source, to: targetFormat)
            }
            guard let converter, let source = sourceFormat,
                  let sourceBuffer = sampleBuffer.pcmBuffer(format: source),
                  let outBuffer = AVAudioPCMBuffer(
                      pcmFormat: targetFormat,
                      frameCapacity: AVAudioFrameCount(
                          Double(sourceBuffer.frameLength) * targetFormat.sampleRate / source.sampleRate
                      ) + 1024
                  )
            else { continue }

            var fed = false
            var convertError: NSError?
            converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            guard convertError == nil, outBuffer.frameLength > 0 else { continue }
            try file.write(from: outBuffer)
        }

        guard reader.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw reader.error ?? UnreadableError(reason: "reading ended before completion")
        }
        return outputURL
    }
}

private extension CMSampleBuffer {
    /// The sample buffer's own PCM format, as an `AVAudioFormat` — always the format requested
    /// via the track output's `outputSettings` (native sample rate/channels, float32).
    func nativeFormat() -> AVAudioFormat? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        var mutableASBD = asbd.pointee
        return AVAudioFormat(streamDescription: &mutableASBD)
    }

    /// Wraps this sample buffer's PCM data in an `AVAudioPCMBuffer` of `format` — valid only
    /// when `format` matches the buffer's own (non-interleaved) layout, i.e. `nativeFormat()`.
    func pcmBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity

        var blockBuffer: CMBlockBuffer?
        let channelCount = Int(format.channelCount)
        // AudioBufferList is a variable-length C struct — one AudioBuffer is declared inline,
        // more must be appended for extra channels — so MemoryLayout<AudioBufferList>.size only
        // ever fits ONE channel's worth. Passing that fixed (too-small) size for a stereo
        // (2-channel) non-interleaved buffer — exactly what system-audio recordings are,
        // 48 kHz/stereo, vs. the mic's mono/24 kHz — makes this call fail (non-`noErr`) on
        // every single sample buffer, silently producing a zero-length WAV: 7274 buffers read,
        // zero frames written, no error surfaced until whisper-server rejects the empty file.
        let listPointer = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(listPointer.unsafeMutablePointer) }
        let listByteSize = MemoryLayout<AudioBufferList>.size
            + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer.unsafeMutablePointer,
            bufferListSize: listByteSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        // Non-interleaved: one AudioBuffer per channel.
        for (index, channel) in listPointer.enumerated() where index < channelCount {
            guard let source = channel.mData, let destination = buffer.floatChannelData?[index] else { continue }
            memcpy(destination, source, Int(channel.mDataByteSize))
        }
        return buffer
    }
}

/// The decode façade the rest of the app calls: AVFoundation first, ffmpeg only if the caller
/// has one configured (auto-detected Homebrew install, or a user-chosen path in Settings).
/// Never hardcodes which formats go where — a per-file try/fallback needs no format table, and
/// stays correct as AVFoundation's own supported-format set shifts across macOS versions.
enum MediaDecoder {
    static func convertToWav(
        input: URL,
        ffmpeg: URL?,
        registerReader: ((AVAssetReader) -> Void)? = nil,
        registerProcess: ((Process) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let hasAudioTrack = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false

        do {
            return try await AVFoundationDecoder.convertToWav(input: input, register: registerReader)
        } catch {
            let ext = input.pathExtension.lowercased()
            guard let ffmpeg else {
                let message = hasAudioTrack
                    ? "Transcriber doesn't recognize this file's audio format (.\(ext)). Install ffmpeg (`brew install ffmpeg`) or point Settings → Tools at a copy, then try again."
                    : "This file has no readable audio, or its format (.\(ext)) needs ffmpeg to open — install it (`brew install ffmpeg`) or point Settings → Tools at a copy."
                throw RecorderError(message: message)
            }
            return try await FFmpeg.convertToWav(input: input, ffmpeg: ffmpeg, register: registerProcess)
        }
    }

    /// Replaces `FFmpeg.duration` + ffprobe entirely for anything AVFoundation can open. Returns
    /// nil (rather than falling back to ffmpeg) for the rare ffmpeg-only formats — duration is
    /// informational job metadata, already optional everywhere it's used.
    static func duration(of file: URL) async -> Double? {
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
