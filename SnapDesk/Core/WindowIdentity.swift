import ApplicationServices

/// How one live window is told apart from another during a single Restore pass. `key` flattens it
/// into a `"cg:<pid>:<id>"` / `"fb:<pid>:<title>"` string that `LaunchService` uses as the key of
/// the set of windows already claimed by an earlier slot, so two slots of the same app cannot
/// both place the same window. Nothing is persisted: a `.snapdesk` document stores frames, and
/// these ids live only for the length of the pass that built them.
enum WindowIdentity: Hashable, Sendable {
    /// Stable for the window's lifetime, and unique across apps. macOS reuses ids after a window
    /// closes, which is harmless here only because a pass never outlives the windows it looked at.
    case cgWindow(CGWindowID, pid: pid_t)
    /// Weaker fallback for when the window id is unavailable. A title that changes between the
    /// wait for a new window and the placement of it — a browser finishing a page load, an editor
    /// adding an "edited" marker — yields two different ids for the same window, so the window
    /// looks unclaimed and a later slot can place a second app window on top of it.
    case fallback(pid: pid_t, title: String)
}

extension WindowIdentity {
    /// The flat form the claim bookkeeping is keyed on. The prefix is what keeps the two
    /// strategies from colliding: a title can look like a number, and a window id is one.
    var key: String {
        switch self {
        case .cgWindow(let id, let pid):
            return "cg:\(pid):\(id)"
        case .fallback(let pid, let title):
            return "fb:\(pid):\(title)"
        }
    }

    var pid: pid_t {
        switch self {
        case .cgWindow(_, let pid), .fallback(let pid, _):
            return pid
        }
    }
}
