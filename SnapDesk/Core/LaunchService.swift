import AppKit
import CoreGraphics
import Foundation

/// Why a slot did not end up placed. A case rather than prose so the HUD can decide what a
/// failure means — whether to beep, whether to stay on screen — without matching on strings that
/// a reworded message would silently break.
enum SlotFailure: Equatable, Sendable {
    case appNotFound
    case launchFailed
    case launchTimedOut
    case noWindow
    case couldNotPosition

    var displayText: String {
        switch self {
        case .appNotFound:
            return "App not found"
        case .launchFailed:
            return "Launch failed"
        case .launchTimedOut:
            return "Launch timed out"
        case .noWindow:
            return "No window"
        case .couldNotPosition:
            return "Could not position"
        }
    }
}

enum SlotStatus: Equatable, Sendable {
    case pending
    case launching
    /// The slot has been given a window and is waiting for the placement pass, which cannot start
    /// until every slot has had its turn at claiming. Without this the HUD shows "Launching" for
    /// slots that are long since resolved while one slow app runs out the window timeout.
    case matched
    case placed
    /// The user stopped the restore. Deliberately *not* a `SlotFailure`: nothing went wrong, so
    /// this must not beep, must not pin the HUD open, and must not be logged as a failure.
    case cancelled
    case failed(SlotFailure)

    var failure: SlotFailure? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }
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

/// A plain read, with no waiting of its own: an app vends its windows over the seconds after it
/// launches, and the decision about how long to keep looking — and about what a Cancel does to a
/// restore that is still looking — belongs to `LaunchService`, which is the only thing that knows
/// how many windows the workspace is still expecting and whether the user has stopped it.
@MainActor
protocol WindowCatalog {
    func standardWindows(bundleIdentifier: String) -> [MatchableWindow]
}

/// Async because placement has to wait for a window to actually come back out of the Dock before
/// it writes the frame; see `WindowPlacement.apply`.
@MainActor
protocol WindowPlacing {
    func place(_ window: MatchableWindow, cocoaFrame: CGRect, minimized: Bool, zoomed: Bool) async -> Bool
}

@MainActor
protocol Clock {
    func sleep(_ duration: Duration) async
}

@MainActor
enum InfoPlistInstancePolicy {
    static func prohibitsMultipleInstances(bundleIdentifier: String, path: String) -> Bool {
        var urls: [URL] = []
        if !path.isEmpty {
            urls.append(URL(fileURLWithPath: path))
        }
        if !bundleIdentifier.isEmpty,
           let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        {
            urls.append(resolved)
        }
        for appURL in urls {
            if readProhibited(from: appURL) { return true }
        }
        return false
    }

    private static func readProhibited(from appURL: URL) -> Bool {
        if let bundle = Bundle(url: appURL),
           let value = bundle.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited") as? Bool
        {
            return value
        }
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: plist),
           let value = dict["LSMultipleInstancesProhibited"] as? Bool
        {
            return value
        }
        return false
    }
}

/// Serialises restores. Ownership passes straight from the finishing run to the next waiter:
/// resuming a continuation only schedules it, so clearing `isHeld` before the resume would leave
/// a window in which a caller arriving fresh sees an idle gate and runs alongside the waiter that
/// has been woken but has not been given control yet.
@MainActor
final class LaunchGate {
    private(set) var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

@MainActor
final class LaunchService {
    /// A cold launch of a large app off a slow disk can take several seconds. Past this the open
    /// is treated as hung so one wedged app cannot stall the rest of the restore.
    static let defaultLaunchTimeout: Duration = .seconds(10)

    /// An app returns from `openApplication` well before it vends a window over AX, so window
    /// discovery has to wait and poll. This bounds that wait.
    static let defaultWindowTimeout: Duration = .seconds(8)

    /// Window discovery polls. AX *does* have a "a window appeared" callback — `AXWindowCreated`,
    /// which registers and fires reliably on every app tested — but it cannot be used to find the
    /// windows a restore actually cares about. An observer can only be armed once the app's AX
    /// server answers, which happens within about 10ms of that app vending its first window, and
    /// there is no replay for windows that already existed when it armed; some apps emit no event
    /// for their launch window at all. Reading `kAXWindows` was the earlier signal in every
    /// measurement and never the later one, so an event-driven path would find the first window of
    /// a just-launched app strictly later, or not at all. The mature window managers carry KVO
    /// gating and retry backoff to survive that race; polling simply does not have it.
    ///
    /// 100ms is short enough that a restore still feels immediate — and that a Cancel is acted on
    /// without a visible delay — and long enough not to hammer the AX server of a starting app.
    static let windowPollInterval: Duration = .milliseconds(100)

    /// How long after placement a leftover claim stays open to being proved wrong. Windows arrive
    /// in two waves: the launch batch, where measured gaps between windows are under 20ms, and then
    /// macOS window restoration, measured at 2.5-3.7s. A slot that settled during the first wave
    /// can still have its own window turn up in the second, so this covers it with margin.
    static let correctionWindow: Duration = .seconds(4)

    private let launcher: any ApplicationLaunching
    private let apps: any RunningApplicationQuerying
    private let windows: any WindowCatalog
    private let placer: any WindowPlacing
    private let displays: any DisplayCatalog
    private let clock: any Clock
    private let launchTimeout: Duration
    private let windowTimeout: Duration
    private let prohibitsMultipleInstances: (String, String) -> Bool
    private var lastRunID = 0
    private var cancelledThroughRunID = 0
    private let gate = LaunchGate()

    init(
        launcher: any ApplicationLaunching,
        apps: any RunningApplicationQuerying,
        windows: any WindowCatalog,
        placer: any WindowPlacing,
        displays: any DisplayCatalog,
        clock: any Clock,
        launchTimeout: Duration = LaunchService.defaultLaunchTimeout,
        windowTimeout: Duration = LaunchService.defaultWindowTimeout,
        prohibitsMultipleInstances: @escaping (String, String) -> Bool = { _, _ in false }
    ) {
        self.launcher = launcher
        self.apps = apps
        self.windows = windows
        self.placer = placer
        self.displays = displays
        self.clock = clock
        self.launchTimeout = launchTimeout
        self.windowTimeout = windowTimeout
        self.prohibitsMultipleInstances = prohibitsMultipleInstances
    }

    convenience init(
        launchTimeout: Duration = LaunchService.defaultLaunchTimeout,
        windowTimeout: Duration = LaunchService.defaultWindowTimeout
    ) {
        let clock = TaskClock()
        self.init(
            launcher: NSWorkspaceLauncher(),
            apps: NSWorkspaceRunningQuery(),
            windows: AXWindowCatalog(),
            placer: AXWindowPlacer(clock: clock),
            displays: NSScreenCatalog(),
            clock: clock,
            launchTimeout: launchTimeout,
            windowTimeout: windowTimeout,
            prohibitsMultipleInstances: { bundleID, path in
                InfoPlistInstancePolicy.prohibitsMultipleInstances(
                    bundleIdentifier: bundleID,
                    path: path
                )
            }
        )
    }

    /// Stops every restore that is outstanding right now — the one that is running and any that
    /// are still waiting their turn on the gate, since the user meant to stop what they can see
    /// and whatever it is holding up. Runs are numbered on entry rather than flagged, so a stale
    /// click (the HUD outlives a restore with the button still live) marks nothing that exists and
    /// cannot reach into the *next* run.
    func cancel() {
        cancelledThroughRunID = lastRunID
    }

    func launch(
        _ document: WorkspaceDocument,
        onProgress: @MainActor @escaping ([SlotProgress]) -> Void
    ) async -> [SlotProgress] {
        lastRunID += 1
        let runID = lastRunID
        await gate.acquire()
        defer { gate.release() }

        let slots = document.windows
        if slots.isEmpty {
            onProgress([])
            return []
        }

        var progress = slots.enumerated().map { index, window in
            SlotProgress(index: index, name: window.name, status: .pending)
        }
        onProgress(progress)

        if isCancelled(runID) {
            cancelPending(&progress)
            onProgress(progress)
            return progress
        }

        let plans = LaunchPlanner.plan(
            document: document,
            runningBundleIDs: apps.runningBundleIDs(),
            prohibitsMultipleInstances: prohibitsMultipleInstances
        )
        Log.launch.info("launching \(document.name, privacy: .public) with \(slots.count) slot(s)")

        for plan in plans {
            if isCancelled(runID) {
                cancelPending(&progress)
                onProgress(progress)
                return progress
            }
            guard case .launch(_, _, let arguments, let newInstance) = plan.action else { continue }

            let index = plan.index
            progress[index].status = .launching
            onProgress(progress)

            guard let url = resolveURL(for: slots[index]) else {
                fail(&progress, index: index, reason: .appNotFound, onProgress: onProgress)
                continue
            }
            let configuration = LaunchConfiguration(
                arguments: arguments,
                createsNewApplicationInstance: newInstance,
                activates: false
            )
            do {
                try await open(at: url, configuration: configuration)
                progress[index].status = .pending
                onProgress(progress)
            } catch {
                // A Cancel that lands while a slow app is being opened comes back here as the open
                // timing out or being torn down. That is the user stopping the restore, not the app
                // failing: reporting it as a failure beeps at them and pins the HUD open.
                if isCancelled(runID) {
                    cancelPending(&progress)
                    onProgress(progress)
                    return progress
                }
                let timedOut = error is LaunchTimeoutError
                Log.launch.error(
                    """
                    slot \(index) could not open \(url.lastPathComponent, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
                fail(
                    &progress,
                    index: index,
                    reason: timedOut ? .launchTimedOut : .launchFailed,
                    onProgress: onProgress
                )
            }
        }

        var claimed: Set<String> = []
        var matches: [Int: MatchableWindow] = [:]
        var provisional: [Int: MatchableWindow] = [:]
        var stopped = false

        // Which slots are still owed a window, in the order the workspace lists them. Nothing here
        // suspends, so a cancel can only have arrived through `onProgress`.
        var waiting: [Int] = []
        for index in slots.indices {
            if isCancelled(runID) {
                cancelPending(&progress)
                onProgress(progress)
                stopped = true
                break
            }
            if case .failed = progress[index].status { continue }

            progress[index].status = .launching
            onProgress(progress)

            let slot = slots[index]

            if resolveURL(for: slot) == nil {
                fail(&progress, index: index, reason: .appNotFound, onProgress: onProgress)
                continue
            }

            if case .reuse = plans[index].action {
                apps.unhide(bundleIdentifier: slot.bundleIdentifier)
            }

            waiting.append(index)
        }

        // How many windows the workspace expects each app to produce. An app that has vended that
        // many has nothing further coming that this restore is entitled to wait for, so the slots
        // still unmatched at that point — titles that changed since the capture, the ordinary case
        // — get their leftovers straight away instead of after the timeout.
        var expectedWindows: [String: Int] = [:]
        for index in waiting {
            expectedWindows[slots[index].bundleIdentifier, default: 0] += 1
        }

        // An app returns from `openApplication` long before it vends its windows, and it vends them
        // in whatever order suits it, unrelated to the order the workspace saved them in. So the
        // claim is retried against a fresh snapshot until every slot has a window, the apps have
        // nothing more to vend, or the timeout runs out. Settling it on the first snapshot strands
        // the slot whose own window is merely late — the normal case on a cold launch, which is
        // also the case the restore exists for.
        //
        // Within a snapshot every exact title is settled before any slot is offered a leftover, and
        // leftovers go out only once nothing more is expected; `WindowMatcher` explains why that
        // has to happen against one read rather than two.
        //
        // Bounded by a poll count rather than a wall clock so the wait is the same length whichever
        // `Clock` is driving it.
        var pollsLeft = Int((windowTimeout / Self.windowPollInterval).rounded(.up))
        while !stopped, !waiting.isEmpty {
            // The window wait is where a Cancel most often lands — the user clicks while a slow app
            // is still starting — so it is checked here, between polls, rather than only once the
            // whole timeout has run out and the slot has already been written off as a failure.
            if isCancelled(runID) {
                cancelPending(&progress)
                onProgress(progress)
                stopped = true
                break
            }

            let pendingSlots = waiting.map { slots[$0] }
            let pool = snapshot(of: pendingSlots)
            let outOfPolls = pollsLeft == 0
            // Which slots may settle for a window they are not named after, decided per app rather
            // than for the restore as a whole. An app that has vended as many windows as the
            // workspace expects of it will not produce more, so its slots can settle now; deciding
            // it globally would hold those slots at "Matching" for the whole timeout whenever some
            // *other* app in the workspace never vends at all.
            let finished = finishedBundles(pendingSlots: pendingSlots, pool: pool, expected: expectedWindows)
            let takingLeftovers = Set(
                pendingSlots.indices.filter { outOfPolls || finished.contains(pendingSlots[$0].bundleIdentifier) }
            )
            let exact = WindowMatcher.exactTitles(slots: pendingSlots, among: pool, claimed: claimed)
            let assignment = WindowMatcher.assign(
                slots: pendingSlots,
                among: pool,
                claimed: claimed,
                takingLeftovers: takingLeftovers
            )

            var stillWaiting: [Int] = []
            for (position, index) in waiting.enumerated() {
                if let window = assignment[position] {
                    claimed.insert(window.id)
                    matches[index] = window
                    // A window the slot is not named after is a guess, not an answer; remember it
                    // so the correction pass below can revisit it if the real one turns up.
                    if exact[position]?.id != window.id {
                        provisional[index] = window
                    }
                    progress[index].status = .matched
                    onProgress(progress)
                } else if takingLeftovers.contains(position) {
                    // Its app is done vending — or the wait is over — and there was nothing left.
                    fail(&progress, index: index, reason: .noWindow, onProgress: onProgress)
                } else {
                    stillWaiting.append(index)
                }
            }
            waiting = stillWaiting
            if waiting.isEmpty { break }

            pollsLeft -= 1
            await clock.sleep(Self.windowPollInterval)
        }

        if !stopped {
            for index in LaunchPlanner.placeOrder(windowCount: slots.count) {
                if isCancelled(runID) {
                    cancelPending(&progress)
                    onProgress(progress)
                    break
                }
                guard let match = matches[index] else { continue }
                let slot = slots[index]

                guard let clamped = targetFrame(for: slot, in: document) else {
                    fail(&progress, index: index, reason: .couldNotPosition, onProgress: onProgress)
                    continue
                }
                let placed = await placer.place(
                    match,
                    cocoaFrame: clamped,
                    minimized: slot.minimized,
                    zoomed: slot.zoomed
                )
                if !placed {
                    // A placement torn down by a Cancel refuses like any other. The user stopping
                    // the restore is not a slot that could not be positioned.
                    if isCancelled(runID) {
                        cancelPending(&progress)
                        onProgress(progress)
                        break
                    }
                    fail(&progress, index: index, reason: .couldNotPosition, onProgress: onProgress)
                    continue
                }

                progress[index].status = .placed
                onProgress(progress)
            }
        }

        activateFrontmost(slots: slots, progress: progress)

        // Settling for a leftover was a guess made on incomplete information, and it is worth
        // revisiting rather than predicting better: whether an app has finished opening its windows
        // is not knowable, and every signal macOS offers reports something strictly earlier. This
        // runs after the layout the user is waiting for is already on screen and after the
        // frontmost app has been activated, so it can only improve on the guess.
        if !stopped, !provisional.isEmpty {
            await correctProvisionalClaims(
                provisional,
                slots: slots,
                document: document,
                claimed: claimed,
                progress: &progress,
                runID: runID,
                onProgress: onProgress
            )
        }
        return progress
    }

    /// Replaces a guessed claim with the window the slot is actually named after, if that window
    /// turns up while the correction window is open. The guessed window is left where it was put:
    /// nothing here knows where it belongs instead, and moving it a second time would be one more
    /// guess. What matters is that the slot the user saved ends up holding its own window.
    private func correctProvisionalClaims(
        _ provisional: [Int: MatchableWindow],
        slots: [SavedWindow],
        document: WorkspaceDocument,
        claimed: Set<String>,
        progress: inout [SlotProgress],
        runID: Int,
        onProgress: @MainActor ([SlotProgress]) -> Void
    ) async {
        var pending = provisional
        var taken = claimed
        var pollsLeft = Int((Self.correctionWindow / Self.windowPollInterval).rounded(.up))

        while pollsLeft > 0, !pending.isEmpty {
            if isCancelled(runID) { return }
            await clock.sleep(Self.windowPollInterval)
            pollsLeft -= 1

            let pool = snapshot(of: pending.keys.map { slots[$0] })
            // Descending, so that when several corrections land in the same poll slot 0 is placed
            // last and therefore ends up on top, matching the placement pass.
            for index in pending.keys.sorted(by: >) {
                let slot = slots[index]
                guard let own = pool.first(where: {
                    $0.bundleIdentifier == slot.bundleIdentifier
                        && $0.title == slot.title
                        && !taken.contains($0.id)
                }) else { continue }

                taken.insert(own.id)
                pending[index] = nil
                guard let frame = targetFrame(for: slot, in: document) else { continue }
                guard await placer.place(
                    own,
                    cocoaFrame: frame,
                    minimized: slot.minimized,
                    zoomed: slot.zoomed
                ) else { continue }

                Log.launch.info(
                    """
                    slot \(index) (\(slot.name, privacy: .public)): replaced a guessed window with \
                    "\(slot.title, privacy: .public)", which vended after the slot had settled
                    """
                )
                progress[index].status = .placed
                onProgress(progress)
            }
        }
    }

    /// Where a slot's window belongs on the screens attached right now. Nil when no display is
    /// attached at all, which is the one case that cannot be a placement.
    private func targetFrame(for slot: SavedWindow, in document: WorkspaceDocument) -> CGRect? {
        let live = displays.displays()
        guard let main = live.first else { return nil }
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
        return FramePlacement.clamp(restored, to: resolved.visibleFrame)
    }

    private func resolveURL(for slot: SavedWindow) -> URL? {
        if let resolved = launcher.urlForApplication(bundleIdentifier: slot.bundleIdentifier) {
            return resolved
        }
        if launcher.applicationExists(at: slot.bundlePath) {
            return URL(fileURLWithPath: slot.bundlePath)
        }
        return nil
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

    /// Every window the still-waiting slots could be given, read once per app rather than once per
    /// slot: two slots of the same app reading separately would see two different snapshots, and a
    /// window that vends between the reads is exactly the one an earlier slot can steal from the
    /// later slot it belongs to.
    private func snapshot(of pendingSlots: [SavedWindow]) -> [MatchableWindow] {
        var seen: Set<String> = []
        var pool: [MatchableWindow] = []
        for slot in pendingSlots {
            guard seen.insert(slot.bundleIdentifier).inserted else { continue }
            pool.append(contentsOf: windows.standardWindows(bundleIdentifier: slot.bundleIdentifier))
        }
        return pool
    }

    /// The apps that will not turn up another window, so their still-unmatched slots may settle for
    /// a leftover now. The signal is the count the workspace saved, not the titles: an app that has
    /// vended as many windows as the workspace expects of it is treated as done, whatever they are
    /// called, because waiting on a title is indistinguishable from waiting on one the user renamed
    /// since the capture — and that case must not cost the whole timeout. The price is the reverse
    /// case: an app that vends an *extra* window early (a start-page window, say) looks finished
    /// before a slot's real window arrives, and that slot settles for the extra one. Counting is the
    /// side of that trade that keeps the common restore fast. `pool` counts claimed windows too —
    /// they are part of what the app has vended.
    private func finishedBundles(
        pendingSlots: [SavedWindow],
        pool: [MatchableWindow],
        expected: [String: Int]
    ) -> Set<String> {
        Set(pendingSlots.map(\.bundleIdentifier)).filter { bundle in
            pool.filter { $0.bundleIdentifier == bundle }.count >= (expected[bundle] ?? 0)
        }
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
        reason: SlotFailure,
        onProgress: @MainActor ([SlotProgress]) -> Void
    ) {
        let name = progress[index].name
        progress[index].status = .failed(reason)
        Log.launch.error("slot \(index) (\(name, privacy: .public)): \(reason.displayText, privacy: .public)")
        onProgress(progress)
    }

    private func isCancelled(_ runID: Int) -> Bool {
        cancelledThroughRunID >= runID
    }

    /// Anything not already placed or failed is lost to the cancel. `.launching` and `.matched`
    /// count: a slot that has claimed a window but not yet been placed would otherwise sit in a
    /// non-terminal status forever and keep the HUD from ever finishing.
    private func cancelPending(_ progress: inout [SlotProgress]) {
        for index in progress.indices {
            switch progress[index].status {
            case .pending, .launching, .matched:
                progress[index].status = .cancelled
            case .placed, .cancelled, .failed:
                continue
            }
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
}

/// The AX reads and writes a placement performs. `AXWindow` is the only real conformance; the
/// protocol exists because the ordering rules in `WindowPlacement` — above all the wait for a
/// window to actually come back out of the Dock — cannot be tested against a live window, whose
/// animations are what make the bug invisible in the first place.
@MainActor
protocol PlaceableWindow {
    /// Nil for a read that failed, which is not the same as false; see `AXWindow.minimizedState`.
    /// The placement needs the distinction, so it takes the honest read and never `isMinimized`.
    var minimizedState: Bool? { get }
    /// Inferred from the frame, so it is a heuristic in both directions; see `AXWindow.isZoomed`.
    /// The placement reads it after a press because a press is a toggle whose direction AppKit
    /// chose — accepting the write is not the window ending up zoomed.
    var isZoomed: Bool { get }
    /// The read and the write in one place, so the two cannot drift apart: a refusal on a window
    /// *confirmed* minimized has to stop a placement, and a refusal on a state that could not be
    /// read must not. See `AXWindow.UnminimizeOutcome`.
    func unminimize() -> AXWindow.UnminimizeOutcome
    func setMinimized(_ minimized: Bool) -> AXError
    func setZoomed(_ zoomed: Bool) -> AXError
    func setCocoaFrame(_ frame: CGRect) -> AXError
}

extension AXWindow: PlaceableWindow {}

@MainActor
enum WindowPlacement {
    /// A deminiaturize animates, and a window still in the Dock swallows position and size writes
    /// while AX reports `.success` for them. Two seconds covers the animation on a loaded machine
    /// and still bounds a wedged app, which would otherwise stall the rest of the restore.
    static let deminiaturizeTimeout: Duration = .seconds(2)

    /// A zoom animates in about a quarter of a second and, unlike the deminiaturize, is not a
    /// precondition for anything after it — so it gets its own, much shorter bound. Reusing the
    /// two-second one would cost that per window whose zoom can never take, and a workspace full of
    /// fixed-size utility windows would spend most of its restore waiting for presses to land that
    /// never will.
    static let zoomTimeout: Duration = .milliseconds(500)

    /// Short enough that a window that comes straight back is not visibly held up, long enough not
    /// to hammer the AX server of an app that is mid-animation.
    static let statePollInterval: Duration = .milliseconds(50)

    static func apply(
        to ax: some PlaceableWindow,
        cocoaFrame: CGRect,
        minimized: Bool,
        zoomed: Bool,
        bundleIdentifier id: String,
        clock: any Clock
    ) async -> Bool {
        // A slot saved minimized on a window that is still minimized needs nothing: the frame write
        // would be swallowed by the Dock anyway, and deminiaturizing just to re-minimize is a flash
        // the user sees for no gain. Only a *confirmed* minimized short-circuits — an unreadable
        // state is not evidence of anything, and falls through to the honest sequence below.
        if minimized, ax.minimizedState == true { return true }

        // Un-minimizing is a precondition, not a cosmetic: a window still in the Dock swallows the
        // writes below while AX reports `.success` for them. What a refusal *means* depends on what
        // the state read said, which is why this comes through `unminimize()` rather than a lossy
        // `AXError`.
        switch ax.unminimize() {
        case .alreadyUp:
            // Nothing was written, so there is nothing to wait for and nothing that can have failed.
            break

        case .wasMinimized(let write):
            // Confirmed in the Dock: getting it out is a precondition, so a refusal — or a state
            // that never flips — stops the placement, because the frame write would report success
            // and do nothing. Accepting the write is not the window being back either (AX writes
            // reach the window server asynchronously), so the state is re-read until it flips.
            guard succeeded(write, bundleIdentifier: id, step: "un-minimize") else { return false }
            guard await settled(clock: clock, timeout: deminiaturizeTimeout, until: { ax.minimizedState == false })
            else {
                Log.ax.error(
                    """
                    a window of \(id, privacy: .public) never came back out of the Dock; \
                    its frame was left alone rather than written to a minimized window
                    """
                )
                return false
            }

        case .stateUnknown(let write):
            // Sent blind, because the read fails for exactly the window that needs it most — one
            // minimized long enough that its app is swapped out. The wait here is for an *answer*
            // rather than for a particular one: a swapped-out app pages back in mid-wait, and what
            // it then says decides this. Still minimized is the same precondition failure as
            // `.wasMinimized` — the frame write would report success and move nothing. Never
            // answering at all is not a verdict, so the frame write below gets its turn rather than
            // a window whose only sin is a slow AX server being refused.
            if write == .success,
               await settled(clock: clock, timeout: deminiaturizeTimeout, until: { ax.minimizedState != nil }),
               ax.minimizedState == true
            {
                Log.ax.error(
                    """
                    a window of \(id, privacy: .public) reported itself still in the Dock after an \
                    un-minimize; its frame was left alone rather than written to a minimized window
                    """
                )
                return false
            }
        }

        // Un-zooming first is only a head start for the frame write, so a refusal must not abort
        // the placement: `isZoomed` is inferred from the frame, so a non-resizable window sitting
        // at the visible frame reads as zoomed, has no zoom button to press, and would lose a move
        // that the frame write alone would have made.
        //
        // Unlike the un-minimize above, this one *stays* conditional on the lossy read, and
        // deliberately: there is no zoom state to read, only a frame to infer one from, and the
        // only way to un-zoom is to press a button that toggles. Pressing on a frame we could not
        // read would zoom a window that was not zoomed — worse than skipping a precondition whose
        // only job is to help the frame write that follows (and which, on a window whose frame
        // cannot be read, fails on its own and reports the placement as failed).
        if ax.isZoomed {
            _ = succeeded(ax.setZoomed(false), bundleIdentifier: id, step: "un-zoom")
        }

        // The one write the whole placement exists for, so its refusal is the one most worth a log
        // line: every other step here already names itself when it fails.
        guard succeeded(ax.setCocoaFrame(cocoaFrame), bundleIdentifier: id, step: "frame") else {
            return false
        }

        // The frame is applied by this point, but a slot whose saved zoom or minimize state was
        // refused has not been restored, so it must not be reported as a clean placement.
        var restoredState = true
        if zoomed {
            restoredState = await ensureZoomed(ax, id: id, clock: clock) && restoredState
        }
        if minimized {
            restoredState = succeeded(ax.setMinimized(true), bundleIdentifier: id, step: "minimize") && restoredState
        }
        return restoredState
    }

    /// Presses towards zoomed only while the state does not already answer the request, then reads
    /// the outcome back — because the press is a toggle AppKit aims from its own frame test, so a
    /// press on a window already sitting on the zoom target sends it back off the frame that was
    /// just written and answers `.success` for having done it.
    ///
    /// Two attempts, because a press that went the wrong way is corrected by the next one.
    /// `isZoomed` is the only outcome there is to read, and reading it is what turns "the button was
    /// pressed" into "the window is there".
    ///
    /// The guard has to live here and not only inside `AXWindow.setZoomed`: this loop is the
    /// placement's own outcome verification, and it is the only one visible at the seam the
    /// sequencing is tested against.
    private static func ensureZoomed(_ ax: some PlaceableWindow, id: String, clock: any Clock) async -> Bool {
        for _ in 0..<2 {
            if ax.isZoomed { return true }
            guard succeeded(ax.setZoomed(true), bundleIdentifier: id, step: "zoom") else { return false }
            if await settled(clock: clock, timeout: zoomTimeout, until: { ax.isZoomed }) { return true }
        }
        Log.ax.error(
            """
            a window of \(id, privacy: .public) was saved zoomed but would not stay zoomed; \
            it is on its saved frame but the slot is not fully restored
            """
        )
        return false
    }

    /// Polls a fixed number of times rather than against a wall clock so the wait is the same
    /// length whichever `Clock` is driving it.
    private static func settled(
        clock: any Clock,
        timeout: Duration,
        until isDone: @MainActor () -> Bool
    ) async -> Bool {
        let polls = Int((timeout / statePollInterval).rounded(.up))
        for _ in 0..<polls {
            if isDone() { return true }
            await clock.sleep(statePollInterval)
        }
        return isDone()
    }

    /// `AXWindow` already logs the refused write; this records which app's placement it cost,
    /// which is what turns a stray AX notice into something a bug report can be read against.
    private static func succeeded(_ result: AXError, bundleIdentifier: String, step: String) -> Bool {
        guard result != .success else { return true }
        Log.ax.error(
            """
            placing a window of \(bundleIdentifier, privacy: .public) failed at \
            \(step, privacy: .public) (AXError \(result.rawValue))
            """
        )
        return false
    }
}

@MainActor
struct AXWindowPlacer: WindowPlacing {
    var clock: any Clock = TaskClock()

    func place(_ window: MatchableWindow, cocoaFrame: CGRect, minimized: Bool, zoomed: Bool) async -> Bool {
        guard let ax = axWindow(matching: window) else { return false }
        return await WindowPlacement.apply(
            to: ax,
            cocoaFrame: cocoaFrame,
            minimized: minimized,
            zoomed: zoomed,
            bundleIdentifier: window.bundleIdentifier,
            clock: clock
        )
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
