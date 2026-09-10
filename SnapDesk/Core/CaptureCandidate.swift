import CoreGraphics
import Foundation

/// The facts `CaptureFilter` decides eligibility on — and only those. Every field is required so a
/// call site cannot leave one at a default that quietly switches a rule off: the restore catalog
/// once built a candidate without the title-bar buttons, and the Open/Save-panel rule never fired
/// on that side.
struct CaptureCandidate: Equatable {
    var subrole: String?
    var frame: CGRect
    var isSnapDesk: Bool
    var activationPolicyIsRegular: Bool
    /// Whether the window vends any of the close / minimize / zoom button elements; see
    /// `CaptureFilter.isChromelessStandardWindow`.
    var hasTitleBarButtons: Bool
}
