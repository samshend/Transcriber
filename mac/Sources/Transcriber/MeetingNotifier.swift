import Foundation
import UserNotifications

/// Delivers the "meeting looks finished" alert as a system notification (so it reaches the user
/// even when the app isn't in front of them — the whole point) and routes its two actions back
/// to the app. Kept as an NSObject because `UNUserNotificationCenterDelegate` requires one.
@MainActor
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let endedCategoryID = "MEETING_ENDED"
    static let startedCategoryID = "MEETING_STARTED"
    static let stopActionID = "MEETING_STOP_SAVE"
    static let keepActionID = "MEETING_KEEP"
    static let startActionID = "MEETING_START_REC"

    var onStopAndSave: (() -> Void)?
    var onKeepRecording: (() -> Void)?
    var onStartRecording: (() -> Void)?

    private var registered = false

    /// Registers the actionable categories and asks permission (once). Safe to call repeatedly.
    func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if !registered {
            let stop = UNNotificationAction(identifier: Self.stopActionID, title: "Stop & Save",
                                            options: [.foreground])
            let keep = UNNotificationAction(identifier: Self.keepActionID, title: "Keep Recording",
                                            options: [])
            let ended = UNNotificationCategory(identifier: Self.endedCategoryID,
                                               actions: [stop, keep], intentIdentifiers: [])
            let start = UNNotificationAction(identifier: Self.startActionID, title: "Start Recording",
                                             options: [.foreground])
            let started = UNNotificationCategory(identifier: Self.startedCategoryID,
                                                 actions: [start], intentIdentifiers: [])
            center.setNotificationCategories([ended, started])
            registered = true
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.meeting.notice("notification authorization: granted=\(granted) error=\(error?.localizedDescription ?? "none")")
        }
    }

    func notifyMeetingStarted(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.startedCategoryID
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Log.meeting.notice("posted meeting-started notification, error=\(error?.localizedDescription ?? "none")")
        }
    }

    func notifyMeetingEnded(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.endedCategoryID
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Log.meeting.notice("posted meeting-ended notification, error=\(error?.localizedDescription ?? "none")")
        }
    }

    // Show the banner even if the app happens to be frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            switch action {
            case Self.stopActionID:
                self.onStopAndSave?()
            case Self.keepActionID:
                self.onKeepRecording?()
            case Self.startActionID:
                self.onStartRecording?()
            case UNNotificationDefaultActionIdentifier:
                // Tapping the body: only the "start?" notification acts (begins recording);
                // tapping the "ended" one just brings the app forward, never auto-stops.
                if category == Self.startedCategoryID { self.onStartRecording?() }
            default:
                break
            }
            completionHandler()
        }
    }
}
