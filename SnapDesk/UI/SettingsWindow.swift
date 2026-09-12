import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: AppSettings
    private var didCenter = false

    private let shortcuts: WorkspaceShortcuts

    init(settings: AppSettings = .shared, shortcuts: WorkspaceShortcuts = WorkspaceShortcuts()) {
        self.settings = settings
        self.shortcuts = shortcuts
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapDesk Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: SettingsView(settings: settings, shortcuts: shortcuts)
        )
        window.setContentSize(NSSize(width: 460, height: 480))
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
    let shortcuts: WorkspaceShortcuts

    /// The picked workspace per slot, mirrored into view state so the rows redraw. The store is
    /// the source of truth; this is seeded from it and written straight back on every change.
    @State private var assigned: [URL?] = []
    @State private var startup: URL?

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Capture", name: .capture)
                KeyboardShortcuts.Recorder("Editor", name: .editor)
            }

            Section("Workspace shortcuts") {
                ForEach(Array(KeyboardShortcuts.Name.workspaceSlots.enumerated()), id: \.offset) { slot, name in
                    HStack {
                        KeyboardShortcuts.Recorder("", name: name)
                        Spacer()
                        Text(assigned.indices.contains(slot) ? (assigned[slot]?.deletingPathExtension().lastPathComponent ?? "No workspace") : "No workspace")
                            .foregroundStyle(assigned.indices.contains(slot) && assigned[slot] != nil ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choose(slot: slot) }
                        if assigned.indices.contains(slot), assigned[slot] != nil {
                            Button("Clear") { assign(nil, to: slot) }
                        }
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if let message = settings.loginItemMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    // "when SnapDesk starts", not "at login": the app cannot tell a login launch
                    // from any other, and a label that means what it says beats one that guesses.
                    Text("Restore when SnapDesk starts")
                    Spacer()
                    Text(startup?.deletingPathExtension().lastPathComponent ?? "Nothing")
                        .foregroundStyle(startup == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") {
                        guard let url = pickWorkspace() else { return }
                        settings.startupWorkspace = url
                        startup = url
                    }
                    if startup != nil {
                        Button("Clear") {
                            settings.startupWorkspace = nil
                            startup = nil
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 480)
        .onAppear {
            assigned = (0..<WorkspaceShortcuts.slotCount).map { shortcuts.workspace(for: $0) }
            startup = settings.startupWorkspace
        }
    }

    private func choose(slot: Int) {
        guard let url = pickWorkspace() else { return }
        assign(url, to: slot)
    }

    private func assign(_ url: URL?, to slot: Int) {
        shortcuts.assign(url, to: slot)
        if assigned.indices.contains(slot) {
            assigned[slot] = url
        }
    }

    private func pickWorkspace() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [WorkspaceFileType.contentType]
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.first
    }
}
