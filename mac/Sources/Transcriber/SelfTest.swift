import Foundation

/// Hidden CLI mode for end-to-end pipeline testing without the GUI:
///   Transcriber --selftest-diarize /path/to/audio
/// Runs convert → whisper (segments) → diarize → merge and prints the markdown body.
enum SelfTest {
    static func runIfRequested() {
        if CommandLine.arguments.contains("--selftest-history") {
            runHistory()
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-markdown") {
            runMarkdown()
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-heuristics") {
            runHeuristics()
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-library") {
            runLibrary()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--rename-batch"),
           CommandLine.arguments.count > index + 1 {
            runRenameBatch(jsonPath: CommandLine.arguments[index + 1])
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-meeting") {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached { await runMeeting(); semaphore.signal() }
            semaphore.wait()
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-meeting-live") {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached { await runMeetingLive(); semaphore.signal() }
            semaphore.wait()
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-mcp") {
            runMCP()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-llm-ab"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do { try await runLLMComparison(transcriptPath: path); print("SELFTEST OK") }
                catch { print("SELFTEST FAILED: \(error.localizedDescription)") }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-diarize-only"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do { try await runDiarizeOnly(path: path); print("SELFTEST OK") }
                catch { print("SELFTEST FAILED: \(error.localizedDescription)") }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-dualtrack"),
           CommandLine.arguments.count > index + 2 {
            let mic = CommandLine.arguments[index + 1]
            let system = CommandLine.arguments[index + 2]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do { try await runDualTrack(mic: mic, system: system); print("SELFTEST OK") }
                catch { print("SELFTEST FAILED: \(error.localizedDescription)") }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-mixrepair"),
           CommandLine.arguments.count > index + 2 {
            let transcript = CommandLine.arguments[index + 1]
            let audio = CommandLine.arguments[index + 2]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do { try await runMixRepair(transcript: transcript, audio: audio); print("SELFTEST OK") }
                catch { print("SELFTEST FAILED: \(error.localizedDescription)") }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        let modes = ["--selftest-diarize", "--selftest-multilingual"]
        guard let (mode, index) = modes
            .compactMap({ m in CommandLine.arguments.firstIndex(of: m).map { (m, $0) } })
            .first,
              CommandLine.arguments.count > index + 1 else { return }
        let path = CommandLine.arguments[index + 1]

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                if mode == "--selftest-multilingual" {
                    try await runMultilingual(path: path)
                } else {
                    try await run(path: path)
                }
                print("SELFTEST OK")
            } catch {
                print("SELFTEST FAILED: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func runDiarizeOnly(path: String) async throws {
        guard let ffmpeg = Tools.find("ffmpeg") else { throw RecorderError(message: "ffmpeg not found") }
        print("converting…")
        let wav = try await FFmpeg.convertToWav(input: URL(fileURLWithPath: path), ffmpeg: ffmpeg)
        defer { try? FileManager.default.removeItem(at: wav) }
        var threshold = Diarizer.defaultThreshold
        if let index = CommandLine.arguments.firstIndex(of: "--threshold"),
           CommandLine.arguments.count > index + 1,
           let value = Double(CommandLine.arguments[index + 1]) {
            threshold = value
        }
        print("diarizing… (threshold \(threshold))")
        let speakers = try await Diarizer.shared.diarize(wavURL: wav, threshold: threshold)
        let distinct = Set(speakers.map(\.speaker)).sorted()
        print("distinct speakers: \(distinct.count) -> \(distinct.joined(separator: ", "))")
        print("total segments: \(speakers.count)")

        let totalSpeech = speakers.reduce(0.0) { $0 + ($1.end - $1.start) }
        print("total speech: \(String(format: "%.1f", totalSpeech))s")
        for name in distinct {
            let mine = speakers.filter { $0.speaker == name }
            let duration = mine.reduce(0.0) { $0 + ($1.end - $1.start) }
            print(String(
                format: "  %@: %d segments, %.1fs (%.1f%% of speech)",
                name, mine.count, duration, duration / totalSpeech * 100
            ))
        }
        for segment in speakers.prefix(40) {
            print(String(format: "  %@  %6.1f – %6.1f  (%.1fs)", segment.speaker, segment.start, segment.end, segment.end - segment.start))
        }
    }

    /// A/B-compares the downloaded GGUF chat models on a real transcript: summarization
    /// quality/speed plus a few comprehension questions (the future "chat with your
    /// transcript" feature). Prints everything for human judging.
    private static func runLLMComparison(transcriptPath: String) async throws {
        let content = try String(contentsOf: URL(fileURLWithPath: transcriptPath), encoding: .utf8)
        let body = MarkdownWriter.transcriptBody(from: content)
        print("transcript: \(transcriptPath)")
        print("characters: \(body.count), declared languages: \(MarkdownWriter.declaredLanguages(from: content).joined(separator: ", "))\n")

        let questions = [
            "Какие конкретные задачи (action items) обсуждались и кто за них отвечает? Ответь списком.",
            "Что решили по поводу инфраструктуры Grazie и перехода на GCP?",
            "Сколько человек участвовало в разговоре и о чём была главная тревога участников?",
        ]

        let models = LLMModel.all.filter {
            FileManager.default.fileExists(atPath: ModelManager.modelsDirectory.appendingPathComponent($0.fileName).path)
        }
        guard !models.isEmpty else {
            throw RecorderError(message: "no GGUF models downloaded yet")
        }

        for model in models {
            let url = ModelManager.modelsDirectory.appendingPathComponent(model.fileName)
            print(String(repeating: "=", count: 70))
            print("MODEL: \(model.displayName)  (\(model.fileName))")
            print(String(repeating: "=", count: 70))

            var clock = ContinuousClock.now
            try await LlamaServer.shared.ensureRunning(model: url)
            print("[load: \(elapsed(since: clock))]\n")

            // 1. Summarization with the default prompt.
            clock = .now
            do {
                let languageName = MarkdownWriter.declaredLanguages(from: content).first
                    .map { Summarizer.languageName($0) }
                let summary = try await Summarizer.summarizeWithLocalModel(
                    transcriptBody: body, model: url, languageName: languageName
                )
                print("--- SUMMARY (default prompt) [\(elapsed(since: clock))] ---")
                print(summary)
            } catch {
                print("--- SUMMARY FAILED: \(error.localizedDescription)")
            }

            // 2. Custom prompt, to prove the setting works.
            clock = .now
            do {
                let custom = try await Summarizer.summarizeWithLocalModel(
                    transcriptBody: body,
                    model: url,
                    customPrompt: "Опиши в трёх пунктах только принятые решения. Пиши по-русски, без вступлений."
                )
                print("\n--- SUMMARY (custom Russian prompt) [\(elapsed(since: clock))] ---")
                print(custom)
            } catch {
                print("\n--- CUSTOM PROMPT FAILED: \(error.localizedDescription)")
            }

            // 3. Q&A — the chat-with-transcript use case.
            for question in questions {
                clock = .now
                do {
                    let answer = try await LlamaServer.shared.complete(
                        system: "Ты отвечаешь на вопросы по стенограмме встречи. Отвечай только на основе текста, "
                            + "не придумывай. Отвечай на языке вопроса, кратко.",
                        user: "Стенограмма:\n\n\(body)\n\nВопрос: \(question)",
                        maxTokens: 500
                    )
                    print("\n--- Q: \(question) [\(elapsed(since: clock))]")
                    print("A: \(answer)")
                } catch {
                    print("\n--- Q FAILED: \(error.localizedDescription)")
                }
            }
            await LlamaServer.shared.stop()
            print("")
        }
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> String {
        let seconds = Double((ContinuousClock.now - start).components.seconds)
        return String(format: "%.1fs", seconds)
    }

    /// Validates the phantom-speaker and dominant-language heuristics against the real
    /// measured shapes of the therapy session and the 4-person meeting.
    private static func runHeuristics() {
        var failures: [String] = []

        // --- Phantom speaker: therapy session shape (68.9% / 0.5% / 30.7%) ---
        var therapy: [Diarizer.RawSegment] = []
        var t = 0.0
        for i in 0..<200 {                                  // Speaker A, ~1375s
            therapy.append(.init(speakerKey: "A", start: t, end: t + 6.9)); t += 8
            if i == 100 {                                    // phantom, 5 segments ~9s
                for _ in 0..<5 {
                    therapy.append(.init(speakerKey: "PHANTOM", start: t, end: t + 1.8)); t += 3
                }
            }
            if i % 2 == 0 {                                  // Speaker B, ~612s
                therapy.append(.init(speakerKey: "B", start: t, end: t + 6.1)); t += 7
            }
        }
        let therapyCleaned = Diarizer.mergePhantomSpeakers(therapy)
        let therapySpeakers = Set(therapyCleaned.map(\.speakerKey))
        if therapySpeakers.contains("PHANTOM") || therapySpeakers.count != 2 {
            failures.append("phantom not merged: \(therapySpeakers.sorted())")
        }

        // --- Real quiet speaker (7.4% / 140s) must survive ---
        var meeting: [Diarizer.RawSegment] = []
        t = 0
        for i in 0..<100 {
            meeting.append(.init(speakerKey: "A", start: t, end: t + 5.7)); t += 7
            meeting.append(.init(speakerKey: "B", start: t, end: t + 7.9)); t += 9
            if i % 3 == 0 {                                  // quiet but real: ~31 segs, 140s
                meeting.append(.init(speakerKey: "QUIET", start: t, end: t + 4.5)); t += 6
            }
            if i % 2 == 0 {
                meeting.append(.init(speakerKey: "D", start: t, end: t + 4.1)); t += 5
            }
        }
        let meetingCleaned = Diarizer.mergePhantomSpeakers(meeting)
        if !Set(meetingCleaned.map(\.speakerKey)).contains("QUIET") {
            failures.append("real quiet speaker was wrongly merged")
        }

        // --- Dominant language: ru dominant, tiny fr/pl/pt junk, real en section ---
        func chunk(_ start: Double) -> MultilingualTranscriber.AudioChunk {
            .init(speaker: "Speaker 1", start: start, end: start + 3)
        }
        var results: [MultilingualTranscriber.ChunkResult] = []
        for i in 0..<60 {                                    // Russian: plenty of text
            results.append(.init(chunk: chunk(Double(i) * 4),
                                 text: String(repeating: "русский текст ", count: 6),
                                 language: "ru", wasForced: false))
        }
        for (i, junk) in ["Mm-hmm.", "Au revoir.", "Czytamy teraz", "Com o que é?"].enumerated() {
            results.append(.init(chunk: chunk(300 + Double(i) * 4), text: junk,
                                 language: ["fr", "fr", "pl", "pt"][i], wasForced: false))
        }
        for i in 0..<8 {                                     // a genuine English stretch
            results.append(.init(chunk: chunk(400 + Double(i) * 4),
                                 text: String(repeating: "this is a real english sentence ", count: 3),
                                 language: "en", wasForced: false))
        }
        guard let dominant = MultilingualTranscriber.dominantLanguage(in: results) else {
            print("SELFTEST FAILED: no dominant language"); return
        }
        if dominant != "ru" { failures.append("dominant should be ru, got \(dominant)") }
        let spurious = MultilingualTranscriber.spuriousLanguages(in: results, dominant: dominant)
        if !spurious.isSuperset(of: ["fr", "pl", "pt"]) {
            failures.append("fr/pl/pt should be spurious, got \(spurious.sorted())")
        }
        if spurious.contains("en") {
            failures.append("a real English section was wrongly flagged spurious")
        }

        // A capture that dies mid-recording must be reported, not silently padded.
        if AudioRecorder.trackMismatch(micSeconds: 3600, systemSeconds: 3598) != nil {
            failures.append("matching track lengths should not warn")
        }
        guard let died = AudioRecorder.trackMismatch(micSeconds: 1930, systemSeconds: 4026) else {
            failures.append("a mic that stopped 35 minutes early must warn")
            return failures.forEach { print("SELFTEST FAILED: \($0)") }
        }
        if !died.contains("microphone") || !died.contains("32:10") || !died.contains("1:07:06") {
            failures.append("mismatch message should name the dead track and both times: \(died)")
        }
        if AudioRecorder.trackMismatch(micSeconds: 4026, systemSeconds: 1930)?.contains("system audio stopped") != true {
            failures.append("the reverse case should blame system audio")
        }
        if AudioRecorder.trackMismatch(micSeconds: 0, systemSeconds: 1000) == nil {
            failures.append("a completely silent mic must warn")
        }

        // Dual-track attribution: two single-speaker tracks merge onto one timeline by start,
        // keeping overlaps (both talking at once) as separate blocks rather than dropping one.
        let micBlocks = [
            TranscriptBlock(speaker: "Speaker 1", start: 0, end: 2, text: "hi there"),
            TranscriptBlock(speaker: "Speaker 1", start: 5, end: 7, text: "still me"),
        ]
        let systemBlocks = [
            TranscriptBlock(speaker: "Speaker 2", start: 1.5, end: 3, text: "overlap"),
            TranscriptBlock(speaker: "Speaker 2", start: 8, end: 9, text: "far side"),
        ]
        let mergedTracks = DualTrackTranscriber.mergeByTimeline(micBlocks, systemBlocks)
        if mergedTracks.count != 4 { failures.append("merge must keep all blocks incl. overlap, got \(mergedTracks.count)") }
        if mergedTracks.map(\.start) != [0, 1.5, 5, 8] {
            failures.append("merged blocks must be ordered by start: \(mergedTracks.map(\.start))")
        }
        // The bigger-text side's languages come first (dominant language leads the frontmatter).
        let langs = DualTrackTranscriber.mergeLanguages(
            mic: [TranscriptBlock(speaker: "Speaker 1", start: 0, end: 1, text: String(repeating: "a", count: 100))],
            micLangs: ["ru", "de"],
            system: [TranscriptBlock(speaker: "Speaker 2", start: 0, end: 1, text: "short")],
            systemLangs: ["en", "de"]
        )
        if langs != ["ru", "de", "en"] {
            failures.append("merged languages should union with the dominant side first: \(langs)")
        }

        // Mixed-language repair: splice re-transcribed native text back into a block, keeping
        // whisper's own spacing for untouched words.
        let repairWords = [
            WhisperServer.Word(text: " Итак", start: 0, end: 0.5),
            WhisperServer.Word(text: " это", start: 0.5, end: 0.8),
            WhisperServer.Word(text: " натюрлих", start: 0.8, end: 1.4),   // transliterated "natürlich"
            WhisperServer.Word(text: " хорошо", start: 1.4, end: 2.0),
        ]
        let repaired = MixedLanguageRepair.rebuild(
            words: repairWords,
            spans: [MixedLanguageRepair.Span(from: 2, to: 2, language: "de")],
            replacements: ["natürlich"]
        )
        if repaired != "Итак это natürlich хорошо" {
            failures.append("repair should splice the native word in place: \(repaired)")
        }
        // No spans → the text is rebuilt verbatim from the words.
        if MixedLanguageRepair.rebuild(words: repairWords, spans: [], replacements: []) != "Итак это натюрлих хорошо" {
            failures.append("repair with no spans must reproduce the original words")
        }
        // validSpans drops out-of-range, inverted, and overlapping spans; keeps ordered ones.
        let cleaned = MixedLanguageRepair.validSpans(
            locateSpans: [
                .init(from: 5, to: 5, language: "de"),   // out of range
                .init(from: 3, to: 1, language: "de"),   // inverted
                .init(from: 0, to: 1, language: "de"),   // valid
                .init(from: 1, to: 2, language: "de"),   // overlaps the previous
                .init(from: 2, to: 3, language: ""),     // blank language
            ],
            wordCount: 4
        )
        if cleaned != [MixedLanguageRepair.Span(from: 0, to: 1, language: "de")] {
            failures.append("validSpans must keep only in-range, ordered, non-overlapping spans: \(cleaned)")
        }
        // Timestamp label parsing (block start → seconds).
        if MixedLanguageRepair.seconds(fromLabel: "02:36") != 156 { failures.append("02:36 must parse to 156s") }
        if MixedLanguageRepair.seconds(fromLabel: "1:02:36") != 3756 { failures.append("1:02:36 must parse to 3756s") }
        if MixedLanguageRepair.seconds(fromLabel: "nope") != nil { failures.append("a malformed time must parse to nil") }
        // The frontmatter marker is inserted once, before the closing '---', and refreshed not duplicated.
        let stamped = MixedLanguageRepair.withRepairMarker("---\nlanguage: ru, de\n---\n\nbody")
        if !stamped.contains("mixed_language_repair: applied\n---") {
            failures.append("repair marker must be stamped inside the frontmatter: \(stamped)")
        }
        if MixedLanguageRepair.withRepairMarker(stamped).components(separatedBy: "mixed_language_repair:").count != 2 {
            failures.append("re-stamping must not duplicate the repair marker")
        }

        // Deciding the final file from what actually got captured. An empty track must never
        // become the recording — that is the header-only ".m4a" that failed with "moov atom not
        // found" on a fresh machine where the microphone delivered no frames.
        let finalCases: [(Double, Double, AudioRecorder.FinalSource)] = [
            (120, 118, .mixBoth),     // both sides captured → mix
            (120, 0, .micOnly),       // mic-only recording
            (0, 120, .systemOnly),    // dead mic, but the call audio survives on the system track
            (0, 0, .empty),           // nothing at all → must be rejected, not sent to ffmpeg
            (0.05, 0, .empty),        // a few stray frames still counts as nothing
        ]
        for (mic, sys, want) in finalCases {
            let got = AudioRecorder.chooseFinal(micSeconds: mic, systemSeconds: sys)
            if got != want {
                failures.append("chooseFinal(mic:\(mic), sys:\(sys)) = \(got), want \(want)")
            }
        }

        // Empty/corrupt input must read as "no audio", not as a raw ffmpeg tool error.
        if !FFmpeg.looksEmpty("[mov,mp4,m4a,3gp,3g2,mj2 @ 0x600] moov atom not found") {
            failures.append("\"moov atom not found\" must be recognised as an empty file")
        }
        if FFmpeg.looksEmpty("Error while decoding stream #0:0: Invalid argument") {
            failures.append("a genuine decode error must not be treated as an empty file")
        }

        // ffmpeg progress parsing drives the "Saving recording…" bar.
        let progressCases: [(String, Double?)] = [
            ("out_time=00:01:23.450000", 83.45),           // -progress pipe:2
            ("frame=1 fps=0 time=01:00:05.00 bitrate=1", 3605),  // default stats line
            ("out_time_us=83450000", nil),                 // must not be misread as seconds
            ("progress=continue", nil),
        ]
        for (line, expected) in progressCases {
            let parsed = AudioRecorder.progressSeconds(in: line)
            guard let expected else {
                if parsed != nil { failures.append("progressSeconds should ignore \"\(line)\", got \(parsed!)") }
                continue
            }
            if parsed == nil || abs(parsed! - expected) > 0.01 {
                failures.append("progressSeconds(\"\(line)\") = \(parsed as Any), want \(expected)")
            }
        }

        // Paragraph merging. A real 2:16 voice message came out as 13 repeated
        // "**Speaker 1**" headers because ordinary pauses broke the turn apart.
        let oneSpeaker = [SpeakerSegment(speaker: "Speaker 1", start: 0, end: 140)]
        let fragmented = (0..<13).map { index in
            WhisperSegment(
                start: Double(index) * 10,
                end: Double(index) * 10 + 8,   // 2 s pause between each
                text: "Fragment \(index) with no final punctuation"
            )
        }
        let merged = TranscriptMerger.merge(whisper: fragmented, speakers: oneSpeaker)
        if merged.count > 2 {
            failures.append("13 fragments of one turn should merge into 1–2 blocks, got \(merged.count)")
        }
        if merged.first?.start != 0 {
            failures.append("a merged block must keep the first segment's timestamp")
        }

        // A real pause must still start a new block, or distinct turns run together.
        let separated = [
            WhisperSegment(start: 0, end: 5, text: "First turn."),
            WhisperSegment(start: 30, end: 35, text: "Much later turn."),
        ]
        if TranscriptMerger.merge(whisper: separated, speakers: oneSpeaker).count != 2 {
            failures.append("a 25 s gap must not be merged into one block")
        }

        // A different speaker always breaks the block, however small the gap.
        let twoSpeakers = [
            SpeakerSegment(speaker: "Speaker 1", start: 0, end: 6),
            SpeakerSegment(speaker: "Speaker 2", start: 6, end: 12),
        ]
        let handover = [
            WhisperSegment(start: 0, end: 5, text: "Question?"),
            WhisperSegment(start: 5.2, end: 11, text: "Answer."),
        ]
        let split = TranscriptMerger.merge(whisper: handover, speakers: twoSpeakers)
        if split.count != 2 || split.first?.speaker == split.last?.speaker {
            failures.append("a speaker change must split the block even with a 0.2 s gap")
        }

        // Long turns keep absorbing until a sentence ends, so no block splits mid-sentence.
        if !TranscriptMerger.endsSentence("Done.") || TranscriptMerger.endsSentence("trailing off") {
            failures.append("endsSentence misclassified sentence boundaries")
        }

        // Accuracy flags. VAD is what stops whisper writing sentences into silence, so a
        // regression here silently reintroduces fabricated text.
        let vadURL = URL(fileURLWithPath: "/tmp/ggml-silero.bin")
        let withVAD = Whisper.accuracyArguments(vadModel: vadURL, initialPrompt: nil)
        if !withVAD.contains("--vad") || !withVAD.contains(vadURL.path) {
            failures.append("VAD flags missing: \(withVAD)")
        }
        // Context-carry is always disabled (`-mc 0`) to avoid the repetition-loop collapse; with
        // no VAD model and no vocabulary those are the only flags accuracyArguments should add.
        let bare = Whisper.accuracyArguments(vadModel: nil, initialPrompt: nil)
        if bare != ["-mc", "0"] {
            failures.append("bare args should be exactly -mc 0, got \(bare)")
        }
        let withVocab = Whisper.accuracyArguments(vadModel: nil, initialPrompt: "NIE, TIE, arraigo")
        guard let promptIndex = withVocab.firstIndex(of: "--prompt"),
              withVocab.indices.contains(promptIndex + 1),
              withVocab[promptIndex + 1] == "NIE, TIE, arraigo" else {
            failures.append("vocabulary must be passed as a single --prompt argument: \(withVocab)")
            failures.forEach { print("SELFTEST FAILED: \($0)") }
            return
        }
        if !withVocab.contains("--carry-initial-prompt") {
            failures.append("vocabulary bias must be carried across windows")
        }
        // Whitespace-only vocabulary must not become a --prompt with an empty value.
        if Whisper.accuracyArguments(vadModel: nil, initialPrompt: "   \n ") != ["-mc", "0"] {
            failures.append("blank vocabulary should add no --prompt flag")
        }

        if failures.isEmpty {
            print("SELFTEST OK")
        } else {
            failures.forEach { print("SELFTEST FAILED: \($0)") }
        }
    }

    /// Drives the MCP server end to end (initialize → tools/list → every tool → resources)
    /// against a fixture folder, so nothing touches the real transcripts or job queue.
    private static func runMCP() {
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-mcp-test-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox")
        defer { try? FileManager.default.removeItem(at: root) }

        let sync = """
        ---
        source: "Team sync.m4a"
        source_path: "\(root.path)/Team sync.m4a"
        type: audio
        duration: "12:34"
        transcribed: 2026-07-28T10:00:00Z
        model: whisper-large-v3-turbo
        language: ru, en
        speakers: ["Speaker 1", "Speaker 2"]
        diarized: true
        ---

        # Team sync 2026-07-28

        \(MarkdownWriter.summaryStart)
        ## Summary
        Обсудили миграцию и дедлайн.
        \(MarkdownWriter.summaryEnd)

        **Speaker 1**
        00:00
        Давай обсудим миграцию на GCP.

        **Speaker 2**
        01:15
        Дедлайн — конец года, флюгегехаймен подтверждён.
        """
        let note = """
        ---
        source: "note.ogg"
        type: audio
        language: en
        ---

        # Voice note from Alex

        Remember to send the flügegeheimen invoice.
        """

        // Padding so pagination has something to paginate.
        let filler = (1...40).map {
            "**Speaker 1**\n\(String(format: "%02d:%02d", $0 / 4, $0 % 60))\nблок номер \($0), немного текста для объёма"
        }.joined(separator: "\n\n")

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try (sync + "\n\n" + filler)
                .write(to: root.appendingPathComponent("Team sync 2026-07-28.md"), atomically: true, encoding: .utf8)
            try note.write(to: root.appendingPathComponent("Voice note from Alex.md"), atomically: true, encoding: .utf8)
            // A plausible media file for transcribe_file to accept.
            try Data("fake".utf8).write(to: root.appendingPathComponent("Team sync.m4a"))
        } catch {
            print("SELFTEST FAILED: fixtures: \(error.localizedDescription)"); return
        }

        let suite = UserDefaults(suiteName: "transcriber-selftest-mcp")!
        suite.set(root.path, forKey: "recordingsFolderPath")
        suite.set("alongside", forKey: "outputMode")
        MCPServer.defaults = suite
        Inbox.folderOverride = inbox
        // Isolate from the real history and library so the fixtures are the only transcripts.
        TranscriptIndex.historyURLOverride = root.appendingPathComponent("history.json")
        TranscriptIndex.libraryRootOverride = root.appendingPathComponent("empty-library")
        defer { TranscriptIndex.libraryRootOverride = nil }

        func call(_ tool: String, _ arguments: [String: Any] = [:]) -> (text: String, isError: Bool) {
            let reply = MCPServer.response(for: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool, "arguments": arguments],
            ])
            guard let result = reply?["result"] as? [String: Any],
                  let content = result["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String
            else { return ("<no content>", true) }
            return (text, result["isError"] as? Bool ?? false)
        }

        // initialize: unknown versions fall back to ours, known ones are echoed.
        let initReply = MCPServer.response(for: [
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": ["protocolVersion": "2024-11-05"],
        ])
        let initResult = initReply?["result"] as? [String: Any]
        if initResult?["protocolVersion"] as? String != "2024-11-05" {
            failures.append("initialize should echo a supported protocol version")
        }
        if (initResult?["serverInfo"] as? [String: Any])?["name"] as? String != "transcriber" {
            failures.append("initialize serverInfo missing")
        }
        if MCPServer.response(for: ["jsonrpc": "2.0", "method": "notifications/initialized"]) != nil {
            failures.append("notifications must not get a reply")
        }
        let unknown = MCPServer.response(for: ["jsonrpc": "2.0", "id": 9, "method": "nope/nope"])
        if unknown?["error"] as? [String: Any] == nil {
            failures.append("unknown methods should return a JSON-RPC error")
        }

        // tools/list
        let toolsReply = MCPServer.response(for: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = ((toolsReply?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let toolNames = Set(tools.compactMap { $0["name"] as? String })
        let expected: Set<String> = [
            "list_transcripts", "search_transcripts", "get_transcript",
            "get_summary", "transcribe_file", "get_jobs",
        ]
        if !toolNames.isSuperset(of: expected) {
            failures.append("tools/list missing \(expected.subtracting(toolNames).sorted())")
        }
        // Everything must survive JSON encoding — a bad schema breaks the whole handshake.
        if !JSONSerialization.isValidJSONObject(["tools": tools]) {
            failures.append("tool definitions are not JSON-serializable")
        }

        let list = call("list_transcripts")
        if !list.text.contains("Team sync 2026-07-28") || !list.text.contains("Voice note from Alex") {
            failures.append("list_transcripts didn't return both fixtures")
        }
        if !list.text.contains("has_summary") || !list.text.contains("12:34") {
            failures.append("list_transcripts lost frontmatter metadata")
        }

        let filtered = call("list_transcripts", ["query": "флюгегехаймен"])
        if !filtered.text.contains("Team sync") || filtered.text.contains("Voice note") {
            failures.append("list_transcripts query filter is wrong")
        }

        // Search: accent-insensitive, and it reports the speaker turn it hit.
        let search = call("search_transcripts", ["query": "flugegeheimen"])
        if !search.text.contains("Voice note from Alex") {
            failures.append("search should fold accents (flügegeheimen)")
        }
        let searchTimed = call("search_transcripts", ["query": "Дедлайн"])
        if !searchTimed.text.contains("01:15") || !searchTimed.text.contains("Speaker 2") {
            failures.append("search should report speaker and timestamp: \(searchTimed.text)")
        }
        if !call("search_transcripts", ["query": "нетакогослова"]).text.contains("No transcript") {
            failures.append("empty search should say so")
        }
        if !call("search_transcripts").isError {
            failures.append("search without a query should be an error")
        }

        // get_transcript by partial title, with the summary and pagination.
        let full = call("get_transcript", ["title": "team sync"])
        if !full.text.contains("Давай обсудим миграцию") || !full.text.contains("Обсудили миграцию")
            || !full.text.contains("Speakers: Speaker 1, Speaker 2") {
            failures.append("get_transcript content: \(full.text)")
        }
        if full.text.contains("source_path:") {
            failures.append("get_transcript should not leak raw frontmatter")
        }
        let paged = call("get_transcript", ["title": "team sync", "max_characters": 600])
        if !paged.text.contains("Truncated") || !paged.text.contains("offset=") {
            failures.append("get_transcript should paginate long bodies")
        }
        let secondPage = call("get_transcript", ["title": "team sync", "max_characters": 600, "offset": 600])
        if secondPage.text.contains("Давай обсудим миграцию") {
            failures.append("get_transcript ignored the offset")
        }
        if !call("get_transcript", ["title": "does not exist"]).isError {
            failures.append("get_transcript on a miss should be an error")
        }
        if !call("get_transcript", ["title": "e"]).text.contains("transcripts match") {
            failures.append("ambiguous titles should list candidates")
        }

        let summary = call("get_summary", ["title": "team sync"])
        if !summary.text.contains("Обсудили миграцию") { failures.append("get_summary: \(summary.text)") }
        if !call("get_summary", ["title": "Voice note"]).text.contains("no stored summary") {
            failures.append("get_summary should explain a missing summary")
        }

        // transcribe_file: validates input, then queues via the inbox.
        if !call("transcribe_file", ["path": "/nope/nope.m4a"]).isError {
            failures.append("transcribe_file should reject a missing file")
        }
        if !call("transcribe_file", ["path": root.appendingPathComponent("Team sync 2026-07-28.md").path]).isError {
            failures.append("transcribe_file should reject a non-media file")
        }
        let queued = call("transcribe_file", ["path": root.appendingPathComponent("Team sync.m4a").path])
        if queued.isError { failures.append("transcribe_file rejected a valid file: \(queued.text)") }
        let drained = Inbox.drain()
        if drained.count != 1 || drained.first?.lastPathComponent != "Team sync.m4a" {
            failures.append("inbox roundtrip returned \(drained.map { $0.lastPathComponent })")
        }
        if !Inbox.drain().isEmpty {
            failures.append("inbox requests must be consumed exactly once")
        }

        if call("get_jobs").text.isEmpty { failures.append("get_jobs returned nothing") }
        if !call("no_such_tool").isError { failures.append("unknown tool should be an error") }

        // Resources mirror the same index.
        let resourcesReply = MCPServer.response(for: ["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        let resources = ((resourcesReply?["result"] as? [String: Any])?["resources"] as? [[String: Any]]) ?? []
        if let uri = resources.first(where: { ($0["name"] as? String) == "Team sync 2026-07-28" })?["uri"] as? String {
            let readReply = MCPServer.response(for: [
                "jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": ["uri": uri],
            ])
            let contents = ((readReply?["result"] as? [String: Any])?["contents"] as? [[String: Any]]) ?? []
            if (contents.first?["text"] as? String)?.contains("Давай обсудим") != true {
                failures.append("resources/read didn't return the file")
            }
        } else {
            failures.append("resources/list is missing the fixture")
        }
        let badRead = MCPServer.response(for: [
            "jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": ["uri": "file:///nope.md"],
        ])
        if badRead?["error"] as? [String: Any] == nil {
            failures.append("resources/read on a missing file should error")
        }

        suite.removePersistentDomain(forName: "transcriber-selftest-mcp")
        if failures.isEmpty {
            print("SELFTEST OK")
        } else {
            failures.forEach { print("SELFTEST FAILED: \($0)") }
        }
    }

    /// Exercises the managed library end to end in a temp dir: ingest copies files in, projects
    /// group and re-parent items, delete removes only the library copy, export writes a copy out,
    /// and migration is one-shot. No UI, no shared state.
    private static func runLibrary() {
        var failures: [String] = []
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-library-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // A source transcript + audio sitting "outside" the library.
        let external = sandbox.appendingPathComponent("external")
        try? FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let sourceMD = external.appendingPathComponent("Client call.md")
        let sourceAudio = external.appendingPathComponent("Client call.m4a")
        let fixture = """
        ---
        source: "Client call.m4a"
        type: audio
        duration: "44:42"
        transcribed: 2026-08-03T14:22:28Z
        model: whisper-large-v3-turbo
        language: ru, en
        speakers: ["Speaker 1", "Speaker 2"]
        recording_warning: "The microphone stopped after 32:10."
        diarized: true
        ---

        # Client call

        **Speaker 1**
        00:00
        Здравствуйте.
        """
        try? fixture.write(to: sourceMD, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: sourceAudio.path, contents: Data("fake-audio".utf8))

        let store = LibraryStore(root: sandbox.appendingPathComponent("Library"))

        // Ingest copies both files in; originals stay put; metadata is denormalised.
        guard let item = try? store.ingest(transcriptURL: sourceMD, audioURL: sourceAudio) else {
            print("SELFTEST FAILED: ingest threw"); return
        }
        if !FileManager.default.fileExists(atPath: sourceMD.path) {
            failures.append("ingest must not remove the original transcript")
        }
        if store.audioURL(for: item) == nil {
            failures.append("audio was not copied into the library")
        }
        if item.durationSeconds != 2682 {
            failures.append("duration not parsed from frontmatter: \(String(describing: item.durationSeconds))")
        }
        if item.speakers.count != 2 { failures.append("speakers not denormalised: \(item.speakers)") }
        if item.recordingWarning == nil { failures.append("recording_warning not captured") }
        if item.projectID != nil { failures.append("a fresh item should be Unsorted (nil project)") }

        // Projects: create, assign, and verify filtering.
        let project = store.createProject(name: "Immigration — Ivanov", notes: "Spain residency")
        store.move(item.id, to: project.id)
        if store.items(in: project.id).count != 1 { failures.append("item did not move into the project") }
        if !store.items(in: nil).isEmpty { failures.append("Unsorted should be empty after the move") }

        // Deleting a project re-parents its items to Unsorted (never loses them).
        store.deleteProject(project.id)
        if store.items(in: nil).count != 1 { failures.append("deleting a project must re-home its items to Unsorted") }
        if !store.projects.isEmpty { failures.append("project was not removed") }

        // Rename moves the file on disk (so search / MCP, which title by filename, stay in sync)
        // and updates the record.
        if !store.rename(item.id, to: "Ivanov — first call") { failures.append("rename returned false") }
        if let renamed = store.items.first {
            if renamed.title != "Ivanov — first call" { failures.append("title rename did not persist") }
            if renamed.transcriptFile != "Ivanov — first call.md" {
                failures.append("rename did not move the transcript file: \(renamed.transcriptFile)")
            }
            if !FileManager.default.fileExists(atPath: store.transcriptURL(for: renamed).path) {
                failures.append("renamed transcript file is missing on disk")
            }
            if let audio = store.audioURL(for: renamed), !FileManager.default.fileExists(atPath: audio.path) {
                failures.append("renamed audio file is missing on disk")
            }
        } else {
            failures.append("item vanished after rename")
        }

        // Export writes a copy out to a chosen name; the library copy remains.
        let downloads = sandbox.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let exported = downloads.appendingPathComponent("Ivanov call.md")
        do {
            try store.export(item.id, kind: .transcript, to: exported)
            if !FileManager.default.fileExists(atPath: exported.path) {
                failures.append("export reported success but wrote nothing")
            }
        } catch {
            failures.append("export threw: \(error)")
        }

        // Persistence: a fresh store over the same root sees the same item.
        let reopened = LibraryStore(root: sandbox.appendingPathComponent("Library"))
        if reopened.items.count != 1 { failures.append("index did not persist across reopen") }

        // Delete removes the library copy but never the user's original.
        let libraryCopy = store.transcriptURL(for: item)
        store.deleteItem(item.id)
        if FileManager.default.fileExists(atPath: libraryCopy.path) {
            failures.append("delete left the library copy on disk")
        }
        if !FileManager.default.fileExists(atPath: sourceMD.path) {
            failures.append("delete must never touch the user's original file")
        }
        if !store.items.isEmpty { failures.append("item not removed from the index") }

        // Migration is one-shot: a second call imports nothing more.
        let migrateStore = LibraryStore(root: sandbox.appendingPathComponent("Library2"))
        migrateStore.migrateIfNeeded(transcriptPaths: [sourceMD]) { _ in sourceAudio }
        let afterFirst = migrateStore.items.count
        migrateStore.migrateIfNeeded(transcriptPaths: [sourceMD]) { _ in sourceAudio }
        if afterFirst != 1 { failures.append("migration should import exactly one item, got \(afterFirst)") }
        if migrateStore.items.count != afterFirst { failures.append("migration ran twice — not idempotent") }

        if failures.isEmpty {
            print("SELFTEST OK")
        } else {
            failures.forEach { print("SELFTEST FAILED: \($0)") }
        }
    }

    /// Maintenance hook: bulk-rename existing library items from a JSON file of
    /// `[{"id": "<uuid>", "title": "<new title>"}]`. Drives the same LibraryStore.rename the UI
    /// uses, so the .md/audio files move, the H1 is rewritten, and library.json stays consistent.
    private static func runRenameBatch(jsonPath: String) {
        struct Entry: Decodable { let id: String; let title: String }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            print("RENAME FAILED: could not read \(jsonPath)")
            return
        }
        let store = LibraryStore()
        var ok = 0
        for entry in entries {
            guard let id = UUID(uuidString: entry.id) else {
                print("SKIP: bad uuid \(entry.id)"); continue
            }
            if store.rename(id, to: entry.title) {
                ok += 1
                print("RENAMED \(entry.id.prefix(8)) -> \(entry.title)")
            } else {
                print("FAILED  \(entry.id.prefix(8)) (not found or move failed)")
            }
        }
        print("RENAME DONE: \(ok)/\(entries.count)")
    }

    /// Meeting-end detection logic: URL matching, the debounce state machine, and the browser /
    /// audio detectors driven through injected inputs (no real AppleScript or audio).
    private static func runMeeting() async {
        var failures: [String] = []
        func key(_ s: String) -> String? { MeetingURL.match(s)?.key }

        // URL recognition.
        if key("https://meet.google.com/abc-defg-hij") != "meet:abc-defg-hij" {
            failures.append("Google Meet code not matched")
        }
        if key("https://meet.google.com/") != nil { failures.append("Meet home page should not match") }
        if key("https://mail.google.com/mail/u/0/#inbox") != nil { failures.append("Gmail should not match") }
        if MeetingURL.match("https://teams.microsoft.com/l/meetup-join/19:meeting_ab12cd@thread.v2/0")?.platform != "teams" {
            failures.append("Teams meeting not matched")
        }
        if key("https://us02web.zoom.us/wc/1234567890/join") != "zoom:1234567890" {
            failures.append("Zoom web client not matched")
        }
        if key("https://example.com/foo") != nil { failures.append("a non-meeting URL matched") }
        let set = MeetingURL.meetings(in: ["https://meet.google.com/abc-defg-hij", "https://github.com/x"])
        if set != ["meet:abc-defg-hij"] { failures.append("meetings(in:) wrong: \(set)") }

        // Debounce state machine.
        let decider = MeetingEndDecider(endedPollsRequired: 3)
        _ = decider.accept(.active)
        if decider.accept(.ended) || decider.accept(.ended) { failures.append("decider fired before the debounce") }
        if !decider.accept(.ended) { failures.append("decider should fire on the 3rd consecutive ended") }

        let neverActive = MeetingEndDecider(endedPollsRequired: 1)
        if neverActive.accept(.ended) { failures.append("decider must not fire before a meeting was ever active") }

        let resets = MeetingEndDecider(endedPollsRequired: 2)
        _ = resets.accept(.active); _ = resets.accept(.ended); _ = resets.accept(.active)
        if resets.accept(.ended) { failures.append("an active reading should reset the ended counter") }
        if !resets.accept(.ended) { failures.append("decider should fire after reset + 2 ended") }

        // Browser detector: recording often starts BEFORE the meeting opens, so it must keep
        // scanning — unknown while nothing is open, lock on when a meeting appears, ended when
        // it goes away. (This is the exact flow that failed in the field.)
        var tabs = ["https://github.com"]
        let browser = BrowserMeetingDetector(tabs: { tabs })
        _ = await browser.begin()
        if await browser.poll() != .unknown { failures.append("no meeting yet should read unknown") }
        tabs = ["https://meet.google.com/abc-defg-hij", "https://github.com"]   // meeting starts later
        if await browser.poll() != .active { failures.append("browser should lock on once a meeting appears") }
        tabs = ["https://github.com"]   // left and closed the tab
        if await browser.poll() != .ended { failures.append("browser should read ended once the meeting tab is gone") }

        // Audio-silence detector.
        var silence: TimeInterval = 0
        let audio = AudioSilenceDetector(threshold: 150, silenceSeconds: { silence })
        if await audio.poll() != .active { failures.append("audio should read active while sound is recent") }
        silence = 200
        if await audio.poll() != .ended { failures.append("audio should read ended after sustained silence") }

        // Regression: a call recorded through the mic (phone on speaker, in-person) keeps the
        // system-audio channel silent the whole time. The silence fed to the detector must be
        // min(mic, system), so mic speech alone keeps the meeting active and it only ends once
        // BOTH channels have been quiet. Watching system audio alone ended live recordings.
        var micSilence: TimeInterval = 5
        let sysSilence: TimeInterval = 200   // nothing ever plays through the laptop
        let bothChannels = AudioSilenceDetector(threshold: 150, silenceSeconds: { min(micSilence, sysSilence) })
        if await bothChannels.poll() != .active { failures.append("mic speech must keep the meeting active despite system-audio silence") }
        micSilence = 200   // the person finally stopped talking too
        if await bothChannels.poll() != .ended { failures.append("both channels silent should read ended") }

        // Proactive suggestion dedup: suggest once per meeting, re-suggest after leave+rejoin,
        // stay quiet while recording or disabled.
        let meet = "meet:abc-defg-hij"
        var state = MeetingSuggestionState()
        if !state.step(current: [], isRecording: false, isEnabled: true).isEmpty {
            failures.append("no meeting should produce no suggestion")
        }
        if state.step(current: [meet], isRecording: false, isEnabled: true) != [meet] {
            failures.append("a new meeting should be suggested once")
        }
        if !state.step(current: [meet], isRecording: false, isEnabled: true).isEmpty {
            failures.append("the same meeting must not be suggested twice")
        }
        _ = state.step(current: [], isRecording: false, isEnabled: true)   // left the call
        if state.step(current: [meet], isRecording: false, isEnabled: true) != [meet] {
            failures.append("re-joining should suggest again")
        }
        var recState = MeetingSuggestionState()
        if !recState.step(current: [meet], isRecording: true, isEnabled: true).isEmpty {
            failures.append("must not suggest while already recording")
        }
        if !recState.step(current: [meet], isRecording: false, isEnabled: true).isEmpty {
            failures.append("a meeting seen during recording must not be suggested right after stop")
        }
        if !state.step(current: ["meet:zzz-zzzz-zzz"], isRecording: false, isEnabled: false).isEmpty {
            failures.append("a disabled monitor must suggest nothing")
        }

        if failures.isEmpty { print("SELFTEST OK") } else { failures.forEach { print("SELFTEST FAILED: \($0)") } }
    }

    /// Live probe: reads the current browser tabs and settings and reports what the meeting
    /// detector sees right now. Run it via the installed app binary (so it shares the app's
    /// Automation permission and settings), while in a call and again after leaving:
    ///   /Applications/Transcriber.app/Contents/MacOS/Transcriber --selftest-meeting-live
    private static func runMeetingLive() async {
        let d = UserDefaults.standard
        func flag(_ key: String, default def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
        print("settings:")
        print("  detectMeetingEnd      = \(flag("detectMeetingEnd", default: true))")
        print("  detectBrowserMeetings = \(flag("detectBrowserMeetings", default: true))")
        print("  detectSilenceFallback = \(flag("detectSilenceFallback", default: true))")
        print("  autoStopAfterMeeting  = \(flag("autoStopAfterMeetingEnd", default: true))")
        print("  captureSystemAudio    = \(flag("captureSystemAudio", default: true))  <- must be ON or the watcher never starts")

        let urls = await BrowserTabs.urls()
        print("\nbrowser tabs read: \(urls.count)")
        if urls.isEmpty {
            print("  ⚠️  no tabs read — Automation permission is likely denied, or no scriptable browser is running.")
            print("      Grant it: System Settings → Privacy & Security → Automation → Transcriber → enable your browser.")
        }
        let interesting = ["meet.google", "zoom.us", "teams.", "webex.com", "whereby.com"]
        let calls = urls.filter { u in interesting.contains { u.lowercased().contains($0) } }
        print("meeting-ish tabs: \(calls.count)")
        for u in calls {
            print("  \(MeetingURL.match(u) != nil ? "MATCHED  " : "UNMATCHED")\(u)")
        }
        let meetings = MeetingURL.meetings(in: urls)
        print("\ndetected meetings right now: \(meetings.isEmpty ? "none" : meetings.sorted().joined(separator: ", "))")
        print("(Run this while IN the call, then again AFTER you leave — the set should change.)")
    }

    private static func runMarkdown() {
        let original = """
        ---
        source: "test.m4a"
        language: ru, en
        ---

        # test

        **Speaker 1**
        00:00
        Привет, как дела?

        **Speaker 2**
        00:05
        Всё нормально, спасибо.
        """

        // transcriptBody strips frontmatter (and keeps the transcript).
        let body = MarkdownWriter.transcriptBody(from: original)
        guard body.contains("Привет"), !body.contains("source:"), body.contains("# test") else {
            print("SELFTEST FAILED: transcriptBody: \(body)"); return
        }

        // Insert a summary, then confirm it lands after the heading and body is preserved.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("md-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try original.write(to: tmp, atomically: true, encoding: .utf8)
            try MarkdownWriter.insertSummary("## Summary\nA short chat.", into: tmp)
            let withSummary = try String(contentsOf: tmp, encoding: .utf8)
            guard withSummary.contains(MarkdownWriter.summaryStart),
                  withSummary.contains("A short chat."),
                  withSummary.contains("Привет"),
                  let hIdx = withSummary.range(of: "# test"),
                  let sIdx = withSummary.range(of: MarkdownWriter.summaryStart),
                  hIdx.upperBound < sIdx.lowerBound else {
                print("SELFTEST FAILED: insertSummary placement"); return
            }

            // Re-summarize replaces, doesn't stack.
            try MarkdownWriter.insertSummary("## Summary\nUpdated.", into: tmp)
            let updated = try String(contentsOf: tmp, encoding: .utf8)
            let count = updated.components(separatedBy: MarkdownWriter.summaryStart).count - 1
            guard count == 1, updated.contains("Updated."), !updated.contains("A short chat.") else {
                print("SELFTEST FAILED: re-summarize stacked (count=\(count))"); return
            }

            // Rename keeps extension, changes base name.
            let renamed = try FileRenamer.rename(tmp, toBaseName: "Team sync 2026")
            defer { try? FileManager.default.removeItem(at: renamed) }
            guard renamed.lastPathComponent == "Team sync 2026.md",
                  FileManager.default.fileExists(atPath: renamed.path),
                  !FileManager.default.fileExists(atPath: tmp.path) else {
                print("SELFTEST FAILED: rename: \(renamed.lastPathComponent)"); return
            }

            // chunking packs blocks and never exceeds budget.
            let big = (0..<50).map { "**S\($0)**\n00:0\($0)\nblock number \($0) text text text" }.joined(separator: "\n\n")
            let chunks = Summarizer.chunk(big, maxCharacters: 300)
            guard chunks.count > 1, chunks.allSatisfy({ $0.count <= 300 || !$0.contains("\n\n") }) else {
                print("SELFTEST FAILED: chunking (\(chunks.count) chunks)"); return
            }
        } catch {
            print("SELFTEST FAILED: \(error.localizedDescription)"); return
        }
        print("SELFTEST OK")
    }

    private static func runHistory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-history-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var done = TranscriptionJob(sourceURL: URL(fileURLWithPath: "/tmp/a.ogg"), diarize: true)
        done.status = .done(outputURL: URL(fileURLWithPath: "/tmp/a.md"))
        done.durationSeconds = 42
        done.finishedAt = Date()
        var failed = TranscriptionJob(sourceURL: URL(fileURLWithPath: "/tmp/b.mp4"))
        failed.status = .failed(message: "boom")
        var running = TranscriptionJob(sourceURL: URL(fileURLWithPath: "/tmp/c.m4a"))
        running.status = .transcribing(progress: 0.5)

        HistoryStore.save([done, failed, running], to: url)
        let loaded = HistoryStore.load(from: url)

        guard loaded.count == 3,
              case .done(let out) = loaded[0].status, out.path == "/tmp/a.md",
              loaded[0].diarize, loaded[0].durationSeconds == 42, loaded[0].finishedAt != nil,
              case .failed(let message) = loaded[1].status, message == "boom",
              loaded[2].status == .queued
        else {
            print("SELFTEST FAILED: history round-trip mismatch: \(loaded)")
            return
        }
        print("SELFTEST OK")
    }

    private static func runMultilingual(path: String) async throws {
        guard let ffmpeg = Tools.find("ffmpeg") else { throw RecorderError(message: "ffmpeg not found") }
        guard let server = Tools.find("whisper-server") else { throw RecorderError(message: "whisper-server not found") }
        let model = WhisperModel.byID("large-v3-turbo-q5_0")
        let modelURL = ModelManager.modelsDirectory.appendingPathComponent(model.fileName)

        // Optional: --allowed ru,en,de
        var allowed: [String] = []
        if let index = CommandLine.arguments.firstIndex(of: "--allowed"),
           CommandLine.arguments.count > index + 1 {
            allowed = Languages.ordered(Set(CommandLine.arguments[index + 1].split(separator: ",").map(String.init)))
            print("allowed languages: \(allowed.joined(separator: ", "))")
        }

        print("converting…")
        let wav = try await FFmpeg.convertToWav(input: URL(fileURLWithPath: path), ffmpeg: ffmpeg)
        defer { try? FileManager.default.removeItem(at: wav) }

        print("diarizing…")
        let speakers = try await Diarizer.shared.diarize(wavURL: wav)
        print("speaker segments: \(speakers.count)")

        print("transcribing per chunk…")
        let output = try await MultilingualTranscriber.transcribe(
            wav: wav,
            speakers: speakers,
            model: modelURL,
            ffmpeg: ffmpeg,
            serverBinary: server,
            allowedLanguages: allowed,
            onProgress: { print(String(format: "  progress %.0f%%", $0 * 100)) }
        )
        await WhisperServer.shared.stop()
        print("languages: \(output.languages.joined(separator: ", "))")
        print("--- transcript ---")
        print(MarkdownWriter.diarizedBody(blocks: output.blocks))
    }

    /// Exercises the deterministic dual-track path end to end on two real per-speaker tracks:
    ///   Transcriber --selftest-dualtrack mic.m4a system.m4a [--allowed ru,de,en]
    /// Mirrors what AppState does when a recording kept isolated mic/system tracks.
    private static func runDualTrack(mic: String, system: String) async throws {
        guard let ffmpeg = Tools.find("ffmpeg") else { throw RecorderError(message: "ffmpeg not found") }
        guard let server = Tools.find("whisper-server") else { throw RecorderError(message: "whisper-server not found") }
        let ffprobe = Tools.find("ffprobe")
        let model = WhisperModel.byID("large-v3-turbo-q5_0")
        let modelURL = ModelManager.modelsDirectory.appendingPathComponent(model.fileName)

        var allowed: [String] = []
        if let index = CommandLine.arguments.firstIndex(of: "--allowed"),
           CommandLine.arguments.count > index + 1 {
            allowed = Languages.ordered(Set(CommandLine.arguments[index + 1].split(separator: ",").map(String.init)))
            print("allowed languages: \(allowed.joined(separator: ", "))")
        }

        let micURL = URL(fileURLWithPath: mic)
        let systemURL = URL(fileURLWithPath: system)
        let usable = await AppState.tracksUsable(mic: micURL, system: systemURL, ffmpeg: ffmpeg, ffprobe: ffprobe)
        print("tracks usable (both carry speech): \(usable)")

        let transcribeTrack: (URL, String, @escaping (Double) -> Void) async throws -> (blocks: [TranscriptBlock], languages: [String]) = { trackURL, speaker, progress in
            print("  [\(speaker)] converting…")
            let trackWav = try await FFmpeg.convertToWav(input: trackURL, ffmpeg: ffmpeg)
            defer { try? FileManager.default.removeItem(at: trackWav) }
            let dur = await FFmpeg.duration(of: trackWav, ffprobe: ffprobe ?? ffmpeg) ?? 0
            let whole = [SpeakerSegment(speaker: speaker, start: 0, end: max(dur, 0.1))]
            let out = try await MultilingualTranscriber.transcribe(
                wav: trackWav, speakers: whole, model: modelURL, ffmpeg: ffmpeg,
                serverBinary: server, allowedLanguages: allowed, onProgress: progress
            )
            return (out.blocks, out.languages)
        }

        let output = try await DualTrackTranscriber.transcribe(
            micWav: micURL, systemWav: systemURL,
            onProgress: { print(String(format: "  progress %.0f%%", $0 * 100)) },
            transcribeTrack: transcribeTrack
        )
        await WhisperServer.shared.stop()
        print("languages: \(output.languages.joined(separator: ", "))")
        print("--- transcript ---")
        print(MarkdownWriter.diarizedBody(blocks: output.blocks))
    }

    /// Exercises the mixed-language repair path end to end against a real transcript + its mixed
    /// audio, WITHOUT touching the original file (works on a temp copy):
    ///   Transcriber --selftest-mixrepair transcript.md audio.m4a [--llm qwen3.5-4b-q5]
    /// Mirrors AppState.runMixedLanguageRepair, printing the LLM candidates, the located spans,
    /// and a before/after diff of each repaired block so the wiring can be verified by eye.
    private static func runMixRepair(transcript: String, audio: String) async throws {
        struct RepairError: LocalizedError { let message: String; var errorDescription: String? { message } }
        guard let ffmpeg = Tools.find("ffmpeg") else { throw RecorderError(message: "ffmpeg not found") }
        guard let server = Tools.find("whisper-server") else { throw RecorderError(message: "whisper-server not found") }
        let ffprobe = Tools.find("ffprobe")

        let whisperModel = ModelManager.modelsDirectory.appendingPathComponent(WhisperModel.byID("large-v3-turbo-q5_0").fileName)
        var llmID = "qwen3.5-4b-q5"
        if let index = CommandLine.arguments.firstIndex(of: "--llm"), CommandLine.arguments.count > index + 1 {
            llmID = CommandLine.arguments[index + 1]
        }
        let llmModel = ModelManager.modelsDirectory.appendingPathComponent(LLMModel.byID(llmID).fileName)
        guard FileManager.default.fileExists(atPath: whisperModel.path) else { throw RepairError(message: "whisper model not downloaded at \(whisperModel.path)") }
        guard FileManager.default.fileExists(atPath: llmModel.path) else { throw RepairError(message: "LLM model not downloaded at \(llmModel.path)") }
        print("whisper: \(whisperModel.lastPathComponent)   llm: \(llmModel.lastPathComponent)")

        let content = try String(contentsOf: URL(fileURLWithPath: transcript), encoding: .utf8)
        let declared = MarkdownWriter.declaredLanguages(from: content)
        let refs = TranscriptIndex.blocks(in: MarkdownWriter.transcriptBody(from: content))
            .filter { $0.speaker != nil && $0.time != nil }
        guard !refs.isEmpty else { throw RepairError(message: "no timestamped speaker turns") }
        print("declared languages: \(declared.joined(separator: ", "))   turns: \(refs.count)")

        let wav = try await FFmpeg.convertToWav(input: URL(fileURLWithPath: audio), ffmpeg: ffmpeg)
        defer { try? FileManager.default.removeItem(at: wav) }
        let totalDuration = await FFmpeg.duration(of: wav, ffprobe: ffprobe ?? ffmpeg) ?? 0

        var blocks: [TranscriptBlock] = []
        for (i, ref) in refs.enumerated() {
            let start = MixedLanguageRepair.seconds(fromLabel: ref.time ?? "") ?? 0
            let nextStart = i + 1 < refs.count
                ? (MixedLanguageRepair.seconds(fromLabel: refs[i + 1].time ?? "") ?? totalDuration)
                : totalDuration
            blocks.append(TranscriptBlock(speaker: ref.speaker ?? "Speaker 1", start: start, end: max(start + 0.1, nextStart), text: ref.text))
        }
        let original = blocks

        try await WhisperServer.shared.ensureRunning(model: whisperModel, serverBinary: server)
        try await LlamaServer.shared.ensureRunning(model: llmModel)
        let languageHint = declared.isEmpty ? "the languages spoken" : declared.joined(separator: ", ")

        let result = try await MixedLanguageRepair.repair(
            blocks: blocks,
            findCandidates: { blocks in
                let c = try await AppState.mixedLanguageCandidates(blocks: blocks, languages: languageHint)
                print("LLM candidate blocks: \(c)")
                return c
            },
            wordsForBlock: { index in
                let block = blocks[index]
                let clipStart = max(0, block.start - 0.12)
                let clip = try await FFmpeg.extract(from: wav, start: block.start, end: block.end, ffmpeg: ffmpeg)
                defer { try? FileManager.default.removeItem(at: clip) }
                let out = try await WhisperServer.shared.transcribeWords(wav: clip, language: nil)
                return out.words.map { WhisperServer.Word(text: $0.text, start: clipStart + $0.start, end: clipStart + $0.end) }
            },
            locateSpans: { words in
                let spans = try await AppState.locateTransliteratedSpans(words: words, languages: languageHint)
                if !spans.isEmpty {
                    let preview = spans.map { s in "\(s.language)[\(s.from)-\(s.to)]:\"\(words[s.from...min(s.to, words.count - 1)].map { $0.text }.joined().trimmingCharacters(in: .whitespaces))\"" }
                    print("  located: \(preview.joined(separator: "  "))")
                }
                return spans
            },
            retranscribeSpan: { start, end, language in
                let clip = try await FFmpeg.extract(from: wav, start: start, end: end, ffmpeg: ffmpeg)
                defer { try? FileManager.default.removeItem(at: clip) }
                let out = try await WhisperServer.shared.transcribe(wav: clip, language: language)
                print("    [\(language)] \(String(format: "%.2f–%.2f", start, end)) → \"\(out.text.trimmingCharacters(in: .whitespaces))\"")
                return out.text
            }
        )
        await WhisperServer.shared.stop()
        await LlamaServer.shared.stop()

        print("\n=== repaired \(result.repairedSpanCount) span(s) ===")
        for (i, block) in result.blocks.enumerated() where block.text != original[i].text {
            print("- [\(original[i].speaker) @ \(String(format: "%.1fs", original[i].start))]")
            print("  before: \(original[i].text)")
            print("  after:  \(block.text)")
        }
        if result.repairedSpanCount == 0 { print("(no changes — transcript left as-is)") }
    }

    private static func run(path: String) async throws {
        guard let ffmpeg = Tools.find("ffmpeg") else { throw RecorderError(message: "ffmpeg not found") }
        guard let whisper = Tools.find("whisper-cli", "whisper-cpp") else { throw RecorderError(message: "whisper-cli not found") }
        let model = WhisperModel.byID("large-v3-turbo-q5_0")
        let modelURL = ModelManager.modelsDirectory.appendingPathComponent(model.fileName)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw RecorderError(message: "whisper model not downloaded")
        }

        print("converting…")
        let wav = try await FFmpeg.convertToWav(input: URL(fileURLWithPath: path), ffmpeg: ffmpeg)
        defer { try? FileManager.default.removeItem(at: wav) }

        // Same accuracy configuration the app uses, so this hook verifies what ships.
        let vadModel = await VADModel.ensureAvailable()
        print("VAD model: \(vadModel?.lastPathComponent ?? "unavailable — silence will not be skipped")")
        let vocabulary = UserDefaults.standard.string(forKey: "customVocabulary") ?? ""
        if !vocabulary.isEmpty { print("vocabulary: \(vocabulary)") }

        print("transcribing…")
        let transcription = try await Whisper.transcribeSegments(
            wav: wav, model: modelURL, language: "auto", cli: whisper,
            vadModel: vadModel, initialPrompt: vocabulary
        )
        print("whisper segments: \(transcription.segments.count), language: \(transcription.language ?? "?")")

        print("diarizing (downloads models on first run)…")
        let speakers = try await Diarizer.shared.diarize(wavURL: wav)
        print("speaker segments: \(speakers.count)")
        for segment in speakers {
            print(String(format: "  %@  %.2f – %.2f", segment.speaker, segment.start, segment.end))
        }

        let blocks = TranscriptMerger.merge(whisper: transcription.segments, speakers: speakers)
        print("--- transcript ---")
        print(MarkdownWriter.diarizedBody(blocks: blocks))
    }
}
