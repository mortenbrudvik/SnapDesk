import AppKit
import CoreGraphics
import Foundation

/// Why a slot did not end up placed. A case rather than prose so the HUD can decide what a
/// failure means — whether to beep, whether to stay on screen — without matching on strings that
/// a reworded message would silently break.
enum SlotFailure: Equatable, Sendable, CaseIterable {
    case appNotFound
    case launchFailed
    case launchTimedOut
    /// The app never vended a window this slot could take.
    case noWindow
    /// Every window the app has belongs to an instance that was already running, and this restore
    /// asked for a new one. Plenty of apps ignore `createsNewApplicationInstance` and simply
    /// activate the copy that is open — reported apart from `.noWindow`, which for an app with six
    /// windows on screen sends the user looking for a bug that is not there.
    case noNewWindow
    /// No display is attached at all, so there is no frame to compute.
    case noDisplay
    /// The app's window list could not be read on any poll — it never answered within the AX
    /// timeout, or Accessibility refused — which is not the same as it having no windows.
    case windowsUnreadable
    /// The window the slot claimed was gone by the time it came to be placed: closed, or retitled
    /// since the claim under the title-based fallback identity.
    case windowGone
    /// A write the placement depends on was refused, or the window never left the Dock.
    case couldNotPosition
    /// The frame was written and the window sits on it; only the saved zoom or minimize did not
    /// take. Reported apart from `couldNotPosition` because the user would otherwise go looking
    /// for a window that is exactly where they saved it.
    case stateNotRestored

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
        case .noNewWindow:
            return "No new window"
        case .noDisplay:
            return "No display attached"
        case .windowsUnreadable:
            return "Could not read windows"
        case .windowGone:
            return "Window disappeared"
        case .couldNotPosition:
            return "Could not position"
        case .stateNotRestored:
            return "Zoom or minimize failed"
        }
    }
}

/// What a "Placed" has to be qualified with. A restore that guessed, or that aimed at a
/// substitute screen, still reports every slot placed — and used to say nothing more, so a layout
/// that came back "wrong" had no explanation anywhere.
struct PlacementNote: Equatable, Sendable {
    /// The slot holds a window it is not named after: a leftover it settled for while its own
    /// window had not vended, and that the correction pass has not (yet) replaced.
    var isGuess = false
    /// The display the window went to, when the one it was captured on is not attached.
    var substituteDisplay: String? = nil

    static let clean = PlacementNote()
}

enum SlotStatus: Equatable, Sendable {
    case pending
    case launching
    /// The slot has been given a window and is waiting for the placement pass, which cannot start
    /// until every slot has had its turn at claiming. Without this the HUD shows "Launching" for
    /// slots that are long since resolved while one slow app runs out the window timeout.
    case matched
    case placed(PlacementNote)
    /// The user stopped the restore. Deliberately *not* a `SlotFailure`: nothing went wrong, so
    /// this must not beep, must not pin the HUD open, and must not be logged as a failure.
    case cancelled
    case failed(SlotFailure)

    var failure: SlotFailure? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }

    var isPlaced: Bool {
        guard case .placed = self else { return false }
        return true
    }
}

/// How one placement ended, from the seam the service drives. A `Bool` here collapsed three
/// different things into "Could not position": a window that vanished, a write that was refused,
/// and a window that sits on its saved frame but would not zoom or minimize.
enum PlacementOutcome: Equatable, Sendable {
    case placed
    /// The frame is applied; the saved zoom or minimize is not.
    case stateNotRestored
    /// The window is no longer listed for its app: closed, or retitled under the title-based
    /// fallback identity since it was claimed.
    case windowGone
    /// The app's window list could not be read at all, so whether the window is still there is
    /// not known — which is a different thing from knowing that it is gone.
    case windowsUnreadable
    /// A write the placement depends on was refused, or the window never left the Dock.
    case refused

    /// The slot failure this outcome reports as; nil for a clean placement.
    var slotFailure: SlotFailure? {
        switch self {
        case .placed: return nil
        case .stateNotRestored: return .stateNotRestored
        case .windowGone: return .windowGone
        case .windowsUnreadable: return .windowsUnreadable
        case .refused: return .couldNotPosition
        }
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
    /// Every process running under the bundle identifier right now. Read before a new-instance
    /// launch, so the windows of those processes can be told from the new instance's.
    func runningPIDs(bundleIdentifier: String) -> Set<pid_t>
    func unhide(bundleIdentifier: String)
    /// Brings the app forward — the process `pid` when it is one of the bundle's, else whichever
    /// process runs under the bundle identifier. A restore that launched a second instance means
    /// the one holding the restored window, not the one the user already had open.
    func activate(bundleIdentifier: String, pid: pid_t?)
}

/// A plain read, with no waiting of its own: an app vends its windows over the seconds after it
/// launches, and the decision about how long to keep looking — and about what a Cancel does to a
/// restore that is still looking — belongs to `LaunchService`, which is the only thing that knows
/// how many windows the workspace is still expecting and whether the user has stopped it.
@MainActor
protocol WindowCatalog {
    /// Throws when the window list could not be read at all — the app did not answer within the
    /// AX timeout, or Accessibility refused — which is not the same as it having no windows: an
    /// empty list is an answer, and the claim loop treats the two differently.
    func standardWindows(bundleIdentifier: String) throws -> [MatchableWindow]
}

/// Async because placement has to wait for a window to actually come back out of the Dock before
/// it writes the frame; see `WindowPlacement.apply`.
@MainActor
protocol WindowPlacing {
    func place(_ window: MatchableWindow, cocoaFrame: CGRect, minimized: Bool, zoomed: Bool) async -> PlacementOutcome
}

/// The two things a bounded wait needs from time: to let some pass, and to know how much has.
/// Both come through here so a whole restore can be driven through poll counts and a virtual
/// clock in tests, with no real sleep. Named to stay clear of `Swift.Clock`.
@MainActor
protocol RestoreClock {
    var now: ContinuousClock.Instant { get }
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
/// resuming a continuation only schedules it, so clearing the holder before the resume would leave
/// a window in which a caller arriving fresh sees an idle gate and runs alongside the waiter that
/// has been woken but has not been given control yet. Only the holder's ticket releases: a stale
/// release — twice from one run, or from a run that is no longer the holder — must not hand the
/// gate to a waiter while the real holder is still restoring.
@MainActor
final class LaunchGate {
    struct Ticket: Equatable, Sendable {
        fileprivate let id: Int
    }

    private var nextID = 0
    private var holder: Int?
    private var waiters: [(ticket: Ticket, continuation: CheckedContinuation<Void, Never>)] = []

    var isHeld: Bool { holder != nil }
    var waiterCount: Int { waiters.count }

    func acquire() async -> Ticket {
        nextID += 1
        let ticket = Ticket(id: nextID)
        guard isHeld else {
            holder = ticket.id
            return ticket
        }
        await withCheckedContinuation { waiters.append((ticket, $0)) }
        return ticket
    }

    func release(_ ticket: Ticket) {
        guard holder == ticket.id else {
            Log.launch.error("a restore tried to release the gate it does not hold; ignored")
            return
        }
        guard !waiters.isEmpty else {
            holder = nil
            return
        }
        let next = waiters.removeFirst()
        holder = next.ticket.id
        next.continuation.resume()
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
    private let clock: any RestoreClock
    private let launchTimeout: Duration
    private let windowTimeout: Duration
    private let prohibitsMultipleInstances: (String, String) -> Bool
    private var lastRunID = 0
    private var cancelledThroughRunID = 0
    private let gate = LaunchGate()
    /// The open this restore is waiting on, so a Cancel can end that wait rather than sit through
    /// it. Restores are serialised by the gate and each opens one app at a time, so there is at
    /// most one.
    private var inFlightOpen: FirstOutcome?

    init(
        launcher: any ApplicationLaunching,
        apps: any RunningApplicationQuerying,
        windows: any WindowCatalog,
        placer: any WindowPlacing,
        displays: any DisplayCatalog,
        clock: any RestoreClock,
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
        // Without this the Cancel is not acted on until the open it landed in comes back — up to
        // `launchTimeout` per slot, and the HUD's Cancel button is the one control that has to
        // answer immediately.
        inFlightOpen?.resume(.failure(LaunchCancelledError()))
    }

    /// Restores parked behind the running one. Exposed for tests, which need to know when a
    /// queued restore has actually reached the gate before aiming a cancel at it.
    var queuedRestores: Int { gate.waiterCount }

    func launch(
        _ workspace: ValidatedWorkspace,
        onProgress: @MainActor @escaping ([SlotProgress]) -> Void
    ) async -> [SlotProgress] {
        let document = workspace.document
        lastRunID += 1
        let runID = lastRunID
        let ticket = await gate.acquire()
        defer { gate.release(ticket) }

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

        let actions = LaunchPlanner.plan(
            document: document,
            runningBundleIDs: apps.runningBundleIDs(),
            prohibitsMultipleInstances: prohibitsMultipleInstances
        )
        Log.launch.info("launching \(document.name, privacy: .public) with \(slots.count) slot(s)")

        // The processes each bundle already had before this restore launched a new instance of
        // it. Their windows are the user's own — a restore with "move existing windows" off
        // exists to leave them alone — and the catalog cannot tell them apart from the new
        // instance's by anything but pid. Read once per bundle, before its first launch, so a
        // second new instance of the same bundle is not mistaken for a pre-existing one.
        var preExistingPIDs: [String: Set<pid_t>] = [:]

        for (index, action) in actions.enumerated() {
            if isCancelled(runID) {
                cancelPending(&progress)
                onProgress(progress)
                return progress
            }
            guard case .launch(let arguments, let newInstance) = action else { continue }

            progress[index].status = .launching
            onProgress(progress)

            let bundle = slots[index].bundleIdentifier
            if newInstance, preExistingPIDs[bundle] == nil {
                preExistingPIDs[bundle] = apps.runningPIDs(bundleIdentifier: bundle)
            }

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
        // Bundles already named in the log for a failed read or a fully-filtered pool, so a poll
        // loop does not repeat itself eighty times.
        var loggedUnreadable: Set<String> = []
        var loggedPreExistingOnly: Set<String> = []

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

            if case .reuse = actions[index] {
                apps.unhide(bundleIdentifier: slot.bundleIdentifier)
            }

            waiting.append(index)
        }

        // How many windows the workspace expects each app to produce. An app that has vended that
        // many has nothing further coming that this restore is entitled to wait for, so the slots
        // still unmatched at that point — titles that changed since the capture, the ordinary case
        // — get their leftovers straight away instead of after the timeout. Counted from the slots
        // still waiting, and compared against a pool that already excludes the windows of an
        // instance that was running before this restore launched a new one — so a reused app with
        // more windows than the workspace saved is "finished" on the first poll, which is correct:
        // they are all windows it has already vended.
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
        // Bounded twice over. The poll count makes the wait the same length whichever clock is
        // driving it, which is what lets a test pin it; the deadline is what holds in the real
        // thing, where each poll's snapshot is synchronous Accessibility I/O on the main thread
        // — up to `AXWindow.messagingTimeout` per read against a hung app — so eighty polls
        // against such an app would be forty seconds with the main actor blocked, not eight.
        var pollsLeft = Int((windowTimeout / Self.windowPollInterval).rounded(.up))
        let deadline = clock.now + windowTimeout
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
            let read = snapshot(of: pendingSlots, excluding: preExistingPIDs)
            let pool = read.pool
            for bundle in read.unreadable where loggedUnreadable.insert(bundle).inserted {
                Log.launch.error(
                    "the windows of \(bundle, privacy: .public) could not be read; polling on in case it answers later"
                )
            }
            for bundle in read.onlyPreExisting where loggedPreExistingOnly.insert(bundle).inserted {
                Log.launch.notice(
                    """
                    every window \(bundle, privacy: .public) has belongs to the instance that was \
                    already running, and this restore asked for a new one; its windows are left alone
                    """
                )
            }
            let outOfPolls = pollsLeft == 0 || clock.now >= deadline
            // Which slots may settle for a window they are not named after, decided per app rather
            // than for the restore as a whole. An app that has vended as many windows as the
            // workspace expects of it will not produce more, so its slots can settle now; deciding
            // it globally would hold those slots at "Launching" for the whole timeout whenever
            // some *other* app in the workspace never vends at all.
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
                    // so the correction pass below can revisit it if the real one turns up, and
                    // say so in the log — a swapped pair of windows is otherwise a restore that
                    // reports every slot placed and explains nothing.
                    if exact[position]?.id != window.id {
                        provisional[index] = window
                        Log.launch.notice(
                            """
                            slot \(index) (\(slots[index].name, privacy: .public)) wanted \
                            "\(slots[index].title, privacy: .public)" and settled for \
                            "\(window.title, privacy: .public)"
                            """
                        )
                    }
                    progress[index].status = .matched
                    onProgress(progress)
                } else if takingLeftovers.contains(position) {
                    // Its app is done vending — or the wait is over — and there was nothing left.
                    // *Why* there was nothing left is three different things to the user, decided
                    // on what this poll saw rather than on what any poll ever saw: the state the
                    // app is in now is the one they are looking at.
                    let bundle = slots[index].bundleIdentifier
                    let reason: SlotFailure
                    if read.unreadable.contains(bundle) {
                        reason = .windowsUnreadable
                    } else if read.onlyPreExisting.contains(bundle) {
                        reason = .noNewWindow
                    } else {
                        reason = .noWindow
                    }
                    fail(&progress, index: index, reason: reason, onProgress: onProgress)
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
                    // `stopped` matters as much here as in the branch below: without it a Cancel
                    // that lands between two *successful* placements still falls through to
                    // `activateFrontmost` and brings an app forward after the user stopped the
                    // restore. The real placer blocks for up to two seconds per window, so this is
                    // where a click most often lands.
                    stopped = true
                    break
                }
                guard let match = matches[index] else { continue }
                let slot = slots[index]

                guard let target = targetFrame(for: slot, in: document) else {
                    fail(&progress, index: index, reason: .noDisplay, onProgress: onProgress)
                    continue
                }
                let outcome = await placer.place(
                    match,
                    cocoaFrame: target.frame,
                    minimized: slot.minimized,
                    zoomed: slot.zoomed
                )
                if let failure = outcome.slotFailure {
                    // A placement torn down by a Cancel refuses like any other. The user stopping
                    // the restore is not a slot that could not be positioned — and nothing after
                    // this is the restore's to do either, not even bringing an app forward.
                    if isCancelled(runID) {
                        cancelPending(&progress)
                        onProgress(progress)
                        stopped = true
                        break
                    }
                    fail(&progress, index: index, reason: failure, onProgress: onProgress)
                    continue
                }

                progress[index].status = .placed(
                    Self.note(for: slot, on: target.display, isGuess: provisional[index] != nil)
                )
                onProgress(progress)
            }
        }

        if !stopped {
            activateFrontmost(slots: slots, matches: matches, progress: progress)
        }

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
                excluding: preExistingPIDs,
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
        excluding preExistingPIDs: [String: Set<pid_t>],
        progress: inout [SlotProgress],
        runID: Int,
        onProgress: @MainActor ([SlotProgress]) -> Void
    ) async {
        var pending = provisional
        var taken = claimed
        var pollsLeft = Int((Self.correctionWindow / Self.windowPollInterval).rounded(.up))
        let deadline = clock.now + Self.correctionWindow

        while pollsLeft > 0, clock.now < deadline, !pending.isEmpty {
            if isCancelled(runID) { return }
            await clock.sleep(Self.windowPollInterval)
            pollsLeft -= 1

            let pool = snapshot(of: pending.keys.map { slots[$0] }, excluding: preExistingPIDs).pool
            // Descending, so that when several corrections land in the same poll slot 0 is placed
            // last and therefore ends up on top, matching the placement pass.
            for index in pending.keys.sorted(by: >) {
                let slot = slots[index]
                guard let own = pool.first(where: {
                    $0.bundleIdentifier == slot.bundleIdentifier
                        && $0.title == slot.title
                        && !taken.contains($0.id)
                }) else { continue }

                // The window is spent either way: a refused placement is not retried against the
                // same window, whose id is stable for its lifetime. The *slot* stays open, so a
                // second window carrying the saved title — an app that reopened the document —
                // can still correct it inside the correction window.
                taken.insert(own.id)
                guard let target = targetFrame(for: slot, in: document) else {
                    Log.launch.error(
                        "slot \(index) (\(slot.name, privacy: .public)): no display attached, so the correction was dropped"
                    )
                    continue
                }
                let outcome = await placer.place(
                    own,
                    cocoaFrame: target.frame,
                    minimized: slot.minimized,
                    zoomed: slot.zoomed
                )
                guard outcome == .placed else {
                    Log.launch.error(
                        """
                        slot \(index) (\(slot.name, privacy: .public)): "\(slot.title, privacy: .public)" \
                        vended after the slot had settled, but placing it ended as \
                        \(String(describing: outcome), privacy: .public); the guess stands for now
                        """
                    )
                    continue
                }
                pending[index] = nil

                Log.launch.info(
                    """
                    slot \(index) (\(slot.name, privacy: .public)): replaced a guessed window with \
                    "\(slot.title, privacy: .public)", which vended after the slot had settled
                    """
                )
                progress[index].status = .placed(Self.note(for: slot, on: target.display, isGuess: false))
                onProgress(progress)
            }
        }
    }

    /// Where a slot's window belongs on the screens attached right now, and which screen that is.
    /// Nil when no display is attached at all, which is the one case that cannot be a placement.
    private func targetFrame(
        for slot: SavedWindow,
        in document: WorkspaceDocument
    ) -> (frame: CGRect, display: LiveDisplay)? {
        let live = displays.displays()
        guard let primary = live.first else { return nil }
        let resolved = DisplayMap.resolve(
            displayId: slot.displayId,
            saved: document.displays,
            live: live,
            primary: primary
        )
        let savedVisible = document.displays.first(where: { $0.id == slot.displayId })?.visibleFrame.cgRect
            ?? resolved.visibleFrame
        let relative = CGRect(x: slot.x, y: slot.y, width: slot.width, height: slot.height)
        let restored = FramePlacement.restore(
            relative: relative,
            savedVisible: savedVisible,
            liveVisible: resolved.visibleFrame
        )
        return (FramePlacement.clamp(restored, to: resolved.visibleFrame), resolved)
    }

    /// What the HUD has to add to "Placed": a screen other than the one the window was captured
    /// on, and a window the slot is not named after.
    private static func note(for slot: SavedWindow, on display: LiveDisplay, isGuess: Bool) -> PlacementNote {
        guard display.id != slot.displayId else {
            return PlacementNote(isGuess: isGuess, substituteDisplay: nil)
        }
        // A screen can report an empty localized name; "Placed on " helps nobody.
        let name = display.name.isEmpty ? "another display" : display.name
        return PlacementNote(isGuess: isGuess, substituteDisplay: name)
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

    /// Opens the app, or throws `LaunchTimeoutError` once `launchTimeout` has passed — and returns
    /// at that moment, whatever the launch is still doing. The launch runs as its own task and is
    /// never awaited past the deadline: `NSWorkspace.openApplication` does not observe cancellation
    /// (its completion handler arrives when LaunchServices is done, however long that takes), so a
    /// structured group racing the two bounded the *error* and not the wait — it had to await the
    /// launch before it could rethrow the timeout, and a bundle that took 90s to open held the
    /// whole restore, and the HUD's Cancel button, for those 90s. The attempt is still cancelled,
    /// for a launcher that honours it; otherwise it finishes on its own, unobserved.
    private func open(at url: URL, configuration: LaunchConfiguration) async throws {
        let timeout = launchTimeout
        let launcher = launcher
        let outcome = FirstOutcome()
        inFlightOpen = outcome
        defer { inFlightOpen = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            outcome.continuation = continuation
            let attempt = Task { @MainActor in
                do {
                    try await launcher.openApplication(at: url, configuration: configuration)
                    outcome.resume(.success(()))
                } catch {
                    outcome.resume(.failure(error))
                }
            }
            let timer = Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                outcome.resume(.failure(LaunchTimeoutError()))
            }
            // Whichever finishes first tears the other down, so a launch that returns promptly does
            // not leave a timer sleeping for the rest of the timeout — one per slot, on real time.
            outcome.onSettled = {
                attempt.cancel()
                timer.cancel()
            }
        }
    }

    /// Every window the still-waiting slots could be given, read once per app rather than once per
    /// slot: two slots of the same app reading separately would see two different snapshots, and a
    /// window that vends between the reads is exactly the one an earlier slot can steal from the
    /// later slot it belongs to. Windows of the processes in `preExistingPIDs` are left out: they
    /// belong to an instance the user already had running when this restore launched a new one.
    /// One poll's worth of catalog, and what it could not offer: the apps whose list would not be
    /// read at all, and the apps whose every window belongs to an instance that was already
    /// running. Both end as a different failure from "this app opened no window".
    private struct PoolRead {
        var pool: [MatchableWindow] = []
        var unreadable: Set<String> = []
        var onlyPreExisting: Set<String> = []
    }

    private func snapshot(
        of pendingSlots: [SavedWindow],
        excluding preExistingPIDs: [String: Set<pid_t>]
    ) -> PoolRead {
        var seen: Set<String> = []
        var read = PoolRead()
        for slot in pendingSlots {
            let bundle = slot.bundleIdentifier
            guard seen.insert(bundle).inserted else { continue }
            let excluded = preExistingPIDs[bundle] ?? []
            do {
                let vended = try windows.standardWindows(bundleIdentifier: bundle)
                let usable = vended.filter { !excluded.contains($0.pid) }
                if usable.isEmpty, !vended.isEmpty {
                    read.onlyPreExisting.insert(bundle)
                }
                read.pool.append(contentsOf: usable)
            } catch {
                read.unreadable.insert(bundle)
            }
        }
        return read
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

    private func activateFrontmost(
        slots: [SavedWindow],
        matches: [Int: MatchableWindow],
        progress: [SlotProgress]
    ) {
        guard !slots.isEmpty else { return }
        let index: Int
        if progress[0].status.isPlaced {
            index = 0
        } else if let placed = progress.first(where: { $0.status.isPlaced }) {
            index = placed.index
        } else {
            return
        }
        apps.activate(bundleIdentifier: slots[index].bundleIdentifier, pid: matches[index]?.pid)
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

    /// A cancelled task counts too. Nothing cancels the task a restore runs in today, but if one
    /// ever were, `Task.sleep` would throw at once and every timed wait would collapse into a
    /// zero-delay loop that burns the poll budget instantly and reports `.noWindow` for slots
    /// that merely had not vended yet — a failure the user never asked for.
    private func isCancelled(_ runID: Int) -> Bool {
        cancelledThroughRunID >= runID || Task.isCancelled
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
private struct LaunchCancelledError: Error {}

/// Hands one continuation whichever of the racing tasks finishes first, and drops every later
/// result: a continuation resumed twice is a crash, and a launch that comes back after its timeout
/// has already been reported is exactly that second resume.
@MainActor
private final class FirstOutcome {
    var continuation: CheckedContinuation<Void, any Error>?
    /// Runs once, when the race is decided: where the losers are torn down.
    var onSettled: (@MainActor () -> Void)?

    func resume(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let settled = onSettled
        onSettled = nil
        settled?()
        continuation.resume(with: result)
    }
}

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

    func runningPIDs(bundleIdentifier: String) -> Set<pid_t> {
        Set(runningApps(bundleIdentifier: bundleIdentifier).map(\.processIdentifier))
    }

    func unhide(bundleIdentifier: String) {
        for app in runningApps(bundleIdentifier: bundleIdentifier) where !app.unhide() {
            // A ⌘H'd app that stays hidden has its windows placed where the user cannot see them,
            // which reads as a restore that did nothing.
            Log.launch.error("\(bundleIdentifier, privacy: .public) refused to unhide")
        }
    }

    func activate(bundleIdentifier: String, pid: pid_t?) {
        let candidates = runningApps(bundleIdentifier: bundleIdentifier)
        guard let app = candidates.first(where: { $0.processIdentifier == pid }) ?? candidates.first else {
            Log.launch.error("\(bundleIdentifier, privacy: .public) is not running; nothing to bring forward")
            return
        }
        if !app.activate() {
            Log.launch.error("\(bundleIdentifier, privacy: .public) refused to come forward")
        }
    }
}

@MainActor
struct AXWindowCatalog: WindowCatalog {
    /// Throws only when every process of the bundle refused the read: one instance answering is
    /// a pool the claim loop can work with, and the refusal of another is logged rather than
    /// allowed to hide those windows.
    func standardWindows(bundleIdentifier: String) throws -> [MatchableWindow] {
        let apps = runningApps(bundleIdentifier: bundleIdentifier)
        var pool: [MatchableWindow] = []
        var answered = 0
        var lastError: AXWindowListError?
        for app in apps {
            let windows: [AXWindow]
            do {
                windows = try AXWindow.windows(pid: app.processIdentifier)
                answered += 1
            } catch {
                Log.launch.error(
                    "could not list the windows of \(bundleIdentifier, privacy: .public) (pid \(app.processIdentifier)): AXError \(error.code.rawValue)"
                )
                lastError = error
                continue
            }
            for window in windows {
                guard let identity = window.identity, isStandard(window) else { continue }
                pool.append(
                    MatchableWindow(
                        id: identity.key,
                        pid: identity.pid,
                        bundleIdentifier: bundleIdentifier,
                        title: window.title ?? ""
                    )
                )
            }
        }
        if let lastError, answered == 0 {
            throw lastError
        }
        return pool
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
    /// precondition for anything after it — so it gets its own, much shorter bound. It is only
    /// ever spent on a press that was *accepted* and still did not reach the visible frame — a
    /// window whose maximum size is smaller than the screen, or an app with a standard frame of
    /// its own — because a window with no zoom button fails fast on `.attributeUnsupported`
    /// instead. Reusing the two-second bound would cost that twice per such window.
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
        clock: any RestoreClock
    ) async -> PlacementOutcome {
        // A slot saved minimized on a window that is still minimized needs nothing: the frame write
        // would be swallowed by the Dock anyway, and deminiaturizing just to re-minimize is a flash
        // the user sees for no gain. Only a *confirmed* minimized short-circuits — an unreadable
        // state is not evidence of anything, and falls through to the honest sequence below.
        if minimized, ax.minimizedState == true { return .placed }

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
            guard succeeded(write, bundleIdentifier: id, step: "un-minimize") else { return .refused }
            guard await settled(clock: clock, timeout: deminiaturizeTimeout, until: { ax.minimizedState == false })
            else {
                Log.ax.error(
                    """
                    a window of \(id, privacy: .public) never came back out of the Dock; \
                    its frame was left alone rather than written to a minimized window
                    """
                )
                return .refused
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
                return .refused
            }
            if ax.minimizedState == nil {
                // Never answered either way. The frame write below is the only step left that can
                // report on this window, so it gets its turn — but the silence is worth a line:
                // it is what a placement that then fails for no visible reason looked like.
                Log.ax.notice(
                    """
                    a window of \(id, privacy: .public) never said whether it was minimized; \
                    writing its frame anyway
                    """
                )
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
            return .refused
        }

        // The frame is applied by this point, but a slot whose saved zoom or minimize state was
        // refused has not been restored, so it must not be reported as a clean placement.
        var restoredState = true
        if zoomed {
            restoredState = await ensureZoomed(ax, id: id, clock: clock) && restoredState
        }
        if minimized {
            restoredState = await ensureMinimized(ax, id: id, clock: clock) && restoredState
        }
        return restoredState ? .placed : .stateNotRestored
    }

    /// Puts the window back in the Dock and waits for it to actually get there. Accepting the
    /// write is not the state changing — the same asynchrony the un-minimize above waits out — and
    /// a window that cannot be miniaturized at all (a panel, a window without the button) answers
    /// `.success` and stays on screen, which used to be reported as a clean placement.
    private static func ensureMinimized(_ ax: some PlaceableWindow, id: String, clock: any RestoreClock) async -> Bool {
        guard succeeded(ax.setMinimized(true), bundleIdentifier: id, step: "minimize") else { return false }
        if await settled(clock: clock, timeout: deminiaturizeTimeout, until: { ax.minimizedState == true }) {
            return true
        }
        Log.ax.error(
            """
            a window of \(id, privacy: .public) was saved minimized but never went into the Dock; \
            it is on its saved frame but the slot is not fully restored
            """
        )
        return false
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
    private static func ensureZoomed(_ ax: some PlaceableWindow, id: String, clock: any RestoreClock) async -> Bool {
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
        clock: any RestoreClock,
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
    var clock: any RestoreClock = TaskClock()

    func place(_ window: MatchableWindow, cocoaFrame: CGRect, minimized: Bool, zoomed: Bool) async -> PlacementOutcome {
        let ax: AXWindow
        switch axWindow(matching: window) {
        case .found(let found):
            ax = found
        case .notListed:
            Log.launch.error(
                """
                window \(window.id, privacy: .public) of \(window.bundleIdentifier, privacy: .public) is no \
                longer listed: closed, or retitled since it was claimed
                """
            )
            return .windowGone
        case .unreadable:
            // Not the same thing: nobody could look, so whether the window is still there is
            // unknown. Reporting it as gone sends the user hunting for a window that is on screen.
            Log.launch.error(
                """
                the windows of \(window.bundleIdentifier, privacy: .public) could not be read when it \
                came to placing one; the slot is unresolved rather than known to be gone
                """
            )
            return .windowsUnreadable
        }
        return await WindowPlacement.apply(
            to: ax,
            cocoaFrame: cocoaFrame,
            minimized: minimized,
            zoomed: zoomed,
            bundleIdentifier: window.bundleIdentifier,
            clock: clock
        )
    }

    private enum Lookup {
        case found(AXWindow)
        /// Every process answered, and none of them has this window any more.
        case notListed
        /// No process answered, so the question was never put.
        case unreadable
    }

    private func axWindow(matching window: MatchableWindow) -> Lookup {
        var answered = 0
        let apps = runningApps(bundleIdentifier: window.bundleIdentifier)
        for app in apps {
            do {
                let windows = try AXWindow.windows(pid: app.processIdentifier)
                answered += 1
                for ax in windows where ax.identity?.key == window.id {
                    return .found(ax)
                }
            } catch {
                Log.launch.error(
                    "could not list the windows of \(window.bundleIdentifier, privacy: .public) (pid \(app.processIdentifier)) to place one: AXError \(error.code.rawValue)"
                )
            }
        }
        return answered == 0 && !apps.isEmpty ? .unreadable : .notListed
    }
}

@MainActor
struct TaskClock: RestoreClock {
    var now: ContinuousClock.Instant { .now }

    func sleep(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

@MainActor
private func runningApps(bundleIdentifier: String) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
}

/// The same eligibility test capture applies, on the restore side: a window capture would have
/// refused — an Open/Save panel above all — must not be handed to a slot as a leftover and resized
/// to a saved frame. The app-level facts are literals because the catalog is only ever asked about
/// a regular app that is not SnapDesk.
@MainActor
private func isStandard(_ window: AXWindow) -> Bool {
    guard let frame = window.cocoaFrame else { return false }
    return CaptureFilter.isEligible(
        CaptureCandidate(
            subrole: window.subrole,
            frame: frame,
            isSnapDesk: false,
            activationPolicyIsRegular: true,
            hasTitleBarButtons: window.hasTitleBarButtons
        )
    )
}
