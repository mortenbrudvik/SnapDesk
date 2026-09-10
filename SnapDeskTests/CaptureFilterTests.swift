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

    // MARK: Chromeless standard windows (Open/Save panels)

    /// An Open panel calls itself AXStandardWindow and is far bigger than the size floor, so every
    /// other rule passes it. Captured, it becomes a workspace slot that can never be restored.
    /// Measured on a real NSOpenPanel: subrole AXStandardWindow, none of the three buttons.
    func testAnOpenPanelIsNotEligible() {
        XCTAssertFalse(
            CaptureFilter.isEligible(
                candidate(subrole: "AXStandardWindow", hasTitleBarButtons: false)
            )
        )
    }

    /// Electron and SwiftUI custom chrome only *look* chromeless. Measured: a window with
    /// fullSizeContentView and a transparent titlebar still vends all three buttons, and so does
    /// one whose buttons are merely `isHidden`. Both must still be captured.
    func testACustomChromeWindowThatStillVendsButtonsIsEligible() {
        XCTAssertTrue(
            CaptureFilter.isEligible(
                candidate(subrole: "AXStandardWindow", hasTitleBarButtons: true)
            )
        )
    }

    /// A genuinely borderless window — Electron's `frame: false` — vends no buttons either, but
    /// macOS reports it as AXDialog rather than AXStandardWindow, and it may be an app's real main
    /// window. The subrole half of the conjunction is what keeps it.
    func testABorderlessDialogWindowWithNoButtonsIsStillEligible() {
        XCTAssertTrue(
            CaptureFilter.isEligible(
                candidate(subrole: "AXDialog", hasTitleBarButtons: false)
            )
        )
    }

    private func candidate(
        role: String = "AXWindow",
        subrole: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        isSnapDesk: Bool = false,
        activationPolicyIsRegular: Bool = true,
        isMinimized: Bool = false,
        hasTitleBarButtons: Bool = true
    ) -> CaptureCandidate {
        CaptureCandidate(
            bundleIdentifier: "com.example.App",
            role: role,
            subrole: subrole,
            frame: frame,
            isSnapDesk: isSnapDesk,
            activationPolicyIsRegular: activationPolicyIsRegular,
            isMinimized: isMinimized,
            cgWindowID: 1,
            hasTitleBarButtons: hasTitleBarButtons
        )
    }
}
