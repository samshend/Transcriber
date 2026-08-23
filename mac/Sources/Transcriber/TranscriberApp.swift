import SwiftUI

/// Keeps the app running after its window is closed so the background meeting monitor can keep
/// suggesting recordings. Quit with ⌘Q; reopen a window from the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct TranscriberApp: App {
    @StateObject private var app = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `--mcp` turns this same binary into a stdio MCP server; neither path returns.
        MCPServer.runIfRequested()
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(models: app.modelManager, recorder: app.recorder)
                .environmentObject(app)
                .frame(minWidth: 620, minHeight: 440)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }

        // Always-visible presence so recording/meeting status is reachable even when the main
        // window is closed and the app is monitoring in the background.
        MenuBarExtra("Transcriber", systemImage: "waveform") {
            MenuBarContent(recorder: app.recorder)
                .environmentObject(app)
        }

        Settings {
            SettingsView(models: app.modelManager)
                .environmentObject(app)
        }
    }
}

/// The menu-bar dropdown: current state and the actions you'd want without opening the window.
struct MenuBarContent: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var recorder: AudioRecorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(recorder.isRecording ? "Recording…" : "Not recording")

        if recorder.isRecording {
            Button("Stop & Save Recording") { app.stopRecordingAndTranscribe() }
        } else {
            Button("Start Recording") { app.startRecording() }
        }

        Divider()

        Button("Open Transcriber") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Quit Transcriber") { NSApplication.shared.terminate(nil) }
    }
}
