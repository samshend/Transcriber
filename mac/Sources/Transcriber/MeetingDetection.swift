import Foundation

/// Where a meeting is happening, and a stable id that stays constant while you're in the call
/// and disappears once you leave. Watching that id come and go is how we know a meeting ended.
struct MeetingRef: Equatable {
    let platform: String   // "meet", "teams", "zoom", "webex", "whereby"
    let id: String         // stable within a call, e.g. the Meet code
    var key: String { "\(platform):\(id)" }
}

/// Recognises meeting URLs (any browser) and extracts the stable meeting id. Pure and testable.
enum MeetingURL {
    static func match(_ raw: String) -> MeetingRef? {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
        let path = url.path
        let full = raw.lowercased()

        // Google Meet: meet.google.com/abc-defg-hij
        if host == "meet.google.com" {
            let code = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if code.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil {
                return MeetingRef(platform: "meet", id: code)
            }
            return nil
        }
        // Microsoft Teams: a join URL carries a "19:meeting_…@thread.v2" conversation id.
        if host.contains("teams.microsoft.com") || host.contains("teams.live.com") {
            if let range = full.range(of: "19:meeting_[a-z0-9]+", options: .regularExpression) {
                return MeetingRef(platform: "teams", id: String(full[range]))
            }
            if full.contains("meetup-join") || full.contains("/meet/") {
                return MeetingRef(platform: "teams", id: shortHash(full))
            }
            return nil
        }
        // Zoom web client: …zoom.us/wc/<id>/… or /j/<id>
        if host.hasSuffix("zoom.us") {
            if let range = full.range(of: "/(wc|j)/(\\d{9,})", options: .regularExpression) {
                let digits = full[range].split(separator: "/").last.map(String.init) ?? shortHash(full)
                return MeetingRef(platform: "zoom", id: digits)
            }
            return nil
        }
        // Webex
        if host.contains("webex.com"), full.contains("/meet") || full.contains("/join") {
            return MeetingRef(platform: "webex", id: shortHash(host + path))
        }
        // Whereby
        if host.hasSuffix("whereby.com"), path.count > 1 {
            return MeetingRef(platform: "whereby", id: path)
        }
        return nil
    }

    /// The set of meetings currently open across a list of tab URLs.
    static func meetings(in tabURLs: [String]) -> Set<String> {
        Set(tabURLs.compactMap { match($0)?.key })
    }

    private static func shortHash(_ s: String) -> String { String(UInt64(bitPattern: Int64(s.hashValue)), radix: 36) }
}

/// One read from a detector.
enum MeetingSignal: Equatable { case active, ended, unknown }

/// A source of meeting-still-going signals. Concrete detectors watch a browser tab, a local
/// app, or (the universal fallback) system-audio silence.
protocol MeetingDetector: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// Lock onto a meeting to watch. Returns false if this detector has nothing to watch now.
    func begin() async -> Bool
    func poll() async -> MeetingSignal
}

/// Turns a stream of per-poll signals into a single, debounced "the meeting ended" decision.
/// Pure state machine so the timing logic is unit-testable.
final class MeetingEndDecider {
    private(set) var everActive = false
    private var consecutiveEnded = 0
    let endedPollsRequired: Int

    /// - Parameter endedPollsRequired: consecutive `.ended` reads before we believe it (debounce).
    init(endedPollsRequired: Int = 3) { self.endedPollsRequired = endedPollsRequired }

    /// Feeds one signal; returns true exactly once, when the meeting is judged ended.
    func accept(_ signal: MeetingSignal) -> Bool {
        switch signal {
        case .active:
            everActive = true
            consecutiveEnded = 0
        case .unknown:
            consecutiveEnded = 0
        case .ended:
            // Only trust "ended" after we saw the meeting actually running, so we never fire
            // on a call that never started.
            guard everActive else { return false }
            consecutiveEnded += 1
            if consecutiveEnded == endedPollsRequired { return true }
        }
        return false
    }
}
