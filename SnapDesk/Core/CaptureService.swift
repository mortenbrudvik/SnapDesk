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
    /// See `CaptureFilter.isChromelessStandardWindow`. Defaulted for the tests that build a
    /// snapshot to exercise something unrelated to window chrome.
    var hasTitleBarButtons: Bool = true
}

@MainActor
protocol AXCapturing {
    /// `displays` is the same list the capture records, and is what zoom is inferred against;
    /// see `AXWindowCapturer.snapshot(pid:displays:)`.
    func snapshot(pid: pid_t, displays: [LiveDisplay]) -> [AXWindowSnapshot]
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
            for window in ax.snapshot(pid: app.pid, displays: liveDisplays) {
                let candidate = CaptureCandidate(
                    bundleIdentifier: app.bundleIdentifier,
                    role: window.role,
                    subrole: window.subrole,
                    frame: window.cocoaFrame,
                    isSnapDesk: isSnapDesk,
                    activationPolicyIsRegular: app.activationPolicyIsRegular,
                    isMinimized: window.minimized,
                    cgWindowID: window.cgWindowID,
                    hasTitleBarButtons: window.hasTitleBarButtons
                )
                if CaptureFilter.isEligible(candidate) {
                    eligible.append((app, window))
                }
            }
        }

        let ordering = CaptureOrdering.sortedIndices(
            of: eligible.map { item in
                OrderedWindow(
                    cgWindowID: item.window.cgWindowID,
                    isMinimized: item.window.minimized
                )
            },
            onScreenFrontToBack: onScreen
        )

        let windows: [SavedWindow] = ordering.compactMap { index in
            let item = eligible[index]
            // Every saved frame is relative to its display's visible frame, so a window with no
            // display has no honest frame to record: writing absolute coordinates would give the
            // same four fields a second meaning that only `displayId` distinguishes. This is
            // reachable only with no display attached, when there is nothing to restore onto.
            guard let assigned = Self.display(containing: item.window.cocoaFrame, in: liveDisplays) else {
                Log.capture.error("skipping \(item.app.name, privacy: .public) window: no display to record it against")
                return nil
            }
            let relative = FramePlacement.relative(
                cocoa: item.window.cocoaFrame,
                visibleFrame: assigned.visibleFrame
            )
            return SavedWindow(
                bundleIdentifier: item.app.bundleIdentifier,
                bundlePath: item.app.bundlePath,
                name: item.app.name,
                title: item.window.title,
                displayId: assigned.id,
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

        Log.capture.info("captured \(windows.count) of \(ordering.count) eligible window(s) on \(savedDisplays.count) display(s)")

        return WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: name,
            moveExistingWindows: true,
            displays: savedDisplays,
            windows: windows
        )
    }

    /// The display a captured window is recorded against. This deliberately diverges from
    /// `ScreenGeometry.display(containing:)`, which answers nil for a window that touches no
    /// display: a window parked off every screen is still worth capturing, so it is recorded
    /// against the primary display and comes back on-screen at restore, where `FramePlacement`
    /// clamps it into that display's visible frame. Nil only when no display is attached.
    private static func display(containing frame: CGRect, in live: [LiveDisplay]) -> LiveDisplay? {
        ScreenGeometry.display(containing: frame, in: live) ?? live.first
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
    /// Takes the display list rather than reading `NSScreen` per window. Zoom is inferred from
    /// the frame against a display's visible frame, and building that list inside the loop would
    /// re-resolve every screen's UUID — and log a line for every screen that has none — once per
    /// captured window, against a snapshot of the screens the document does not record.
    func snapshot(pid: pid_t, displays: [LiveDisplay]) -> [AXWindowSnapshot] {
        AXWindow.windows(pid: pid).compactMap { window in
            // A failed AX read must not be captured as `false`: the value goes to disk and every
            // later restore reproduces it. `minimizedState` distinguishes the two, so a window
            // whose state cannot be read is skipped rather than saved wrong. Zoom is inferred
            // from the frame unwrapped here rather than read again, because a window that goes
            // away between the two reads comes back nil from the second one, and the only thing
            // left to save then is the lossy `false` this guard exists to keep off disk.
            guard let cocoaFrame = window.cocoaFrame, let minimized = window.minimizedState else { return nil }
            return AXWindowSnapshot(
                cgWindowID: window.cgWindowID,
                title: window.title ?? "",
                role: "AXWindow",
                subrole: window.subrole,
                cocoaFrame: cocoaFrame,
                minimized: minimized,
                zoomed: AXWindow.isZoomed(frame: cocoaFrame, on: displays),
                hasTitleBarButtons: window.hasTitleBarButtons
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
