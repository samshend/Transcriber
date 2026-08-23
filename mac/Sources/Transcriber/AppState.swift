import AVFoundation
import Combine
import Foundation
import SwiftUI
import UserNotifications

enum OutputMode: String, CaseIterable {
    case alongside
    case folder
}

/// What the sidebar has selected. Drives both which items are listed and where a newly
/// finished transcript is filed.
enum LibrarySelection: Hashable {
    case all
    case unsorted
    case project(UUID)
}

@MainActor
final class AppState: ObservableObject {
    @Published var jobs: [TranscriptionJob] = [] {
        didSet { scheduleHistorySave() }
    }
    @Published var isProcessing = false

    @Published var modelID: String { didSet { defaults.set(modelID, forKey: "modelID") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var includeTimestamps: Bool { didSet { defaults.set(includeTimestamps, forKey: "includeTimestamps") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var outputFolderPath: String { didSet { defaults.set(outputFolderPath, forKey: "outputFolderPath") } }
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "captureSystemAudio") } }
    @Published var keepSourceTracks: Bool { didSet { defaults.set(keepSourceTracks, forKey: "keepSourceTracks") } }
    @Published var diarizeRecordings: Bool { didSet { defaults.set(diarizeRecordings, forKey: "diarizeRecordings") } }
    @Published var diarizeImported: Bool { didSet { defaults.set(diarizeImported, forKey: "diarizeImported") } }
    @Published var multilingualMode: Bool { didSet { defaults.set(multilingualMode, forKey: "multilingualMode") } }
    @Published var autoSummarize: Bool { didSet { defaults.set(autoSummarize, forKey: "autoSummarize") } }
    @Published var summaryEngine: SummaryEngine { didSet { defaults.set(summaryEngine.rawValue, forKey: "summaryEngine") } }
    @Published var llmModelID: String { didSet { defaults.set(llmModelID, forKey: "llmModelID") } }
    @Published var summaryPrompt: String { didSet { defaults.set(summaryPrompt, forKey: "summaryPrompt") } }
    @Published var askPrompt: String { didSet { defaults.set(askPrompt, forKey: "askPrompt") } }
    @Published var useVAD: Bool { didSet { defaults.set(useVAD, forKey: "useVAD") } }
    @Published var customVocabulary: String { didSet { defaults.set(customVocabulary, forKey: "customVocabulary") } }
    @Published var detectMeetingEnd: Bool { didSet { defaults.set(detectMeetingEnd, forKey: "detectMeetingEnd") } }
    @Published var detectBrowserMeetings: Bool { didSet { defaults.set(detectBrowserMeetings, forKey: "detectBrowserMeetings") } }
    @Published var detectSilenceFallback: Bool { didSet { defaults.set(detectSilenceFallback, forKey: "detectSilenceFallback") } }
    @Published var autoStopAfterMeetingEnd: Bool { didSet { defaults.set(autoStopAfterMeetingEnd, forKey: "autoStopAfterMeetingEnd") } }
    @Published var suggestRecording: Bool { didSet { defaults.set(suggestRecording, forKey: "suggestRecording") } }
    @Published var allowedLanguages: Set<String> { didSet { defaults.set(Array(allowedLanguages), forKey: "allowedLanguages") } }
    @Published var recordingsFolderPath: String { didSet { defaults.set(recordingsFolderPath, forKey: "recordingsFolderPath") } }

    @Published var ffmpegURL: URL?
    @Published var ffprobeURL: URL?
    @Published var whisperURL: URL?
    @Published var alertMessage: String?
    /// Result of Settings → "Test detection now"; a human-readable multi-line report.
    @Published var meetingDetectionReport: String?
    /// True when at least one open, supported browser has refused the Automation permission, so
    /// Settings can show the "open Automation settings" recovery banner.
    @Published var automationPermissionDenied = false
    /// Short, self-dismissing status line (assistant hand-offs, MCP requests).
    @Published var toast: String?

    let modelManager = ModelManager()
    let recorder = AudioRecorder()

    /// The managed library: the source of truth for finished transcripts.
    let library = LibraryStore()
    /// Which project/bucket the sidebar is showing.
    @Published var selection: LibrarySelection = .all
    /// The transcript open in the detail pane.
    @Published var selectedItemID: UUID?

    var selectedItem: LibraryItem? {
        selectedItemID.flatMap { id in library.items.first { $0.id == id } }
    }

    private let defaults = UserDefaults.standard
    private var libraryObserver: AnyCancellable?

    // Meeting-end detection.
    private let meetingNotifier = MeetingNotifier()
    private var meetingWatcher: MeetingWatcher?
    private var meetingStartMonitor: MeetingStartMonitor?
    private var meetingGraceTask: Task<Void, Never>?
    private static let meetingGrace: TimeInterval = 600   // 10 minutes before auto-stopping
    private var currentProcess: Process?
    private var stopRequested = false
    private var isWorking = false
    private var historySaveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var inboxTask: Task<Void, Never>?

    init() {
        modelID = defaults.string(forKey: "modelID") ?? WhisperModel.all[0].id
        language = defaults.string(forKey: "language") ?? "auto"
        includeTimestamps = defaults.bool(forKey: "includeTimestamps")
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .alongside
        outputFolderPath = defaults.string(forKey: "outputFolderPath") ?? ""
        // On by default: her use case is recording Meet/Zoom/Teams calls, where the *other*
        // side lives in system audio. An explicit opt-out is still respected.
        captureSystemAudio = defaults.object(forKey: "captureSystemAudio") as? Bool ?? true
        keepSourceTracks = defaults.object(forKey: "keepSourceTracks") as? Bool ?? true
        diarizeRecordings = defaults.object(forKey: "diarizeRecordings") as? Bool ?? true
        diarizeImported = defaults.bool(forKey: "diarizeImported")
        multilingualMode = defaults.object(forKey: "multilingualMode") as? Bool ?? true
        autoSummarize = defaults.bool(forKey: "autoSummarize")
        summaryEngine = SummaryEngine(rawValue: defaults.string(forKey: "summaryEngine") ?? "") ?? .automatic
        llmModelID = defaults.string(forKey: "llmModelID") ?? LLMModel.all[0].id
        summaryPrompt = defaults.string(forKey: "summaryPrompt") ?? ""
        askPrompt = defaults.string(forKey: "askPrompt") ?? ""
        useVAD = defaults.object(forKey: "useVAD") as? Bool ?? true
        customVocabulary = defaults.string(forKey: "customVocabulary") ?? ""
        detectMeetingEnd = defaults.object(forKey: "detectMeetingEnd") as? Bool ?? true
        detectBrowserMeetings = defaults.object(forKey: "detectBrowserMeetings") as? Bool ?? true
        detectSilenceFallback = defaults.object(forKey: "detectSilenceFallback") as? Bool ?? true
        autoStopAfterMeetingEnd = defaults.object(forKey: "autoStopAfterMeetingEnd") as? Bool ?? true
        suggestRecording = defaults.object(forKey: "suggestRecording") as? Bool ?? true
        allowedLanguages = Set(defaults.stringArray(forKey: "allowedLanguages") ?? [])
        recordingsFolderPath = defaults.string(forKey: "recordingsFolderPath") ?? ""
        refreshTools()

        // The job list is now only the transient processing queue; finished transcripts live
        // in the library. Keep just the unfinished jobs from last session (there are rarely
        // any), so old "done" rows don't duplicate what's already in the library.
        jobs = HistoryStore.load().filter { !$0.status.isFinished }

        // Re-publish the library's changes through AppState so views observing `app` refresh
        // when items or projects change (SwiftUI doesn't observe nested ObservableObjects).
        libraryObserver = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // One-time import of pre-library transcripts into an "Unsorted" bucket. Guarded off the
        // headless MCP/self-test process, and idempotent via a marker file.
        if !LaunchMode.isHeadless {
            migrateExistingTranscripts()
            // Do XProtect's one-time, main-thread-only AppleScript init now, so the off-main
            // browser reads later don't hang on their first run. Cheap, once, on the main thread.
            AppleScriptWarmup.prewarmOnMain()
            meetingNotifier.onStopAndSave = { [weak self] in self?.meetingStopAndSave() }
            meetingNotifier.onKeepRecording = { [weak self] in self?.stopMeetingWatch() }
            meetingNotifier.onStartRecording = { [weak self] in self?.startRecording() }
            startMeetingSuggestions()
        }

        startInboxWatcher()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.historySaveTask?.cancel()
                HistoryStore.save(self.jobs)
            }
        }
    }

    /// Imports transcripts produced before the library existed (history + scanned folders),
    /// copying each into an "Unsorted" item. Runs once; never moves or deletes the originals.
    private func migrateExistingTranscripts() {
        let paths = TranscriptIndex.candidateFiles(defaults: defaults)
        library.migrateIfNeeded(transcriptPaths: paths) { md in
            // The transcript's frontmatter records the media it came from; copy that audio in
            // too when it's still on disk.
            guard let data = try? String(contentsOf: md, encoding: .utf8) else { return nil }
            let fields = TranscriptIndex.frontmatter(data)
            if let source = fields["source_path"], FileManager.default.fileExists(atPath: source) {
                return URL(fileURLWithPath: source)
            }
            return nil
        }
    }

    /// Where a newly finished transcript is filed: the project the sidebar is showing, else
    /// Unsorted.
    private var ingestProjectID: UUID? {
        if case .project(let id) = selection { return id }
        return nil
    }

    // MARK: - Library item actions

    func summarize(item: LibraryItem) {
        let url = library.transcriptURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        Task {
            do {
                try await generateSummary(for: url)
                library.refreshMetadata(item.id)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func ask(item: LibraryItem, target: AskAssistant.Target) {
        let url = library.transcriptURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = "The transcript file is missing."
            return
        }
        do {
            showToast(try AskAssistant.ask(transcript: url, target: target, prompt: askPrompt))
        } catch {
            alertMessage = "Could not open \(target == .claude ? "Claude" : "ChatGPT"): \(error.localizedDescription)"
        }
    }

    func renameItem(_ item: LibraryItem, to title: String) {
        if !library.rename(item.id, to: title) {
            alertMessage = "Could not rename “\(item.title)”."
        }
    }

    func move(_ item: LibraryItem, to projectID: UUID?) {
        library.move(item.id, to: projectID)
    }

    /// Move by id — used by drag-and-drop, where only the transferred id is available.
    func moveItem(_ id: UUID, to projectID: UUID?) {
        library.move(id, to: projectID)
    }

    func deleteItem(_ item: LibraryItem) {
        library.deleteItem(item.id)
    }

    /// After renaming speakers (which rewrites the .md in place) refresh the denormalised
    /// speaker list shown in the library.
    func refreshItem(_ item: LibraryItem) {
        library.refreshMetadata(item.id)
    }

    /// Copies a stored transcript or audio out to a user-chosen location and name.
    func export(_ item: LibraryItem, kind: LibraryStore.ExportKind, to destination: URL) {
        do {
            let written = try library.export(item.id, kind: kind, to: destination)
            showToast("Saved to \(written.lastPathComponent).")
        } catch {
            alertMessage = "Could not save the file: \(error.localizedDescription)"
        }
    }

    /// The default filename offered when exporting (title + the right extension).
    func exportName(for item: LibraryItem, kind: LibraryStore.ExportKind) -> String {
        switch kind {
        case .transcript: return LibraryStore.sanitize(item.title) + ".md"
        case .audio:
            let ext = item.audioFile.map { ($0 as NSString).pathExtension } ?? "m4a"
            return LibraryStore.sanitize(item.title) + "." + ext
        }
    }

    // MARK: - Projects

    func createProject(name: String) {
        let project = library.createProject(name: name)
        selection = .project(project.id)
    }

    func renameProject(_ id: UUID, to name: String) { library.renameProject(id, to: name) }
    func setProjectNotes(_ id: UUID, notes: String) { library.setNotes(id, notes: notes) }

    func deleteProject(_ id: UUID) {
        if case .project(id) = selection { selection = .all }
        library.deleteProject(id)
    }

    /// Debounced: jobs mutate many times per second during transcription progress.
    private func scheduleHistorySave() {
        historySaveTask?.cancel()
        let snapshot = jobs
        historySaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            HistoryStore.save(snapshot)
        }
    }

    var recordingsFolder: URL {
        if !recordingsFolderPath.isEmpty {
            return URL(fileURLWithPath: recordingsFolderPath, isDirectory: true)
        }
        return AppPaths.recordingsFolder(defaults: defaults)
    }

    /// Picks up `transcribe_file` requests from the MCP server, which runs in its own
    /// process and can't talk to us directly.
    private func startInboxWatcher() {
        guard !LaunchMode.isHeadless else { return }
        inboxTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                let urls = Inbox.drain()
                guard !urls.isEmpty else { continue }
                let before = self.jobs.count
                self.add(urls: urls)
                let added = self.jobs.count - before
                self.showToast(added > 0
                    ? "Added \(added) file\(added == 1 ? "" : "s") requested by an assistant."
                    : "An assistant requested files that are already in the list.")
            }
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Assistant hand-off

    /// Opens Claude Code / ChatGPT on a finished transcript (see AskAssistant).
    func ask(_ job: TranscriptionJob, target: AskAssistant.Target) {
        guard case .done(let outputURL) = job.status,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            alertMessage = "The transcript file is missing — it may have been moved or deleted."
            return
        }
        do {
            showToast(try AskAssistant.ask(transcript: outputURL, target: target, prompt: askPrompt))
        } catch {
            alertMessage = "Could not open \(target == .claude ? "Claude" : "ChatGPT"): \(error.localizedDescription)"
        }
    }

    var selectedModel: WhisperModel { WhisperModel.byID(modelID) }

    var missingTools: [String] {
        var missing: [String] = []
        if ffmpegURL == nil { missing.append("ffmpeg") }
        if whisperURL == nil { missing.append("whisper-cli") }
        return missing
    }

    var isModelReady: Bool { modelManager.isDownloaded(selectedModel) }
    var isReadyToRun: Bool { missingTools.isEmpty && isModelReady }
    var hasQueuedJobs: Bool { jobs.contains { $0.status == .queued } }
    var hasFinishedJobs: Bool { jobs.contains { $0.status.isFinished } }

    func refreshTools() {
        ffmpegURL = Tools.find("ffmpeg")
        ffprobeURL = Tools.find("ffprobe")
        whisperURL = Tools.find("whisper-cli", "whisper-cpp")
    }

    // MARK: - Queue management

    func add(urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let entry = enumerator?.nextObject() as? URL {
                    if MediaTypes.all.contains(entry.pathExtension.lowercased()) {
                        files.append(entry)
                    }
                }
            } else if MediaTypes.all.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }

        let knownPaths = Set(jobs.map { $0.sourceURL.path })
        let newFiles = files
            .filter { !knownPaths.contains($0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        jobs.append(contentsOf: newFiles.map { TranscriptionJob(sourceURL: $0, diarize: diarizeImported) })
        start()
    }

    // MARK: - Recording

    func startRecording() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                alertMessage = "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
                return
            }
            do {
                try recorder.start(captureSystemAudio: captureSystemAudio, folder: recordingsFolder)
                startMeetingWatch()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func stopRecordingAndTranscribe() {
        stopMeetingWatch()
        Task {
            do {
                let recording = try await recorder.finish(ffmpeg: ffmpegURL, keepSourceTracks: keepSourceTracks)
                var job = TranscriptionJob(sourceURL: recording.url, diarize: diarizeRecordings)
                job.recordingWarning = recording.warning
                jobs.append(job)
                if let warning = recording.warning {
                    // A half-captured meeting is worth an interruption: the user needs to
                    // know before they rely on the transcript.
                    alertMessage = "Recording saved as \(recording.url.lastPathComponent), but the capture had a problem.\n\n\(warning)"
                } else {
                    showToast("Recording saved as \(recording.url.lastPathComponent).")
                }
                start()
            } catch {
                alertMessage = "Could not finish the recording: \(error.localizedDescription)"
            }
        }
    }

    func discardRecording() {
        stopMeetingWatch()
        recorder.discard()
    }

    // MARK: - Meeting-end detection

    /// Starts watching for the meeting to end (browser tab first, silence fallback). Only when
    /// the feature is on and we're actually capturing a call's system audio.
    private func startMeetingWatch() {
        guard detectMeetingEnd else {
            Log.meeting.notice("watch not started: meeting-end detection is off")
            return
        }
        guard captureSystemAudio else {
            Log.meeting.notice("watch not started: system-audio capture is off (feature only runs for calls)")
            return
        }
        Log.meeting.notice("starting meeting watch (browser=\(self.detectBrowserMeetings), silence=\(self.detectSilenceFallback))")
        meetingNotifier.prepare()
        let watcher = MeetingWatcher.standard(
            browserEnabled: detectBrowserMeetings,
            audioEnabled: detectSilenceFallback,
            silenceSeconds: { [weak self] in self?.recorder.systemSilenceSeconds ?? .greatestFiniteMagnitude }
        )
        meetingWatcher = watcher
        watcher.start { [weak self] in self?.handleMeetingEnded() }
    }

    private func handleMeetingEnded() {
        Log.meeting.notice("meeting judged ended (recording=\(self.recorder.isRecording))")
        guard recorder.isRecording else { return }
        let body = autoStopAfterMeetingEnd
            ? "Stop and save the recording? It will save on its own in 10 minutes if you don't respond."
            : "Stop and save the recording?"
        meetingNotifier.notifyMeetingEnded(title: "Meeting looks finished", body: body)
        showToast("Meeting looks finished — stop & save the recording?")

        guard autoStopAfterMeetingEnd else { return }
        meetingGraceTask?.cancel()
        meetingGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.meetingGrace * 1_000_000_000))
            guard let self, !Task.isCancelled, self.recorder.isRecording else { return }
            self.showToast("Auto-stopped the recording — the meeting had ended.")
            self.meetingStopAndSave()
        }
    }

    private func meetingStopAndSave() {
        guard recorder.isRecording else { stopMeetingWatch(); return }
        stopRecordingAndTranscribe()   // this also calls stopMeetingWatch()
    }

    private func stopMeetingWatch() {
        meetingGraceTask?.cancel()
        meetingGraceTask = nil
        meetingWatcher?.stop()
        meetingWatcher = nil
    }

    /// Proactively watches for a meeting to start while NOT recording, and suggests recording it.
    /// Runs for the app's lifetime; the monitor scans only when the feature is on and we're idle,
    /// so it touches the browser (and its permission) only when actually enabled.
    private func startMeetingSuggestions() {
        let monitor = MeetingStartMonitor(
            isEnabled: { [weak self] in self?.suggestRecording ?? false },
            isRecording: { [weak self] in self?.recorder.isRecording ?? false }
        )
        meetingStartMonitor = monitor
        monitor.start { [weak self] _ in self?.promptToRecord() }
    }

    private func promptToRecord() {
        meetingNotifier.prepare()
        meetingNotifier.notifyMeetingStarted(
            title: "Meeting detected",
            body: "You're in a call — record it?"
        )
        showToast("Meeting detected — want to record it?")
    }

    // MARK: - Detection diagnostics (Settings)

    /// Probes meeting detection end-to-end and reports what it sees: which browsers are open,
    /// their Automation permission, how many tabs were read, any recognized meeting, and the
    /// notification permission. Also surfaces the consent dialog for any not-yet-asked browser,
    /// so this doubles as the manual "grant permission" trigger for the user.
    func testMeetingDetection() {
        meetingDetectionReport = "Checking…"
        Task {
            var lines: [String] = []
            let running = BrowserTabs.runningBrowsers()
            let unsupported = BrowserTabs.runningUnsupportedBrowsers()

            if running.isEmpty && unsupported.isEmpty {
                lines.append("No browser is open. Open your meeting in Chrome, Safari, Edge, Brave, Arc, Vivaldi or Opera, then test again.")
            }

            await AutomationPermissionState.shared.ensurePrompted(running.map { $0.bundleID })
            let statuses = await AutomationPermissionState.shared.statuses()
            for browser in running {
                let status = statuses[browser.bundleID] ?? .notDetermined
                lines.append("• \(browser.name): \(status.humanDescription)")
            }
            for name in unsupported {
                lines.append("• \(name): can't read its tabs — use one of the supported browsers for meeting detection.")
            }

            let urls = await BrowserTabs.urls()
            let meetings = MeetingURL.meetings(in: urls)
            lines.append("Read \(urls.count) open tab\(urls.count == 1 ? "" : "s").")
            if meetings.isEmpty {
                lines.append("No meeting recognized right now.")
            } else {
                lines.append("Meeting detected: \(meetings.sorted().joined(separator: ", ")).")
            }

            lines.append("Notifications: \(await notificationStatusText()).")

            automationPermissionDenied = running.contains { statuses[$0.bundleID] == .denied }
            meetingDetectionReport = lines.joined(separator: "\n")
        }
    }

    /// Non-intrusive refresh (no prompts) of whether any open browser is blocking Automation, so
    /// the Settings banner is accurate when the tab appears.
    func refreshAutomationStatus() {
        Task {
            let running = BrowserTabs.runningBrowsers()
            await AutomationPermissionState.shared.refresh(running.map { $0.bundleID })
            let statuses = await AutomationPermissionState.shared.statuses()
            automationPermissionDenied = running.contains { statuses[$0.bundleID] == .denied }
        }
    }

    private func notificationStatusText() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "on"
        case .denied: return "off — turn them on in System Settings › Notifications › Transcriber"
        case .notDetermined: return "not yet requested (start or record a meeting once to be asked)"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Summaries & renaming

    var selectedLLM: LLMModel { LLMModel.byID(llmModelID) }
    var isLLMReady: Bool { modelManager.isDownloaded(selectedLLM) && LlamaServer.binary != nil }

    /// Runs the summary for one transcript, choosing the engine:
    /// Apple Intelligence when it supports the language, otherwise the local GGUF model.
    private func generateSummary(for outputURL: URL) async throws {
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        let body = MarkdownWriter.transcriptBody(from: content)
        guard !body.isEmpty else {
            throw SummaryError(message: "There's no transcript text to summarize.")
        }
        let languages = MarkdownWriter.declaredLanguages(from: content)
        let prompt = summaryPrompt.isEmpty ? nil : summaryPrompt
        // First declared language is the dominant one; name it so the summary comes out
        // in that language instead of English.
        let languageName = languages.first.map { Summarizer.languageName($0) }

        let appleCanDoIt = Summarizer.isReady
            && Summarizer.unsupportedLanguages(in: languages).isEmpty

        let useApple: Bool
        switch summaryEngine {
        case .appleIntelligence:
            useApple = true
        case .localModel:
            useApple = false
        case .automatic:
            // Prefer Apple (instant, no download); fall back to the local model when it
            // can't handle the language — that's the Russian case.
            useApple = appleCanDoIt || !isLLMReady
        }

        let summary: String
        if useApple {
            summary = try await Summarizer.summarize(
                transcriptBody: body,
                declaredLanguages: languages,
                customPrompt: prompt,
                languageName: languageName
            )
        } else {
            guard LlamaServer.binary != nil else {
                throw SummaryError(message: "The language-model helper is missing from the app. Try reinstalling Transcriber.")
            }
            guard modelManager.isDownloaded(selectedLLM) else {
                throw SummaryError(message: "Download the \(selectedLLM.displayName) model first (Settings → On-device summaries).")
            }
            summary = try await Summarizer.summarizeWithLocalModel(
                transcriptBody: body,
                model: modelManager.localURL(for: selectedLLM),
                customPrompt: prompt,
                languageName: languageName
            )
        }
        guard !summary.isEmpty else {
            throw SummaryError(message: "The model returned an empty summary.")
        }
        try MarkdownWriter.insertSummary(summary, into: outputURL)
    }

    /// Best-effort content-based title for a just-finished transcript, using the same engine
    /// choice as summaries. Returns nil when no model is available, so the caller keeps the
    /// date-stamped name.
    private func generatedTitle(for outputURL: URL) async -> String? {
        guard let content = try? String(contentsOf: outputURL, encoding: .utf8) else { return nil }
        let body = MarkdownWriter.transcriptBody(from: content)
        guard !body.isEmpty else { return nil }
        let languages = MarkdownWriter.declaredLanguages(from: content)
        let languageName = languages.first.map { Summarizer.languageName($0) }
        let appleCanDoIt = Summarizer.isReady && Summarizer.unsupportedLanguages(in: languages).isEmpty

        let useApple: Bool
        switch summaryEngine {
        case .appleIntelligence: useApple = true
        case .localModel: useApple = false
        case .automatic: useApple = appleCanDoIt || !isLLMReady
        }

        if useApple, appleCanDoIt,
           let title = await Summarizer.generateTitle(transcriptBody: body, languageName: languageName) {
            return title
        }
        if isLLMReady {
            return await Summarizer.generateTitleWithLocalModel(
                transcriptBody: body,
                model: modelManager.localURL(for: selectedLLM),
                languageName: languageName
            )
        }
        return nil
    }

    func summarize(_ job: TranscriptionJob) {
        guard case .done(let outputURL) = job.status,
              FileManager.default.fileExists(atPath: outputURL.path) else { return }
        guard !(jobs.first { $0.id == job.id }?.summarizing ?? false) else { return }

        updateJob(job.id) { $0.summarizing = true }
        Task {
            defer { updateJob(job.id) { $0.summarizing = false } }
            do {
                try await generateSummary(for: outputURL)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func renameTranscript(_ job: TranscriptionJob, to newBaseName: String) {
        guard case .done(let outputURL) = job.status else { return }
        do {
            let newURL = try FileRenamer.rename(outputURL, toBaseName: newBaseName)
            updateJob(job.id) { $0.status = .done(outputURL: newURL) }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func remove(_ job: TranscriptionJob) {
        guard !job.status.isRunning else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }

    func start() {
        guard !isWorking, isReadyToRun, hasQueuedJobs else { return }
        stopRequested = false
        isWorking = true
        isProcessing = true
        Task {
            while !stopRequested, let next = jobs.first(where: { $0.status == .queued }) {
                await process(next.id)
            }
            // Free the ~600 MB the chunk-transcription server holds once the queue is done.
            await WhisperServer.shared.stop()
            isWorking = false
            isProcessing = false
        }
    }

    func stopAll() {
        stopRequested = true
        currentProcess?.terminate()
    }

    private func updateJob(_ id: UUID, _ mutate: (inout TranscriptionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    // MARK: - Processing

    private func process(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }),
              let ffmpeg = ffmpegURL,
              let whisper = whisperURL else { return }

        defer {
            updateJob(id) {
                if $0.status.isFinished, $0.finishedAt == nil {
                    $0.finishedAt = Date()
                }
            }
        }

        guard job.sourceExists else {
            updateJob(id) { $0.status = .failed(message: "Source file not found — was it moved or deleted?") }
            return
        }

        let model = selectedModel
        let modelURL = modelManager.localURL(for: model)
        // Carried into the transcript so a faulty capture is visible when reading it later,
        // not only in the app's job list.
        var captureWarning = job.recordingWarning.map {
            "recording_warning: \"\($0.replacingOccurrences(of: "\"", with: "'"))\"\n"
        } ?? ""
        // Isolated per-side tracks, when the recorder kept them: one voice each, so they can
        // be re-transcribed or re-attributed without the other side bleeding in.
        let tracks = Self.sourceTracks(for: job.sourceURL)
        if !tracks.isEmpty {
            captureWarning += "tracks: [" + tracks.map { "\"\($0.lastPathComponent)\"" }.joined(separator: ", ") + "]\n"
        }
        let languageCode = language
        let timestamps = includeTimestamps
        let vocabulary = customVocabulary
        // Fetched once on first use (under 1 MB); nil just means we transcribe without it.
        let vadModel = useVAD ? await VADModel.ensureAvailable() : nil

        updateJob(id) { $0.status = .converting }
        do {
            // Transcripts are written here first, then copied into the library (the source of
            // truth) and this scratch copy is discarded.
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcriber-out-\(id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            var duration: Double?
            if let ffprobe = ffprobeURL {
                duration = await FFmpeg.duration(of: job.sourceURL, ffprobe: ffprobe)
                updateJob(id) { $0.durationSeconds = duration }
            }

            let wav = try await FFmpeg.convertToWav(input: job.sourceURL, ffmpeg: ffmpeg) { [weak self] process in
                self?.currentProcess = process
            }
            defer { try? FileManager.default.removeItem(at: wav) }

            if stopRequested {
                updateJob(id) { $0.status = .cancelled }
                return
            }

            updateJob(id) { $0.status = .transcribing(progress: nil) }
            let onProgress: (Double) -> Void = { [weak self] progress in
                Task { @MainActor in
                    self?.updateJob(id) { $0.status = .transcribing(progress: progress) }
                }
            }
            let registerProcess: (Process) -> Void = { [weak self] process in
                self?.currentProcess = process
            }

            let outputURL: URL
            if job.diarize,
               multilingualMode,
               languageCode == "auto",
               let serverBinary = Tools.find("whisper-server") {
                // Multilingual path: diarize first, then transcribe chunk by chunk so
                // each speaker turn gets its own language detection (EN → RU switches).
                updateJob(id) { $0.status = .diarizing }
                let speakers = try await Diarizer.shared.diarize(wavURL: wav)
                if stopRequested {
                    updateJob(id) { $0.status = .cancelled }
                    return
                }
                updateJob(id) { $0.status = .transcribing(progress: 0) }
                let allowed = Languages.ordered(allowedLanguages)
                let output = try await MultilingualTranscriber.transcribe(
                    wav: wav,
                    speakers: speakers,
                    model: modelURL,
                    ffmpeg: ffmpeg,
                    serverBinary: serverBinary,
                    allowedLanguages: allowed,
                    isCancelled: { [weak self] in self?.stopRequested ?? true },
                    onProgress: onProgress
                )
                if stopRequested {
                    updateJob(id) { $0.status = .cancelled }
                    return
                }
                if output.blocks.isEmpty {
                    throw CommandFailure(tool: "whisper-server", status: 0, stderrTail: "No speech detected in the file.")
                }
                outputURL = try MarkdownWriter.writeDiarized(
                    blocks: output.blocks,
                    source: job.sourceURL,
                    duration: duration,
                    modelID: model.id,
                    language: output.languages.isEmpty ? "auto" : output.languages.joined(separator: ", "),
                    directory: workDir,
                    extraFrontmatter: captureWarning
                )
            } else if job.diarize {
                let transcription = try await Whisper.transcribeSegments(
                    wav: wav,
                    model: modelURL,
                    language: languageCode,
                    cli: whisper,
                    vadModel: vadModel,
                    initialPrompt: vocabulary,
                    register: registerProcess,
                    onProgress: onProgress
                )
                if transcription.segments.isEmpty {
                    throw CommandFailure(tool: "whisper-cli", status: 0, stderrTail: "No speech detected in the file.")
                }
                if stopRequested {
                    updateJob(id) { $0.status = .cancelled }
                    return
                }
                updateJob(id) { $0.status = .diarizing }
                let speakers = try await Diarizer.shared.diarize(wavURL: wav)
                let blocks = TranscriptMerger.merge(whisper: transcription.segments, speakers: speakers)
                outputURL = try MarkdownWriter.writeDiarized(
                    blocks: blocks,
                    source: job.sourceURL,
                    duration: duration,
                    modelID: model.id,
                    language: transcription.language ?? languageCode,
                    directory: workDir,
                    extraFrontmatter: captureWarning
                )
            } else {
                let text = try await Whisper.transcribe(
                    wav: wav,
                    model: modelURL,
                    language: languageCode,
                    timestamps: timestamps,
                    cli: whisper,
                    vadModel: vadModel,
                    initialPrompt: vocabulary,
                    register: registerProcess,
                    onProgress: onProgress
                )
                if text.isEmpty {
                    throw CommandFailure(tool: "whisper-cli", status: 0, stderrTail: "No speech detected in the file.")
                }
                outputURL = try MarkdownWriter.write(
                    text: text,
                    source: job.sourceURL,
                    duration: duration,
                    modelID: model.id,
                    language: languageCode,
                    directory: workDir,
                    extraFrontmatter: captureWarning
                )
            }
            updateJob(id) { $0.status = .done(outputURL: outputURL) }

            // Best-effort summary; a failure never fails the transcription. Done before ingest
            // so the summary travels into the library copy.
            if autoSummarize, Summarizer.isReady || isLLMReady {
                updateJob(id) { $0.summarizing = true }
                do {
                    try await generateSummary(for: outputURL)
                } catch {
                    alertMessage = "Transcript saved, but summary failed: \(error.localizedDescription)"
                }
                updateJob(id) { $0.summarizing = false }
            }

            // File it in the library (source of truth): copies the transcript and the source
            // audio in, then the scratch copy is dropped with workDir. The job leaves the queue
            // because it now lives in the library.
            let targetProject = ingestProjectID
            // Give the recording a content-based name instead of the raw date stamp; falls back
            // to the date name when no on-device model is available.
            let autoTitle = await generatedTitle(for: outputURL)
            do {
                let item = try library.ingest(
                    transcriptURL: outputURL,
                    audioURL: job.sourceURL,
                    projectID: targetProject,
                    title: autoTitle
                )
                jobs.removeAll { $0.id == id }
                showToast("Added “\(item.title)” to \(projectName(targetProject)).")
            } catch {
                updateJob(id) {
                    $0.status = .failed(message: "Transcript created but could not be added to the library: \(error.localizedDescription)")
                }
            }
        } catch {
            let cancelled = stopRequested
            updateJob(id) { $0.status = cancelled ? .cancelled : .failed(message: error.localizedDescription) }
        }
        currentProcess = nil
    }

    /// `Recording X.m4a` → its `Recording X.mic.m4a` / `Recording X.system.m4a` siblings.
    static func sourceTracks(for source: URL) -> [URL] {
        let base = source.deletingPathExtension()
        return ["mic", "system"]
            .map { base.appendingPathExtension("\($0).m4a") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Display name for a project id (nil == the Unsorted bucket).
    func projectName(_ id: UUID?) -> String {
        guard let id else { return "Unsorted" }
        return library.projects.first { $0.id == id }?.name ?? "Unsorted"
    }
}
