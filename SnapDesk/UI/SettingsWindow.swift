import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: AppSettings
    private var didCenter = false

    private let shortcuts: WorkspaceShortcuts

    init(settings: AppSettings = .shared, shortcuts: WorkspaceShortcuts) {
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
                    WorkspaceChoiceRow(
                        workspace: assigned.indices.contains(slot) ? assigned[slot] : nil,
                        emptyText: "No workspace",
                        onChoose: { choose(slot: slot) },
                        onClear: { assign(nil, to: slot) }
                    ) {
                        KeyboardShortcuts.Recorder("", name: name)
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
                WorkspaceChoiceRow(
                    workspace: startup,
                    emptyText: "Nothing",
                    onChoose: {
                        guard let url = pickWorkspace() else { return }
                        settings.startupWorkspace = url
                        startup = url
                    },
                    onClear: {
                        settings.startupWorkspace = nil
                        startup = nil
                    }
                ) {
                    // "When SnapDesk starts", not "at login"; see `AppSettings.startupWorkspace`.
                    Text("Restore when SnapDesk starts")
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

/// One "what is bound here, Choose…, Clear" row. The five workspace shortcuts and the startup
/// workspace are the same control with a different label, so they are one view.
private struct WorkspaceChoiceRow<Label: View>: View {
    var workspace: URL?
    /// What to show when nothing is chosen: the shortcut rows say "No workspace", the startup row
    /// says "Nothing", because the sentence around each is different.
    var emptyText: String
    var onChoose: () -> Void
    var onClear: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        HStack {
            label
            Spacer()
            Text(WorkspaceChoice.text(for: workspace, empty: emptyText))
                .foregroundStyle(workspace == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…", action: onChoose)
            if workspace != nil {
                Button("Clear", action: onClear)
            }
        }
    }
}

/// What a picker row shows for its workspace. A file that is gone says so: the bookmark stores
/// answer with the last known path for a deleted file, and a row that named it as if present
/// would leave the user to learn otherwise from the next key press.
enum WorkspaceChoice {
    static func text(for workspace: URL?, empty: String) -> String {
        guard let workspace else { return empty }
        let name = workspace.deletingPathExtension().lastPathComponent
        return FileManager.default.fileExists(atPath: workspace.path) ? name : "\(name) (missing)"
    }
}
