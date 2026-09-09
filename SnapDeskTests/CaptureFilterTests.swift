import XCTest
@testable import SnapDesk

final class CaptureFilterTests: XCTestCase {
    func testSnapDeskSkipped() {
        let c = candidate(isSnapDesk: true)
        XCTAssertFalse(CaptureFilter.isEligible(c))
    }

    func testAccessorySkipped() {
        let c = candidate(activationPolicyIsRegular: false)
        XCTAssertFalse(CaptureFilter.isEligible(c))
    }

    func testFloatingSkipped() {
        let c = candidate(subrole: "AXFloatingWindow")
        XCTAssertFalse(CaptureFilter.isEligible(c))
    }

    func testTinyFrameSkipped() {
        let c = candidate(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertFalse(CaptureFilter.isEligible(c))
    }

    func testAXWindowNilSubroleEligible() {
        let c = candidate(subrole: nil, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(CaptureFilter.isEligible(c))
    }

    func testMinimizedEligible() {
        let c = candidate(isMinimized: true)
        XCTAssertTrue(CaptureFilter.isEligible(c))
    }

    private func candidate(
        role: String = "AXWindow",
        subrole: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        isSnapDesk: Bool = false,
        activationPolicyIsRegular: Bool = true,
        isMinimized: Bool = false
    ) -> CaptureCandidate {
        CaptureCandidate(
            bundleIdentifier: "com.example.App",
            role: role,
            subrole: subrole,
            frame: frame,
            isSnapDesk: isSnapDesk,
            activationPolicyIsRegular: activationPolicyIsRegular,
            isMinimized: isMinimized,
            cgWindowID: 1
        )
    }
}
