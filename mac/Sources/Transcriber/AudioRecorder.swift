import AVFoundation
import Foundation

struct RecorderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// What `finish()` produced, including anything that went wrong on the way. A recording
/// where one capture died is still worth keeping — but the user has to be told.
struct FinishedRecording {
    let url: URL
    let micSeconds: Double
    let systemSeconds: Double
    /// Original per-source tracks, kept on disk when something looked wrong.
    let keptTracks: [URL]
    let warning: String?
}

/// Records the microphone (and optionally system audio) to an .m4a file.
/// Mic and system audio are captured into separate files and mixed with ffmpeg on stop.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var systemAudioActive = false
    /// False while the microphone isn't delivering buffers — surfaced in red in the
    /// recording bar. A silent dropout once cost 25 minutes of one side of a meeting.
    @Published private(set) var micLive = true
    /// True from "Stop & Transcribe" until the audio file is on disk. Mixing a long
    /// meeting takes tens of seconds, and without this the window looks empty and idle.
    @Published private(set) var isFinishing = false
    @Published private(set) var finishProgress: Double?
    @Published private(set) var finishedLength: TimeInterval = 0
    @Published var warning: String?

    private let engine = AVAudioEngine()
    private var micWriter: MicWriter?
    private var micURL: URL?
    private var finalURL: URL?
    private var systemTap: SystemAudioTap?

    /// Seconds the captured system audio has been silent — feeds the meeting-end silence
    /// detector. Very large when there is no system-audio capture, so silence-detection simply
    /// never fires in mic-only recordings.
    var systemSilenceSeconds: TimeInterval { systemTap?.secondsSinceAudible ?? .greatestFiniteMagnitude }
    private var systemURL: URL?

    private var watchdogTask: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private var lastRestartAt: Date?
    private var restartCount = 0

    /// No mic buffer for this long means the capture is dead, not that the room is quiet —
    /// taps deliver buffers continuously regardless of loudness.
    private static let stallThreshold: TimeInterval = 2.5
    private static let restartCooldown: TimeInterval = 5

    func start(captureSystemAudio: Bool, folder: URL) throws {
        guard !isRecording else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let baseName = "Recording \(formatter.string(from: Date()))"
        var final = folder.appendingPathComponent("\(baseName).m4a")
        var counter = 2
        while FileManager.default.fileExists(atPath: final.path) {
            final = folder.appendingPathComponent("\(baseName) (\(counter)).m4a")
            counter += 1
        }
        finalURL = final

        warning = nil
        micLive = true
        restartCount = 0
        lastRestartAt = nil
        systemAudioActive = false
        if captureSystemAudio {
            let sysURL = final.deletingPathExtension().appendingPathExtension("system.m4a")
            let tap = SystemAudioTap()
            do {
                try tap.start(writingTo: sysURL)
                systemTap = tap
                systemURL = sysURL
                systemAudioActive = true
            } catch {
                systemTap = nil
                systemURL = nil
                // Expected on first use until "System Audio Recording" is granted (the prompt
                // appears the first time we create the tap). Keep recording the mic so nothing is
                // lost, and tell the user exactly how to capture the other side next time.
                warning = "Recording your microphone only. To also capture the other side of the "
                    + "call, allow Transcriber under System Settings → Privacy & Security → Screen "
                    + "& System Audio Recording, then start recording again."
                Log.recording.notice("system audio tap unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        let micURL = systemAudioActive
            ? final.deletingPathExtension().appendingPathExtension("mic.m4a")
            : final
        self.micURL = micURL

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            stopSystemTap()
            throw RecorderError(message: "No microphone input available.")
        }

        let writer = try MicWriter(url: micURL, inputFormat: inputFormat)
        writer.onUpdate = { [weak self] elapsed, level in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = elapsed
                self.level = level
            }
        }
        micWriter = writer

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            writer.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            micWriter = nil
            stopSystemTap()
            throw RecorderError(message: "Could not start the microphone: \(error.localizedDescription)")
        }

        isRecording = true
        isPaused = false
        elapsed = 0
        level = 0
        observeConfigurationChanges()
        startWatchdog()
    }

    func pause() {
        guard isRecording else { return }
        micWriter?.paused = true
        systemTap?.paused = true
        isPaused = true
        level = 0
    }

    func resume() {
        guard isRecording else { return }
        micWriter?.paused = false
        systemTap?.paused = false
        isPaused = false
    }

    // MARK: - Keeping the capture alive

    /// AVAudioEngine silently stops delivering buffers when the input device or its format
    /// changes (AirPods connecting, a call app switching devices, sample-rate changes).
    /// Without this the tap is dead for the rest of the meeting and nothing says so.
    private func observeConfigurationChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.warning = "The audio device changed — restarting the microphone."
                self.restartMicCapture()
            }
        }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRecording else { return }
                self.checkCaptureHealth()
            }
        }
    }

    private func checkCaptureHealth() {
        guard isRecording, !isPaused, let writer = micWriter else { return }

        let silentFor = writer.secondsSinceLastBuffer
        if silentFor > Self.stallThreshold {
            micLive = false
            warning = "The microphone stopped delivering audio \(Int(silentFor))s ago — trying to restart it. "
                + "Check the input device in System Settings → Sound."
            let now = Date()
            if lastRestartAt == nil || now.timeIntervalSince(lastRestartAt!) > Self.restartCooldown {
                lastRestartAt = now
                restartMicCapture()
            }
        } else if !micLive {
            micLive = true
            warning = "Microphone recovered after a dropout — some audio was lost."
        }

        if let dropped = micWriter?.droppedBuffers, dropped > 0, micLive {
            warning = "The microphone dropped \(dropped) buffer(s); the recording may be slightly out of sync."
        }
        if systemAudioActive, let tap = systemTap, tap.secondsSinceLastBuffer > 5 {
            warning = "System audio stopped arriving — the other side of the call may not be recorded."
        }
    }

    private func restartMicCapture() {
        guard isRecording, let writer = micWriter else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            warning = "No microphone input available. Reconnect the device — the recording is still running."
            return
        }
        // MicWriter re-derives its converter from each buffer's format, so a device with a
        // different sample rate or channel count keeps writing into the same file.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            restartCount += 1
        } catch {
            warning = "Could not restart the microphone: \(error.localizedDescription)"
        }
    }

    // MARK: - Finishing

    /// Stops recording and returns the final audio file (mixing in system audio if captured).
    func finish(ffmpeg: URL?, keepSourceTracks: Bool = true) async throws -> FinishedRecording {
        guard isRecording, let finalURL, let micURL else {
            throw RecorderError(message: "Not recording.")
        }
        let systemURL = self.systemURL
        let systemFrames = systemTap?.framesWritten ?? 0
        let systemSeconds = systemTap?.secondsWritten ?? 0
        let micSeconds = micWriter?.secondsWritten ?? 0
        let droppedBuffers = micWriter?.droppedBuffers ?? 0
        let recordedLength = max(elapsed, max(micSeconds, systemSeconds))
        let restarts = restartCount
        tearDownCapture()

        finishedLength = recordedLength
        finishProgress = nil
        isFinishing = true
        defer {
            isFinishing = false
            finishProgress = nil
        }

        var problems: [String] = []
        var keptTracks: [URL] = []

        // Decide, from how much audio actually landed on each track, what the final file is. A
        // track with (near-)zero frames is a header-only AAC file with no moov atom: unreadable,
        // and if it becomes the recording the failure only surfaces much later as a cryptic
        // "ffmpeg: … moov atom not found" when transcription tries to open it. Catch it now.
        let choice = Self.chooseFinal(micSeconds: micSeconds, systemSeconds: systemSeconds)
        guard choice != .empty else {
            try? FileManager.default.removeItem(at: micURL)
            if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
            throw RecorderError(message: """
                No audio was captured. Check that your microphone works and isn't muted, and that \
                Transcriber has access in System Settings → Privacy & Security → Microphone, then \
                record again.
                """)
        }

        if systemFrames > 0,
           let mismatch = Self.trackMismatch(micSeconds: micSeconds, systemSeconds: systemSeconds) {
            problems.append(mismatch)
        }
        if droppedBuffers > 0 {
            problems.append("The microphone dropped \(droppedBuffers) buffer(s), so its timing may drift.")
        }
        if restarts > 0 {
            problems.append("The microphone had to be restarted \(restarts)× during the recording.")
        }
        // Keeping the untouched per-source tracks means nothing is ever unrecoverable if a
        // capture misbehaves — and each side is isolated, which is what makes reliable
        // speaker attribution possible later (see INTEGRATIONS.md, dual-track mode).
        let keepSources = keepSourceTracks || !problems.isEmpty

        if choice == .mixBoth, let systemURL, let ffmpeg {
            let arguments = [
                "-hide_banner", "-nostdin", "-y", "-nostats",
                "-progress", "pipe:2",
                "-i", micURL.path,
                "-i", systemURL.path,
                // normalize=0 keeps both sides at full level; the limiter then stops the sum
                // from clipping (the old command clipped at 0 dB on every loud passage).
                "-filter_complex", "amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.97",
                "-c:a", "aac", "-b:a", "128k",
                finalURL.path,
            ]
            // `-progress pipe:2` emits newline-terminated key=value blocks, so real progress
            // is available instead of a spinner that says nothing.
            let result = try await runProcess(ffmpeg, arguments, onStderrLine: { [weak self] line in
                guard recordedLength > 0, let seconds = Self.progressSeconds(in: line) else { return }
                Task { @MainActor in
                    self?.finishProgress = min(1, seconds / recordedLength)
                }
            })
            if result.status == 0 {
                if keepSources {
                    keptTracks = [micURL, systemURL].filter { FileManager.default.fileExists(atPath: $0.path) }
                } else {
                    try? FileManager.default.removeItem(at: micURL)
                    try? FileManager.default.removeItem(at: systemURL)
                }
            } else {
                // Mixing failed. Keep whichever side actually has audio — blindly keeping the mic
                // would throw away the whole call if the microphone was the track that died.
                let survivor = micSeconds >= systemSeconds ? micURL : systemURL
                let spare = survivor == micURL ? systemURL : micURL
                try? FileManager.default.moveItem(at: survivor, to: finalURL)
                keptTracks = [spare].filter { FileManager.default.fileExists(atPath: $0.path) }
                let keptName = survivor == micURL ? "microphone" : "system audio"
                problems.append("Could not mix the two audio tracks; kept the \(keptName) track only.")
            }
        } else if choice == .systemOnly, let systemURL {
            // The microphone captured nothing; the system-audio side has the conversation, so it
            // becomes the recording rather than being discarded. (trackMismatch already warned.)
            try? FileManager.default.removeItem(at: micURL)
            try FileManager.default.moveItem(at: systemURL, to: finalURL)
        } else {
            // Microphone-only (the common case), or both had audio but ffmpeg was unavailable.
            if micURL != finalURL {
                try FileManager.default.moveItem(at: micURL, to: finalURL)
            }
            if let systemURL, FileManager.default.fileExists(atPath: systemURL.path) {
                if choice == .mixBoth {
                    // Don't lose the far side just because we couldn't combine the tracks.
                    keptTracks.append(systemURL)
                    problems.append("Could not combine the two audio tracks; saved the microphone and kept the system-audio track separately.")
                } else {
                    try? FileManager.default.removeItem(at: systemURL)
                }
            }
        }

        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            throw RecorderError(message: "Recording file was not created.")
        }

        var message: String?
        if !problems.isEmpty {
            message = problems.joined(separator: " ")
            if !keptTracks.isEmpty {
                message! += " The original tracks were kept: "
                    + keptTracks.map { $0.lastPathComponent }.joined(separator: ", ") + "."
            }
            warning = message
        }
        return FinishedRecording(
            url: finalURL,
            micSeconds: micSeconds,
            systemSeconds: systemSeconds,
            keptTracks: keptTracks,
            warning: message
        )
    }

    /// Both captures run for the same wall-clock time, so their durations must match. A
    /// gap means one of them died mid-recording and the mix is one-sided from that point on.
    nonisolated static func trackMismatch(
        micSeconds: Double,
        systemSeconds: Double,
        tolerance: Double = 5
    ) -> String? {
        guard micSeconds > 0, systemSeconds > 0 else {
            if micSeconds <= 0 { return "Nothing was recorded from the microphone." }
            if systemSeconds <= 0 { return "Nothing was recorded from system audio." }
            return nil
        }
        guard abs(micSeconds - systemSeconds) > tolerance else { return nil }
        let micDied = micSeconds < systemSeconds
        let deadName = micDied ? "microphone" : "system audio"
        let liveName = micDied ? "system audio" : "microphone"
        let deadAt = MarkdownWriter.formatDuration(min(micSeconds, systemSeconds))
        let total = MarkdownWriter.formatDuration(max(micSeconds, systemSeconds))
        return "The \(deadName) stopped after \(deadAt) while \(liveName) continued to \(total) — "
            + "everything after \(deadAt) has only one side of the conversation."
    }

    /// Which captured track(s) make up the final recording, from how much audio landed on each.
    /// Less than `minAudio` seconds counts as "nothing recorded": an empty AAC file has no moov
    /// atom and can't be read back, so such a track must never become the recording on its own.
    enum FinalSource { case mixBoth, micOnly, systemOnly, empty }

    nonisolated static func chooseFinal(
        micSeconds: Double,
        systemSeconds: Double,
        minAudio: Double = 0.15
    ) -> FinalSource {
        switch (micSeconds >= minAudio, systemSeconds >= minAudio) {
        case (true, true): return .mixBoth
        case (true, false): return .micOnly
        case (false, true): return .systemOnly
        case (false, false): return .empty
        }
    }

    func discard() {
        guard isRecording else { return }
        let mic = micURL
        let system = systemURL
        tearDownCapture()
        if let mic { try? FileManager.default.removeItem(at: mic) }
        if let system { try? FileManager.default.removeItem(at: system) }
    }

    private func tearDownCapture() {
        watchdogTask?.cancel()
        watchdogTask = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micWriter?.close()
        micWriter = nil
        stopSystemTap()
        isRecording = false
        isPaused = false
        level = 0
        micLive = true
    }

    /// Pulls a position out of an ffmpeg progress line: `out_time=00:01:23.450000`
    /// (from `-progress`) or `time=00:01:23.45` (from the default stats line).
    nonisolated static func progressSeconds(in line: String) -> Double? {
        guard let range = line.range(
            of: #"(?:out_)?time=(\d+):(\d{2}):(\d{2}(?:\.\d+)?)"#,
            options: .regularExpression
        ) else { return nil }
        let text = line[range]
        guard let equals = text.firstIndex(of: "=") else { return nil }
        let parts = text[text.index(after: equals)...].split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private func stopSystemTap() {
        systemTap?.stop()
        systemTap = nil
        systemAudioActive = false
    }
}

/// Writes mic buffers to an AAC file. Used only from the audio tap thread
/// (callbacks are serial); shared state is guarded by a lock.
private final class MicWriter: @unchecked Sendable {
    var onUpdate: ((TimeInterval, Float) -> Void)?

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let monoFormat: AVAudioFormat
    private let sampleRate: Double
    private var frames: Int64 = 0
    private var _paused = false
    private var _dropped = 0
    private var _lastBufferAt = Date()

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }

    /// Buffers the encoder refused. Silently swallowing these is how a recording ends up
    /// with a drifting or truncated microphone track.
    var droppedBuffers: Int {
        lock.lock(); defer { lock.unlock() }; return _dropped
    }

    var secondsWritten: Double {
        lock.lock(); defer { lock.unlock() }
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    var secondsSinceLastBuffer: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastBufferAt)
    }

    init(url: URL, inputFormat: AVAudioFormat) throws {
        sampleRate = inputFormat.sampleRate
        monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        // Recorded even while paused: this is the liveness signal for the watchdog.
        _lastBufferAt = Date()
        guard let file, !_paused else { return }

        let toWrite: AVAudioPCMBuffer
        if buffer.format == monoFormat {
            toWrite = buffer
        } else {
            // Rebuilt whenever the input format changes — after a device switch the old
            // converter would fail on every single buffer, silently.
            if converterInput != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: monoFormat)
                converterInput = buffer.format
            }
            guard let converter,
                  let mono = AVAudioPCMBuffer(
                      pcmFormat: monoFormat,
                      frameCapacity: AVAudioFrameCount(
                          Double(buffer.frameLength) * monoFormat.sampleRate / buffer.format.sampleRate
                      ) + 1024
                  )
            else { _dropped += 1; return }
            var fed = false
            var error: NSError?
            converter.convert(to: mono, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, mono.frameLength > 0 else { _dropped += 1; return }
            toWrite = mono
        }

        guard (try? file.write(from: toWrite)) != nil else { _dropped += 1; return }
        frames += Int64(toWrite.frameLength)

        var levelValue: Float = 0
        if let channel = toWrite.floatChannelData?[0] {
            let count = Int(toWrite.frameLength)
            var sum: Float = 0
            for i in 0..<count {
                sum += channel[i] * channel[i]
            }
            let rms = count > 0 ? sqrtf(sum / Float(count)) : 0
            // Map RMS to a rough 0…1 meter (-50 dB floor).
            let db = 20 * log10f(max(rms, 0.000_01))
            levelValue = max(0, min(1, (db + 50) / 50))
        }
        onUpdate?(Double(frames) / sampleRate, levelValue)
    }

    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}
