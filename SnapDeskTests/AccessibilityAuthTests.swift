import XCTest
@testable import SnapDesk

/// The permission policy behind the status-item row and the command path: which of the two
/// mutually exclusive scripts — grant it, or relaunch to apply a grant — a given trust state
/// calls for. As much of `AccessibilityAuth` as can be checked without a modal on screen.
@MainActor
final class AccessibilityAuthTests: XCTestCase {
    func testAWorkingCallNeedsNothingWhateverTCCSays() {
        XCTAssertEqual(AccessibilityAuth.remedy(isTrusted: true, isEffectivelyTrusted: true), AccessibilityAuth.Remedy.none)
        XCTAssertEqual(AccessibilityAuth.remedy(isTrusted: false, isEffectivelyTrusted: true), AccessibilityAuth.Remedy.none)
    }

    func testNeverGrantedAsksForTheGrantAndNotForARelaunch() {
        XCTAssertEqual(AccessibilityAuth.remedy(isTrusted: false, isEffectivelyTrusted: false), AccessibilityAuth.Remedy.grant)
    }

    func testGrantedButStillFailingAsksForARelaunch() {
        XCTAssertEqual(AccessibilityAuth.remedy(isTrusted: true, isEffectivelyTrusted: false), AccessibilityAuth.Remedy.relaunch)
    }
}
