import AppKit
import AVFoundation
import SwiftUI

// MARK: - Audio playback

/// Minimal player for a transcript's stored audio: play/pause and scrub. One instance lives in
/// the detail pane and is re-pointed whenever the selected transcript changes.
@MainActor
final class AudioPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func load(_ url: URL?) {
        guard loadedURL != url else { return }
        stop()
        loadedURL = url
        duration = 0
        currentTime = 0
        guard let url, FileManager.default.fileExists(atPath: url.path) else { player = nil; return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.invalidate()
        } else {
            player.play()
            isPlaying = true
            ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.player else { return }
                    self.currentTime = p.currentTime
                }
            }
        }
    }

    func seek(to time: Double) {
        player?.currentTime = time
        currentTime = time
    }

    func stop() {
        player?.stop()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.ticker?.invalidate()
        }
    }
}

// MARK: - Sidebar

/// Projects list: All / Unsorted / each project. Selection drives the middle column and where
/// new transcripts are filed. Projects (and Unsorted) accept dragged transcripts.
struct ProjectsSidebar: View {
    @EnvironmentObject private var app: AppState
    @Binding var selection: LibrarySelection?
    @State private var newProject = false
    @State private var editing: Project?

    var body: some View {
        List(selection: $selection) {
            Label("All", systemImage: "tray.full").tag(LibrarySelection.all)

            Label("Unsorted", systemImage: "tray")
                .tag(LibrarySelection.unsorted)
                .dropDestination(for: String.self) { ids, _ in moveDropped(ids, to: nil) }

            Section("Projects") {
                ForEach(app.library.projects) { project in
                    Label(project.name, systemImage: "folder")
                        .tag(LibrarySelection.project(project.id))
                        .dropDestination(for: String.self) { ids, _ in moveDropped(ids, to: project.id) }
                        .contextMenu {
                            Button("Edit…") { editing = project }
                            Button("Delete Project", role: .destructive) { app.deleteProject(project.id) }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { newProject = true } label: {
                Label("New Project", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(isPresented: $newProject) {
            ProjectSheet(title: "New Project", name: "", notes: "") { name, _ in app.createProject(name: name) }
        }
        .sheet(item: $editing) { project in
            ProjectSheet(title: "Edit Project", name: project.name, notes: project.notes) { name, notes in
                app.renameProject(project.id, to: name)
                app.setProjectNotes(project.id, notes: notes)
            }
        }
    }

    private func moveDropped(_ ids: [String], to projectID: UUID?) -> Bool {
        let uuids = ids.compactMap(UUID.init)
        for id in uuids { app.moveItem(id, to: projectID) }
        return !uuids.isEmpty
    }
}

// MARK: - Middle column: the transcript list

struct TranscriptListColumn: View {
    @EnvironmentObject private var app: AppState
    let selection: LibrarySelection

    private var items: [LibraryItem] {
        switch selection {
        case .all: return app.library.items
        case .unsorted: return app.library.items(in: nil)
        case .project(let id): return app.library.items(in: id)
        }
    }

    private var projectNotes: String? {
        if case .project(let id) = selection {
            return app.library.projects.first { $0.id == id }?.notes.nonEmpty
        }
        return nil
    }

    private var isAllView: Bool {
        if case .all = selection { return true }
        return false
    }

    var body: some View {
        List(selection: $app.selectedItemID) {
            if let projectNotes {
                Text(projectNotes).font(.callout).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            if !app.jobs.isEmpty {
                Section("Processing") {
                    ForEach(app.jobs) { job in ProcessingRow(job: job) }
                }
            }
            if items.isEmpty && app.jobs.isEmpty {
                emptyState.listRowSeparator(.hidden)
            } else {
                ForEach(items) { item in
                    // The project badge is only informative when projects are mixed together,
                    // i.e. the "All" view; inside a project every row would show the same tag.
                    ItemRow(item: item, showProjectBadge: isAllView)
                        .tag(item.id)
                        .draggable(item.id.uuidString)
                        .contextMenu { ItemMenu(item: item) }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(title)
    }

    private var title: String {
        switch selection {
        case .all: return "All Transcripts"
        case .unsorted: return "Unsorted"
        case .project(let id): return app.library.projects.first { $0.id == id }?.name ?? "Project"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No transcripts yet").font(.title3)
            Text("Record a call, or drop an audio or video file onto the window.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

private struct ItemRow: View {
    @EnvironmentObject private var app: AppState
    let item: LibraryItem
    var showProjectBadge = false

    /// The project this transcript is filed under, if any (nil == Unsorted).
    private var projectName: String? {
        guard let id = item.projectID else { return nil }
        return app.library.projects.first { $0.id == id }?.name
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if let d = item.durationSeconds {
                        Text(MarkdownWriter.formatDuration(d)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let lang = item.language {
                        Text(lang.uppercased()).font(.caption2).foregroundStyle(.secondary)
                    }
                    if item.hasSummary {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(.secondary)
                    }
                    if item.recordingWarning != nil {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    if showProjectBadge, let projectName {
                        ProjectBadge(name: projectName)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

/// Small pill showing which project a transcript is filed under — so it's clear at a glance,
/// in the "All" view, which transcripts are already categorised.
private struct ProjectBadge: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "folder.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

// MARK: - Detail column: preview + audio

struct TranscriptDetailColumn: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var audio = AudioPlayerModel()
    @State private var bodyText = ""
    @State private var renaming = false
    @State private var renamingSpeakers = false
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let item = app.selectedItem {
                content(for: item)
            } else {
                placeholder
            }
        }
        .onChange(of: app.selectedItemID) { load(app.selectedItem) }
        .onAppear { load(app.selectedItem) }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Select a transcript").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(for item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.title2).fontWeight(.semibold)
                    .lineLimit(2).textSelection(.enabled)
                HStack(spacing: 10) {
                    if let d = item.durationSeconds { metaLabel(MarkdownWriter.formatDuration(d), "clock") }
                    if let lang = item.language { metaLabel(lang.uppercased(), "globe") }
                    if !item.speakers.isEmpty { metaLabel("\(item.speakers.count)", "person.2") }
                    if item.hasSummary { metaLabel("Summary", "sparkles") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let warning = item.recordingWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                }
            }
            .padding()

            if item.audioFile != nil {
                AudioControls(audio: audio).padding(.horizontal).padding(.bottom, 8)
            }

            Divider()

            ScrollView {
                Text(bodyText.isEmpty ? "…" : bodyText)
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .toolbar { detailToolbar(item) }
        .sheet(isPresented: $renaming) {
            RenameFileSheet(currentName: item.title) { app.renameItem(item, to: $0) }
        }
        .sheet(isPresented: $renamingSpeakers, onDismiss: { app.refreshItem(item); load(item) }) {
            RenameSpeakersSheet(fileURL: app.library.transcriptURL(for: item))
        }
        .confirmationDialog(
            "Delete “\(item.title)” permanently? The transcript and its audio copy are removed. Your original file is not affected.",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                app.deleteItem(item)
                app.selectedItemID = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func metaLabel(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
    }

    @ToolbarContentBuilder
    private func detailToolbar(_ item: LibraryItem) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { NSWorkspace.shared.open(app.library.transcriptURL(for: item)) } label: {
                Image(systemName: "doc.text")
            }
            .help("Open transcript in the default app")

            Button { NSWorkspace.shared.activateFileViewerSelecting([app.library.transcriptURL(for: item)]) } label: {
                Image(systemName: "folder")
            }
            .help("Reveal the transcript file in Finder")

            Menu {
                ItemMenu(item: item, renaming: $renaming, renamingSpeakers: $renamingSpeakers, confirmingDelete: $confirmingDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func load(_ item: LibraryItem?) {
        guard let item else { audio.load(nil); bodyText = ""; return }
        audio.load(app.library.audioURL(for: item))
        let url = app.library.transcriptURL(for: item)
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            bodyText = MarkdownWriter.contentWithoutFrontmatter(content)
        } else {
            bodyText = ""
        }
    }
}

private struct AudioControls: View {
    @ObservedObject var audio: AudioPlayerModel

    var body: some View {
        HStack(spacing: 12) {
            Button { audio.togglePlay() } label: {
                Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.borderless)
            .disabled(audio.loadedURL == nil)

            Text(time(audio.currentTime)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { audio.currentTime }, set: { audio.seek(to: $0) }),
                in: 0...max(audio.duration, 0.1)
            )
            Text(time(audio.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func time(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Shared item menu

/// The per-transcript actions, shared by the list's context menu and the detail toolbar. The
/// sheet/dialog bindings are optional so the context-menu use (which has no local sheet state)
/// can still trigger rename/delete via a lightweight fallback.
struct ItemMenu: View {
    @EnvironmentObject private var app: AppState
    let item: LibraryItem
    var renaming: Binding<Bool>? = nil
    var renamingSpeakers: Binding<Bool>? = nil
    var confirmingDelete: Binding<Bool>? = nil

    var body: some View {
        Button { NSWorkspace.shared.open(app.library.transcriptURL(for: item)) } label: {
            Label("Open Transcript", systemImage: "doc.text")
        }
        Button { NSWorkspace.shared.activateFileViewerSelecting([app.library.transcriptURL(for: item)]) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Menu {
            Button("Save to Downloads") { exportToDownloads(.transcript) }
            Button("Save As…") { exportWithPanel(.transcript) }
            if item.audioFile != nil {
                Divider()
                Button("Save Audio to Downloads") { exportToDownloads(.audio) }
                Button("Save Audio As…") { exportWithPanel(.audio) }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        Menu {
            Button("Unsorted") { app.move(item, to: nil) }
            if !app.library.projects.isEmpty { Divider() }
            ForEach(app.library.projects) { project in
                Button(project.name) { app.move(item, to: project.id) }
            }
        } label: {
            Label("Move to", systemImage: "folder")
        }
        if let renaming {
            Button { renaming.wrappedValue = true } label: { Label("Rename", systemImage: "pencil") }
        }
        if !item.speakers.isEmpty, let renamingSpeakers {
            Button { renamingSpeakers.wrappedValue = true } label: { Label("Rename Speakers", systemImage: "person.2") }
        }
        if !item.hasSummary {
            Button { app.summarize(item: item) } label: { Label("Summarize", systemImage: "sparkles") }
        }
        Button { app.ask(item: item, target: .claude) } label: { Label("Ask Claude", systemImage: "terminal") }
        Button { app.ask(item: item, target: .chatGPT) } label: {
            Label("Ask ChatGPT", systemImage: "bubble.left.and.text.bubble.right")
        }
        Divider()
        if let confirmingDelete {
            Button(role: .destructive) { confirmingDelete.wrappedValue = true } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) {
                app.deleteItem(item)
                if app.selectedItemID == item.id { app.selectedItemID = nil }
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        }
    }

    private func exportToDownloads(_ kind: LibraryStore.ExportKind) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        app.export(item, kind: kind, to: downloads.appendingPathComponent(app.exportName(for: item, kind: kind)))
    }

    private func exportWithPanel(_ kind: LibraryStore.ExportKind) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = app.exportName(for: item, kind: kind)
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { app.export(item, kind: kind, to: url) }
    }
}

// MARK: - Processing row (transient jobs)

private struct ProcessingRow: View {
    @EnvironmentObject private var app: AppState
    let job: TranscriptionJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.isVideo ? "film" : "waveform").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.sourceURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                status
            }
            Spacer()
            if !job.status.isRunning {
                Button { app.remove(job) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var status: some View {
        switch job.status {
        case .queued: Text("Queued").font(.caption).foregroundStyle(.secondary)
        case .converting: Text("Extracting audio…").font(.caption).foregroundStyle(.blue)
        case .transcribing(let progress):
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress).frame(width: 120)
                    Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.caption).foregroundStyle(.blue)
                }
            }
        case .diarizing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Detecting speakers…").font(.caption).foregroundStyle(.blue)
            }
        case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        case .cancelled: Text("Stopped").font(.caption).foregroundStyle(.secondary)
        case .done: EmptyView()
        }
    }
}

// MARK: - Project sheet

private struct ProjectSheet: View {
    let title: String
    @State var name: String
    @State var notes: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
            Text("Notes (optional)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $notes).font(.body).frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed, notes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }
}

private extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
