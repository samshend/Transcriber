import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SummaryEngine: String, CaseIterable, Identifiable {
    case automatic
    case appleIntelligence
    case localModel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .appleIntelligence: return "Apple Intelligence"
        case .localModel: return "Downloaded model (llama.cpp)"
        }
    }
}

enum SummaryState: Equatable {
    case unsupportedOS
    case unavailable(String)  // human-readable reason
    case ready
}

struct SummaryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// On-device meeting summarization via Apple Foundation Models (macOS 26+, Apple Intelligence).
/// Nothing leaves the machine. Long transcripts are summarized map-reduce style because the
/// on-device model has a small context window.
enum Summarizer {
    static var state: SummaryState {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                return .unavailable(describe(reason))
            }
        } else {
            return .unsupportedOS
        }
        #else
        return .unsupportedOS
        #endif
    }

    static var isReady: Bool { state == .ready }

    /// Language codes Apple's on-device model accepts (e.g. ["en","de","fr",…]).
    static var supportedLanguageCodes: Set<String> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return Set(SystemLanguageModel.default.supportedLanguages.compactMap { $0.languageCode?.identifier })
        }
        #endif
        return []
    }

    /// Given the transcript's declared languages, returns those Apple FM can't handle.
    /// Empty result means summarization can proceed.
    static func unsupportedLanguages(in declared: [String]) -> [String] {
        let supported = supportedLanguageCodes
        guard !supported.isEmpty else { return [] }
        return declared.filter { !supported.contains($0) }
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri, then try again."
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence, so on-device summaries aren't available."
        case .modelNotReady:
            return "The on-device model is still downloading or preparing. Try again in a few minutes."
        @unknown default:
            return "On-device summaries are currently unavailable."
        }
    }
    #endif

    /// Summarizes with a local GGUF model via llama.cpp. Works for any language
    /// (including Russian, which Apple's model refuses) and honours a custom prompt.
    static func summarizeWithLocalModel(
        transcriptBody: String,
        model: URL,
        customPrompt: String? = nil,
        languageName: String? = nil
    ) async throws -> String {
        try await LlamaServer.shared.ensureRunning(model: model)

        // A custom prompt is taken literally — the user controls the output language there.
        let instruction = (customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaultPrompt(languageName: languageName)

        // Local models have a real context window; condense oversized transcripts first.
        let chunks = chunk(transcriptBody, maxCharacters: 24000)
        let content: String
        if chunks.count == 1 {
            content = transcriptBody
        } else {
            var condensed: [String] = []
            for (index, piece) in chunks.enumerated() {
                let partial = try await LlamaServer.shared.complete(
                    system: mapInstructions,
                    user: "Part \(index + 1) of \(chunks.count) of a meeting transcript. "
                        + "Summarize the key points, decisions and tasks:\n\n\(piece)",
                    maxTokens: 900
                )
                condensed.append(partial)
            }
            content = condensed.joined(separator: "\n\n")
        }

        return try await LlamaServer.shared.complete(
            system: reduceInstructions,
            user: "\(instruction)\n\nTranscript:\n\n\(content)",
            maxTokens: 1600
        )
    }

    /// The editable default instruction shown in Settings.
    static let defaultPromptTemplate = """
        Write a summary of this meeting using exactly this Markdown structure:

        ## Summary
        (2-4 sentences of what the meeting was about and what was decided.)

        ## Key points
        - (bullet points of the main topics)

        ## Action items
        - (each task, with the responsible person if mentioned; write "none" if there are none)

        The transcript marks who is speaking as **Name** followed by a timestamp. Attribute every \
        statement to the speaker it belongs to and never move one to another person; if the \
        speaker is unclear, write the point without naming anyone.
        """

    /// Naming the output language explicitly is the only reliable way to get it: telling a
    /// model to "reply in the same language as the transcript" is ignored, and an English
    /// prompt then yields an English summary of a Russian meeting.
    static func defaultPrompt(languageName: String?) -> String {
        guard let languageName else { return defaultPromptTemplate }
        return defaultPromptTemplate
            + "\n\nWrite the summary text in \(languageName). Keep the three headings in English."
    }

    /// Produces a Markdown summary block (overview + action items) for a transcript body.
    /// `declaredLanguages` lets us fail fast with a clear message when the content is in a
    /// language Apple's on-device model can't process (e.g. Russian).
    static func summarize(
        transcriptBody: String,
        declaredLanguages: [String] = [],
        customPrompt: String? = nil,
        languageName: String? = nil
    ) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw SummaryError(message: "On-device summaries require macOS 26 or later.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw SummaryError(message: describe(reason))
        }

        let unsupported = unsupportedLanguages(in: declaredLanguages)
        if !unsupported.isEmpty {
            throw SummaryError(message: unsupportedLanguageMessage(unsupported))
        }

        let chunks = chunk(transcriptBody, maxCharacters: 6000)
        let partials: [String]
        if chunks.count == 1 {
            partials = chunks
        } else {
            // Map: condense each chunk first so the whole thing fits the context window.
            var condensed: [String] = []
            for (index, chunk) in chunks.enumerated() {
                let session = LanguageModelSession(instructions: mapInstructions)
                let reply = try await session.respond(
                    to: "Part \(index + 1) of \(chunks.count) of a meeting transcript. Summarize the key points and any decisions or tasks mentioned:\n\n\(chunk)"
                )
                condensed.append(reply.content)
            }
            partials = condensed
        }

        // Reduce: produce the final structured summary in the transcript's language.
        let session = LanguageModelSession(instructions: reduceInstructions)
        let joined = partials.joined(separator: "\n\n")
        do {
            let reply = try await session.respond(
                to: finalPrompt(joined, customPrompt: customPrompt, languageName: languageName)
            )
            return reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            throw SummaryError(message: friendly(error))
        }
        #else
        throw SummaryError(message: "On-device summaries are not supported in this build.")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func friendly(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .unsupportedLanguageOrLocale:
            return unsupportedLanguageMessage([])
        case .exceededContextWindowSize:
            return "This transcript is too long for the on-device model even after chunking."
        case .guardrailViolation:
            return "Apple Intelligence blocked this content by its safety guardrail."
        default:
            return "On-device summary failed: \(error.localizedDescription)"
        }
    }
    #endif

    private static func unsupportedLanguageMessage(_ unsupported: [String]) -> String {
        let names = unsupported.map { languageName($0) }
        let supportedNames = supportedLanguageCodes
            .map { languageName($0) }
            .sorted()
            .joined(separator: ", ")
        let subject = names.isEmpty ? "This transcript's language" : names.joined(separator: ", ")
        return "\(subject) isn't supported by Apple's on-device model, so it can't be summarized locally. "
            + "Apple Intelligence currently supports: \(supportedNames)."
    }

    // MARK: - Prompts

    private static let mapInstructions =
        "You condense one part of a longer meeting transcript. Keep names, decisions, numbers, " +
        "and tasks, and keep track of which speaker said what (speakers appear as **Name** " +
        "before a timestamp). Be terse. Reply in the same language as the transcript."

    private static let reduceInstructions =
        "You write concise, accurate meeting summaries for later reference. Never invent facts " +
        "that are not in the transcript and never attribute one speaker's statement to another. " +
        "Always reply in the same language as the transcript."

    private static func finalPrompt(_ body: String, customPrompt: String?, languageName: String? = nil) -> String {
        let instruction = (customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaultPrompt(languageName: languageName)
        return "\(instruction)\n\nTranscript:\n\n\(body)"
    }

    // MARK: - Chunking

    /// Splits on blank lines (our transcripts are blocks separated by \n\n), packing
    /// blocks into chunks under the character budget without cutting a block in half.
    static func chunk(_ text: String, maxCharacters: Int) -> [String] {
        let blocks = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""
        for block in blocks {
            if current.isEmpty {
                current = block
            } else if current.count + block.count + 2 <= maxCharacters {
                current += "\n\n" + block
            } else {
                chunks.append(current)
                current = block
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Title generation

    /// A short, content-based title for a transcript, for use as a filename (e.g. "Client call
    /// — Spain residency"). Best-effort via Apple's on-device model: returns nil when it's
    /// unavailable or produces nothing usable, so callers keep the date-stamped fallback name.
    static func generateTitle(transcriptBody: String, languageName: String? = nil) async -> String? {
        let excerpt = titleExcerpt(from: transcriptBody)
        guard !excerpt.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isReady {
            let session = LanguageModelSession(instructions: titleInstructions(languageName: languageName))
            if let reply = try? await session.respond(to: "Transcript excerpt:\n\n\(excerpt)") {
                return cleanTitle(reply.content)
            }
        }
        #endif
        return nil
    }

    /// Local-model title variant, used when Apple FM can't handle the language (e.g. Russian).
    static func generateTitleWithLocalModel(
        transcriptBody: String,
        model: URL,
        languageName: String? = nil
    ) async -> String? {
        let excerpt = titleExcerpt(from: transcriptBody)
        guard !excerpt.isEmpty else { return nil }
        do {
            try await LlamaServer.shared.ensureRunning(model: model)
            let reply = try await LlamaServer.shared.complete(
                system: titleInstructions(languageName: languageName),
                user: "Transcript excerpt:\n\n\(excerpt)",
                maxTokens: 40
            )
            return cleanTitle(reply)
        } catch {
            return nil
        }
    }

    /// A title reflects the topic, which is established up front; the opening is enough and
    /// keeps this cheap (no map-reduce over the whole transcript).
    private static func titleExcerpt(from body: String, maxCharacters: Int = 6000) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= maxCharacters ? trimmed : String(trimmed.prefix(maxCharacters))
    }

    private static func titleInstructions(languageName: String?) -> String {
        var s = "You produce a short, specific title for a meeting or voice-message transcript, "
            + "to be used as a filename. Use 3 to 7 words. Name the concrete topic — who or what "
            + "it is about. No date, no surrounding quotes, no trailing punctuation, no file "
            + "extension, and none of these characters: / \\ : * ? \" < > |. "
            + "Reply with the title only, nothing else."
        if let languageName { s += " Write the title in \(languageName)." }
        return s
    }

    /// Trims a model reply down to a single clean title line.
    private static func cleanTitle(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = t.split(separator: "\n", omittingEmptySubsequences: true).first {
            t = String(firstLine)
        }
        // Drop a leading "Title:" / "Title -" label the model sometimes prepends.
        if let r = t.range(of: #"^\s*title\s*[:\-]\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        // Strip wrapping quotes, Markdown emphasis/heading marks, and list bullets.
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#•-–— \t."))
        if t.count > 80 { t = String(t.prefix(80)) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
