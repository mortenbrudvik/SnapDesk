import ApplicationServices
import AppKit

/// Thin wrapper around a window `AXUIElement`. This is the only place in the app that handles
/// Accessibility-space (top-left origin) coordinates; everything it exposes is Cocoa space.
@MainActor
struct AXWindow {
    private let element: AXUIElement

    /// How long one AX request may block. The system default is 6 seconds, which would freeze
    /// SnapDesk's main thread for that long whenever the target app is beachballing.
    static let messagingTimeout: Float = 0.25
    private static let enhancedUserInterface = "AXEnhancedUserInterface" as CFString

    /// Fails unless `element` has the window role, so a sheet or a group can never be wrapped.
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
        guard boolValue(app, Self.enhancedUserInterface as String) else { return write() }

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

    var isMinimized: Bool {
        boolValue(element, kAXMinimizedAttribute)
    }

    @discardableResult
    func setMinimized(_ minimized: Bool) -> AXError {
        setBool(kAXMinimizedAttribute, minimized)
    }

    var isZoomed: Bool {
        boolValue(element, "AXZoomed")
    }

    @discardableResult
    func setZoomed(_ zoomed: Bool) -> AXError {
        setBool("AXZoomed", zoomed)
    }

    // MARK: Lookup

    static func windows(pid: pid_t) -> [AXWindow] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value
        )
        guard error == .success, let elements = value as? [AXUIElement] else { return [] }
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

private func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else { return nil }
    return value
}

private func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
    copyValue(element, attribute) as? String
}

private func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool {
    guard let value = copyValue(element, attribute) else { return false }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }
    return (value as? NSNumber)?.boolValue ?? false
}
