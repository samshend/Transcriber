import Foundation

/// Runs a local `llama-server` (llama.cpp, MIT) so transcripts can be summarized and
/// queried by a downloaded GGUF model. Bound to 127.0.0.1 only; nothing leaves the Mac.
actor LlamaServer {
    static let shared = LlamaServer()

    private var process: Process?
    private var port = 0
    private var loadedModelPath: String?

    struct ServerFailure: LocalizedError {
        let message: String
        var errorDescription: String? { "llama-server: \(message)" }
    }

    var isRunning: Bool { process?.isRunning == true }
    var currentModelPath: String? { isRunning ? loadedModelPath : nil }

    static var binary: URL? { Tools.find("llama-server") }

    /// 32k context: Cyrillic is token-hungry (~2.5 chars/token), so a one-hour Russian
    /// transcript needs far more room than the same text in English.
    func ensureRunning(model: URL, contextSize: Int = 32768) async throws {
        if let process, process.isRunning, loadedModelPath == model.path { return }
        stop()

        guard let binary = Self.binary else {
            throw ServerFailure(message: "helper binary is missing from the app bundle (try reinstalling Transcriber)")
        }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw ServerFailure(message: "model file is missing at \(model.path)")
        }

        let chosenPort = Int.random(in: 49500...64000)
        let server = Process()
        server.executableURL = binary
        server.arguments = [
            "-m", model.path,
            "--host", "127.0.0.1",
            "--port", String(chosenPort),
            "-c", String(contextSize),
            "-ngl", "999",          // offload everything to Metal
            "--no-warmup",
            "--jinja",              // use the model's own chat template
        ]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        server.standardInput = FileHandle.nullDevice
        try server.run()
        process = server
        port = chosenPort
        loadedModelPath = model.path

        // Wait for /health to report ready (model load can take a while).
        let health = URL(string: "http://127.0.0.1:\(chosenPort)/health")!
        for _ in 0..<600 {
            guard server.isRunning else {
                stop()
                throw ServerFailure(message: "exited during startup (is the GGUF valid?)")
            }
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        stop()
        throw ServerFailure(message: "did not become ready in time")
    }

    /// One-shot chat completion. `system` is the instruction, `user` the content.
    func complete(
        system: String,
        user: String,
        maxTokens: Int = 1200,
        temperature: Double = 0.3
    ) async throws -> String {
        try await chat(system: system, user: user, maxTokens: maxTokens, temperature: temperature, responseFormat: nil)
    }

    /// A completion constrained to emit JSON matching `schema` (llama.cpp's grammar-backed
    /// `response_format: json_schema`). Returns the raw JSON string — the caller decodes it.
    /// Temperature is pinned low: this is extraction, not prose, so determinism matters.
    func completeJSON(
        system: String,
        user: String,
        schema: [String: Any],
        maxTokens: Int = 1200
    ) async throws -> String {
        let format: [String: Any] = [
            "type": "json_schema",
            "json_schema": ["name": "result", "strict": true, "schema": schema],
        ]
        return try await chat(system: system, user: user, maxTokens: maxTokens, temperature: 0.0, responseFormat: format)
    }

    private func chat(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double,
        responseFormat: [String: Any]?
    ) async throws -> String {
        guard isRunning else { throw ServerFailure(message: "not running") }

        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
            // Qwen3 and friends emit <think> blocks unless reasoning is disabled;
            // summaries should be the answer only.
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        if let responseFormat {
            body["response_format"] = responseFormat
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 900

        let (data, _) = try await URLSession.shared.data(for: request)
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            struct Failure: Decodable { let message: String? }
            let choices: [Choice]?
            let error: Failure?
        }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw ServerFailure(message: "unexpected response: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
        }
        if let error = decoded.error?.message {
            throw ServerFailure(message: error)
        }
        let text = decoded.choices?.first?.message.content ?? ""
        return Self.stripReasoning(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes any `<think>…</think>` block some models emit before the answer.
    static func stripReasoning(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text }
        return String(text[end.upperBound...])
    }

    func stop() {
        process?.terminate()
        process = nil
        loadedModelPath = nil
    }
}
