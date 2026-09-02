import Foundation

enum Tools {
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    /// Where per-user CLIs land — `claude` in particular installs into ~/.local/bin.
    static var userDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/bin"]
    }

    /// Tools bundled inside the app (Contents/Resources/bin) by Scripts/bundle-tools.sh.
    /// Empty in a plain `swift run` dev build, so we fall through to the system paths there.
    static var bundledDirectory: String? {
        Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true).path
    }

    static func find(_ names: String...) -> URL? {
        // Prefer the bundled copy so a shipped app never depends on the user's Homebrew.
        var directories: [String] = []
        if let bundledDirectory { directories.append(bundledDirectory) }
        directories += searchDirectories + userDirectories

        for directory in directories {
            for name in names {
                let path = "\(directory)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }
}

enum FFmpeg {
    /// Converts any audio/video file into a 16 kHz mono WAV that whisper accepts.
    static func convertToWav(
        input: URL,
        ffmpeg: URL,
        register: ((Process) -> Void)? = nil
    ) async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-\(UUID().uuidString).wav")
        let arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", input.path,
            "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
            output.path,
        ]
        let result = try await runProcess(ffmpeg, arguments, register: register)
        guard result.status == 0 else {
            // A header-only/empty file (a recording that captured no audio, or a truncated
            // import) trips these ffmpeg errors. Say so plainly instead of leaking "moov atom
            // not found", which reads like a tool bug rather than "there was no audio".
            if looksEmpty(result.stderr) {
                throw RecorderError(message: "This file has no readable audio — it looks empty or "
                    + "the recording didn't capture anything. Nothing to transcribe.")
            }
            throw CommandFailure(
                tool: "ffmpeg",
                status: result.status,
                stderrTail: String(result.stderr.suffix(300))
            )
        }
        return output
    }

    /// True when ffmpeg's stderr says the input contained no usable audio (as opposed to a real
    /// conversion failure) — an empty/unfinalized container or a stream with nothing decodable.
    static func looksEmpty(_ stderr: String) -> Bool {
        let markers = [
            "moov atom not found",
            "Invalid data found when processing input",
            "Output file #0 does not contain any stream",
            "does not contain any stream",
        ]
        return markers.contains { stderr.contains($0) }
    }

    // `extract`/`silences`/`duration` moved to `PCMAnalysis`/`MediaDecoder` — pure Swift via
    // AVFoundation, since they only ever ran on audio the app already decoded or recorded
    // itself. ffmpeg is now used only for the initial decode of a container AVFoundation can't
    // read, via `MediaDecoder.convertToWav`'s fallback to `convertToWav` above.
}

/// Silero VAD, used to skip silence before whisper ever sees it.
///
/// Without it whisper invents text in silent stretches: measured on a real recording whose
/// microphone had died, 6 of 8 segments in a 3:38 window were fabricated ("Субтитры создавал
/// DimaTorzok", "Спасибо за субтитры Алексею Дубровскому!"). With VAD the same window produced
/// 3 segments, all real speech, and ran far faster because silence is never decoded.
enum VADModel {
    static let fileName = "ggml-silero-v5.1.2.bin"
    static let downloadURL = URL(
        string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/\(fileName)"
    )!

    static var localURL: URL {
        ModelManager.modelsDirectory.appendingPathComponent(fileName)
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    /// Fetches the model on first use. It is under 1 MB, so this needs no progress UI —
    /// a failure just means transcription proceeds without VAD.
    static func ensureAvailable() async -> URL? {
        if isAvailable { return localURL }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
            try FileManager.default.createDirectory(
                at: ModelManager.modelsDirectory,
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.moveItem(at: temporary, to: localURL)
            return localURL
        } catch {
            return nil
        }
    }
}

struct WhisperSegment {
    let start: Double
    let end: Double
    let text: String
}

struct WhisperTranscription {
    let segments: [WhisperSegment]
    let language: String?
}

enum Whisper {
    /// Flags that improve accuracy without changing the model.
    ///
    /// `-mc 0` disables carrying previously-decoded text forward as context. whisper-cli
    /// defaults to `--max-context -1` (unlimited), which on long, repetitive audio — e.g. a
    /// language lesson that drills the same phrase — spirals into a runaway repetition loop:
    /// one real hour-long recording collapsed into "Я был в Италии" ~80× over seven minutes of
    /// ordinary speech. Isolated slices of that same audio transcribe cleanly, confirming the
    /// loop is driven by accumulated context, not the audio.
    ///
    /// Do NOT be tempted to "keep a little context" with a small positive cap — it is worse,
    /// not a compromise. Sweeping this exact file (large-v3-turbo-q5_0, VAD on):
    ///   -mc -1 → 3.1k chars, 38% repeated   (the reported bug)
    ///   -mc 128 → 5.7k, 26% ("I was? I was?" loop)
    ///   -mc  64 → 1.2k, collapses to "я / ян"
    ///   -mc  32 → 8.1k, 58% ("Оля."×196 — worst of all)
    ///   -mc   0 → 11.0k chars, 7% repeated  (clean; 3.5× more real content than default)
    /// The loop phrase is only a few tokens, so any window that carries ≥ that many prior
    /// tokens can reseed it and defeat the temperature-fallback safeguard. Only zero is robust.
    /// VAD still gives each window its own local context; we cut only the cross-window carry.
    /// `--carry-initial-prompt` still re-injects the vocabulary bias each window, so `-mc 0`
    /// does not weaken the `--prompt` feature.
    ///
    /// `--vad` is the important one: it stops whisper from hallucinating sentences in silence.
    /// `--suppress-nst` drops non-speech tokens. `--prompt` biases decoding toward a supplied
    /// vocabulary, which is how domain terms and proper nouns get spelled correctly.
    static func accuracyArguments(vadModel: URL?, initialPrompt: String?) -> [String] {
        var arguments: [String] = ["-mc", "0"]
        if let vadModel {
            arguments += ["--vad", "-vm", vadModel.path, "--suppress-nst"]
        }
        let vocabulary = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !vocabulary.isEmpty {
            // Carried so the bias applies to every window, not just the first.
            arguments += ["--prompt", vocabulary, "--carry-initial-prompt"]
        }
        return arguments
    }

    /// Transcribes and returns individual segments with timing, for speaker-attributed
    /// transcripts. Uses whisper-cli's JSON output.
    static func transcribeSegments(
        wav: URL,
        model: URL,
        language: String,
        cli: URL,
        vadModel: URL? = nil,
        initialPrompt: String? = nil,
        register: ((Process) -> Void)? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> WhisperTranscription {
        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-\(UUID().uuidString)")
        let jsonURL = outputBase.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
        let arguments = [
            "-m", model.path,
            "-f", wav.path,
            "-l", language,
            "-t", String(threads),
            "--print-progress",
            "-oj", "-of", outputBase.path,
        ] + accuracyArguments(vadModel: vadModel, initialPrompt: initialPrompt)
        let result = try await runProcess(cli, arguments, register: register) { line in
            reportProgress(line, onProgress)
        }
        guard result.status == 0 else {
            throw CommandFailure(
                tool: "whisper-cli",
                status: result.status,
                stderrTail: String(result.stderr.suffix(300))
            )
        }

        let data = try Data(contentsOf: jsonURL)
        let parsed = try JSONDecoder().decode(WhisperJSONFile.self, from: data)
        let segments = parsed.transcription.map {
            WhisperSegment(
                start: Double($0.offsets.from) / 1000.0,
                end: Double($0.offsets.to) / 1000.0,
                text: $0.text
            )
        }
        return WhisperTranscription(segments: segments, language: parsed.result?.language)
    }

    private struct WhisperJSONFile: Decodable {
        struct Offsets: Decodable {
            let from: Int
            let to: Int
        }
        struct Segment: Decodable {
            let offsets: Offsets
            let text: String
        }
        struct Result: Decodable {
            let language: String?
        }
        let transcription: [Segment]
        let result: Result?
    }

    private static func reportProgress(_ line: String, _ onProgress: ((Double) -> Void)?) {
        // whisper-cli reports "... progress =  35%" on stderr
        guard let marker = line.range(of: "progress =") else { return }
        let tail = line[marker.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")
        if let percent = Double(tail) {
            onProgress?(min(1.0, percent / 100.0))
        }
    }

    static func transcribe(
        wav: URL,
        model: URL,
        language: String,
        timestamps: Bool,
        cli: URL,
        vadModel: URL? = nil,
        initialPrompt: String? = nil,
        register: ((Process) -> Void)? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> String {
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
        var arguments = [
            "-m", model.path,
            "-f", wav.path,
            "-l", language,
            "-t", String(threads),
            "--print-progress",
        ] + accuracyArguments(vadModel: vadModel, initialPrompt: initialPrompt)
        if !timestamps {
            arguments.append("-nt")
        }
        let result = try await runProcess(cli, arguments, register: register) { line in
            reportProgress(line, onProgress)
        }
        guard result.status == 0 else {
            throw CommandFailure(
                tool: "whisper-cli",
                status: result.status,
                stderrTail: String(result.stderr.suffix(300))
            )
        }
        return cleanUp(result.stdout, keepTimestamps: timestamps)
    }

    private static func cleanUp(_ raw: String, keepTimestamps: Bool) -> String {
        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: keepTimestamps ? "\n" : "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
