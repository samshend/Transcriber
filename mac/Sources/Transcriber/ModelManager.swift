import Foundation

struct WhisperModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sizeMB: Int
    let note: String

    var fileName: String { "ggml-\(id).bin" }
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    static let all: [WhisperModel] = [
        WhisperModel(
            id: "large-v3-turbo-q5_0",
            displayName: "Large v3 Turbo (compressed)",
            sizeMB: 574,
            note: "Recommended: near best-in-class accuracy, fast, all languages."
        ),
        WhisperModel(
            id: "large-v3-turbo",
            displayName: "Large v3 Turbo (full)",
            sizeMB: 1620,
            note: "Slightly better accuracy than the compressed variant, uses more RAM."
        ),
        WhisperModel(
            id: "small",
            displayName: "Small",
            sizeMB: 488,
            note: "Much faster, noticeably less accurate. Good for quick drafts."
        ),
    ]

    static func byID(_ id: String) -> WhisperModel {
        all.first { $0.id == id } ?? all[0]
    }
}

/// Downloads whisper model files into Application Support and tracks what is available.
/// All URLSession callbacks are delivered on the main queue.
final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let modelsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Transcriber/models", isDirectory: true)
    }()

    @Published private(set) var downloadedIDs: Set<String> = []
    @Published private(set) var downloadedLLMIDs: Set<String> = []
    @Published private(set) var downloadingModelID: String?
    @Published private(set) var downloadProgress: Double = 0
    @Published var errorMessage: String?

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var activeTask: URLSessionDownloadTask?
    private var activeModel: WhisperModel?
    private var activeLLM: LLMModel?

    override init() {
        super.init()
        refreshDownloaded()
    }

    func refreshDownloaded() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.modelsDirectory.path)) ?? []
        downloadedIDs = Set(WhisperModel.all.filter { files.contains($0.fileName) }.map(\.id))
        downloadedLLMIDs = Set(LLMModel.all.filter { files.contains($0.fileName) }.map(\.id))
    }

    // MARK: - Chat models (GGUF)

    func localURL(for model: LLMModel) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.fileName)
    }

    func isDownloaded(_ model: LLMModel) -> Bool {
        downloadedLLMIDs.contains(model.id)
    }

    func download(_ model: LLMModel) {
        guard downloadingModelID == nil else { return }
        errorMessage = nil
        downloadingModelID = model.id
        downloadProgress = 0
        activeLLM = model
        activeModel = nil
        let task = session.downloadTask(with: model.downloadURL)
        activeTask = task
        task.resume()
    }

    func localURL(for model: WhisperModel) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.fileName)
    }

    func isDownloaded(_ model: WhisperModel) -> Bool {
        downloadedIDs.contains(model.id)
    }

    func download(_ model: WhisperModel) {
        guard downloadingModelID == nil else { return }
        errorMessage = nil
        downloadingModelID = model.id
        downloadProgress = 0
        activeModel = model
        activeLLM = nil
        let task = session.downloadTask(with: model.downloadURL)
        activeTask = task
        task.resume()
    }

    func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        activeModel = nil
        activeLLM = nil
        downloadingModelID = nil
        downloadProgress = 0
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        defer {
            activeTask = nil
            activeModel = nil
            activeLLM = nil
            downloadingModelID = nil
            refreshDownloaded()
        }
        // Either a whisper model or a GGUF chat model is in flight.
        let destination: URL
        if let model = activeModel {
            destination = localURL(for: model)
        } else if let llm = activeLLM {
            destination = localURL(for: llm)
        } else {
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            errorMessage = "Download failed (HTTP \(http.statusCode))."
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            errorMessage = "Could not save model: \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code != NSURLErrorCancelled {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
        activeTask = nil
        activeModel = nil
        downloadingModelID = nil
        downloadProgress = 0
    }
}
