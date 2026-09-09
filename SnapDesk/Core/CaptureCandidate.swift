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
}
