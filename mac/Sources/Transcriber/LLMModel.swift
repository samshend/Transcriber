import Foundation

/// A downloadable GGUF chat model used for summaries (and, later, chatting with transcripts).
/// All candidates are Apache-2.0 so they're safe to recommend in a commercial app.
struct LLMModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let repo: String
    let fileName: String
    let sizeGB: Double
    let minimumRAMGB: Int
    let note: String

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)")!
    }

    static let all: [LLMModel] = [
        LLMModel(
            id: "qwen3.5-4b-q5",
            displayName: "Qwen 3.5 4B",
            repo: "unsloth/Qwen3.5-4B-GGUF",
            fileName: "Qwen3.5-4B-Q5_K_M.gguf",
            sizeGB: 3.0,
            minimumRAMGB: 16,
            note: "Recommended: strong multilingual quality (incl. Russian) at a small size."
        ),
        LLMModel(
            id: "gemma-4-e4b-q5",
            displayName: "Gemma 4 E4B",
            repo: "unsloth/gemma-4-E4B-it-GGUF",
            fileName: "gemma-4-E4B-it-Q5_K_M.gguf",
            sizeGB: 5.1,
            minimumRAMGB: 16,
            note: "Very broad language coverage; often a smoother writer for summaries."
        ),
        LLMModel(
            id: "qwen3.5-9b-q5",
            displayName: "Qwen 3.5 9B",
            repo: "unsloth/Qwen3.5-9B-GGUF",
            fileName: "Qwen3.5-9B-Q5_K_M.gguf",
            sizeGB: 6.6,
            minimumRAMGB: 24,
            note: "Higher quality, noticeably slower. Good if you have RAM to spare."
        ),
        LLMModel(
            id: "gemma-4-12b-q5",
            displayName: "Gemma 4 12B",
            repo: "unsloth/gemma-4-12b-it-GGUF",
            fileName: "gemma-4-12b-it-Q5_K_M.gguf",
            sizeGB: 8.6,
            minimumRAMGB: 32,
            note: "Best local quality of these options; needs a roomy Mac."
        ),
    ]

    static func byID(_ id: String) -> LLMModel {
        all.first { $0.id == id } ?? all[0]
    }

    /// Physical RAM in GB, used to warn before downloading something too large.
    static var systemRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    var fitsInRAM: Bool { Self.systemRAMGB >= minimumRAMGB }
}
