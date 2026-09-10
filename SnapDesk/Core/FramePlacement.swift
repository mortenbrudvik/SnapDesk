import CoreGraphics

enum FramePlacement {
    static func relative(cocoa: CGRect, visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: cocoa.minX - visibleFrame.minX,
            y: cocoa.minY - visibleFrame.minY,
            width: cocoa.width,
            height: cocoa.height
        )
    }

    static func cocoa(relative: CGRect, visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: relative.minX + visibleFrame.minX,
            y: relative.minY + visibleFrame.minY,
            width: relative.width,
            height: relative.height
        )
    }

    /// The saved frame put back on the display it is being restored to. A visible frame within a
    /// point of the saved one is the same screen and the frame is used verbatim; anything else is
    /// scaled proportionally in each axis, so a workspace captured on a 4K display comes back in
    /// proportion on a laptop instead of half off the screen. `max(_, 1)` guards the divisor: a
    /// saved visible frame of zero reaches this from a hand-edited file.
    static func restore(relative: CGRect, savedVisible: CGRect, liveVisible: CGRect) -> CGRect {
        let sizeMatches =
            abs(savedVisible.width - liveVisible.width) <= 1
            && abs(savedVisible.height - liveVisible.height) <= 1
        if sizeMatches {
            return cocoa(relative: relative, visibleFrame: liveVisible)
        }
        let sx = liveVisible.width / max(savedVisible.width, 1)
        let sy = liveVisible.height / max(savedVisible.height, 1)
        let scaled = CGRect(
            x: relative.minX * sx,
            y: relative.minY * sy,
            width: relative.width * sx,
            height: relative.height * sy
        )
        return cocoa(relative: scaled, visibleFrame: liveVisible)
    }

    /// Fits `frame` entirely inside `visible`, shrinking it to `visible` when it does not fit.
    ///
    /// Full containment is also what keeps a restored window grabbable: `visible` already
    /// excludes the menu bar and the dock, so a window inside it always has its title bar in
    /// reach. A separate title-bar floor would be redundant here — and would be overwritten by
    /// the containment clamp below — so there is none; relaxing the containment clamp means
    /// reintroducing one.
    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        if frame.width > visible.width || frame.height > visible.height {
            return visible
        }
        var result = frame
        if result.maxX > visible.maxX { result.origin.x = visible.maxX - result.width }
        if result.minX < visible.minX { result.origin.x = visible.minX }
        if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
        if result.minY < visible.minY { result.origin.y = visible.minY }
        return result
    }
}
