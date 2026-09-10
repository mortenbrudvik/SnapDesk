import Foundation

enum LaunchAction: Equatable {
    case launch(bundleIdentifier: String, path: String, arguments: [String], newInstance: Bool)
    case reuse
}

struct SlotPlan: Equatable {
    var index: Int
    var action: LaunchAction
}

enum LaunchPlanner {
    static func plan(
        document: WorkspaceDocument,
        runningBundleIDs: Set<String>,
        prohibitsMultipleInstances: (String, String) -> Bool = { _, _ in false }
    ) -> [SlotPlan] {
        let windows = document.windows
        var groupOrder: [String] = []
        var groupIndices: [String: [Int]] = [:]
        for (index, window) in windows.enumerated() {
            let key = groupKey(for: window)
            if groupIndices[key] == nil {
                groupOrder.append(key)
                groupIndices[key] = []
            }
            groupIndices[key]!.append(index)
        }

        var plans = Array(repeating: SlotPlan(index: 0, action: .reuse), count: windows.count)
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
                        plans[index] = SlotPlan(index: index, action: .reuse)
                    } else {
                        plans[index] = SlotPlan(
                            index: index,
                            action: .launch(
                                bundleIdentifier: window.bundleIdentifier,
                                path: window.bundlePath,
                                arguments: ArgumentTokenizer.tokenize(window.arguments),
                                newInstance: false
                            )
                        )
                    }
                } else {
                    plans[index] = SlotPlan(
                        index: index,
                        action: .launch(
                            bundleIdentifier: window.bundleIdentifier,
                            path: window.bundlePath,
                            arguments: ArgumentTokenizer.tokenize(window.arguments),
                            newInstance: true
                        )
                    )
                }
            }
        }
        return plans
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

    private static func groupKey(for window: SavedWindow) -> String {
        if window.bundleIdentifier.isEmpty {
            return "path:\(window.bundlePath)"
        }
        return "id:\(window.bundleIdentifier)"
    }
}
