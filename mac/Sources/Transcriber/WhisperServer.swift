import Foundation

/// Manages a local whisper-server process so many small chunks can be transcribed
/// without reloading the model each time. Bound to 127.0.0.1 only.
actor WhisperServer {
    static let shared = WhisperServer()

    private var process: Process?
    private var port = 0
    private var modelPath: String?

    struct ServerFailure: LocalizedError {
        let message: String
        var errorDescription: String? { "whisper-server: \(message)" }
    }

    func ensureRunning(model: URL, serverBinary: URL) async throws {
        if let process, process.isRunning, modelPath == model.path { return }
        stop()

        let chosenPort = Int.random(in: 49500...64000)
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
        let serverProcess = Process()
        serverProcess.executableURL = serverBinary
        serverProcess.arguments = [
            "-m", model.path,
            "--host", "127.0.0.1",
            "--port", String(chosenPort),
            "-t", String(threads),
            "-l", "auto",
        ]
        serverProcess.standardOutput = FileHandle.nullDevice
        serverProcess.standardError = FileHandle.nullDevice
        serverProcess.standardInput = FileHandle.nullDevice
        try serverProcess.run()
        process = serverProcess
        port = chosenPort
        modelPath = model.path

        // Wait until the server answers HTTP (it listens only after the model loads).
        let probe = URL(string: "http://127.0.0.1:\(chosenPort)/")!
        for _ in 0..<240 {
            guard serverProcess.isRunning else {
                stop()
                throw ServerFailure(message: "exited during startup")
            }
            do {
                _ = try await URLSession.shared.data(from: probe)
                return
            } catch {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        stop()
        throw ServerFailure(message: "did not become ready in time")
    }

    /// One word with the audio time-range it was spoken in (seconds, relative to the clip
    /// that was sent). The mixed-language repair pass needs these to slice out the exact
    /// audio behind a transliterated word and re-transcribe it under a forced language.
    struct Word: Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    /// Transcribes one chunk. `language` nil means auto-detect.
    /// Returns the text and the language whisper detected/used.
    func transcribe(wav: URL, language: String?) async throws -> (text: String, language: String?) {
        let out = try await transcribeWords(wav: wav, language: language)
        return (out.text, out.language)
    }

    /// Like `transcribe`, but also returns per-word timestamps. `verbose_json` (which we
    /// already request) carries `segments[].words[]` with `word/start/end`; the plain
    /// `transcribe` path just discards them.
    func transcribeWords(wav: URL, language: String?) async throws -> (text: String, language: String?, words: [Word]) {
        guard process?.isRunning == true else {
            throw ServerFailure(message: "not running")
        }

        let boundary = "transcriber-\(UUID().uuidString)"
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        addField("response_format", "verbose_json")
        addField("temperature", "0.0")
        addField("temperature_inc", "0.2")
        if let language {
            addField("language", language)
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: wav))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 600

        let (data, _) = try await URLSession.shared.data(for: request)
        struct Response: Decodable {
            struct Segment: Decodable {
                struct W: Decodable {
                    let word: String
                    let start: Double
                    let end: Double
                }
                let words: [W]?
            }
            let text: String?
            let language: String?
            let error: String?
            let segments: [Segment]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ServerFailure(message: "unexpected response: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
        }
        if let error = decoded.error {
            throw ServerFailure(message: error)
        }
        let words = (decoded.segments ?? []).flatMap { $0.words ?? [] }
            .map { Word(text: $0.word, start: $0.start, end: $0.end) }
        return (decoded.text ?? "", decoded.language, words)
    }

    func stop() {
        process?.terminate()
        process = nil
        modelPath = nil
    }
}
