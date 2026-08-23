import Foundation
import os

/// Lightweight logging so a real recording session leaves a trail in Console.app.
/// Filter with: `log stream --predicate 'subsystem == "dev.semen.transcriber"'`
enum Log {
    static let meeting = Logger(subsystem: "dev.semen.transcriber", category: "meeting")
    static let recording = Logger(subsystem: "dev.semen.transcriber", category: "recording")
}
