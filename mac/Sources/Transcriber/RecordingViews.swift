import SwiftUI

/// Bottom bar shown while a recording is in progress.
struct RecordingBar: View {
    @ObservedObject var recorder: AudioRecorder
    let onStop: () -> Void
    let onDiscard: () -> Void
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 12, height: 12)
                    .opacity(recorder.isPaused ? 1 : 0.9)

                Text(timeString)
                    .font(.system(.title3, design: .monospaced))
                    .frame(minWidth: 80, alignment: .leading)

                LevelMeter(level: recorder.level)
                    .frame(width: 140, height: 8)

                if !recorder.micLive {
                    Label("Microphone not responding", systemImage: "mic.slash.fill")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                } else if recorder.systemAudioActive {
                    Label("Mic + system audio", systemImage: "speaker.wave.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Microphone", systemImage: "mic")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    recorder.isPaused ? recorder.resume() : recorder.pause()
                } label: {
                    Label(
                        recorder.isPaused ? "Resume" : "Pause",
                        systemImage: recorder.isPaused ? "play.fill" : "pause.fill"
                    )
                }

                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Label("Discard", systemImage: "trash")
                }

                Button {
                    onStop()
                } label: {
                    Label("Stop & Transcribe", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            if let warning = recorder.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(recorder.micLive ? .orange : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) { onDiscard() }
            Button("Keep Recording", role: .cancel) {}
        }
    }

    /// Red dot = recording, orange = paused, and a red *slash* state when the mic stalls —
    /// the one failure that used to be completely invisible.
    private var indicatorColor: Color {
        if !recorder.micLive { return .red }
        return recorder.isPaused ? .orange : .red
    }

    private var timeString: String {
        let total = Int(recorder.elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Shown between "Stop & Transcribe" and the audio file existing on disk. Mixing the
/// microphone and system-audio tracks for a long meeting takes real time, and an empty
/// window there reads as "the app lost my recording".
struct SavingRecordingBar: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Saving recording…")
                        .fontWeight(.semibold)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let progress = recorder.finishProgress {
                    ProgressView(value: progress)
                        .frame(width: 160)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()
            }

            if let warning = recorder.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var detail: String {
        let length = MarkdownWriter.formatDuration(recorder.finishedLength)
        return recorder.finishProgress == nil
            ? "Writing the \(length) audio file — keep the app open."
            : "Mixing microphone and system audio (\(length)) — keep the app open."
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.85 ? Color.orange : Color.green)
                    .frame(width: proxy.size.width * CGFloat(max(0, min(1, level))))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}

/// Renames the transcript `.md` file on disk.
struct RenameFileSheet: View {
    let currentName: String
    let onRename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Transcript")
                .font(.headline)
            TextField("File name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("The .md extension is kept automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = currentName }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        dismiss()
    }
}

/// Loads a diarized transcript, lets the user replace "Speaker 1/2/…" with real names,
/// and rewrites the file.
struct RenameSpeakersSheet: View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var speakers: [(original: String, new: String)] = []
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Speakers")
                .font(.headline)
            Text(fileURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let loadError {
                Text(loadError).foregroundStyle(.red)
            } else if speakers.isEmpty {
                Text("No speaker labels found in this transcript.")
                    .foregroundStyle(.secondary)
            } else {
                Form {
                    ForEach(speakers.indices, id: \.self) { index in
                        TextField(
                            speakers[index].original,
                            text: Binding(
                                get: { speakers[index].new },
                                set: { speakers[index].new = $0 }
                            )
                        )
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(speakers.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { load() }
    }

    private func load() {
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            speakers = Self.speakerLabels(in: content).map { ($0, $0) }
        } catch {
            loadError = "Could not read the transcript: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            var content = try String(contentsOf: fileURL, encoding: .utf8)
            for (original, new) in speakers {
                let trimmed = new.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != original else { continue }
                content = content.replacingOccurrences(of: "**\(original)**\n", with: "**\(trimmed)**\n")
                content = content.replacingOccurrences(of: "\"\(original)\"", with: "\"\(trimmed)\"")
            }
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            dismiss()
        } catch {
            loadError = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Speaker labels are lines like `**Name**` immediately followed by a `MM:SS` line.
    static func speakerLabels(in content: String) -> [String] {
        var labels: [String] = []
        let lines = content.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 else { continue }
            guard index + 1 < lines.count,
                  lines[index + 1].range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
            else { continue }
            let label = String(line.dropFirst(2).dropLast(2))
            if !labels.contains(label) {
                labels.append(label)
            }
        }
        return labels
    }
}
