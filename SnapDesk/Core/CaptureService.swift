import AppKit
import CoreGraphics
import Foundation

struct RunningAppInfo: Equatable {
    var pid: pid_t
    var bundleIdentifier: String
    var bundlePath: String
    var name: String
    var activationPolicyIsRegular: Bool
    var isSnapDesk: Bool
}

@MainActor
protocol RunningAppSourcing {
    func apps() -> [RunningAppInfo]
}

struct AXWindowSnapshot: Equatable {
    var cgWindowID: UInt32?
    var title: String
    var role: String
    var subrole: String?
    var cocoaFrame: CGRect
    var minimized: Bool
    var zoomed: Bool
}

@MainActor
protocol AXCapturing {
    func snapshot(pid: pid_t) -> [AXWindowSnapshot]
}

@MainActor
protocol CGWindowOrdering {
    func onScreenWindowIDsFrontToBack() -> [UInt32]
}

@MainActor
protocol DisplayCatalog {
    func displays() -> [LiveDisplay]
}

@MainActor
struct CaptureService {
    private let apps: any RunningAppSourcing
    private let ax: any AXCapturing
    private let order: any CGWindowOrdering
    private let displays: any DisplayCatalog
    private let snapDeskBundleID: String

    init(
        apps: any RunningAppSourcing,
        ax: any AXCapturing,
        order: any CGWindowOrdering,
        displays: any DisplayCatalog,
        snapDeskBundleID: String = Bundle.main.bundleIdentifier ?? "com.brudvik.snapdesk"
    ) {
        self.apps = apps
        self.ax = ax
        self.order = order
        self.displays = displays
        self.snapDeskBundleID = snapDeskBundleID
    }

    init(snapDeskBundleID: String = Bundle.main.bundleIdentifier ?? "com.brudvik.snapdesk") {
        self.init(
            apps: NSWorkspaceRunningApps(snapDeskBundleID: snapDeskBundleID),
            ax: AXWindowCapturer(),
            order: CGWindowListOrdering(),
            displays: NSScreenCatalog(),
            snapDeskBundleID: snapDeskBundleID
        )
    }

    func capture(name: String = "Untitled") -> WorkspaceDocument {
        let liveDisplays = displays.displays()
        let onScreen = order.onScreenWindowIDsFrontToBack()

        var eligible: [(app: RunningAppInfo, window: AXWindowSnapshot)] = []
        for app in apps.apps() {
            let isSnapDesk = app.isSnapDesk || app.bundleIdentifier == snapDeskBundleID
            guard app.activationPolicyIsRegular, !isSnapDesk else { continue }
            for window in ax.snapshot(pid: app.pid) {
                let candidate = CaptureCandidate(
                    bundleIdentifier: app.bundleIdentifier,
                    role: window.role,
                    subrole: window.subrole,
                    frame: window.cocoaFrame,
                    isSnapDesk: isSnapDesk,
                    activationPolicyIsRegular: app.activationPolicyIsRegular,
                    isMinimized: window.minimized,
                    cgWindowID: window.cgWindowID
                )
                if CaptureFilter.isEligible(candidate) {
                    eligible.append((app, window))
                }
            }
        }

        let sorted = CaptureOrdering.sort(
            candidates: eligible.enumerated().map { index, item in
                OrderedWindow(
                    cgWindowID: item.window.cgWindowID,
                    isMinimized: item.window.minimized,
                    label: String(index)
                )
            },
            onScreenFrontToBack: onScreen
        )

        let windows: [SavedWindow] = sorted.compactMap { ordered in
            guard let index = Int(ordered.label) else { return nil }
            let item = eligible[index]
            let assigned = Self.display(containing: item.window.cocoaFrame, in: liveDisplays)
            let relative = FramePlacement.relative(
                cocoa: item.window.cocoaFrame,
                visibleFrame: assigned?.visibleFrame ?? .zero
            )
            return SavedWindow(
                bundleIdentifier: item.app.bundleIdentifier,
                bundlePath: item.app.bundlePath,
                name: item.app.name,
                title: item.window.title,
                displayId: assigned?.id ?? "",
                x: relative.origin.x,
                y: relative.origin.y,
                width: relative.size.width,
                height: relative.size.height,
                minimized: item.window.minimized,
                zoomed: item.window.zoomed,
                arguments: ""
            )
        }

        let savedDisplays = liveDisplays.map { screen in
            SavedDisplay(
                id: screen.id,
                name: screen.name,
                frame: CodableRect(screen.frame),
                visibleFrame: CodableRect(screen.visibleFrame),
                scale: Double(screen.scale)
            )
        }

        Log.capture.info("captured \(windows.count) window(s) on \(savedDisplays.count) display(s)")

        return WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: name,
            moveExistingWindows: true,
            displays: savedDisplays,
            windows: windows
        )
    }

    private static func display(containing frame: CGRect, in live: [LiveDisplay]) -> LiveDisplay? {
        let geometry = live.map { Display(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        if let match = ScreenGeometry.display(containing: frame, in: geometry),
           let index = geometry.firstIndex(of: match) {
            return live[index]
        }
        return live.first
    }
}

struct NSWorkspaceRunningApps: RunningAppSourcing {
    var snapDeskBundleID: String

    func apps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.map { app in
            let bundleIdentifier = app.bundleIdentifier ?? ""
            return RunningAppInfo(
                pid: app.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                bundlePath: app.bundleURL?.path ?? "",
                name: app.localizedName ?? "",
                activationPolicyIsRegular: app.activationPolicy == .regular,
                isSnapDesk: bundleIdentifier == snapDeskBundleID
            )
        }
    }
}

struct AXWindowCapturer: AXCapturing {
    func snapshot(pid: pid_t) -> [AXWindowSnapshot] {
        AXWindow.windows(pid: pid).compactMap { window in
            guard let cocoaFrame = window.cocoaFrame else { return nil }
            return AXWindowSnapshot(
                cgWindowID: window.cgWindowID,
                title: window.title ?? "",
                role: "AXWindow",
                subrole: window.subrole,
                cocoaFrame: cocoaFrame,
                minimized: window.isMinimized,
                zoomed: window.isZoomed
            )
        }
    }
}

struct CGWindowListOrdering: CGWindowOrdering {
    func onScreenWindowIDsFrontToBack() -> [UInt32] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { entry in
            (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }
}

struct NSScreenCatalog: DisplayCatalog {
    func displays() -> [LiveDisplay] {
        NSScreen.screens.map(LiveDisplay.init)
    }
}
