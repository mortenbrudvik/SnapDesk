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

    static func clamp(_ frame: CGRect, to visible: CGRect, titleBar: CGFloat = 80) -> CGRect {
        var result = frame
        if result.width > visible.width || result.height > visible.height {
            return visible
        }
        if result.maxX < visible.minX { result.origin.x = visible.minX }
        if result.minX > visible.maxX { result.origin.x = visible.maxX - result.width }
        let minTitleTop = visible.minY + titleBar
        if result.maxY < minTitleTop { result.origin.y = minTitleTop - result.height }
        if result.minY > visible.maxY { result.origin.y = visible.maxY - result.height }
        if result.maxX > visible.maxX { result.origin.x = visible.maxX - result.width }
        if result.minX < visible.minX { result.origin.x = visible.minX }
        if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
        if result.minY < visible.minY { result.origin.y = visible.minY }
        return result
    }
}
