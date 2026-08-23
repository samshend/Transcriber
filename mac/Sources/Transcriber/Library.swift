import Foundation

/// A user-created grouping of transcripts, like a ChatGPT/Claude project.
struct Project: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var notes: String = ""
    var created: Date = Date()
}

/// One transcript in the managed library. The transcript `.md` and (optionally) a copy of the
/// source audio live in `Library/<id>/`; the fields below are denormalised from the transcript's
/// frontmatter so the list can render without opening every file.
struct LibraryItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var projectID: UUID?          // nil == the built-in "Unsorted" bucket
    var title: String
    var transcriptFile: String    // filename inside Library/<id>/
    var audioFile: String?        // filename inside Library/<id>/, if audio was copied in
    var created: Date = Date()
    var modified: Date = Date()

    // Denormalised for display.
    var durationSeconds: Double?
    var language: String?
    var speakers: [String] = []
    var hasSummary: Bool = false
    var recordingWarning: String?
    var sourceName: String?
}

/// The on-disk index. Bumping `version` lets future migrations detect an old layout.
struct LibraryIndex: Codable {
    var version: Int = 1
    var projects: [Project] = []
    var items: [LibraryItem] = []
}

/// Owns the managed library: the `Library/` folder, its `library.json` index, and every
/// mutation. The library is the source of truth for transcripts — files are copied *in* on
/// ingest and only ever leave through `export`. Deliberately holds no reference to `AppState`
/// so the same store can be driven from tests and (later) the MCP process.
final class LibraryStore: ObservableObject {
    @Published private(set) var index = LibraryIndex()

    let root: URL

    /// - Parameter root: the `Library` directory. Tests pass a temp dir for isolation.
    init(root: URL = AppPaths.support.appendingPathComponent("Library", isDirectory: true)) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    var indexURL: URL { root.appendingPathComponent("library.json") }
    private func itemFolder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    // MARK: - Convenience reads

    var projects: [Project] { index.projects.sorted { $0.created < $1.created } }
    var items: [LibraryItem] { index.items.sorted { $0.modified > $1.modified } }

    func items(in projectID: UUID?) -> [LibraryItem] {
        items.filter { $0.projectID == projectID }
    }

    func transcriptURL(for item: LibraryItem) -> URL {
        itemFolder(item.id).appendingPathComponent(item.transcriptFile)
    }

    func audioURL(for item: LibraryItem) -> URL? {
        item.audioFile.map { itemFolder(item.id).appendingPathComponent($0) }
    }

    // MARK: - Projects

    @discardableResult
    func createProject(name: String, notes: String = "") -> Project {
        let project = Project(name: name.trimmingCharacters(in: .whitespaces), notes: notes)
        index.projects.append(project)
        save()
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        guard let i = index.projects.firstIndex(where: { $0.id == id }) else { return }
        index.projects[i].name = name.trimmingCharacters(in: .whitespaces)
        save()
    }

    func setNotes(_ id: UUID, notes: String) {
        guard let i = index.projects.firstIndex(where: { $0.id == id }) else { return }
        index.projects[i].notes = notes
        save()
    }

    /// Deleting a project keeps its transcripts — they fall back to Unsorted.
    func deleteProject(_ id: UUID) {
        for i in index.items.indices where index.items[i].projectID == id {
            index.items[i].projectID = nil
        }
        index.projects.removeAll { $0.id == id }
        save()
    }

    // MARK: - Items

    /// Copies a transcript (and optionally its audio) into the library and records it.
    /// The originals are never modified.
    @discardableResult
    func ingest(
        transcriptURL: URL,
        audioURL: URL? = nil,
        projectID: UUID? = nil,
        title: String? = nil,
        copyAudio: Bool = true
    ) throws -> LibraryItem {
        let id = UUID()
        let folder = itemFolder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let displayTitle = title ?? transcriptURL.deletingPathExtension().lastPathComponent
        let mdName = Self.sanitize(displayTitle) + ".md"
        let mdDestination = folder.appendingPathComponent(mdName)
        try FileManager.default.copyItem(at: transcriptURL, to: mdDestination)

        var audioName: String?
        if copyAudio, let audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
            let name = Self.sanitize(displayTitle) + "." + audioURL.pathExtension
            let destination = folder.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: audioURL, to: destination)
            if FileManager.default.fileExists(atPath: destination.path) { audioName = name }
        }

        var item = LibraryItem(
            id: id,                       // must match the folder created above
            projectID: projectID,
            title: displayTitle,
            transcriptFile: mdName,
            audioFile: audioName,
            sourceName: audioURL?.lastPathComponent
        )
        applyMetadata(to: &item, from: mdDestination)

        index.items.append(item)
        save()
        return item
    }

    /// Refreshes the denormalised fields from the transcript on disk (call after editing the .md).
    func refreshMetadata(_ id: UUID) {
        guard let i = index.items.firstIndex(where: { $0.id == id }) else { return }
        applyMetadata(to: &index.items[i], from: transcriptURL(for: index.items[i]))
        index.items[i].modified = Date()
        save()
    }

    func move(_ id: UUID, to projectID: UUID?) {
        guard let i = index.items.firstIndex(where: { $0.id == id }) else { return }
        index.items[i].projectID = projectID
        index.items[i].modified = Date()
        save()
    }

    /// Renames the item: moves the transcript `.md` (and its sibling audio) on disk, rewrites the
    /// `# heading` inside the transcript, and updates the record. Renaming the *file* is what keeps
    /// search and the MCP server consistent, since both title a transcript by its filename.
    @discardableResult
    func rename(_ id: UUID, to newTitle: String) -> Bool {
        guard let i = index.items.firstIndex(where: { $0.id == id }) else { return false }
        let clean = newTitle.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return false }

        let folder = itemFolder(id)
        let currentMD = index.items[i].transcriptFile
        let base = uniqueBase(Self.sanitize(clean), in: folder, keeping: currentMD)

        // Move the transcript. If this fails we abort without touching the record.
        let oldMD = folder.appendingPathComponent(currentMD)
        let newMDName = base + ".md"
        let newMD = folder.appendingPathComponent(newMDName)
        if newMD != oldMD {
            do {
                try FileManager.default.moveItem(at: oldMD, to: newMD)
            } catch {
                Log.recording.error("rename: could not move transcript: \(error.localizedDescription, privacy: .public)")
                return false
            }
            index.items[i].transcriptFile = newMDName
        }

        // Move the sibling audio to match, keeping its extension. Best-effort.
        if let audio = index.items[i].audioFile {
            let oldAudio = folder.appendingPathComponent(audio)
            let ext = (audio as NSString).pathExtension
            let newAudioName = base + (ext.isEmpty ? "" : "." + ext)
            let newAudio = folder.appendingPathComponent(newAudioName)
            if newAudio != oldAudio, FileManager.default.fileExists(atPath: oldAudio.path) {
                try? FileManager.default.moveItem(at: oldAudio, to: newAudio)
                if FileManager.default.fileExists(atPath: newAudio.path) {
                    index.items[i].audioFile = newAudioName
                }
            }
        }

        // Keep the in-file H1 in sync so the transcript reads right when opened directly.
        rewriteHeading(at: newMD, to: clean)

        index.items[i].title = clean
        index.items[i].modified = Date()
        save()
        return true
    }

    /// Picks a filename base that doesn't collide with another file in `folder`, ignoring the
    /// item's own current transcript. Appends " 2", " 3", … on collision.
    private func uniqueBase(_ base: String, in folder: URL, keeping currentMD: String) -> String {
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while candidate + ".md" != currentMD,
              fm.fileExists(atPath: folder.appendingPathComponent(candidate + ".md").path) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    /// Replaces the first Markdown H1 (`# …`) in the transcript with `title`. No-op if absent.
    private func rewriteHeading(at url: URL, to title: String) {
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return }
        lines[idx] = "# " + title
        content = lines.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Permanently removes the library's copy (transcript + audio). Never touches anything the
    /// user has elsewhere on disk.
    func deleteItem(_ id: UUID) {
        try? FileManager.default.removeItem(at: itemFolder(id))
        index.items.removeAll { $0.id == id }
        save()
    }

    enum ExportKind { case transcript, audio }

    /// Copies the stored transcript or audio out to a user-chosen location and name.
    /// Returns the written URL. Duplicates are expected and fine.
    @discardableResult
    func export(_ id: UUID, kind: ExportKind, to destination: URL) throws -> URL {
        guard let item = index.items.first(where: { $0.id == id }) else {
            throw LibraryError.notFound
        }
        let source: URL?
        switch kind {
        case .transcript: source = transcriptURL(for: item)
        case .audio: source = audioURL(for: item)
        }
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            throw LibraryError.missingFile
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    // MARK: - Migration

    private var migrationMarker: URL { root.appendingPathComponent(".migrated") }

    /// One-time import of transcripts produced before the library existed. Copies each `.md`
    /// (and its sibling audio if still present) into an "Unsorted" item. Idempotent: a marker
    /// file ensures it runs once, and it never moves or deletes the originals.
    func migrateIfNeeded(transcriptPaths: [URL], audioResolver: (URL) -> URL? = { _ in nil }) {
        guard !FileManager.default.fileExists(atPath: migrationMarker.path) else { return }

        for md in transcriptPaths where FileManager.default.fileExists(atPath: md.path) {
            let audio = audioResolver(md)
            _ = try? ingest(transcriptURL: md, audioURL: audio, projectID: nil)
        }
        FileManager.default.createFile(atPath: migrationMarker.path, contents: nil)
        save()
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // must match save()'s encoder
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? decoder.decode(LibraryIndex.self, from: data) else { return }
        index = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Helpers

    private func applyMetadata(to item: inout LibraryItem, from md: URL) {
        guard let entry = TranscriptIndex.load(md) else { return }
        item.language = entry.languages.joined(separator: ", ").ifEmptyNil
        item.speakers = entry.speakers
        item.hasSummary = entry.hasSummary
        item.durationSeconds = Self.seconds(from: entry.duration)
        item.recordingWarning = entry.recordingWarningText
        if item.sourceName == nil { item.sourceName = entry.sourceName }
        item.modified = entry.modified ?? item.modified
    }

    /// "44:42" / "1:07:06" -> seconds.
    static func seconds(from label: String?) -> Double? {
        guard let label else { return nil }
        let parts = label.split(separator: ":").map { Double($0) ?? 0 }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return nil
        }
    }

    /// Filesystem-safe filename component (mirrors FileRenamer's rules).
    static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "transcript" : cleaned
    }

    enum LibraryError: Error { case notFound, missingFile }
}

private extension String {
    var ifEmptyNil: String? { isEmpty ? nil : self }
}

private extension TranscriptEntry {
    /// The library stores `recording_warning:` as plain metadata; TranscriptEntry doesn't parse
    /// it, so pull it straight from the frontmatter when present.
    var recordingWarningText: String? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return TranscriptIndex.frontmatter(data)["recording_warning"]
    }
}
