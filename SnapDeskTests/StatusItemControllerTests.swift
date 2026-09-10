import AppKit
import XCTest
@testable import SnapDesk

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private final class SpyLaunching: WorkspaceLaunching {
        private(set) var launchedURLs: [URL] = []
        private(set) var launchedDocuments: [WorkspaceDocument] = []

        func launch(url: URL) { launchedURLs.append(url) }
        func launch(document: WorkspaceDocument) { launchedDocuments.append(document) }
    }

    private final class SpyCapturing: WorkspaceCapturing {
        private(set) var captureCount = 0

        func captureToEditor() { captureCount += 1 }
    }

    private final class SpyAlerting: UserAlerting {
        private(set) var titles: [String] = []

        func show(title: String, detail: String?) { titles.append(title) }
    }

    /// Shared with the controller's callbacks by reference, so a test can flip the permission
    /// answer or count openings after the controller has been built.
    private final class Environment {
        var accessibilityTrusted: Bool
        var editorOpens = 0
        var settingsOpens = 0

        init(accessibilityTrusted: Bool) {
            self.accessibilityTrusted = accessibilityTrusted
        }
    }

    private struct Fixture {
        let controller: StatusItemController
        let recents: RecentsStore
        let launching: SpyLaunching
        let capturing: SpyCapturing
        let alerting: SpyAlerting
        let environment: Environment
    }

    // MARK: Menu shape

    func testMenuTitlesIncludeCaptureEditorOpenQuitRecentsAndAccessibility() throws {
        let url = try makeWorkspaceFile()
        let fixture = makeFixture()
        // Each controller adds a live item to the real menu bar; nothing takes it away again.
        defer { fixture.controller.removeFromStatusBar() }
        fixture.recents.add(url)
        fixture.controller.menuWillOpen(fixture.controller.menu)

        let titles = fixture.controller.menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Capture"))
        XCTAssertTrue(titles.contains("Editor"))
        XCTAssertTrue(titles.contains("Open…"))
        XCTAssertTrue(titles.contains("Quit SnapDesk"))

        let recentsTitles = try submenuTitles(of: "Recents", in: fixture)
        XCTAssertTrue(recentsTitles.contains { $0.contains(url.lastPathComponent) })

        XCTAssertEqual(try accessibilityRow(in: fixture).title, "SnapDesk needs Accessibility")
    }

    func testEmptyRecentsShowsASinglePlaceholderThatDoesNothing() throws {
        let fixture = makeFixture()
        defer { fixture.controller.removeFromStatusBar() }

        let recentsItem = try item(titled: "Recents", in: fixture.controller.menu)
        let recentsSubmenu = try XCTUnwrap(recentsItem.submenu)

        XCTAssertEqual(recentsSubmenu.items.map(\.title), ["No Recents"])
        XCTAssertNil(recentsSubmenu.items.first?.action, "an item with no action stays greyed out")
    }

    // MARK: Actions

    func testCaptureItemAsksForACapture() throws {
        let fixture = makeFixture()
        defer { fixture.controller.removeFromStatusBar() }

        try perform("Capture", in: fixture.controller.menu)

        XCTAssertEqual(fixture.capturing.captureCount, 1)
    }

    func testEditorAndSettingsItemsCallTheirOpeners() throws {
        let fixture = makeFixture()
        defer { fixture.controller.removeFromStatusBar() }

        try perform("Editor", in: fixture.controller.menu)
        try perform("Settings…", in: fixture.controller.menu)

        XCTAssertEqual(fixture.environment.editorOpens, 1)
        XCTAssertEqual(fixture.environment.settingsOpens, 1)
    }

    func testRecentLaunchesTheWorkspaceItPointsAt() throws {
        let url = try makeWorkspaceFile()
        let fixture = makeFixture()
        defer { fixture.controller.removeFromStatusBar() }
        fixture.recents.add(url)
        fixture.controller.menuWillOpen(fixture.controller.menu)

        try performFirstRecent(in: fixture)

        XCTAssertEqual(fixture.launching.launchedURLs, [url])
        XCTAssertTrue(fixture.alerting.titles.isEmpty)
    }

    func testRecentWhoseFileIsGoneExplainsInsteadOfLaunching() throws {
        let url = try makeWorkspaceFile()
        let fixture = makeFixture()
        defer { fixture.controller.removeFromStatusBar() }
        fixture.recents.add(url)
        fixture.controller.menuWillOpen(fixture.controller.menu)
        try FileManager.default.removeItem(at: url)

        try performFirstRecent(in: fixture)

        XCTAssertEqual(fixture.alerting.titles, ["Could not open “\(url.lastPathComponent)”"])
        XCTAssertTrue(fixture.launching.launchedURLs.isEmpty)
    }

    // MARK: Opening the menu

    func testMenuWillOpenPicksUpRecentsAddedSinceTheMenuWasBuilt() throws {
        let url = try makeWorkspaceFile()
        let fixture = makeFixture()
        defer { fixture.controller.removeFromStatusBar() }

        XCTAssertEqual(try submenuTitles(of: "Recents", in: fixture), ["No Recents"])

        fixture.recents.add(url)
        XCTAssertEqual(
            try submenuTitles(of: "Recents", in: fixture),
            ["No Recents"],
            "the submenu is only rebuilt when the menu opens"
        )

        fixture.controller.menuWillOpen(fixture.controller.menu)

        XCTAssertEqual(try submenuTitles(of: "Recents", in: fixture), [url.lastPathComponent])
    }

    func testMenuWillOpenRetitlesTheAccessibilityRowWhenPermissionChanges() throws {
        let fixture = makeFixture(accessibilityTrusted: false)
        defer { fixture.controller.removeFromStatusBar() }

        XCTAssertEqual(try accessibilityRow(in: fixture).title, "SnapDesk needs Accessibility")

        fixture.environment.accessibilityTrusted = true
        fixture.controller.menuWillOpen(fixture.controller.menu)

        XCTAssertEqual(try accessibilityRow(in: fixture).title, "SnapDesk can move windows")
    }

    // MARK: The Accessibility row

    func testAccessibilityRowStaysDisabledWhilePermissionIsWorking() throws {
        let fixture = makeFixture(accessibilityTrusted: true)
        defer { fixture.controller.removeFromStatusBar() }
        let row = try accessibilityRow(in: fixture)

        XCTAssertFalse(fixture.controller.validateMenuItem(row))
        // What AppKit does every time the menu opens. Assigning `isEnabled` in the controller
        // would be undone here, because `autoenablesItems` is on and the row has a target and
        // an action: the answer has to come from validation.
        fixture.controller.menu.update()

        XCTAssertFalse(row.isEnabled, "a working permission is a status line, not a command")
    }

    func testAccessibilityRowIsClickableWhilePermissionIsMissing() throws {
        let fixture = makeFixture(accessibilityTrusted: false)
        defer { fixture.controller.removeFromStatusBar() }
        let row = try accessibilityRow(in: fixture)

        XCTAssertTrue(fixture.controller.validateMenuItem(row))
        fixture.controller.menu.update()

        XCTAssertTrue(row.isEnabled, "it is the way into System Settings")
    }

    func testEveryOtherMenuItemValidatesAsUsable() throws {
        let fixture = makeFixture(accessibilityTrusted: true)
        defer { fixture.controller.removeFromStatusBar() }

        for title in ["Capture", "Editor", "Open…", "Settings…", "Relaunch"] {
            let menuItem = try item(titled: title, in: fixture.controller.menu)
            XCTAssertTrue(fixture.controller.validateMenuItem(menuItem), title)
        }
    }

    // MARK: Fixture

    private func makeFixture(accessibilityTrusted: Bool = false) -> Fixture {
        let recents = RecentsStore(defaults: scratchDefaults())
        let launching = SpyLaunching()
        let capturing = SpyCapturing()
        let alerting = SpyAlerting()
        let environment = Environment(accessibilityTrusted: accessibilityTrusted)
        let controller = StatusItemController(
            recents: recents,
            launching: launching,
            capturing: capturing,
            alerting: alerting,
            onEditor: { environment.editorOpens += 1 },
            onSettings: { environment.settingsOpens += 1 },
            accessibilityTrusted: { environment.accessibilityTrusted }
        )
        return Fixture(
            controller: controller,
            recents: recents,
            launching: launching,
            capturing: capturing,
            alerting: alerting,
            environment: environment
        )
    }

    private func makeWorkspaceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-\(UUID().uuidString).snapdesk")
        try Data().write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "com.brudvik.snapdesk.tests.status.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func item(titled title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first(where: { $0.title == title }), "no menu item titled \(title)")
    }

    private func perform(_ title: String, in menu: NSMenu) throws {
        let index = try XCTUnwrap(
            menu.items.firstIndex(where: { $0.title == title }),
            "no menu item titled \(title)"
        )
        menu.performActionForItem(at: index)
    }

    private func submenu(of title: String, in fixture: Fixture) throws -> NSMenu {
        try XCTUnwrap(item(titled: title, in: fixture.controller.menu).submenu)
    }

    private func submenuTitles(of title: String, in fixture: Fixture) throws -> [String] {
        try submenu(of: title, in: fixture).items.map(\.title)
    }

    private func performFirstRecent(in fixture: Fixture) throws {
        let recentsMenu = try submenu(of: "Recents", in: fixture)
        XCTAssertFalse(recentsMenu.items.isEmpty)
        recentsMenu.performActionForItem(at: 0)
    }

    private func accessibilityRow(in fixture: Fixture) throws -> NSMenuItem {
        let titles: Set<String> = ["SnapDesk can move windows", "SnapDesk needs Accessibility"]
        return try XCTUnwrap(
            fixture.controller.menu.items.first(where: { titles.contains($0.title) }),
            "no Accessibility row in the menu"
        )
    }
}
