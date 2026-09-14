import Foundation

/// What restore does for one slot before it starts looking for windows. `reuse` is a slot whose
/// app is already running, or whose group launched on an earlier slot; `launch` opens the app,
/// as a fresh instance or not.
enum LaunchAction: Equatable {
    case launch(arguments: [String], newInstance: Bool)
    /// A slot that names a document. The document is opened *in* the app, which launches it when
    /// it is not running and otherwise hands it to the running one — the one call that works both
    /// ways, where arguments reach a new instance only. Whether the document then gets a window
    /// of its own is the app's choice; see `DocumentOpening`.
    ///
    /// Every such slot opens, including the second and third of a group and including under
    /// `moveExistingWindows`, because each open is what asks for that slot's window. Only the
    /// group's first slot asks for a new instance, so three documents land in one app rather than
    /// three copies of it — except with `moveExistingWindows` off and the app already running,
    /// where the pre-existing instance's windows are off limits and an open that names no
    /// instance could land in it: there every document slot gets an instance of its own, exactly
    /// as every plain slot does in that mode.
    case openDocument(url: URL, arguments: [String], newInstance: Bool)
    case reuse

    /// What one slot's open needs, flattened: the document when the slot names one, the slot's
    /// own arguments, and whether it asks for a new instance. Nil for `.reuse`, which opens
    /// nothing. The two open paths are identical apart from which call they make in the middle,
    /// and this is the shape `LaunchService` works from.
    struct OpenRequest: Equatable {
        var document: URL?
        var arguments: [String]
        var newInstance: Bool
    }

    var openRequest: OpenRequest? {
        switch self {
        case .reuse:
            return nil
        case let .launch(arguments, newInstance):
            return OpenRequest(document: nil, arguments: arguments, newInstance: newInstance)
        case let .openDocument(url, arguments, newInstance):
            return OpenRequest(document: url, arguments: arguments, newInstance: newInstance)
        }
    }
}

enum LaunchPlanner {
    /// One action per slot, in slot order. Slots are grouped by bundle identifier, and the rule
    /// is decided per group from its first slot: under `moveExistingWindows` — or for an app whose
    /// Info.plist sets `LSMultipleInstancesProhibited`, which forces that mode — a running app is
    /// reused, and only the group's first plain slot launches at all (as the existing instance, so
    /// later slots reuse it); otherwise every plain slot launches a new instance of its own. A
    /// slot with a document opens it whichever mode applies; see `LaunchAction.openDocument`. The
    /// arguments are the slot's own, tokenised.
    static func plan(
        document: WorkspaceDocument,
        runningBundleIDs: Set<String>,
        prohibitsMultipleInstances: (String, String) -> Bool = { _, _ in false }
    ) -> [LaunchAction] {
        let windows = document.windows
        var groupOrder: [String] = []
        var groupIndices: [String: [Int]] = [:]
        for (index, window) in windows.enumerated() {
            let key = window.bundleIdentifier
            if groupIndices[key] == nil {
                groupOrder.append(key)
                groupIndices[key] = []
            }
            groupIndices[key]!.append(index)
        }

        var actions = Array(repeating: LaunchAction.reuse, count: windows.count)
        for key in groupOrder {
            let indices = groupIndices[key]!
            let first = windows[indices[0]]
            let moveExisting = document.moveExistingWindows
                || prohibitsMultipleInstances(first.bundleIdentifier, first.bundlePath)
            let isRunning = runningBundleIDs.contains(first.bundleIdentifier)
            for (offset, index) in indices.enumerated() {
                let window = windows[index]
                // A document slot is decided first and on its own terms: the open has to happen
                // for every such slot, which is the opposite of the group rule below, where only
                // the first slot launches.
                if let document = window.document {
                    if let url = WorkspaceDocumentReference.url(for: document) {
                        actions[index] = .openDocument(
                            url: url,
                            arguments: ArgumentTokenizer.tokenize(window.arguments),
                            newInstance: !moveExisting && (offset == 0 || isRunning)
                        )
                        continue
                    }
                    // Unreachable through `ValidatedWorkspace`, whose validation refuses such a
                    // document. A plain launch is the safe fallback, but a quiet one would hide
                    // whatever let the value through.
                    Log.launch.error(
                        "slot \(index) has a document that cannot be opened; launching without it"
                    )
                }
                if moveExisting {
                    if isRunning || offset > 0 {
                        actions[index] = .reuse
                    } else {
                        actions[index] = .launch(
                            arguments: ArgumentTokenizer.tokenize(window.arguments),
                            newInstance: false
                        )
                    }
                } else {
                    actions[index] = .launch(
                        arguments: ArgumentTokenizer.tokenize(window.arguments),
                        newInstance: true
                    )
                }
            }
        }
        return actions
    }

    /// Descending on purpose. Placing a window raises it, so walking the slots back-to-front
    /// leaves slot 0 on top — the stacking order the workspace was captured in. Replacing this
    /// with `Array(0..<windowCount)` would invert every restored stack while every placement
    /// assertion still passed, because the set of placed windows would not change.
    ///
    /// This orders *placement* only. Which window each slot gets is settled before any of this
    /// runs, by title first and then in slot order; see the claim loop in `LaunchService`.
    static func placeOrder(windowCount: Int) -> [Int] {
        guard windowCount > 0 else { return [] }
        return Array((0..<windowCount).reversed())
    }
}
