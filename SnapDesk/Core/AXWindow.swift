import ApplicationServices
import AppKit

/// Thin wrapper around a window `AXUIElement`. Everything it exposes is in Cocoa space: the
/// Accessibility-space (top-left origin) rects the API returns are flipped here before they
/// leave. That is a convention this file keeps, not one it can enforce — `ScreenGeometry`'s
/// conversions are callable from anywhere — so new AX reads belong here rather than at a
/// call site that would have to remember to flip them.
@MainActor
struct AXWindow {
    private let element: AXUIElement

    /// How long one AX request may block. Every read here is synchronous and on the main thread, so
    /// the default — measured at ~1.5s against a SIGSTOPped app, not the 6s the documentation is
    /// often quoted for — would freeze SnapDesk for that long per call whenever a target app is
    /// beachballing, and a restore makes many calls against many apps at once.
    ///
    /// Not lower than this. A read that times out returns `.cannotComplete`, which is
    /// indistinguishable from "this app has no windows yet" — so an over-tight timeout does not
    /// merely lose a value, it feeds the wrong branch of the wait-or-settle decision in
    /// `LaunchService`. Legitimate reads have been measured at 257–261ms while several apps launch
    /// at once, which is exactly what a restore does, so 0.25s was inside the range that bites.
    static let messagingTimeout: Float = 0.5
    private static let enhancedUserInterface = "AXEnhancedUserInterface" as CFString

    /// Fails unless the element's *role* is exactly `AXWindow`, which is what stops a position
    /// or size write from landing on the application element or the system-wide element. It is a
    /// role check and nothing more: dialogs, palettes and sheets that macOS reports as windows
    /// with a narrower *subrole* all pass it, and which of them a workspace keeps is
    /// `CaptureFilter`'s call — it drops a few subroles and captures the rest, sheets included.
    /// Capture and placement pass `role: "AXWindow"` downstream on the strength of this guard,
    /// so the role they filter on is this one, never a second read of the live element.
    init?(windowElement element: AXUIElement) {
        guard stringValue(element, kAXRoleAttribute) == kAXWindowRole else { return nil }
        self.element = element
    }

    /// Makes `messagingTimeout` the process-wide default for every AX request. Call once at launch.
    static func installMessagingTimeout() {
        let error = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
        if error != .success {
            Log.ax.error("could not set the AX messaging timeout (AXError \(error.rawValue))")
        }
    }

    // MARK: Identity

    var pid: pid_t? {
        var value: pid_t = 0
        guard AXUIElementGetPid(element, &value) == .success else { return nil }
        return value
    }

    var title: String? {
        stringValue(element, kAXTitleAttribute)
    }

    var subrole: String? {
        stringValue(element, kAXSubroleAttribute)
    }

    var identity: WindowIdentity? {
        guard let pid else { return nil }
        if let id = cgWindowID {
            return .cgWindow(id, pid: pid)
        }
        return .fallback(pid: pid, title: title ?? "")
    }

    /// The CGWindowID behind this element, through a private HIServices SPI that has no public
    /// header. Resolved with dlsym so a macOS that drops the symbol yields nil (and the weaker
    /// title-based identity) instead of failing at load. Not App Store safe.
    var cgWindowID: CGWindowID? {
        guard let getWindow = Self.getWindow else { return nil }
        var identifier: CGWindowID = 0
        guard getWindow(element, &identifier) == .success else { return nil }
        return identifier
    }

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindowFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow") else {
            Log.ax.error("_AXUIElementGetWindow is unavailable; Restore will identify windows by title")
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    // MARK: Frame

    var cocoaFrame: CGRect? {
        guard let axFrame, let top = ScreenGeometry.primaryMaxY else { return nil }
        return ScreenGeometry.cocoaRect(fromAX: axFrame, primaryMaxY: top)
    }

    @discardableResult
    func setCocoaFrame(_ frame: CGRect) -> AXError {
        guard let top = ScreenGeometry.primaryMaxY else { return .failure }
        let ax = ScreenGeometry.axRect(fromCocoa: frame, primaryMaxY: top)
        return withEnhancedUserInterfaceDisabled {
            // Size, then position, then size again. If position goes first, an app can clamp the
            // window back onto its current screen when the target rect would not fit there
            // (moving to a smaller or differently placed display), so shrink first. The trailing
            // size pass is for apps that clamped the first one to the *old* screen's bounds.
            //
            // The trade-off of leading with size: a window that refuses the first size write is
            // never moved either, because the guard below returns before `setPoint`. A
            // fixed-size window therefore cannot be repositioned at all, even though the move
            // alone would have worked. Reporting the failure is worth more than a half-applied
            // frame, which would leave the window somewhere the saved workspace never described.
            var error = setSize(ax.size)
            guard error == .success else { return error }
            error = setPoint(ax.origin)
            guard error == .success else { return error }
            return setSize(ax.size)
        }
    }

    private var axFrame: CGRect? {
        guard let origin = point(attribute: kAXPositionAttribute),
              let size = size(attribute: kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// `AXEnhancedUserInterface` is switched on for an app while an assistive client is attached
    /// (VoiceOver; Electron and Chromium also set it themselves). While it is on, AppKit animates
    /// AX position and size writes and can drop or clamp one that lands mid-animation, so tiles
    /// end up off target. Turn it off just around the write and put it back, so assistive-tech
    /// users of that app are not left with it disabled.
    private func withEnhancedUserInterfaceDisabled(_ write: () -> AXError) -> AXError {
        guard let pid else { return write() }
        let app = AXUIElementCreateApplication(pid)
        // Nil (most apps never vend the attribute) means there is nothing to turn off.
        guard boolValue(app, Self.enhancedUserInterface as String) == true else { return write() }

        let disabled = AXUIElementSetAttributeValue(app, Self.enhancedUserInterface, kCFBooleanFalse)
        if disabled != .success {
            Log.ax.notice("could not disable enhanced UI for pid \(pid) (AXError \(disabled.rawValue))")
        }
        let result = write()
        let restored = AXUIElementSetAttributeValue(app, Self.enhancedUserInterface, kCFBooleanTrue)
        if restored != .success {
            Log.ax.error("could not restore enhanced UI for pid \(pid) (AXError \(restored.rawValue))")
        }
        return result
    }

    // MARK: Min / zoom

    /// Nil when the read *failed* (the app did not answer within `messagingTimeout`, or the
    /// window is gone), as opposed to false for a window that is simply not minimized. Anything
    /// that persists the value — capture writes it into the `.snapdesk` file — must use this and
    /// not `isMinimized`: a failed read saved as `minimized: false` is wrong forever, and every
    /// later restore reproduces it faithfully.
    var minimizedState: Bool? {
        boolValue(element, kAXMinimizedAttribute)
    }

    /// False both for a window that is not minimized and for a read that failed. Fine for a
    /// decision made now and discarded; see `minimizedState` before saving the value, and
    /// `unminimize()` before making the answer a precondition for something else.
    var isMinimized: Bool {
        minimizedState ?? false
    }

    @discardableResult
    func setMinimized(_ minimized: Bool) -> AXError {
        let result = setBool(kAXMinimizedAttribute, minimized)
        if result != .success {
            Log.ax.notice("could not set AXMinimized=\(minimized) (AXError \(result.rawValue))")
        }
        return result
    }

    /// What one un-minimize established — separately, because a caller's answer to a refusal is
    /// opposite in the two cases that can produce one.
    enum UnminimizeOutcome: Equatable {
        /// Confirmed out of the Dock already. Nothing was written, so there is nothing to wait for
        /// and nothing that can have failed.
        case alreadyUp
        /// The window was confirmed minimized, and the un-minimize came back with this. Getting it
        /// out is a hard precondition for everything after it: a frame written to a window still in
        /// the Dock is swallowed while AX reports `.success` for the write. So a refusal here — or
        /// a state that never flips back — has to stop the placement, rather than let it report a
        /// window placed that the user never sees move.
        case wasMinimized(write: AXError)
        /// The state could not be read, so the un-minimize was sent blind. Sending it is not
        /// optional: the read fails for exactly the window that needs the write most, one minimized
        /// long enough that its app is swapped out and misses `messagingTimeout` on the first
        /// message. But the outcome is no verdict on the placement — a window whose state is
        /// unreadable may never have been minimized at all — so a refusal, or a state that stays
        /// unreadable, must not by itself fail a placement whose frame write then succeeds.
        case stateUnknown(write: AXError)
    }

    /// Un-minimizes unless the window is *confirmed* to be up already, and reports both halves of
    /// what happened: what the state read said, and what the write returned. A caller using
    /// minimized state as a precondition must come through here rather than branch on
    /// `isMinimized`, whose `false` also stands for a read that failed.
    ///
    /// Note what this does *not* establish: a write that returned `.success` has only been
    /// accepted. A deminiaturize animates, so the window is not actually out until `minimizedState`
    /// says so.
    func unminimize() -> UnminimizeOutcome {
        switch minimizedState {
        case .some(false): return .alreadyUp
        case .some(true): return .wasMinimized(write: setMinimized(false))
        case nil: return .stateUnknown(write: setMinimized(false))
        }
    }

    /// There is no `AXZoomed` attribute. A titled window vends `AXZoomButton` (the button
    /// element) but no boolean zoom state: reading, writing or even asking whether "AXZoomed"
    /// is settable returns `kAXErrorAttributeUnsupported` (-25205), and the string appears
    /// nowhere in the dyld shared cache, so no OS-provided window will ever answer it. Zoom
    /// state is therefore *inferred* from the frame, because a zoom takes the window to the
    /// visible frame of the display it is on (to within a point; see `zoomFrameTolerance`).
    ///
    /// That makes this a heuristic, not ground truth, in both directions: a window whose maximum
    /// size is smaller than the screen reads as not zoomed even when the user zoomed it, and one
    /// the user dragged to fill the screen reads as zoomed. Nil means the frame could not be
    /// read at all — see `minimizedState` for why that is not the same as false.
    ///
    /// Each read takes its own `NSScreen` snapshot, which resolves every screen's UUID. A caller
    /// holding a display list — capture holds the one it writes into the document — should ask
    /// `isZoomed(frame:on:)` instead of paying that per window.
    var zoomedState: Bool? {
        guard let frame = cocoaFrame else { return nil }
        return Self.isZoomed(frame: frame, on: NSScreen.screens.map(LiveDisplay.init))
    }

    /// The same inference, against a display list the caller already has and a frame it has
    /// already read. Capture uses this so the zoom flag it saves is derived from the very frame
    /// it saves beside it — a second read of the frame can answer for a window that has since
    /// gone, and the nil that comes back then has nowhere to go but a lossy `false`.
    static func isZoomed(frame: CGRect, on displays: [LiveDisplay]) -> Bool {
        guard let visible = ScreenGeometry.display(containing: frame, in: displays)?.visibleFrame else {
            return false
        }
        return abs(frame.minX - visible.minX) <= zoomFrameTolerance
            && abs(frame.minY - visible.minY) <= zoomFrameTolerance
            && abs(frame.width - visible.width) <= zoomFrameTolerance
            && abs(frame.height - visible.height) <= zoomFrameTolerance
    }

    var isZoomed: Bool {
        zoomedState ?? false
    }

    /// Presses the green zoom button, which is the only mechanism macOS offers — there is no zoom
    /// attribute to write. Returns `.attributeUnsupported` for a window that has no zoom button (a
    /// fixed-size utility window), which is a real outcome a caller may want to report, not a
    /// no-op.
    ///
    /// Whether the window vends any of the three title-bar button elements. An Open/Save panel
    /// vends none of them while still calling itself `AXStandardWindow`, which is what lets
    /// `CaptureFilter` keep one out of a saved workspace; see `isChromelessStandardWindow` there
    /// for why all three have to be absent before that means anything.
    var hasTitleBarButtons: Bool {
        [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
            .contains { elementValue(attribute: $0) != nil }
    }

    /// The press has no direction of its own: it runs `-[NSWindow zoom:]`, a *toggle* AppKit aims
    /// with its own `isZoomed` — the window's frame measured against its standard frame. So
    /// `.success` says the button was pressed and nothing more; whether the window ended up zoomed
    /// is only ever answered by reading the state back afterwards.
    @discardableResult
    func pressZoomButton() -> AXError {
        guard let button = elementValue(attribute: kAXZoomButtonAttribute) else {
            // No direction to name: the press is a toggle, so this window's zoom state is stuck
            // wherever it is, whichever way the caller wanted to move it.
            Log.ax.notice("no zoom button on this window; its zoom state cannot be changed")
            return .attributeUnsupported
        }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if result != .success {
            Log.ax.notice("pressing the zoom button failed (AXError \(result.rawValue))")
        }
        return result
    }

    /// Moves the window towards `zoomed`, pressing only when the state it can read does not
    /// already answer the request.
    ///
    /// That guard is needed in *both* directions, because the toggle is aimed by the same frame
    /// comparison `zoomedState` makes: AppKit's `isZoomed` is the frame against the standard
    /// frame, ours is the frame against the visible frame, and for an ordinary resizable window
    /// those are the same test. Pressing while the frame already satisfies the request therefore
    /// toggles the window *out* of it. Restore is where that bites: it writes the saved frame
    /// first, and for a slot saved zoomed that frame is the visible frame, so a press there sends
    /// the window back to its pre-zoom size — off the frame just written — and reports `.success`
    /// for having done it.
    ///
    /// So `.success` means one of exactly two things: the state was already confirmed to match, or
    /// the button was pressed. It never means the window ended up zoomed — the press animates, and
    /// its direction was AppKit's to choose. A caller that needs the outcome must read `isZoomed`
    /// back under a bounded wait (`WindowPlacement` does) and call again to correct it; calling
    /// again once the state does match costs nothing, which is what makes that loop safe.
    ///
    /// An unreadable frame is not a confirmation, so it presses: skipping there would leave a slot
    /// saved zoomed silently un-zoomed, where a press at worst toggles a state nobody could read.
    @discardableResult
    func setZoomed(_ zoomed: Bool) -> AXError {
        if zoomedState == zoomed { return .success }
        return pressZoomButton()
    }

    /// Windows with size constraints never land exactly on the visible frame, and a scaled
    /// display rounds; 2pt absorbs both without matching anything a user would call un-zoomed.
    private static let zoomFrameTolerance: CGFloat = 2

    // MARK: Lookup

    /// The app's windows, role-filtered. Throws rather than answering `[]` when the list itself
    /// could not be read, because an empty list is a real answer — "this app has no windows" —
    /// and the failures are not: `.cannotComplete` is an app that did not answer within
    /// `messagingTimeout` (beachballing, swapping, mid-launch, or already gone),
    /// `.invalidUIElement` a stale element, `.apiDisabled` a lost trust grant. Collapsing them
    /// into `[]` is how a capture came to drop a busy app and still report a healthy window count.
    /// Callers decide what a failure means for them and log it with the app's name; this layer
    /// only knows a pid.
    static func windows(pid: pid_t) throws(AXWindowListError) -> [AXWindow] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value
        )
        guard error == .success else { throw AXWindowListError(code: error) }
        guard let elements = value as? [AXUIElement] else {
            Log.ax.error("the window list of pid \(pid) was not an array of AX elements")
            throw AXWindowListError(code: .failure)
        }
        return elements.compactMap(AXWindow.init(windowElement:))
    }

    // MARK: Raw attribute access

    private func point(attribute: String) -> CGPoint? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func size(attribute: String) -> CGSize? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func elementValue(attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func setPoint(_ point: CGPoint) -> AXError {
        var value = point
        guard let ax = AXValueCreate(.cgPoint, &value) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, ax)
    }

    private func setSize(_ size: CGSize) -> AXError {
        var value = size
        guard let ax = AXValueCreate(.cgSize, &value) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, ax)
    }

    private func setBool(_ attribute: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

/// The window list of a process could not be read at all; `code` is what Accessibility answered.
struct AXWindowListError: Error, Equatable {
    let code: AXError
}

/// The single funnel for every attribute read: title, subrole, position, size, minimized state.
/// Nil covers both "no such value" and "the read failed", which the call sites cannot tell apart,
/// so each failure is logged here — otherwise a whole partial read is invisible after the fact.
private func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else {
        logReadFailure(error, attribute: attribute, of: element)
        return nil
    }
    return value
}

private func logReadFailure(_ error: AXError, attribute: String, of element: AXUIElement) {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    switch error {
    case .noValue, .attributeUnsupported:
        // Ordinary: plenty of windows have no subrole, and no window has a zoom button unless
        // it is resizable. Nothing was lost, so this stays out of the default log.
        Log.ax.debug("pid \(pid) does not vend \(attribute, privacy: .public) (AXError \(error.rawValue))")
    default:
        Log.ax.notice("could not read \(attribute, privacy: .public) for pid \(pid) (AXError \(error.rawValue))")
    }
}

private func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
    copyValue(element, attribute) as? String
}

/// Nil when the attribute could not be read, so a caller that cares can tell that apart from a
/// genuine false. Collapsing the two is how a failed read gets saved as real window state.
private func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
    guard let value = copyValue(element, attribute) else { return nil }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }
    return (value as? NSNumber)?.boolValue
}
