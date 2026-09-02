import Foundation

/// Transcribes a diarized recording chunk by chunk, so each speaker turn gets its own
/// language detection. This handles meetings that switch between languages (e.g. EN → RU).
enum MultilingualTranscriber {
    struct Output {
        let blocks: [TranscriptBlock]
        let languages: [String]
    }

    struct AudioChunk {
        let speaker: String
        var start: Double
        var end: Double
        var duration: Double { end - start }
    }

    /// `allowedLanguages` (canonical order, empty = allow any) restricts which languages
    /// may appear. A chunk detected as a disallowed language is re-transcribed forcing the
    /// conversation's current language (or the first allowed one), which fixes whisper
    /// mis-detecting short/unclear chunks as e.g. French/Portuguese/Ukrainian.
    static func transcribe(
        wav: URL,
        speakers: [SpeakerSegment],
        model: URL,
        serverBinary: URL,
        allowedLanguages: [String] = [],
        initialPrompt: String? = nil,
        isCancelled: () -> Bool = { false },
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> Output {
        let silences = await PCMAnalysis.silences(in: wav)
        let chunks = makeChunks(speakers: speakers, silences: silences)
        guard !chunks.isEmpty else {
            throw CommandFailure(tool: "diarizer", status: 0, stderrTail: "No speech detected in the file.")
        }

        try await WhisperServer.shared.ensureRunning(model: model, serverBinary: serverBinary, initialPrompt: initialPrompt)

        var results: [ChunkResult] = []
        var lastLanguage: String?

        for (index, chunk) in chunks.enumerated() {
            if isCancelled() { break }

            // Extend extraction into the silence around the chunk: the diarizer often
            // clips quiet leading/trailing words. Never overlap neighbouring chunks.
            let previousEnd = index > 0 ? chunks[index - 1].end : 0
            let nextStart = index < chunks.count - 1 ? chunks[index + 1].start : Double.greatestFiniteMagnitude
            let maxLeft = index == 0 ? 3.0 : 0.6
            let leftPad = max(0.12, min(maxLeft, (chunk.start - previousEnd) / 2))
            let rightPad = max(0.12, min(index == chunks.count - 1 ? 1.0 : 0.6, (nextStart - chunk.end) / 2))
            let piece = try await PCMAnalysis.extract(
                from: wav,
                start: max(0, chunk.start - leftPad),
                end: chunk.end + rightPad,
                padding: 0
            )
            defer { try? FileManager.default.removeItem(at: piece) }

            // Only chunks too short to say anything ("угу", "yes") inherit the current
            // language — forcing a language on longer chunks makes whisper translate.
            let hint = chunk.duration < 0.8 ? lastLanguage : nil
            var response = try await WhisperServer.shared.transcribe(wav: piece, language: hint)
            var text = cleanChunkText(response.text)
            var chunkLanguage = hint ?? languageCode(response.language)

            // Enforce the language allow-list: if whisper auto-detected a language the
            // user didn't ask for, re-transcribe forcing the conversation's language.
            if hint == nil,
               !allowedLanguages.isEmpty,
               let detected = chunkLanguage,
               !allowedLanguages.contains(detected) {
                if let forced = lastLanguage ?? allowedLanguages.first {
                    response = try await WhisperServer.shared.transcribe(wav: piece, language: forced)
                    text = cleanChunkText(response.text)
                    chunkLanguage = forced
                }
            }

            if let chunkLanguage, !text.isEmpty {
                lastLanguage = chunkLanguage
            }
            results.append(ChunkResult(
                chunk: chunk,
                text: text,
                language: chunkLanguage,
                wasForced: hint != nil
            ))
            // Pass 1 is the bulk of the work; leave headroom for the cleanup pass.
            onProgress?(Double(index + 1) / Double(chunks.count) * 0.9)
        }

        // Pass 2: fix chunks whose detected language is almost certainly wrong.
        // Whisper mis-hears filler sounds ("Mm-hmm", "Yes", "Ага") as French/Polish/
        // Portuguese. Anything in a language with a negligible overall share is
        // re-transcribed in the conversation's dominant language — and so is a short chunk,
        // but ONLY when its own language is also a minor one overall. Without that guard, a
        // call that genuinely switches language for a long stretch (e.g. small talk in
        // Russian, then a formal conversation entirely in English) gets its short utterances
        // in that second language ("Okay", "Yeah", "Got it") flipped back into the first —
        // and since the audio really was English, forcing whisper to decode it as Russian
        // doesn't translate it, it hallucinates similar-sounding Russian words instead.
        if let dominant = dominantLanguage(in: results) {
            let spurious = spuriousLanguages(in: results, dominant: dominant)
            let counts = characterCounts(in: results)
            let total = counts.values.reduce(0, +)
            let suspects = results.indices.filter { index in
                let result = results[index]
                guard !result.wasForced, !result.text.isEmpty,
                      let language = result.language, language != dominant else { return false }
                if spurious.contains(language) { return true }
                guard result.text.count < shortTextThreshold, total > 0 else { return false }
                let share = Double(counts[language, default: 0]) / Double(total)
                return share < 0.10
            }
            for (offset, index) in suspects.enumerated() {
                if isCancelled() { break }
                let chunk = results[index].chunk
                let piece = try await PCMAnalysis.extract(
                    from: wav, start: chunk.start, end: chunk.end, padding: 0.12
                )
                defer { try? FileManager.default.removeItem(at: piece) }
                if let redone = try? await WhisperServer.shared.transcribe(wav: piece, language: dominant) {
                    let text = cleanChunkText(redone.text)
                    if !text.isEmpty {
                        results[index].text = text
                        results[index].language = dominant
                    }
                }
                onProgress?(0.9 + Double(offset + 1) / Double(suspects.count) * 0.1)
            }
        }
        onProgress?(1.0)

        // Build the final blocks, coalescing same-speaker/same-language runs.
        var blocks: [TranscriptBlock] = []
        var blockLanguages: [String?] = []
        var languageChars: [String: Int] = [:]
        for result in results where !result.text.isEmpty {
            if let language = result.language {
                languageChars[language, default: 0] += result.text.count
            }
            let chunk = result.chunk
            if var last = blocks.last,
               last.speaker == chunk.speaker,
               blockLanguages.last == result.language,
               chunk.start - last.end < 0.8,
               chunk.end - last.start < 30 {
                last.text += " " + result.text
                last.end = chunk.end
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(TranscriptBlock(
                    speaker: chunk.speaker, start: chunk.start, end: chunk.end, text: result.text
                ))
                blockLanguages.append(result.language)
            }
        }
        // Dominant language first — downstream (summaries) uses the first entry as the
        // language to write in.
        let languages = languageChars.sorted { $0.value > $1.value }.map(\.key)
        return Output(blocks: blocks, languages: languages)
    }

    // MARK: - Dominant-language heuristics

    struct ChunkResult {
        let chunk: AudioChunk
        var text: String
        var language: String?
        var wasForced: Bool
    }

    /// Chunks shorter than this are treated as filler and pinned to the dominant language.
    /// Measured on a real session: every false-positive language sat at ≤29 characters,
    /// while the median real block was 61.
    static let shortTextThreshold = 40

    /// The language holding the most transcribed text.
    static func dominantLanguage(in results: [ChunkResult]) -> String? {
        characterCounts(in: results).max { $0.value < $1.value }?.key
    }

    /// Languages with too little text to be real (a genuine second language in a meeting
    /// produces hundreds of characters; a mis-detection produces a handful).
    static func spuriousLanguages(
        in results: [ChunkResult],
        dominant: String,
        minCharacters: Int = 500,
        minShare: Double = 0.10
    ) -> Set<String> {
        let counts = characterCounts(in: results)
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return Set(counts.filter { language, count in
            language != dominant && count < minCharacters && Double(count) / Double(total) < minShare
        }.keys)
    }

    private static func characterCounts(in results: [ChunkResult]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for result in results where !result.text.isEmpty {
            guard let language = result.language, !result.wasForced else { continue }
            counts[language, default: 0] += result.text.count
        }
        return counts
    }

    // MARK: - Chunking

    /// Cuts diarization segments at detected silences (so a mid-turn language switch
    /// separated by a pause lands in its own chunk), keeps chunks within sane bounds.
    static func makeChunks(
        speakers: [SpeakerSegment],
        silences: [(start: Double, end: Double)],
        maxLength: Double = 20,
        minLength: Double = 1.2
    ) -> [AudioChunk] {
        let splitPoints = silences.map { ($0.start + $0.end) / 2 }.sorted()

        var chunks: [AudioChunk] = []
        for segment in speakers {
            var boundaries = [segment.start]
            boundaries += splitPoints.filter { $0 > segment.start + 0.3 && $0 < segment.end - 0.3 }
            boundaries.append(segment.end)

            var pieces = zip(boundaries, boundaries.dropFirst()).map {
                AudioChunk(speaker: segment.speaker, start: $0, end: $1)
            }

            // Merge fragments that are too short for reliable transcription.
            var merged: [AudioChunk] = []
            for piece in pieces {
                if var last = merged.last, last.duration < minLength || piece.duration < minLength {
                    last.end = piece.end
                    merged[merged.count - 1] = last
                } else {
                    merged.append(piece)
                }
            }
            pieces = merged

            // Split anything longer than whisper's window into equal parts.
            for piece in pieces {
                if piece.duration > maxLength {
                    let parts = Int(ceil(piece.duration / maxLength))
                    let step = piece.duration / Double(parts)
                    for i in 0..<parts {
                        chunks.append(AudioChunk(
                            speaker: piece.speaker,
                            start: piece.start + Double(i) * step,
                            end: i == parts - 1 ? piece.end : piece.start + Double(i + 1) * step
                        ))
                    }
                } else {
                    chunks.append(piece)
                }
            }
        }
        return chunks.sorted { $0.start < $1.start }
    }

    // MARK: - Helpers

    /// Drops whisper artifacts on silent/noisy chunks like "[BLANK_AUDIO]" or "(music)"
    /// and joins the server's per-segment lines into one flowing paragraph.
    static func cleanChunkText(_ raw: String) -> String {
        let text = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.range(of: #"^[\[\(][^\]\)]*[\]\)]$"#, options: .regularExpression) != nil {
            return ""
        }
        return text
    }

    /// whisper-server returns full language names ("english"); map to short codes.
    static func languageCode(_ name: String?) -> String? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        let map: [String: String] = [
            "english": "en", "russian": "ru", "ukrainian": "uk", "german": "de",
            "french": "fr", "spanish": "es", "italian": "it", "portuguese": "pt",
            "dutch": "nl", "polish": "pl", "turkish": "tr", "chinese": "zh",
            "japanese": "ja", "korean": "ko", "arabic": "ar", "hebrew": "he",
            "hindi": "hi", "czech": "cs", "swedish": "sv", "norwegian": "no",
            "danish": "da", "finnish": "fi", "greek": "el", "romanian": "ro",
            "hungarian": "hu", "bulgarian": "bg", "serbian": "sr", "croatian": "hr",
            "slovak": "sk", "lithuanian": "lt", "latvian": "lv", "estonian": "et",
            "belarusian": "be", "kazakh": "kk", "georgian": "ka", "armenian": "hy",
            "azerbaijani": "az", "uzbek": "uz", "vietnamese": "vi", "thai": "th",
            "indonesian": "id", "malay": "ms", "hebrew iw": "he",
        ]
        return map[name] ?? name
    }
}
