import Foundation
import os

/// Lightweight logging so a real recording session leaves a trail in Console.app.
/// Filter with: `log stream --predicate 'subsystem == "com.samshend.transcriber"'`
enum Log {
    static let meeting = Logger(subsystem: "com.samshend.transcriber", category: "meeting")
    static let recording = Logger(subsystem: "com.samshend.transcriber", category: "recording")
}
