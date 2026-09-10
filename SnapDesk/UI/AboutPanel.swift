import AppKit

/// The About box, which for this app is the only place a version number is visible: SnapDesk is
/// `LSUIElement`, so there is no app menu and no Dock icon to right-click.
///
/// AppKit's standard panel rather than a window of our own. It reads the icon, the name, the
/// version and the copyright straight out of the bundle, so none of them can drift from what the
/// app actually is — a second copy of the version string in code is one more thing to keep in step
/// with `project.yml`, and the one that goes stale is always the one on screen.
@MainActor
enum AboutPanel {
    /// What SnapDesk is, in the words used everywhere else it is described.
    static let summary = "Capture the windows you have open and put them back."

    /// KeyboardShortcuts ships under the MIT licence, which requires its copyright notice to be
    /// included with any copy of the software. This is that notice. If SnapDesk is ever
    /// distributed beyond this machine, ship the full licence text alongside it as well.
    static let acknowledgement = """
        Uses KeyboardShortcuts by Sindre Sorhus
        Copyright © Sindre Sorhus, MIT License
        """

    static var options: [NSApplication.AboutPanelOptionKey: Any] {
        let text = "\(summary)\n\n\(acknowledgement)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [
            .credits: NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            ),
        ]
    }

    /// Activates first, for the same reason every alert in `AccessibilityAuth` does: an
    /// `LSUIElement` app is rarely frontmost, and a panel ordered front without activating opens
    /// behind whatever the user is actually looking at.
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
