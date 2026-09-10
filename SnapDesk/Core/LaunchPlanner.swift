import Foundation

/// What restore does for one slot before it starts looking for windows. `reuse` is a slot whose
/// app is already running, or whose group launched on an earlier slot; `launch` opens the app,
/// as a fresh instance or not.
enum LaunchAction: Equatable {
    case launch(arguments: [String], newInstance: Bool)
    case reuse
}

enum LaunchPlanner {
    /// One action per slot, in slot order. Slots are grouped by bundle identifier, and the rule
    /// is decided per group from its first slot: under `moveExistingWindows` — or for an app whose
    /// Info.plist sets `LSMultipleInstancesProhibited`, which forces that mode — a running app is
    /// reused, and only the group's first slot launches at all (as the existing instance, so
    /// later slots reuse it); otherwise every slot launches a new instance of its own. The
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
