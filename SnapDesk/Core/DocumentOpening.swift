import AppKit

/// Opening a document, page or folder in a named application.
///
/// A seam of its own rather than another method on `ApplicationLaunching`, because the difference
/// between the two calls is the entire point of the feature. Launch arguments reach a *new*
/// instance only: hand them to an app that is already running and they are discarded, which is why
/// a workspace of three browser windows restored to a running browser used to come back as one.
/// `NSWorkspace.open(_:withApplicationAt:configuration:)` puts the document into the app either
/// way — launching it if it is not running, adding a window if it is.
@MainActor
protocol DocumentOpening {
    func open(_ url: URL, withApplicationAt app: URL, configuration: LaunchConfiguration) async throws
}

/// The production conformance. Mirrors `NSWorkspaceLauncher`: it translates `LaunchConfiguration`
/// and does nothing else, so every decision about what to open and what a refusal means stays in
/// `LaunchService`, where it is testable against a fake.
@MainActor
struct NSWorkspaceDocumentOpener: DocumentOpening {
    func open(_ url: URL, withApplicationAt app: URL, configuration: LaunchConfiguration) async throws {
        let nsConfiguration = NSWorkspace.OpenConfiguration()
        nsConfiguration.arguments = configuration.arguments
        nsConfiguration.createsNewApplicationInstance = configuration.createsNewApplicationInstance
        // A restore places windows itself and raises them in its own order; letting each open
        // steal focus would leave whichever app answered last on top instead of slot 0.
        nsConfiguration.activates = configuration.activates
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: nsConfiguration)
    }
}
