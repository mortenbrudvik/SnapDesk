import AppKit
import SwiftUI

/// The Help window. Built the way `SettingsWindowController` is, for the same reason: an
/// `LSUIElement` app has no app menu, so every window it shows is one it makes itself.
///
/// Resizable and scrollable, unlike Settings — the help is longer than a screen, and a user who
/// wants it beside the app while they follow it should be able to make it the shape they need.
@MainActor
final class HelpWindowController: NSWindowController {
    private var didCenter = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapDesk Help"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.contentViewController = NSHostingController(rootView: HelpView())
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        // Rebuilt on each open, so the shortcut rows show whatever is bound now rather than what
        // was bound the first time the window was made.
        window?.contentViewController = NSHostingController(rootView: HelpView())
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        if !didCenter {
            window?.center()
            didCenter = true
        }
        window?.makeKeyAndOrderFront(sender)
    }
}

/// The window's content: the document inside a scroll view.
struct HelpView: View {
    var body: some View {
        ScrollView {
            HelpDocument()
        }
    }
}

/// The help itself, with no scrolling of its own — so it can be rendered whole and read end to
/// end, which is the only way to judge a page four screens tall. A `ScrollView` clips anything
/// past its own height when rendered offscreen.
struct HelpDocument: View {
    private let topics = HelpContent.topics()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SnapDesk")
                    .font(.title2.weight(.semibold))
                Text("Capture the windows you have open and put them back.")
                    .foregroundStyle(.secondary)
            }

            ForEach(topics) { topic in
                VStack(alignment: .leading, spacing: 10) {
                    Text(topic.title)
                        .font(.headline)
                    ForEach(Array(topic.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.term)
                                .font(.subheadline.weight(.medium))
                            Text(entry.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
