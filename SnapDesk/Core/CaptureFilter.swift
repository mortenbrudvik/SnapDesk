import Foundation

enum CaptureFilter {
    private static let excludedSubroles: Set<String> = [
        "AXUnknown",
        "AXFloatingWindow",
        "AXSystemDialog",
    ]

    static func isEligible(_ c: CaptureCandidate) -> Bool {
        if c.isSnapDesk { return false }
        if !c.activationPolicyIsRegular { return false }
        if c.role != "AXWindow" { return false }
        if let subrole = c.subrole, excludedSubroles.contains(subrole) { return false }
        if c.frame.width < 8 || c.frame.height < 8 { return false }
        return true
    }
}
