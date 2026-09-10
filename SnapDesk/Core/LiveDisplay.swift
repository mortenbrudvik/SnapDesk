import AppKit
import CoreGraphics

/// A snapshot of one attached screen: its identity, plus its geometry in Cocoa coordinates (the
/// full frame, and the frame minus menu bar and dock). A plain value with a memberwise init, so
/// layout and multi-display logic can be exercised in tests without an `NSScreen`, which cannot
/// be fabricated.
struct LiveDisplay: Equatable, Sendable {
    /// Stable across reconnects and reboots when the display reports a UUID; see `identity(for:)`
    /// for what stands in when it does not. Never empty, because it is written to disk as
    /// `SavedDisplay.id` and an empty id would collide with every other id-less display.
    var id: String
    var name: String
    var frame: CGRect
    var visibleFrame: CGRect
    var scale: CGFloat

    init(id: String, name: String, frame: CGRect, visibleFrame: CGRect, scale: CGFloat) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
    }

    @MainActor
    init(_ screen: NSScreen) {
        self.init(
            id: Self.identity(for: screen),
            name: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            scale: screen.backingScaleFactor
        )
    }

    /// The display's UUID string, or a fallback that is still unique among the attached screens.
    ///
    /// A UUID-less display is rare but real (some virtual and capture displays report none), and
    /// returning the same placeholder for two of them would make one workspace slot land on the
    /// wrong screen and would give `[SavedDisplay]` duplicate `Identifiable` ids, which SwiftUI
    /// misrenders. The fallbacks are unique but not stable: a display number is reassigned on
    /// reconnect and a frame changes with the arrangement, so a workspace saved against one
    /// rematches later only by name or size.
    /// Said once per identity: a `LiveDisplay` is rebuilt from `NSScreen` on every read — per
    /// slot, per correction poll, and inside every zoom read-back — so an unconditional line here
    /// appeared dozens of times per placed window and buried the errors that mattered.
    @MainActor
    private static let fallbackLog = OnceGate()

    @MainActor
    private static func identity(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if let number, let cfUUID = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, cfUUID) as String
        }
        let fallback = fallbackIdentity(number: number, frame: screen.frame)
        if fallbackLog.shouldLog(fallback) {
            Log.displays.error(
                "no UUID for display \(screen.localizedName, privacy: .public); identifying it as \(fallback, privacy: .public), which will not survive a reconnect"
            )
        }
        return fallback
    }

    static func fallbackIdentity(number: CGDirectDisplayID?, frame: CGRect) -> String {
        if let number {
            return "display-number:\(number)"
        }
        return "display-frame:\(whole(frame.minX)),\(whole(frame.minY)),\(whole(frame.width)),\(whole(frame.height))"
    }

    /// `Int(someDouble)` traps on a value past `Int.max`, and this runs on frames decoded straight
    /// from a `.snapdesk` file, before the document has been validated — a hand-edited or corrupt
    /// `1e308` would abort the process on a file the user merely double-clicked. Out-of-range and
    /// non-finite values become a marker instead: two displays that both land there stay
    /// distinguishable by the rest of the frame, and `DisplayMap` re-matches by name or size anyway.
    private static func whole(_ value: CGFloat) -> String {
        guard let exact = Int(exactly: value.rounded()) else { return "x" }
        return String(exact)
    }
}
