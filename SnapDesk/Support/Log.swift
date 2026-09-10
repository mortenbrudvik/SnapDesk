import Foundation
import os

/// Unified-logging categories. Read them with
/// `log stream --predicate 'subsystem == "<the app's bundle identifier>"' --level debug`,
/// which is `com.brudvik.snapdesk` unless the bundle identifier in `project.yml` has changed —
/// the subsystem below follows it rather than a copy of it.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.brudvik.snapdesk"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let launch = Logger(subsystem: subsystem, category: "launch")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    /// The editor window's own file IO: opening, saving, trashing and reloading a workspace.
    static let editor = Logger(subsystem: subsystem, category: "editor")
    static let displays = Logger(subsystem: subsystem, category: "displays")
}
