import XCTest
@testable import SnapDesk

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private final class FakeLaunching: WorkspaceLaunching {
        func launch(url: URL) {}
        func launch(document: WorkspaceDocument) {}
    }

    private final class FakeCapturing: WorkspaceCapturing {
        func captureToEditor() {}
    }

    private final class FakeAlerting: UserAlerting {
        func show(message: String) {}
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "com.brudvik.snapdesk.tests.status.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testMenuTitlesIncludeCaptureEditorOpenQuitRecentsAndAccessibility() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Coding.snapdesk")
        try Data().write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let recents = RecentsStore(defaults: scratchDefaults())
        recents.add(url)

        let controller = StatusItemController(
            recents: recents,
            launching: FakeLaunching(),
            capturing: FakeCapturing(),
            alerting: FakeAlerting()
        )
        let titles = controller.menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Capture"))
        XCTAssertTrue(titles.contains("Editor"))
        XCTAssertTrue(titles.contains("Open…"))
        XCTAssertTrue(titles.contains("Quit SnapDesk"))

        let recentsItem = try XCTUnwrap(controller.menu.items.first { $0.title == "Recents" })
        let recentsTitles = recentsItem.submenu?.items.map(\.title) ?? []
        XCTAssertTrue(recentsTitles.contains { $0.contains("Coding") })

        let accessTitles: Set<String> = ["SnapDesk can move windows", "SnapDesk needs Accessibility"]
        XCTAssertTrue(titles.contains { accessTitles.contains($0) })
    }
}
