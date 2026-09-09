import Foundation
import os

/// Unified-logging categories. Read them with
/// `log stream --predicate 'subsystem == "com.brudvik.snapdesk"' --level debug`.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.brudvik.snapdesk"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let launch = Logger(subsystem: subsystem, category: "launch")
    static let capture = Logger(subsystem: subsystem, category: "capture")
}
