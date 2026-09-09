import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapDesk Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.setContentSize(NSSize(width: 420, height: 240))
        self.init(window: window)
        self.window?.title = "SnapDesk Settings"
    }

    override func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
    }
}

private struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Capture", name: .capture)
                KeyboardShortcuts.Recorder("Editor", name: .editor)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if let message = settings.loginItemMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 240)
    }
}
