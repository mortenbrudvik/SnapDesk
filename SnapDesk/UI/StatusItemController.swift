import AppKit
import KeyboardShortcuts
import UniformTypeIdentifiers

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem: NSStatusItem
    private let recents: RecentsStore
    private weak var launching: (any WorkspaceLaunching)?
    private weak var capturing: (any WorkspaceCapturing)?
    private weak var alerting: (any UserAlerting)?
    private let onEditor: () -> Void
    private let onSettings: () -> Void
    /// Injectable so tests can pin both permission states; the real check hits TCC and the
    /// window server, which a test rig cannot dictate.
    private let accessibilityTrusted: () -> Bool
    private let recentsMenu = NSMenu()
    private let accessibilityItem = NSMenuItem(
        title: "",
        action: #selector(openAccessibilitySettings),
        keyEquivalent: ""
    )

    /// The status-bar menu, exposed for tests.
    var menu: NSMenu {
        statusItem.menu!
    }

    init(
        recents: RecentsStore,
        launching: any WorkspaceLaunching,
        capturing: any WorkspaceCapturing,
        alerting: any UserAlerting,
        onEditor: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        accessibilityTrusted: @escaping () -> Bool = { AccessibilityAuth.isEffectivelyTrusted }
    ) {
        self.recents = recents
        self.launching = launching
        self.capturing = capturing
        self.alerting = alerting
        self.onEditor = onEditor
        self.onSettings = onSettings
        self.accessibilityTrusted = accessibilityTrusted
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "SnapDesk") {
                image.isTemplate = true
                button.image = image
            } else {
                assertionFailure("status bar symbol is missing")
                button.title = "SnapDesk"
            }
        }
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Required by KeyboardShortcuts once menu items show their shortcut via setShortcut(for:):
    // NSMenu runs the thread in tracking mode, so Carbon hot-key events would queue up and all
    // fire at once when the menu closes. Disabling them while it is open drops them instead.
    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.disable(.capture, .editor)
        rebuildRecents()
        updateAccessibilityRow()
    }

    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.enable(.capture, .editor)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let capture = NSMenuItem(title: "Capture", action: #selector(captureWorkspace), keyEquivalent: "")
        capture.target = self
        capture.setShortcut(for: .capture)
        menu.addItem(capture)

        let recentsItem = NSMenuItem(title: "Recents", action: nil, keyEquivalent: "")
        recentsItem.submenu = recentsMenu
        menu.addItem(recentsItem)
        rebuildRecents()

        let editor = NSMenuItem(title: "Editor", action: #selector(openEditor), keyEquivalent: "")
        editor.target = self
        editor.setShortcut(for: .editor)
        menu.addItem(editor)

        let open = NSMenuItem(title: "Open…", action: #selector(openWorkspace), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        updateAccessibilityRow()

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let relaunch = NSMenuItem(title: "Relaunch", action: #selector(relaunch), keyEquivalent: "")
        relaunch.target = self
        menu.addItem(relaunch)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SnapDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func rebuildRecents() {
        recentsMenu.removeAllItems()
        if recents.urls.isEmpty {
            let empty = NSMenuItem(title: "No Recents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsMenu.addItem(empty)
            return
        }
        for url in recents.urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            recentsMenu.addItem(item)
        }
    }

    private func updateAccessibilityRow() {
        accessibilityItem.title = accessibilityTrusted()
            ? "SnapDesk can move windows"
            : "SnapDesk needs Accessibility"
    }

    /// The Accessibility row is a status line, not a command, once permission is working.
    /// Assigning `isEnabled` cannot express that: `NSMenu.autoenablesItems` is on, so AppKit
    /// re-enables every item with a target and an action each time the menu opens, and asks
    /// here instead.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem === accessibilityItem else { return true }
        return !accessibilityTrusted()
    }

    /// Takes the item out of the menu bar. Nothing else removes it — a released controller
    /// leaves its `NSStatusItem` behind — so anything that builds controllers repeatedly, tests
    /// above all, has to say when it is done with one.
    func removeFromStatusBar() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func captureWorkspace() {
        capturing?.captureToEditor()
    }

    @objc private func openEditor() {
        onEditor()
    }

    @objc private func openWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [WorkspaceFileType.contentType]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            launching?.launch(url: url)
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            alerting?.show(
                title: WorkspaceOpener.openFailureTitle(for: url),
                detail: WorkspaceOpener.missingFileDetail
            )
            return
        }
        launching?.launch(url: url)
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityAuth.openSystemSettings()
    }

    @objc private func openSettings() {
        onSettings()
    }

    @objc private func relaunch() {
        AccessibilityAuth.relaunch()
    }
}
