import AppKit
import CoreGraphics

struct LiveDisplay: Equatable, Sendable {
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

    init(_ screen: NSScreen) {
        self.init(
            id: Self.uuidString(for: screen),
            name: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            scale: screen.backingScaleFactor
        )
    }

    private static func uuidString(for screen: NSScreen) -> String {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let cfUUID = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
        else {
            return ""
        }
        return CFUUIDCreateString(nil, cfUUID) as String
    }
}
