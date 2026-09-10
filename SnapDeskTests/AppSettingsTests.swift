import XCTest
import ServiceManagement
@testable import SnapDesk

@MainActor
final class AppSettingsTests: XCTestCase {
    private final class FakeLoginItems: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var statusAfterRegister: SMAppService.Status = .enabled
        var registerError: Error?
        var unregisterError: Error?
        var registerCalls = 0
        var unregisterCalls = 0

        func register() throws {
            registerCalls += 1
            if let registerError { throw registerError }
            status = statusAfterRegister
        }

        func unregister() throws {
            unregisterCalls += 1
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    private struct Failure: Error {}

    func testFailedRegistrationRollsTheToggleBackOnceWithoutRecursing() {
        let fake = FakeLoginItems()
        fake.registerError = Failure()
        fake.unregisterError = Failure()
        let settings = AppSettings(loginItems: fake)

        settings.launchAtLogin = true

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(fake.unregisterCalls, 0, "rollback must not fire the observer again")
        XCTAssertNotNil(settings.loginItemMessage)
    }

    func testRegistrationThatNeedsApprovalKeepsTheToggleOnAndExplains() {
        let fake = FakeLoginItems()
        fake.statusAfterRegister = .requiresApproval
        let settings = AppSettings(loginItems: fake)

        settings.launchAtLogin = true

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.loginItemStatus, .requiresApproval)
        XCTAssertTrue(settings.loginItemMessage?.contains("Login Items") == true, "\(String(describing: settings.loginItemMessage))")
        XCTAssertTrue(settings.loginItemMessage?.contains("SnapDesk") == true, "\(String(describing: settings.loginItemMessage))")
    }

    func testSuccessfulRegistrationClearsAnyMessage() {
        let fake = FakeLoginItems()
        let settings = AppSettings(loginItems: fake)

        settings.launchAtLogin = true

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertNil(settings.loginItemMessage)
        XCTAssertEqual(fake.registerCalls, 1)
    }

    /// `SMAppService` is the source of truth and the user can change it in System Settings while
    /// the pane is open — approve the item, or remove it. Both values were computed once in `init`,
    /// so the pane kept telling the user to approve an item they had approved, forever.
    func testRefreshReReadsTheLoginItemStatusWithoutWritingIt() {
        let fake = FakeLoginItems()
        fake.statusAfterRegister = .requiresApproval
        let settings = AppSettings(loginItems: fake)
        settings.launchAtLogin = true
        XCTAssertNotNil(settings.loginItemMessage)

        fake.status = .enabled
        settings.refresh()

        XCTAssertNil(settings.loginItemMessage, "the approval message goes away once the user has approved")
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(fake.registerCalls, 1, "a refresh reads; it must never register again")

        fake.status = .notRegistered
        settings.refresh()

        XCTAssertFalse(settings.launchAtLogin, "the toggle follows an item removed in System Settings")
        XCTAssertEqual(fake.unregisterCalls, 0, "and mirroring that is not an unregister")
    }

    func testTurningOffUnregisters() {
        let fake = FakeLoginItems()
        fake.status = .enabled
        let settings = AppSettings(loginItems: fake)
        XCTAssertTrue(settings.launchAtLogin, "initial state mirrors the service")

        settings.launchAtLogin = false

        XCTAssertEqual(fake.unregisterCalls, 1)
        XCTAssertFalse(settings.launchAtLogin)
    }
}
