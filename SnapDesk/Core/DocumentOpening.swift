import AppKit

/// Opening a document, page or folder in a named application.
///
/// A seam of its own rather than another method on `ApplicationLaunching`, because the difference
/// between the two calls is the entire point of the feature. Launch arguments reach a *new*
/// instance only: hand them to an app that is already running and they are discarded.
/// `NSWorkspace.open(_:withApplicationAt:configuration:)` puts the document into the app either
/// way — launching it if it is not running, handing it to the running one if it is.
///
/// What the app then does with it is the app's choice, and was measured rather than assumed:
/// TextEdit and Terminal open a window per document, while Safari and Brave both put a document
/// handed to a running instance into a *tab* of an existing window — so a workspace of three
/// browser pages would come back as one window with three tabs and two slots reporting "No
/// window". Chromium-based browsers offer a way around that, which `ChromiumHandoff` takes.
@MainActor
protocol DocumentOpening {
    func open(_ url: URL, withApplicationAt app: URL, configuration: LaunchConfiguration) async throws
}

/// How a Chromium-based browser is asked for a window rather than a tab.
///
/// Measured on Brave: a new-instance launch with `--new-window <document>` raised the running
/// instance's window count from one to two. Chromium's process singleton forwards a second
/// process's arguments to the running one, which opens a window, and the second process exits —
/// so the arguments reach a running browser after all, through a launch rather than an open. The
/// marker is `CrProductDirName`, which Chromium's build writes into every browser built on it and
/// which Safari's Info.plist lacks.
///
/// With `moveExistingWindows` off this cannot help: the window appears in the pre-existing
/// instance, whose windows that mode deliberately leaves out of the pool — which was already the
/// case for a plain launch of a Chromium browser, since a second instance always hands off.
enum ChromiumHandoff {
    static let marker = "CrProductDirName"

    static func isChromiumApp(infoPlist: [String: Any]) -> Bool {
        infoPlist[marker] != nil
    }

    static func isChromiumApp(at appURL: URL) -> Bool {
        guard let info = Bundle(url: appURL)?.infoDictionary else { return false }
        return isChromiumApp(infoPlist: info)
    }

    /// `--new-window` first, so the document is what it applies to; the slot's own arguments
    /// follow.
    static func arguments(opening url: URL, then arguments: [String]) -> [String] {
        ["--new-window", url.absoluteString] + arguments
    }
}

/// The production conformance. Mirrors `NSWorkspaceLauncher`: it translates `LaunchConfiguration`
/// and does nothing else, so every decision about what to open and what a refusal means stays in
/// `LaunchService`, where it is testable against a fake — apart from the one platform fact above,
/// which belongs to the call that has to act on it.
@MainActor
struct NSWorkspaceDocumentOpener: DocumentOpening {
    func open(_ url: URL, withApplicationAt app: URL, configuration: LaunchConfiguration) async throws {
        let nsConfiguration = NSWorkspace.OpenConfiguration()
        // A restore places windows itself and raises them in its own order; letting each open
        // steal focus would leave whichever app answered last on top instead of slot 0.
        nsConfiguration.activates = configuration.activates
        if ChromiumHandoff.isChromiumApp(at: app) {
            nsConfiguration.createsNewApplicationInstance = true
            nsConfiguration.arguments = ChromiumHandoff.arguments(opening: url, then: configuration.arguments)
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: nsConfiguration)
            return
        }
        nsConfiguration.arguments = configuration.arguments
        nsConfiguration.createsNewApplicationInstance = configuration.createsNewApplicationInstance
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: nsConfiguration)
    }
}
