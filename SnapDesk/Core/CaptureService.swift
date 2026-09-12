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

extension RunningAppInfo {
    /// What to call this app in something the user reads. `localizedName` can be absent — it is
    /// nil for a few background and helper processes — and "" is not a name: a report then said
    /// " did not answer" and named nothing at all.
    var displayName: String {
        if !name.isEmpty { return name }
        if !bundleIdentifier.isEmpty { return bundleIdentifier }
        return "an unnamed app (pid \(pid))"
    }
}

@MainActor
protocol RunningAppSourcing {
    func apps() -> [RunningAppInfo]
}

/// One window as Accessibility answered for it — the raw reads, with the two that decide whether
/// the window can be recorded at all left optional. A failed read must reach `CaptureService` as
/// a failure and not as a default: `minimized: false` for a window whose state could not be read
/// goes to disk and is reproduced by every later restore.
struct AXWindowSnapshot: Equatable {
    var cgWindowID: UInt32?
    var title: String
    var subrole: String?
    /// Nil when the position or size could not be read.
    var cocoaFrame: CGRect?
    /// Nil when the read failed, as opposed to false for a window that is simply up; see
    /// `AXWindow.minimizedState`.
    var minimized: Bool?
    /// True fullscreen, read from a real attribute rather than inferred the way zoom must be.
    /// Nil for a read that failed; see `AXWindow.fullscreenState`.
    var fullscreen: Bool?
    /// Whatever the window vends as its document, unchecked. A candidate rather than a URL; see
    /// `AXWindow.documentURL`, and `WorkspaceDocumentReference` for what may actually be saved.
    var document: String?
    /// See `CaptureFilter.isChromelessStandardWindow`.
    var hasTitleBarButtons: Bool
}

@MainActor
protocol AXCapturing {
    /// Every window the app vends, or a throw when the list itself could not be read — an app
    /// that did not answer within the AX timeout, one that has exited, or a lost trust grant.
    func windows(pid: pid_t) throws -> [AXWindowSnapshot]
}

/// What a capture could not record, so the user can be told rather than left with a workspace that
/// silently lacks an app. Every field is by app *name*, which is what the editor shows.
struct CaptureReport: Equatable {
    /// Apps whose window list could not be read at all: they did not answer within the AX timeout,
    /// exited mid-capture, or Accessibility refused the read.
    var unreadableApps: [String] = []
    /// Apps skipped because they have no bundle identifier; restore matches windows by bundle
    /// identifier, so a slot for one could never be filled.
    var unidentifiedApps: [String] = []
    /// Windows skipped because their frame or minimized state could not be read, per app.
    var skippedWindows: [String: Int] = [:]

    static let clean = CaptureReport()

    var isClean: Bool {
        unreadableApps.isEmpty && unidentifiedApps.isEmpty && skippedWindows.isEmpty
    }

    /// One paragraph naming what was left out, for an alert. Nil when nothing was.
    var explanation: String? {
        var sentences: [String] = []
        if !unreadableApps.isEmpty {
            sentences.append(
                "\(list(unreadableApps)) did not answer, so \(unreadableApps.count == 1 ? "its" : "their") windows were not captured."
            )
        }
        for (app, count) in skippedWindows.sorted(by: { $0.key < $1.key }) {
            sentences.append("\(count) window\(count == 1 ? "" : "s") of \(app) could not be read.")
        }
        if !unidentifiedApps.isEmpty {
            sentences.append(
                "\(list(unidentifiedApps)) \(unidentifiedApps.count == 1 ? "has" : "have") no bundle identifier and cannot be restored."
            )
        }
        guard !sentences.isEmpty else { return nil }
        if !unreadableApps.isEmpty || !skippedWindows.isEmpty {
            sentences.append("Try again once every app responds.")
        }
        return sentences.joined(separator: " ")
    }

    private func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
}

/// A capture and what it had to leave out. The document is complete for everything that could be
/// read; the report says what could not.
struct CaptureOutcome: Equatable {
    var document: WorkspaceDocument
    var report: CaptureReport
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

    func capture(name: String = "Untitled") -> CaptureOutcome {
        let liveDisplays = displays.displays()
        let onScreen = order.onScreenWindowIDsFrontToBack()
        var report = CaptureReport()

        var eligible: [(app: RunningAppInfo, window: AXWindowSnapshot, frame: CGRect, minimized: Bool)] = []
        for app in apps.apps() {
            let isSnapDesk = app.isSnapDesk || app.bundleIdentifier == snapDeskBundleID
            guard app.activationPolicyIsRegular, !isSnapDesk else { continue }
            // Restore matches windows by bundle identifier, so a slot without one could never be
            // filled: it would burn the whole window timeout and fail. Not writing it is kinder
            // than writing it wrong, but only if the user hears that the app was left out.
            guard !app.bundleIdentifier.isEmpty else {
                Log.capture.error("skipping \(app.displayName, privacy: .public): it has no bundle identifier")
                report.unidentifiedApps.append(app.displayName)
                continue
            }
            let windows: [AXWindowSnapshot]
            do {
                windows = try ax.windows(pid: app.pid)
            } catch {
                // The app did not answer within the AX timeout, exited, or Accessibility refused.
                // Dropping it silently left a workspace that looked complete and lacked the app
                // on every later restore, with nothing but a pid in the log to say so.
                Log.capture.error(
                    "\(app.displayName, privacy: .public) (pid \(app.pid)) did not answer; its windows were not captured: \(String(describing: error), privacy: .public)"
                )
                report.unreadableApps.append(app.displayName)
                continue
            }
            for window in windows {
                // A failed read must not be captured as a value: `minimized: false` for a window
                // whose state could not be read goes to disk and is reproduced by every later
                // restore. The window is skipped instead — and counted, so the user is told.
                guard let frame = window.cocoaFrame, let minimized = window.minimized else {
                    Log.capture.error(
                        "skipping a window of \(app.displayName, privacy: .public): its frame or minimized state could not be read"
                    )
                    report.skippedWindows[app.displayName, default: 0] += 1
                    continue
                }
                let candidate = CaptureCandidate(
                    subrole: window.subrole,
                    frame: frame,
                    isSnapDesk: isSnapDesk,
                    activationPolicyIsRegular: app.activationPolicyIsRegular,
                    hasTitleBarButtons: window.hasTitleBarButtons
                )
                if CaptureFilter.isEligible(candidate) {
                    eligible.append((app, window, frame, minimized))
                }
            }
        }

        let ordering = CaptureOrdering.sortedIndices(
            of: eligible.map { item in
                OrderedWindow(
                    cgWindowID: item.window.cgWindowID,
                    isMinimized: item.minimized
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
            guard let assigned = Self.display(containing: item.frame, in: liveDisplays) else {
                Log.capture.error("skipping \(item.app.name, privacy: .public) window: no display to record it against")
                return nil
            }
            let relative = FramePlacement.relative(
                cocoa: item.frame,
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
                minimized: item.minimized,
                // Inferred against the display list this capture records, from the very frame it
                // saves beside it, so the two cannot disagree.
                zoomed: AXWindow.isZoomed(frame: item.frame, on: liveDisplays),
                // Read rather than inferred, which is the whole difference from `zoomed` above.
                // An unreadable state stays nil: saved as `false` it would drag the window out of
                // fullscreen on every later restore. Unlike the frame and the minimized state, it
                // does not disqualify the window — nil is a value this field is allowed to hold.
                fullscreen: item.window.fullscreen,
                // Filtered rather than passed through: the attribute is not a URL field, and a
                // capture must never produce a document the loader would then refuse. That
                // invariant is pinned by `testCaptureNeverRecordsAWindowValidationWouldReject`.
                // An unusable value costs the document, never the window.
                document: item.window.document.flatMap {
                    WorkspaceDocumentReference.isUsable($0) ? $0 : nil
                },
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

        if let explanation = report.explanation {
            Log.capture.error(
                "captured \(windows.count) window(s) on \(savedDisplays.count) display(s), incomplete: \(explanation, privacy: .public)"
            )
        } else {
            Log.capture.info("captured \(windows.count) of \(ordering.count) eligible window(s) on \(savedDisplays.count) display(s)")
        }

        let document = WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: name,
            moveExistingWindows: true,
            displays: savedDisplays,
            windows: windows
        )
        return CaptureOutcome(document: document, report: report)
    }

    /// The display a captured window is recorded against. This deliberately diverges from
    /// `ScreenGeometry.display(containing:)`, which answers nil for a window that touches no
    /// display: a window parked off every screen is still worth capturing, so it is recorded
    /// against the primary display and comes back on-screen at restore, where `FramePlacement`
    /// clamps it into that display's visible frame. Nil only when no display is attached.
    private static func display(containing frame: CGRect, in live: [LiveDisplay]) -> LiveDisplay? {
        if let exact = ScreenGeometry.display(containing: frame, in: live) {
            return exact
        }
        if let primary = live.first {
            Log.capture.notice(
                "a window at \(frame.debugDescription, privacy: .public) is off every display; recording it against \(primary.name, privacy: .public)"
            )
            return primary
        }
        return nil
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
    /// The raw reads and nothing else: which of them a failed read disqualifies, and what a failed
    /// list means, is `CaptureService`'s decision, where it is testable against a fake. The
    /// honest `minimizedState` is passed through rather than `isMinimized`, because the value goes
    /// to disk and a failed read saved as `false` is reproduced by every later restore.
    func windows(pid: pid_t) throws -> [AXWindowSnapshot] {
        try AXWindow.windows(pid: pid).map { window in
            AXWindowSnapshot(
                cgWindowID: window.cgWindowID,
                title: window.title ?? "",
                subrole: window.subrole,
                cocoaFrame: window.cocoaFrame,
                minimized: window.minimizedState,
                fullscreen: window.fullscreenState,
                document: window.documentURL,
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
