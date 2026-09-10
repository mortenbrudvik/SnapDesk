import Foundation

enum CaptureFilter {
    /// An *exclusion* list, not an allow list: a sheet or an `AXDialog` may well be a window the
    /// user arranged — an app's real main window reports `AXDialog` when it is borderless. What is
    /// dropped is what a workspace can never restore: `AXUnknown` is a window macOS itself cannot
    /// classify, `AXFloatingWindow` a palette that follows its app rather than a saved frame, and
    /// `AXSystemDialog` a system-owned alert that belongs to no workspace. The role is not checked
    /// here — `AXWindow.init?` is that guard, and nothing else constructs one.
    private static let excludedSubroles: Set<String> = [
        "AXUnknown",
        "AXFloatingWindow",
        "AXSystemDialog",
    ]

    /// The size floor is 8pt on each side. No window a user arranged is that small; what is are
    /// the 1x1 and zero-size elements some apps keep in their window list, which would otherwise
    /// become slots the user has to delete by hand.
    static func isEligible(_ c: CaptureCandidate) -> Bool {
        if c.isSnapDesk { return false }
        if !c.activationPolicyIsRegular { return false }
        if let subrole = c.subrole, excludedSubroles.contains(subrole) { return false }
        if c.frame.width < 8 || c.frame.height < 8 { return false }
        if isChromelessStandardWindow(c) { return false }
        return true
    }

    /// An Open/Save panel reports `AXStandardWindow` like an ordinary window and is large enough to
    /// clear the size floor, so nothing above rejects it — and a workspace that captured one comes
    /// back with a slot that can never be restored. What it does not have is any window chrome:
    /// measured, every real window vends all three of close, minimize and zoom, while a panel
    /// vends none.
    ///
    /// Both halves of the conjunction are load-bearing. Requiring *all three* to be missing keeps
    /// the Electron and SwiftUI custom-chrome styles, which look chromeless but are not: a window
    /// with `fullSizeContentView` and a transparent titlebar still vends all three, and so does one
    /// whose buttons are merely `isHidden`. Requiring `AXStandardWindow` keeps a genuinely
    /// borderless window — Electron's `frame: false` — which vends no buttons but which macOS
    /// reports as `AXDialog`, and which may well be an app's real main window.
    private static func isChromelessStandardWindow(_ c: CaptureCandidate) -> Bool {
        c.subrole == "AXStandardWindow" && !c.hasTitleBarButtons
    }
}
