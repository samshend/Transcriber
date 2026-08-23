import AppKit
import Foundation

/// Hands a finished transcript to an assistant the user already has — the Linear desktop
/// pattern. We never call an API ourselves: no keys, no billing, no data leaving except by
/// the user's own hand.
///
/// Claude Code gets a real session opened in the transcript's folder, so it reads the file
/// itself (no size limit, nothing truncated). ChatGPT has no supported way to inject text,
/// so it gets the clipboard plus a focused window.
@MainActor
enum AskAssistant {
    enum Target: String, Identifiable {
        case claude
        case chatGPT

        var id: String { rawValue }
        var label: String { self == .claude ? "Ask Claude" : "Ask ChatGPT" }
        var symbol: String { self == .claude ? "terminal" : "bubble.left.and.text.bubble.right" }
    }

    static let defaultPrompt = """
        This is a transcript of a recorded conversation, with speaker labels and timestamps. \
        Help me work with it: answer my questions, pull out decisions and action items, and \
        cite the timestamps you used.
        """

    static var claudeCLI: URL? { Tools.find("claude") }

    /// Opens the assistant. Returns a short status line for the UI.
    @discardableResult
    static func ask(transcript: URL, target: Target, prompt: String) throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = trimmed.isEmpty ? defaultPrompt : trimmed

        switch target {
        case .claude:
            if let claude = claudeCLI {
                try openClaudeCode(claude: claude, transcript: transcript, prompt: instructions)
                return "Opened Claude Code for \(transcript.lastPathComponent)."
            }
            copyToClipboard(prompt: instructions, transcript: transcript)
            openApp(preferredPaths: ["/Applications/Claude.app"],
                    bundleIdentifiers: ["com.anthropic.claudefordesktop"],
                    webFallback: "https://claude.ai/new")
            return "Claude Code isn't installed — transcript copied. Paste it into Claude (⌘V)."

        case .chatGPT:
            copyToClipboard(prompt: instructions, transcript: transcript)
            openApp(preferredPaths: ["/Applications/ChatGPT.app"],
                    bundleIdentifiers: ["com.openai.chat", "com.openai.codex"],
                    webFallback: "https://chatgpt.com/")
            return "Transcript copied. Paste it into ChatGPT (⌘V)."
        }
    }

    // MARK: - Claude Code

    /// Writes a throwaway `.command` script and lets Terminal run it, so the user lands in
    /// an interactive Claude Code session in the transcript's folder.
    private static func openClaudeCode(claude: URL, transcript: URL, prompt: String) throws {
        let folder = transcript.deletingLastPathComponent()
        let fullPrompt = "\(prompt)\n\nTranscript file: @\(transcript.lastPathComponent)"
        // Quoted heredoc + unique sentinel: the prompt is passed through literally, so no
        // amount of quotes or backticks in it can break the script.
        let sentinel = "TRANSCRIBER_PROMPT_\(UUID().uuidString.prefix(8))"
        let script = """
            #!/bin/zsh
            cd \(shellQuote(folder.path)) || exit 1
            exec \(shellQuote(claude.path)) "$(cat <<'\(sentinel)'
            \(fullPrompt)
            \(sentinel)
            )"
            """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ask Claude about \(transcript.deletingPathExtension().lastPathComponent).command")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let terminal = NSWorkspace.shared.urlForApplication(toOpen: scriptURL)
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([scriptURL], withApplicationAt: terminal, configuration: configuration) { _, _ in
            // Terminal has read the script by now; don't leave it lying around.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                try? FileManager.default.removeItem(at: scriptURL)
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Clipboard hand-off

    private static func copyToClipboard(prompt: String, transcript: URL) {
        var payload = "\(prompt)\n\nTranscript: \(transcript.lastPathComponent)\n\n"
        if let content = try? String(contentsOf: transcript, encoding: .utf8) {
            payload += MarkdownWriter.contentWithoutFrontmatter(content)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }

    /// Path first, then bundle identifiers: several OpenAI/Anthropic apps can be installed
    /// side by side (ChatGPT vs ChatGPT Classic), and the path is what the user means.
    private static func openApp(preferredPaths: [String], bundleIdentifiers: [String], webFallback: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        for path in preferredPaths where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
            return
        }
        for identifier in bundleIdentifiers {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                NSWorkspace.shared.openApplication(at: app, configuration: configuration)
                return
            }
        }
        if let url = URL(string: webFallback) {
            NSWorkspace.shared.open(url)
        }
    }
}
