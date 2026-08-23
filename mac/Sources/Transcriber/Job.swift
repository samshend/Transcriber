import Foundation

enum JobStatus: Equatable {
    case queued
    case converting
    case transcribing(progress: Double?)
    case diarizing
    case done(outputURL: URL)
    case failed(message: String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    var isRunning: Bool {
        switch self {
        case .converting, .transcribing, .diarizing: return true
        default: return false
        }
    }
}

struct TranscriptionJob: Identifiable, Equatable {
    let id = UUID()
    let sourceURL: URL
    var diarize = false
    var status: JobStatus = .queued
    var durationSeconds: Double?
    var finishedAt: Date?
    /// Set when the capture itself was faulty (a track died, buffers dropped). Persisted,
    /// because the user needs to know that months later when reading the transcript.
    var recordingWarning: String?
    var summarizing = false  // transient, not persisted

    var isVideo: Bool {
        MediaTypes.videoExtensions.contains(sourceURL.pathExtension.lowercased())
    }

    var sourceExists: Bool {
        FileManager.default.fileExists(atPath: sourceURL.path)
    }
}

// MARK: - Persistence

/// Snapshot of a job saved to disk so the list survives app restarts.
/// Jobs that were mid-flight are restored as queued.
struct PersistedJob: Codable {
    let sourcePath: String
    let diarize: Bool
    let state: String
    let outputPath: String?
    let message: String?
    let duration: Double?
    let finishedAt: Date?
    let recordingWarning: String?

    init(from job: TranscriptionJob) {
        sourcePath = job.sourceURL.path
        diarize = job.diarize
        duration = job.durationSeconds
        finishedAt = job.finishedAt
        recordingWarning = job.recordingWarning
        switch job.status {
        case .done(let outputURL):
            state = "done"
            outputPath = outputURL.path
            message = nil
        case .failed(let failureMessage):
            state = "failed"
            outputPath = nil
            message = failureMessage
        case .cancelled:
            state = "cancelled"
            outputPath = nil
            message = nil
        default:
            state = "queued"
            outputPath = nil
            message = nil
        }
    }

    func toJob() -> TranscriptionJob {
        var job = TranscriptionJob(sourceURL: URL(fileURLWithPath: sourcePath), diarize: diarize)
        job.durationSeconds = duration
        job.finishedAt = finishedAt
        job.recordingWarning = recordingWarning
        switch state {
        case "done" where outputPath != nil:
            job.status = .done(outputURL: URL(fileURLWithPath: outputPath!))
        case "failed":
            job.status = .failed(message: message ?? "Failed")
        case "cancelled":
            job.status = .cancelled
        default:
            job.status = .queued
        }
        return job
    }
}

enum HistoryStore {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Transcriber/history.json")
    }()

    static func load(from url: URL = url) -> [TranscriptionJob] {
        loadPersisted(from: url).map { $0.toJob() }
    }

    /// The raw snapshots — used by the MCP server, which reports job states without
    /// rebuilding the app's in-memory model.
    static func loadPersisted(from url: URL = url) -> [PersistedJob] {
        guard let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode([PersistedJob].self, from: data)
        else { return [] }
        return persisted
    }

    static func save(_ jobs: [TranscriptionJob], to url: URL = url) {
        let persisted = jobs.map { PersistedJob(from: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(persisted) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

enum MediaTypes {
    static let audioExtensions: Set<String> = [
        "ogg", "oga", "opus", "m4a", "mp3", "wav", "aac", "flac",
        "amr", "wma", "caf", "aif", "aiff", "aifc", "au", "mka",
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "webm", "m4v", "3gp", "mpg",
        "mpeg", "wmv", "flv", "ts",
    ]
    static var all: Set<String> { audioExtensions.union(videoExtensions) }
}
