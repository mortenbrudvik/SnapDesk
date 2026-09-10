import CoreGraphics
import Foundation

struct CaptureCandidate: Equatable {
    var bundleIdentifier: String
    var role: String
    var subrole: String?
    var frame: CGRect
    var isSnapDesk: Bool
    var activationPolicyIsRegular: Bool
    var isMinimized: Bool
    var cgWindowID: UInt32?
    /// Whether the window vends any of the close / minimize / zoom button elements. Defaulted so
    /// the many call sites that build a candidate to ask a question unrelated to window chrome do
    /// not have to answer it; capture, which is the one that must, passes the real value.
    var hasTitleBarButtons: Bool = true
}
