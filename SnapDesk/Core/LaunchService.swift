import AppKit
import CoreGraphics
import Foundation

enum SlotStatus: Equatable, Sendable {
    case pending
    case launching
    case placed
    case failed(String)
}

struct SlotProgress: Equatable, Sendable {
    var index: Int
    var name: String
    var status: SlotStatus
}

struct LaunchConfiguration: Equatable, Sendable {
    var arguments: [String]
    var createsNewApplicationInstance: Bool
    var activates: Bool
}

@MainActor
protocol ApplicationLaunching: Sendable {
    func urlForApplication(bundleIdentifier: String) -> URL?
    func applicationExists(at path: String) -> Bool
    func openApplication(at url: URL, configuration: LaunchConfiguration) async throws
}

@MainActor
protocol RunningApplicationQuerying {
    func runningBundleIDs() -> Set<String>
    func unhide(bundleIdentifier: String)
    func activate(bundleIdentifier: String)
}

@MainActor
protocol WindowCatalog {
    func standardWindows(bundleIdentifier: String) -> [MatchableWindow]
    func waitForWindow(
        bundleIdentifier: String,
        excluding: Set<String>,
        timeout: Duration
    ) async -> MatchableWindow?
}

@MainActor
protocol WindowPlacing {
    func place(_ window: MatchableWindow, cocoaFrame: CGRect, minimized: Bool, zoomed: Bool) -> Bool
}

@MainActor
protocol Clock {
    func sleep(_ duration: Duration) async
}

@MainActor
final class LaunchService {
    private let launcher: any ApplicationLaunching
    private let apps: any RunningApplicationQuerying
    private let windows: any WindowCatalog
    private let placer: any WindowPlacing
    private let displays: any DisplayCatalog
    private let clock: any Clock
    private let launchTimeout: Duration
    private let windowTimeout: Duration
    private var cancelled = false

    init(
        launcher: any ApplicationLaunching,
        apps: any RunningApplicationQuerying,
        windows: any WindowCatalog,
        placer: any WindowPlacing,
        displays: any DisplayCatalog,
        clock: any Clock,
        launchTimeout: Duration = .seconds(10),
        windowTimeout: Duration = .seconds(8)
    ) {
        self.launcher = launcher
        self.apps = apps
        self.windows = windows
        self.placer = placer
        self.displays = displays
        self.clock = clock
        self.launchTimeout = launchTimeout
        self.windowTimeout = windowTimeout
    }

    convenience init(
        launchTimeout: Duration = .seconds(10),
        windowTimeout: Duration = .seconds(8)
    ) {
        let clock = TaskClock()
        self.init(
            launcher: NSWorkspaceLauncher(),
            apps: NSWorkspaceRunningQuery(),
            windows: AXWindowCatalog(clock: clock),
            placer: AXWindowPlacer(),
            displays: NSScreenCatalog(),
            clock: clock,
            launchTimeout: launchTimeout,
            windowTimeout: windowTimeout
        )
    }

    func cancel() {
        cancelled = true
    }

    func launch(
        _ document: WorkspaceDocument,
        onProgress: @MainActor @escaping ([SlotProgress]) -> Void
    ) async -> [SlotProgress] {
        defer { cancelled = false }

        let slots = document.windows
        if slots.isEmpty {
            onProgress([])
            return []
        }

        var progress = slots.enumerated().map { index, window in
            SlotProgress(index: index, name: window.name, status: .pending)
        }
        onProgress(progress)

        if cancelled {
            failPending(&progress)
            onProgress(progress)
            return progress
        }

        let plans = LaunchPlanner.plan(document: document, runningBundleIDs: apps.runningBundleIDs())
        Log.launch.info("launching \(document.name, privacy: .public) with \(slots.count) slot(s)")

        var claimed: Set<String> = []
        for index in LaunchPlanner.placeOrder(windowCount: slots.count) {
            if cancelled {
                failPending(&progress)
                onProgress(progress)
                break
            }

            progress[index].status = .launching
            onProgress(progress)

            let slot = slots[index]
            let plan = plans[index]

            let url: URL?
            if let resolved = launcher.urlForApplication(bundleIdentifier: slot.bundleIdentifier) {
                url = resolved
            } else if launcher.applicationExists(at: slot.bundlePath) {
                url = URL(fileURLWithPath: slot.bundlePath)
            } else {
                url = nil
            }
            guard let url else {
                fail(&progress, index: index, reason: "App not found", onProgress: onProgress)
                continue
            }

            switch plan.action {
            case .launch(_, _, let arguments, let newInstance):
                let configuration = LaunchConfiguration(
                    arguments: arguments,
                    createsNewApplicationInstance: newInstance,
                    activates: false
                )
                do {
                    try await open(at: url, configuration: configuration)
                } catch {
                    fail(&progress, index: index, reason: "Launch failed", onProgress: onProgress)
                    continue
                }
            case .reuse:
                apps.unhide(bundleIdentifier: slot.bundleIdentifier)
            }

            guard let match = await resolveWindow(for: slot, claimed: claimed) else {
                fail(&progress, index: index, reason: "No window", onProgress: onProgress)
                continue
            }
            claimed.insert(match.id)

            let live = displays.displays()
            guard let main = live.first else {
                fail(&progress, index: index, reason: "Could not position", onProgress: onProgress)
                continue
            }
            let resolved = DisplayMap.resolve(
                displayId: slot.displayId,
                saved: document.displays,
                live: live,
                main: main
            )
            let savedVisible = document.displays.first(where: { $0.id == slot.displayId })?.visibleFrame.cgRect
                ?? resolved.visibleFrame
            let relative = CGRect(x: slot.x, y: slot.y, width: slot.width, height: slot.height)
            let restored = FramePlacement.restore(
                relative: relative,
                savedVisible: savedVisible,
                liveVisible: resolved.visibleFrame
            )
            let clamped = FramePlacement.clamp(restored, to: resolved.visibleFrame)

            if !placer.place(match, cocoaFrame: clamped, minimized: slot.minimized, zoomed: slot.zoomed) {
                fail(&progress, index: index, reason: "Could not position", onProgress: onProgress)
                continue
            }

            progress[index].status = .placed
            onProgress(progress)
        }

        activateFrontmost(slots: slots, progress: progress)
        return progress
    }

    private func open(at url: URL, configuration: LaunchConfiguration) async throws {
        let timeout = launchTimeout
        let launcher = launcher
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await launcher.openApplication(at: url, configuration: configuration)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LaunchTimeoutError()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func resolveWindow(for slot: SavedWindow, claimed: Set<String>) async -> MatchableWindow? {
        let waited = await windows.waitForWindow(
            bundleIdentifier: slot.bundleIdentifier,
            excluding: claimed,
            timeout: windowTimeout
        )
        guard let waited else { return nil }

        let pool = windows.standardWindows(bundleIdentifier: slot.bundleIdentifier)
        if pool.count > 1 {
            return WindowMatcher.match(slot: slot, among: pool, claimed: claimed)
        }
        guard !claimed.contains(waited.id) else { return nil }
        return waited
    }

    private func activateFrontmost(slots: [SavedWindow], progress: [SlotProgress]) {
        guard !slots.isEmpty else { return }
        if progress[0].status == .placed {
            apps.activate(bundleIdentifier: slots[0].bundleIdentifier)
            return
        }
        if let placed = progress.first(where: { $0.status == .placed }) {
            apps.activate(bundleIdentifier: slots[placed.index].bundleIdentifier)
        }
    }

    private func fail(
        _ progress: inout [SlotProgress],
        index: Int,
        reason: String,
        onProgress: @MainActor ([SlotProgress]) -> Void
    ) {
        let name = progress[index].name
        progress[index].status = .failed(reason)
        Log.launch.error("slot \(index) (\(name, privacy: .public)): \(reason, privacy: .public)")
        onProgress(progress)
    }

    private func failPending(_ progress: inout [SlotProgress]) {
        for index in progress.indices where progress[index].status == .pending {
            progress[index].status = .failed("Cancelled")
        }
    }
}

private struct LaunchTimeoutError: Error {}

@MainActor
struct NSWorkspaceLauncher: ApplicationLaunching {
    func urlForApplication(bundleIdentifier: String) -> URL? {
        guard !bundleIdentifier.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func applicationExists(at path: String) -> Bool {
        guard URL(fileURLWithPath: path).pathExtension == "app" else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func openApplication(at url: URL, configuration: LaunchConfiguration) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = configuration.arguments
        config.createsNewApplicationInstance = configuration.createsNewApplicationInstance
        config.activates = configuration.activates
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

@MainActor
struct NSWorkspaceRunningQuery: RunningApplicationQuerying {
    func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func unhide(bundleIdentifier: String) {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleIdentifier {
            app.unhide()
        }
    }

    func activate(bundleIdentifier: String) {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }?.activate()
    }
}

@MainActor
struct AXWindowCatalog: WindowCatalog {
    var clock: any Clock

    func standardWindows(bundleIdentifier: String) -> [MatchableWindow] {
        runningApps(bundleIdentifier: bundleIdentifier).flatMap { app in
            AXWindow.windows(pid: app.processIdentifier).compactMap { window -> MatchableWindow? in
                guard isStandard(window), let id = matchableID(for: window) else { return nil }
                return MatchableWindow(
                    id: id,
                    bundleIdentifier: bundleIdentifier,
                    title: window.title ?? ""
                )
            }
        }
    }

    func waitForWindow(
        bundleIdentifier: String,
        excluding: Set<String>,
        timeout: Duration
    ) async -> MatchableWindow? {
        let timeline = ContinuousClock()
        let deadline = timeline.now.advanced(by: timeout)
        repeat {
            if let found = standardWindows(bundleIdentifier: bundleIdentifier).first(where: {
                !excluding.contains($0.id)
            }) {
                return found
            }
            if timeline.now >= deadline { return nil }
            await clock.sleep(.milliseconds(100))
        } while timeline.now < deadline
        return standardWindows(bundleIdentifier: bundleIdentifier).first { !excluding.contains($0.id) }
    }
}

@MainActor
struct AXWindowPlacer: WindowPlacing {
    func place(_ window: MatchableWindow, cocoaFrame: CGRect, minimized: Bool, zoomed: Bool) -> Bool {
        guard let ax = axWindow(matching: window) else { return false }
        _ = ax.setMinimized(false)
        if zoomed || ax.isZoomed {
            _ = ax.setZoomed(false)
        }
        guard ax.setCocoaFrame(cocoaFrame) == .success else { return false }
        if zoomed {
            _ = ax.setZoomed(true)
        }
        if minimized {
            _ = ax.setMinimized(true)
        }
        return true
    }

    private func axWindow(matching window: MatchableWindow) -> AXWindow? {
        for app in runningApps(bundleIdentifier: window.bundleIdentifier) {
            for ax in AXWindow.windows(pid: app.processIdentifier) {
                if matchableID(for: ax) == window.id {
                    return ax
                }
            }
        }
        return nil
    }
}

@MainActor
struct TaskClock: Clock {
    func sleep(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

@MainActor
private func runningApps(bundleIdentifier: String) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
}

@MainActor
private func matchableID(for window: AXWindow) -> String? {
    guard let identity = window.identity else { return nil }
    switch identity {
    case .cgWindow(let id, let pid):
        return "cg:\(pid):\(id)"
    case .fallback(let pid, let title):
        return "fb:\(pid):\(title)"
    }
}

@MainActor
private func isStandard(_ window: AXWindow) -> Bool {
    guard let frame = window.cocoaFrame else { return false }
    return CaptureFilter.isEligible(
        CaptureCandidate(
            bundleIdentifier: "",
            role: "AXWindow",
            subrole: window.subrole,
            frame: frame,
            isSnapDesk: false,
            activationPolicyIsRegular: true,
            isMinimized: window.isMinimized,
            cgWindowID: window.cgWindowID
        )
    )
}
