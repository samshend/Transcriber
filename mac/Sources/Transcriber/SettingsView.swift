import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var models: ModelManager
    @State private var mcpStatus: String?
    @State private var mcpFailed = false
    @State private var isAddingMCP = false

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            speakersTab.tabItem { Label("Speakers", systemImage: "person.2") }
            recordingTab.tabItem { Label("Recording", systemImage: "record.circle") }
            summariesTab.tabItem { Label("Summaries", systemImage: "sparkles") }
            integrationsTab.tabItem { Label("AI & MCP", systemImage: "link") }
            toolsTab.tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 520)
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section("Speech model") {
                Picker("Model", selection: $app.modelID) {
                    ForEach(WhisperModel.all) { model in
                        Text("\(model.displayName) — \(model.sizeMB) MB").tag(model.id)
                    }
                }
                Text(app.selectedModel.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                modelStatusRow
            }

            Section("Transcription") {
                Picker("Language", selection: $app.language) {
                    ForEach(Languages.withAuto, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Toggle("Include timestamps in transcript", isOn: $app.includeTimestamps)
                Toggle("Skip silence (recommended)", isOn: $app.useVAD)
                Text("Without this, speech recognition invents sentences during silent stretches — "
                     + "subtitle credits and stray phrases that were never said. Also makes "
                     + "transcription faster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom vocabulary") {
                TextEditor(text: $app.customVocabulary)
                    .font(.body)
                    .frame(minHeight: 60)
                Text("Names, jargon and terms that come up in your recordings, separated by "
                     + "commas. Spelling these out here is the most effective way to get them "
                     + "transcribed correctly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var speakersTab: some View {
        Form {
            Section("Speakers") {
                Toggle("Detect who is speaking in recordings", isOn: $app.diarizeRecordings)
                Toggle("Detect who is speaking in added files", isOn: $app.diarizeImported)
                Toggle("Handle mixed languages", isOn: $app.multilingualMode)
                Text("For speaker-detected files with language set to Auto: each speaker turn gets its own language detection, so meetings can switch languages (e.g. English → Russian) mid-conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if app.multilingualMode {
                    DisclosureGroup("Languages to detect (\(allowedSummary))") {
                        Text("Pick only the languages that actually occur in your meetings. Anything else whisper thinks it hears is re-transcribed as the current language — this stops stray French/Portuguese/Ukrainian lines. Leave all off to allow any language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(Languages.supported, id: \.code) { language in
                            Toggle(language.name, isOn: Binding(
                                get: { app.allowedLanguages.contains(language.code) },
                                set: { isOn in
                                    if isOn { app.allowedLanguages.insert(language.code) }
                                    else { app.allowedLanguages.remove(language.code) }
                                }
                            ))
                        }
                    }
                }
                Text("Speaker detection runs a local diarization model (downloaded once, ~100 MB). Transcripts get \"Speaker 1/2/…\" labels with timing — rename them from the job list afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var summariesTab: some View {
        Form {
            Section("On-device summaries") {
                Toggle("Summarize automatically after transcribing", isOn: $app.autoSummarize)
                Picker("Engine", selection: $app.summaryEngine) {
                    ForEach(SummaryEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                Text(engineExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if app.summaryEngine != .localModel {
                    summaryStatusRow
                }
                if app.summaryEngine != .appleIntelligence {
                    llmSection
                }
            }

            Section("Summary prompt") {
                TextEditor(text: $app.summaryPrompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if app.summaryPrompt.isEmpty {
                            Text(Summarizer.defaultPromptTemplate)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Text("Leave empty to use the default shown above. The transcript is appended after your instructions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { app.summaryPrompt = "" }
                        .disabled(app.summaryPrompt.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var integrationsTab: some View {
        Form {
            Section("Ask Claude / Ask ChatGPT") {
                Text("Every finished transcript has an assistant menu (and a right-click menu) that starts a session about it. Claude Code opens in the transcript's folder and reads the file itself; ChatGPT gets the transcript on the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $app.askPrompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 80)
                    .overlay(alignment: .topLeading) {
                        if app.askPrompt.isEmpty {
                            Text(AskAssistant.defaultPrompt)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Text("The opening message sent to the assistant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { app.askPrompt = "" }
                        .disabled(app.askPrompt.isEmpty)
                }
                if let claude = AskAssistant.claudeCLI {
                    Label("Claude Code found at \(claude.path)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("The `claude` CLI wasn't found — Ask Claude falls back to the clipboard.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Let Claude read your transcripts (MCP)") {
                Text("Runs this app as a local MCP server so Claude can list, search and read your transcripts, and queue new audio for transcription. Nothing is uploaded — Claude talks to the app on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Add to Claude Code") { addToClaudeCode() }
                        .disabled(MCPSetup.claudeCLI == nil || isAddingMCP)
                    if isAddingMCP { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Copy command") { copy(MCPSetup.claudeCodeCommand) }
                }
                if let mcpStatus {
                    Text(mcpStatus)
                        .font(.caption)
                        .foregroundStyle(mcpFailed ? .red : .green)
                        .textSelection(.enabled)
                }

                DisclosureGroup("Claude Desktop / Codex (manual)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Claude Desktop — add to claude_desktop_config.json:")
                            .font(.caption)
                        Text(MCPSetup.claudeDesktopConfig)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Button("Copy JSON") { copy(MCPSetup.claudeDesktopConfig) }
                            Button("Reveal config file") {
                                NSWorkspace.shared.activateFileViewerSelecting([MCPSetup.claudeDesktopConfigURL])
                            }
                        }
                        Divider()
                        Text("Codex CLI — add to ~/.codex/config.toml:")
                            .font(.caption)
                        Text(MCPSetup.codexConfig)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy TOML") { copy(MCPSetup.codexConfig) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("ChatGPT can't connect to local MCP servers (its connectors are remote only) — use Ask ChatGPT for that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var recordingTab: some View {
        Form {
            Section("Recording") {
                Toggle("Also capture system audio (for online calls)", isOn: $app.captureSystemAudio)
                Text("Captures what you hear (the other side of a call) in addition to your microphone. macOS will ask for the System Audio Recording permission once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep the separate microphone and system tracks", isOn: $app.keepSourceTracks)
                Text("Saves `<name>.mic.m4a` and `<name>.system.m4a` next to the mixed recording. Each holds one side only, so if a capture misbehaves nothing is lost, and speaker attribution can be redone from clean audio. Costs roughly 30 MB per hour per track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Recordings folder")
                    Spacer()
                    Text(app.recordingsFolder.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseRecordingsFolder() }
                }
            }

            Section("Stop recording automatically") {
                Toggle("Remind me when a meeting ends", isOn: $app.detectMeetingEnd)
                if app.detectMeetingEnd {
                    Toggle("Detect browser meetings (Google Meet, Teams, Zoom web)", isOn: $app.detectBrowserMeetings)
                    Text("Reads your open browser tabs to notice when you leave a call. macOS asks permission once. Works with Chrome, Safari, Edge, Brave, Arc, Vivaldi and Opera.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Fall back to silence detection (any app, e.g. Zoom)", isOn: $app.detectSilenceFallback)
                    Text("When no browser meeting is found, treat a few minutes of silence on the call audio as the meeting ending.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Auto-stop 10 minutes after it ends if I don't respond", isOn: $app.autoStopAfterMeetingEnd)
                }
                Text("Only runs while recording a call with system audio. You always get a notification first.")
                    .font(.caption).foregroundStyle(.secondary)
                if app.detectMeetingEnd && !app.captureSystemAudio {
                    Label("This needs “Also capture system audio” (above) turned on — meeting-end detection only runs while recording a call.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Suggest recording") {
                Toggle("Remind me to record when a meeting starts", isOn: $app.suggestRecording)
                Text("While you're not recording, Transcriber notices when you join a Google Meet, Teams or Zoom-web call and asks whether to record it. Uses the same browser-tab permission as above, and keeps working when the window is closed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Check meeting detection") {
                if app.automationPermissionDenied {
                    HStack(alignment: .top) {
                        Label("Transcriber is blocked from reading your browser tabs, so it can't detect meetings. Allow it under Automation, then test again.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") { openAutomationSettings() }
                    }
                }
                Button("Test detection now") { app.testMeetingDetection() }
                if let report = app.meetingDetectionReport {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Open your meeting in a browser first, then click Test. This shows whether Transcriber can see the call and has the permissions it needs — and asks for any permission it's still missing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { app.refreshAutomationStatus() }
    }

    private var toolsTab: some View {
        Form {
            Section("Library") {
                Text("Transcripts and a copy of their audio are kept privately inside the app and organised into projects. Nothing is written elsewhere on your Mac. To get a file out, use **Export** on a transcript (Save to Downloads, choose a folder, or rename it on the way out).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tools") {
                toolRow(name: "whisper-cli", url: app.whisperURL)
                if !app.missingTools.isEmpty {
                    HStack {
                        Label("Some built-in tools are missing (\(app.missingTools.joined(separator: ", "))). Try reinstalling Transcriber.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Re-check") { app.refreshTools() }
                    }
                }
            }

            Section("ffmpeg (optional plugin)") {
                Text("Most files decode without any extra install. ffmpeg only adds support for a few less-common formats — ogg, opus, mkv, webm, and a handful of others.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                toolRow(name: "ffmpeg", url: app.ffmpegURL)
                HStack {
                    Text("Custom path")
                    Spacer()
                    Text(app.customFFmpegPath.isEmpty ? "auto-detect" : app.customFFmpegPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFFmpegPath() }
                    if !app.customFFmpegPath.isEmpty {
                        Button("Clear") { app.customFFmpegPath = ""; app.refreshTools() }
                    }
                }
                Text("Don't have it? `brew install ffmpeg`, or download a build and point this at the binary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var engineExplanation: String {
        switch app.summaryEngine {
        case .automatic:
            return "Uses Apple Intelligence when it supports the transcript's language, and the downloaded model otherwise (Apple's model doesn't support Russian or Ukrainian). Both run on-device."
        case .appleIntelligence:
            return "Instant and needs no download, but only covers Apple's supported languages."
        case .localModel:
            return "Works for any language including Russian. Needs a one-time model download."
        }
    }

    @ViewBuilder
    private var llmSection: some View {
        Picker("Model", selection: $app.llmModelID) {
            ForEach(LLMModel.all) { model in
                Text("\(model.displayName) — \(String(format: "%.1f", model.sizeGB)) GB").tag(model.id)
            }
        }
        Text(app.selectedLLM.note)
            .font(.caption)
            .foregroundStyle(.secondary)

        if !app.selectedLLM.fitsInRAM {
            Label(
                "This model wants \(app.selectedLLM.minimumRAMGB) GB of RAM; this Mac has \(LLMModel.systemRAMGB) GB.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }

        if LlamaServer.binary == nil {
            HStack {
                Label("The language-model helper is missing. Try reinstalling Transcriber.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Re-check") { app.refreshTools() }
            }
        }

        if models.isDownloaded(app.selectedLLM) {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if models.downloadingModelID == app.selectedLLM.id {
            HStack {
                ProgressView(value: models.downloadProgress)
                Text("\(Int(models.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { models.cancelDownload() }
            }
        } else {
            HStack {
                Label("Not downloaded", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download") { models.download(app.selectedLLM) }
                    .disabled(models.downloadingModelID != nil)
            }
        }
    }

    @ViewBuilder
    private var summaryStatusRow: some View {
        switch Summarizer.state {
        case .ready:
            Label("Apple Intelligence is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unsupportedOS:
            Label("Requires macOS 26 or later", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var allowedSummary: String {
        let allowed = Languages.ordered(app.allowedLanguages)
        if allowed.isEmpty { return "any" }
        return allowed.map { Languages.name(for: $0) }.joined(separator: ", ")
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        let model = app.selectedModel
        if models.isDownloaded(model) {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if models.downloadingModelID == model.id {
            HStack {
                ProgressView(value: models.downloadProgress)
                Text("\(Int(models.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { models.cancelDownload() }
            }
        } else {
            HStack {
                Label("Not downloaded", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download") { models.download(model) }
                    .disabled(models.downloadingModelID != nil)
            }
            if let error = models.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func toolRow(name: String, url: URL?) -> some View {
        HStack {
            Text(name)
            Spacer()
            if let url {
                Text(url.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Label("Not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        mcpFailed = false
        mcpStatus = "Copied to the clipboard."
    }

    /// Runs `claude mcp add` for the user. Undo with `claude mcp remove transcriber`.
    private func addToClaudeCode() {
        isAddingMCP = true
        Task {
            do {
                let output = try await MCPSetup.addToClaudeCode()
                mcpFailed = false
                mcpStatus = "\(output)\nRestart Claude Code, then ask it to list your transcripts."
            } catch {
                mcpFailed = true
                mcpStatus = error.localizedDescription
            }
            isAddingMCP = false
        }
    }

    /// Opens System Settings straight to Privacy & Security → Automation, the only place to undo
    /// a prior "Don't Allow" (macOS won't re-prompt once denied).
    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func chooseFFmpegPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an ffmpeg binary"
        if panel.runModal() == .OK, let url = panel.urls.first {
            app.customFFmpegPath = url.path
            app.refreshTools()
        }
    }

    private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for meeting recordings"
        if panel.runModal() == .OK, let url = panel.urls.first {
            app.recordingsFolderPath = url.path
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for transcripts"
        if panel.runModal() == .OK, let url = panel.urls.first {
            app.outputFolderPath = url.path
        }
    }
}
