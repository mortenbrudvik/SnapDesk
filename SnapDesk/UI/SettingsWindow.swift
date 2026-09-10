import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: AppSettings
    private var didCenter = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapDesk Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(settings: settings))
        window.setContentSize(NSSize(width: 420, height: 240))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        // What the pane shows can have changed while it was closed; see `AppSettings.refresh`.
        settings.refresh()
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        // Centred the first time only: after that the window stays where the user dragged it.
        if !didCenter {
            window?.center()
            didCenter = true
        }
        window?.makeKeyAndOrderFront(sender)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: AppSettings

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
