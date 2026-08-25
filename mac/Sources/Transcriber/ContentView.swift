import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var models: ModelManager
    @ObservedObject var recorder: AudioRecorder
    @State private var isDropTargeted = false

    /// NavigationSplitView needs an optional binding; nil maps to "All".
    private var sidebarSelection: Binding<LibrarySelection?> {
        Binding(get: { app.selection }, set: { app.selection = $0 ?? .all })
    }

    var body: some View {
        VStack(spacing: 0) {
            if !app.missingTools.isEmpty {
                missingToolsBanner
            }
            if app.missingTools.isEmpty && !app.isModelReady {
                modelBanner
            }

            NavigationSplitView {
                ProjectsSidebar(selection: sidebarSelection)
                    .navigationSplitViewColumnWidth(min: 170, ideal: 200)
            } content: {
                TranscriptListColumn(selection: app.selection)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300)
                    .toolbar { toolbarContent }
            } detail: {
                TranscriptDetailColumn()
            }

            if recorder.isRecording {
                RecordingBar(
                    recorder: recorder,
                    onStop: { app.stopRecordingAndTranscribe() },
                    onDiscard: { app.discardRecording() }
                )
            } else if recorder.isFinishing {
                SavingRecordingBar(recorder: recorder)
            }
            if let toast = app.toast {
                ToastBar(message: toast) { app.toast = nil }
            }
        }
        .alert(
            "Transcriber",
            isPresented: Binding(
                get: { app.alertMessage != nil },
                set: { if !$0 { app.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alertMessage ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Banners

    private var missingToolsBanner: some View {
        Banner(color: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Missing tools: \(app.missingTools.joined(separator: ", "))")
                    .fontWeight(.semibold)
                Text("These ship inside Transcriber. Try reinstalling the app, then click Re-check.")
            }
            Spacer()
            Button("Re-check") { app.refreshTools() }
        }
    }

    private var modelBanner: some View {
        Banner(color: .blue) {
            if models.downloadingModelID != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading \(app.selectedModel.displayName)…")
                        .fontWeight(.semibold)
                    ProgressView(value: models.downloadProgress)
                        .frame(maxWidth: 320)
                    Text("\(Int(models.downloadProgress * 100))% of \(app.selectedModel.sizeMB) MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { models.cancelDownload() }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech model required")
                        .fontWeight(.semibold)
                    Text("\(app.selectedModel.displayName) (\(app.selectedModel.sizeMB) MB) — downloaded once, then everything runs offline.")
                        .font(.callout)
                    if let error = models.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
                Spacer()
                Button("Download") { models.download(app.selectedModel) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !recorder.isRecording {
                Button {
                    app.startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .foregroundStyle(.red)
                }
                .help("Record a meeting or conversation")
            }

            Button {
                pickFiles()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add audio/video files or folders")

            if app.isProcessing {
                Button {
                    app.stopAll()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop everything and clear the queue")
            } else if app.hasQueuedJobs {
                Button {
                    app.start()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(!app.isReadyToRun)
                .help("Start transcribing the queue")
            }

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Model, language and output settings")
        }
    }

    // MARK: - Input

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose audio/video files, or folders to scan for them"
        if panel.runModal() == .OK {
            app.add(urls: panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    app.add(urls: [url])
                }
            }
        }
        return handled
    }
}

// MARK: - Toast

/// Self-dismissing status line for things that happen outside the job list:
/// assistant hand-offs, files requested over MCP, a finished recording.
private struct ToastBar: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Banner container

private struct Banner<Content: View>: View {
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
