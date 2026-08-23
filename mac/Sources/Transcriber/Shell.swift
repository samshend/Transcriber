import Foundation

struct CommandOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct CommandFailure: LocalizedError {
    let tool: String
    let status: Int32
    let stderrTail: String

    var errorDescription: String? {
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "\(tool) failed (exit code \(status))" : "\(tool): \(detail)"
    }
}

/// Runs an external tool, streaming stderr lines to `onStderrLine` (called on a
/// background queue). `register` receives the Process so the caller can terminate it.
func runProcess(
    _ executable: URL,
    _ arguments: [String],
    register: ((Process) -> Void)? = nil,
    onStderrLine: ((String) -> Void)? = nil
) async throws -> CommandOutput {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let collector = OutputCollector(onStderrLine: onStderrLine)
    outPipe.fileHandleForReading.readabilityHandler = { fh in
        let data = fh.availableData
        if !data.isEmpty { collector.appendStdout(data) }
    }
    errPipe.fileHandleForReading.readabilityHandler = { fh in
        let data = fh.availableData
        if !data.isEmpty { collector.appendStderr(data) }
    }

    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { finished in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if let rest = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil, !rest.isEmpty {
                collector.appendStdout(rest)
            }
            if let rest = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil, !rest.isEmpty {
                collector.appendStderr(rest)
            }
            continuation.resume(returning: CommandOutput(
                status: finished.terminationStatus,
                stdout: collector.stdoutString,
                stderr: collector.stderrString
            ))
        }
        do {
            try process.run()
            register?(process)
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "transcriber.output-collector")
    private var stdout = Data()
    private var stderr = Data()
    private var lineBuffer = ""
    private let onStderrLine: ((String) -> Void)?

    init(onStderrLine: ((String) -> Void)?) {
        self.onStderrLine = onStderrLine
    }

    func appendStdout(_ data: Data) {
        queue.sync { stdout.append(data) }
    }

    func appendStderr(_ data: Data) {
        queue.sync {
            stderr.append(data)
            guard let callback = onStderrLine,
                  let chunk = String(data: data, encoding: .utf8) else { return }
            lineBuffer += chunk
            while let newline = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[..<newline.lowerBound])
                lineBuffer = String(lineBuffer[newline.upperBound...])
                callback(line)
            }
        }
    }

    var stdoutString: String { queue.sync { String(data: stdout, encoding: .utf8) ?? "" } }
    var stderrString: String { queue.sync { String(data: stderr, encoding: .utf8) ?? "" } }
}
