import AppKit
import CoreServices
import Foundation

/// Runs AppleScript on a single dedicated, long-lived thread that owns a live run loop.
///
/// This exists because reading browser tabs used to freeze the UI. Two hard constraints force
/// the design:
///  1. `NSAppleScript.executeAndReturnError` must NOT run on the main thread — it blocks the
///     calling thread for the full round-trip of a cross-process Apple Event, and reading every
///     tab of a busy browser can take hundreds of milliseconds, stalling the UI each poll.
///  2. It also can't run on the Swift cooperative pool or an arbitrary GCD queue — AppleScript
///     needs a *running* run loop to receive the Apple Event reply, which those don't provide,
///     so it hangs there. A dedicated `Thread` with its own run loop satisfies both.
///
/// Compiled scripts are cached per source: compilation is itself expensive and was being redone
/// on every poll tick. All mutable state is touched only on `thread`, so no locking is needed.
/// The outcome of one AppleScript run, so callers can tell a permission denial (which the UI
/// must surface) apart from an ordinary failure or an empty result.
enum AppleScriptResult {
    case success(String)
    case denied         // errAEEventNotPermitted (-1743): the Automation permission was refused
    case failed(Int)    // any other AppleScript error number
}

final class AppleScriptRunner: NSObject {
    static let shared = AppleScriptRunner()

    private let thread: Thread
    private var compiled: [String: NSAppleScript] = [:]   // touched only on `thread`

    private override init() {
        let runnerThread = Thread {
            // A persistent port keeps the run loop alive when nothing else is scheduled, so it
            // blocks in `run(...)` waiting for `perform(...)` work instead of returning.
            let loop = RunLoop.current
            loop.add(NSMachPort(), forMode: .default)
            while !Thread.current.isCancelled {
                loop.run(mode: .default, before: .distantFuture)
            }
        }
        runnerThread.name = "dev.semen.transcriber.applescript"
        runnerThread.stackSize = 1 << 20
        self.thread = runnerThread
        super.init()
        runnerThread.start()
    }

    /// Boxes one request so it can cross to the runner thread via `perform(_:on:with:)`.
    private final class Request: NSObject {
        let source: String
        let completion: (AppleScriptResult) -> Void
        init(source: String, completion: @escaping (AppleScriptResult) -> Void) {
            self.source = source
            self.completion = completion
        }
    }

    @objc private func execute(_ request: Request) {
        let script = compiled[request.source] ?? NSAppleScript(source: request.source)
        if let script { compiled[request.source] = script }
        var error: NSDictionary?
        let output = script?.executeAndReturnError(&error)
        if let error {
            // Surface a TCC denial distinctly so the UI can guide the user, instead of the old
            // behaviour where every error (denied, browser hung, no such app) collapsed to nil.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            request.completion(code == errAEEventNotPermitted ? .denied : .failed(code))
        } else {
            request.completion(.success(output?.stringValue ?? ""))
        }
    }

    /// Compile (once) and run `source` on the dedicated thread; returns the result (success text,
    /// permission denial, or error code). Never blocks the caller's thread.
    func run(_ source: String) async -> AppleScriptResult {
        await withCheckedContinuation { continuation in
            let request = Request(source: source) { continuation.resume(returning: $0) }
            perform(#selector(execute(_:)), on: thread, with: request, waitUntilDone: false)
        }
    }
}

enum AppleScriptWarmup {
    /// macOS's XProtect performs a one-time, main-thread-only initialization the first time any
    /// AppleScript runs in a process; if that first run happens on a background thread it can
    /// hang (a documented 2025–2026 regression). Running a trivial script on the main thread at
    /// launch does that init up front so later off-main reads don't stall. Call once, on main.
    static func prewarmOnMain() {
        var error: NSDictionary?
        _ = NSAppleScript(source: "return 1")?.executeAndReturnError(&error)
    }
}

/// Whether Transcriber is allowed to read a specific browser's tabs — the macOS Automation
/// ("Apple Events") permission. Uses `AEDeterminePermissionToAutomateTarget`, the canonical API
/// that both reports the current grant and, with `prompt: true`, surfaces the consent dialog.
/// This is deliberately more explicit than letting a raw off-main AppleScript send trigger the
/// prompt — that path failed silently, which is why detection stopped working after re-signing.
enum AutomationPermission {
    enum Status {
        case authorized, denied, notRunning, notDetermined

        var humanDescription: String {
            switch self {
            case .authorized:    return "allowed"
            case .denied:        return "blocked — allow it in System Settings › Privacy & Security › Automation"
            case .notRunning:    return "not running"
            case .notDetermined: return "waiting for your permission"
            }
        }
    }

    /// Query (and optionally prompt for) permission to control `bundleID`. Synchronous; with
    /// `prompt: true` it BLOCKS until the user answers, so only call it off the main thread. The
    /// dialog is presented by the system, so it appears regardless of which thread calls.
    static func status(bundleID: String, prompt: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let code = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), prompt)
        switch Int(code) {
        case Int(noErr):                        return .authorized
        case errAEEventNotPermitted:            return .denied
        case procNotFound:                      return .notRunning
        case errAEEventWouldRequireUserConsent: return .notDetermined
        default:                                return .denied
        }
    }
}

/// Session memory for the Automation prompt: ask once per browser, and remember the last status
/// so the UI can explain why detection isn't working. An actor so the blocking permission calls
/// run off the main thread and can't race.
actor AutomationPermissionState {
    static let shared = AutomationPermissionState()
    private var prompted: Set<String> = []
    private var status: [String: AutomationPermission.Status] = [:]

    /// Ensure the consent dialog has been shown once for each running browser; refresh statuses.
    func ensurePrompted(_ bundleIDs: [String]) {
        for id in bundleIDs {
            let shouldPrompt = !prompted.contains(id)
            prompted.insert(id)
            status[id] = AutomationPermission.status(bundleID: id, prompt: shouldPrompt)
        }
    }

    /// Read statuses without prompting (for the settings status row).
    func refresh(_ bundleIDs: [String]) {
        for id in bundleIDs { status[id] = AutomationPermission.status(bundleID: id, prompt: false) }
    }

    func statuses() -> [String: AutomationPermission.Status] { status }
}

/// Reads open tab URLs from every running, scriptable browser via AppleScript. This is the one
/// piece that needs the Automation ("control Google Chrome") permission. Async because the read
/// runs off the main thread on `AppleScriptRunner`, so the UI never blocks on a slow browser.
enum BrowserTabs {
    /// AppleScript-scriptable browsers whose open-tab URLs we can read. `name` is the AppleScript
    /// application name; `bundleID` is what NSWorkspace reports.
    static let browsers: [(name: String, bundleID: String)] = [
        ("Google Chrome", "com.google.Chrome"),
        ("Google Chrome Beta", "com.google.Chrome.beta"),
        ("Google Chrome Canary", "com.google.Chrome.canary"),
        ("Google Chrome Dev", "com.google.Chrome.dev"),
        ("Microsoft Edge", "com.microsoft.edgemac"),
        ("Brave Browser", "com.brave.Browser"),
        ("Arc", "company.thebrowser.Browser"),
        ("Vivaldi", "com.vivaldi.Vivaldi"),
        ("Opera", "com.operasoftware.Opera"),
        ("Safari", "com.apple.Safari"),
    ]

    /// Browsers we can see are open but can't read (no usable AppleScript tab dictionary), so the
    /// UI can say "detection won't work here" instead of silently doing nothing.
    static let unsupportedBrowsers: [(name: String, bundleID: String)] = [
        ("Firefox", "org.mozilla.firefox"),
        ("Firefox Developer Edition", "org.mozilla.firefoxdeveloperedition"),
        ("Zen Browser", "app.zen-browser.zen"),
    ]

    static func runningBrowsers() -> [(name: String, bundleID: String)] {
        let running = runningBundleIDs()
        return browsers.filter { running.contains($0.bundleID) }
    }

    static func runningUnsupportedBrowsers() -> [String] {
        let running = runningBundleIDs()
        return unsupportedBrowsers.filter { running.contains($0.bundleID) }.map { $0.name }
    }

    private static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }

    static func urls() async -> [String] {
        let running = runningBrowsers()
        // Ask for permission for each open browser before trying to read it, so the consent
        // dialog actually appears. The old path relied on the off-main AppleScript send to
        // trigger it, which silently failed and left detection dead with no feedback.
        await AutomationPermissionState.shared.ensurePrompted(running.map { $0.bundleID })

        var out: [String] = []
        for browser in running {
            switch await AppleScriptRunner.shared.run(script(for: browser.name)) {
            case .success(let text):
                out += text.split(whereSeparator: \.isNewline).map(String.init)
            case .denied:
                Log.meeting.notice("automation denied for \(browser.name, privacy: .public) — can't read its tabs")
            case .failed(let code):
                Log.meeting.notice("applescript error \(code, privacy: .public) reading \(browser.name, privacy: .public)")
            }
        }
        return out
    }

    private static func script(for app: String) -> String {
        // Same shape works for both the Chromium family and Safari. `with timeout` bounds the
        // worst case if the browser is slow or hung answering the event.
        """
        with timeout of 3 seconds
            tell application "\(app)"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (URL of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
        end timeout
        """
    }
}

/// Watches browser tabs for a meeting to appear and later disappear (you left the call → the tab
/// navigates away or closes). Crucially it keeps scanning: it locks on the first time a meeting
/// shows up — which may be well after recording started — rather than snapshotting once. The tab
/// source is injectable so the logic tests without real AppleScript.
final class BrowserMeetingDetector: MeetingDetector {
    let id = "browser"
    let displayName = "Browser meetings (Google Meet, Teams, Zoom web)"

    private let tabs: () async -> [String]
    private var watchedKey: String?
    private(set) var everLocked = false

    init(tabs: @escaping () async -> [String] = BrowserTabs.urls) { self.tabs = tabs }

    /// Always applicable while browser detection is on — the meeting may not be open yet.
    func begin() async -> Bool { true }

    func poll() async -> MeetingSignal {
        let current = MeetingURL.meetings(in: await tabs())
        if let watchedKey {
            // Locked on: still there → active, gone → ended.
            return current.contains(watchedKey) ? .active : .ended
        }
        // Not yet locked: grab the first meeting that appears.
        if let first = current.sorted().first {
            watchedKey = first
            everLocked = true
            Log.meeting.notice("browser locked onto meeting \(first, privacy: .public)")
            return .active
        }
        return .unknown   // no meeting open yet — keep looking
    }
}

/// Universal fallback: the meeting is "over" once the far side has been silent long enough. Uses
/// the recorder's live silence measurement; injectable for tests.
final class AudioSilenceDetector: MeetingDetector {
    let id = "audio"
    let displayName = "Silence detection (any app)"

    private let silenceSeconds: () -> TimeInterval
    private let threshold: TimeInterval

    /// - Parameter threshold: sustained silence (seconds) that counts as "meeting ended".
    init(threshold: TimeInterval = 150, silenceSeconds: @escaping () -> TimeInterval) {
        self.threshold = threshold
        self.silenceSeconds = silenceSeconds
    }

    func begin() async -> Bool { true }   // always available as a last resort

    func poll() async -> MeetingSignal {
        silenceSeconds() >= threshold ? .ended : .active
    }
}

/// Runs the chosen detector on a timer and reports, once, when the meeting is judged ended.
/// Browser detection is preferred; audio-silence is the fallback when no app-specific detector
/// locks on. AppState owns what happens next (notify → confirm → long-grace auto-stop).
@MainActor
final class MeetingWatcher {
    private let detectors: [MeetingDetector]
    private let interval: TimeInterval
    private var task: Task<Void, Never>?
    private var onEnded: (() -> Void)?

    /// - Parameter interval: how often to poll. Short, because ending a call should feel
    ///   immediate; an AppleScript tab read is cheap and a tab reload keeps the same URL, so a
    ///   fast poll won't misfire.
    init(detectors: [MeetingDetector], interval: TimeInterval = 3) {
        self.detectors = detectors
        self.interval = interval
    }

    /// Convenience wiring for the app: browser first, audio-silence fallback.
    static func standard(
        browserEnabled: Bool,
        audioEnabled: Bool,
        silenceSeconds: @escaping () -> TimeInterval
    ) -> MeetingWatcher {
        var detectors: [MeetingDetector] = []
        if browserEnabled { detectors.append(BrowserMeetingDetector()) }
        if audioEnabled { detectors.append(AudioSilenceDetector(silenceSeconds: silenceSeconds)) }
        return MeetingWatcher(detectors: detectors)
    }

    func start(onEnded: @escaping () -> Void) {
        self.onEnded = onEnded
        task = Task { [weak self] in
            guard let self else { return }

            let browser = detectors.first { $0.id == "browser" }
            let audio = detectors.first { $0.id == "audio" }
            let useBrowser = await browser?.begin() ?? false
            let useAudio = await audio?.begin() ?? false
            Log.meeting.notice("watching (browser=\(useBrowser, privacy: .public) audio=\(useAudio, privacy: .public)); scanning continuously for a meeting to start and end")
            guard useBrowser || useAudio else { return }

            // Browser is authoritative once it has actually seen a meeting. Silence is only a
            // fallback for when no browser meeting is ever detected (e.g. Zoom desktop), so a
            // quiet moment mid-call can't false-trigger it.
            let browserDecider = MeetingEndDecider(endedPollsRequired: 2)   // ~6s at a 3s interval
            let audioDecider = MeetingEndDecider(endedPollsRequired: 1)     // silence already timed
            var browserSawMeeting = false

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }

                if useBrowser, let browser {
                    let signal = await browser.poll()
                    if signal == .active { browserSawMeeting = true }
                    Log.meeting.debug("browser poll -> \(String(describing: signal), privacy: .public)")
                    if browserDecider.accept(signal) {
                        Log.meeting.notice("browser: meeting ended")
                        onEnded(); return
                    }
                }
                // Only consult silence while no browser meeting has been seen this session.
                if useAudio, let audio, !browserSawMeeting {
                    let signal = await audio.poll()
                    Log.meeting.debug("audio poll -> \(String(describing: signal), privacy: .public)")
                    if audioDecider.accept(signal) {
                        Log.meeting.notice("audio: sustained silence — meeting ended")
                        onEnded(); return
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// The dedup rule for proactive suggestions, as a plain value type so it's trivially testable:
/// suggest each meeting once, forget it when it ends (so re-joining suggests again), and stay
/// quiet while recording (marking the ongoing meeting as known so it isn't suggested on stop).
struct MeetingSuggestionState {
    private(set) var suggested: Set<String> = []

    mutating func step(current: Set<String>, isRecording: Bool, isEnabled: Bool) -> [String] {
        guard isEnabled else { return [] }
        suggested.formIntersection(current)        // forget meetings that ended
        guard !isRecording else {
            suggested.formUnion(current)           // don't suggest what we're already recording
            return []
        }
        let fresh = current.subtracting(suggested).sorted()
        suggested.formUnion(fresh)
        return fresh
    }
}

/// The proactive counterpart to `MeetingWatcher`: runs while you are NOT recording and nudges
/// "want to record this?" when a meeting appears (Bluedot-style).
@MainActor
final class MeetingStartMonitor {
    private let interval: TimeInterval
    private let tabs: () async -> [String]
    private let isEnabled: () -> Bool
    private let isRecording: () -> Bool
    private var task: Task<Void, Never>?
    private var onDetected: ((String) -> Void)?
    private var state = MeetingSuggestionState()

    init(
        interval: TimeInterval = 15,
        tabs: @escaping () async -> [String] = BrowserTabs.urls,
        isEnabled: @escaping () -> Bool,
        isRecording: @escaping () -> Bool
    ) {
        self.interval = interval
        self.tabs = tabs
        self.isEnabled = isEnabled
        self.isRecording = isRecording
    }

    /// One scan. Returns meeting keys newly worth suggesting.
    func scanOnce() async -> [String] {
        guard isEnabled() else { return [] }   // skip the browser read entirely when off
        return state.step(
            current: MeetingURL.meetings(in: await tabs()),
            isRecording: isRecording(),
            isEnabled: true
        )
    }

    func start(onDetected: @escaping (String) -> Void) {
        self.onDetected = onDetected
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                for key in await scanOnce() {
                    Log.meeting.notice("meeting detected while not recording: \(key, privacy: .public)")
                    onDetected(key)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
