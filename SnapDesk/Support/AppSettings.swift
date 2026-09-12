import Foundation
import ServiceManagement

/// The slice of `SMAppService` that `AppSettings` uses, so the toggle logic can be tested
/// against a fake. `SMAppService` conforms as-is.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Which workspace each of the five assignable hotkeys opens.
///
/// The slots are fixed and the *binding* lives here; the key combination itself lives in
/// KeyboardShortcuts under the matching `KeyboardShortcuts.Name`. Two stores rather than one
/// because they answer to different owners: the user rebinds keys in Settings, while a workspace
/// assignment has to follow a file that gets moved or renamed, which is what the bookmark is for.
@MainActor
final class WorkspaceShortcuts {
    /// Matches `KeyboardShortcuts.Name.workspaceSlots`. Both are pinned together by
    /// `HotkeyNameTests`, because a slot with no name could never fire and a name with no slot
    /// could never be assigned.
    static let slotCount = 5

    private enum Key {
        static let bookmarks = "workspaceShortcutBookmarks"
        static let paths = "workspaceShortcutPaths"
    }

    private let defaults: UserDefaults
    /// Exactly `slotCount` entries, empty ones included, so a slot index is an array index.
    private var slots: [WorkspaceBookmark]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        slots = Self.load(from: defaults)
    }

    /// The workspace bound to a slot, or nil when it is empty or the index is out of range.
    /// Resolved on every call so a file renamed since launch is still found.
    func workspace(for slot: Int) -> URL? {
        guard slots.indices.contains(slot) else { return nil }
        let entry = slots[slot]
        guard !entry.isEmpty else { return nil }
        var needsRewrite = false
        let resolved = entry.resolve(needsRewrite: &needsRewrite)
        if needsRewrite, let resolved {
            // A stale bookmark resolved but will stop working; rewriting it here is what keeps
            // the slot pointing at the file after the next move.
            slots[slot] = WorkspaceBookmark.make(for: resolved)
            persist()
        }
        return resolved
    }

    /// Binds a workspace to a slot, or clears it with nil. An index outside the fixed range is
    /// ignored rather than trapping: it can arrive from a preference an older or newer build
    /// wrote.
    func assign(_ url: URL?, to slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot] = url.map(WorkspaceBookmark.make(for:)) ?? .none
        persist()
    }

    private func persist() {
        defaults.set(slots.map(\.bookmark), forKey: Key.bookmarks)
        defaults.set(slots.map(\.path), forKey: Key.paths)
    }

    /// Always returns `slotCount` entries, whatever is in defaults: a short array from an older
    /// build, or a long one from a newer, must not change what a slot index means.
    private static func load(from defaults: UserDefaults) -> [WorkspaceBookmark] {
        let bookmarks = defaults.array(forKey: Key.bookmarks) as? [Data] ?? []
        let paths = defaults.array(forKey: Key.paths) as? [String] ?? []
        return (0..<slotCount).map { i in
            WorkspaceBookmark(
                path: i < paths.count ? paths[i] : "",
                bookmark: i < bookmarks.count ? bookmarks[i] : Data()
            )
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var launchAtLogin: Bool {
        didSet { applyLoginItem() }
    }

    /// Why the login item is not simply on or off (approval pending, last change failed).
    /// Nil when there is nothing to explain.
    @Published private(set) var loginItemMessage: String?

    var loginItemStatus: SMAppService.Status {
        loginItems.status
    }

    private let loginItems: any LoginItemService
    private var isApplyingLoginItem = false

    /// Nothing here is written to `UserDefaults`: `SMAppService` owns the login-item state, and
    /// a local copy could only ever disagree with it — the user can remove the item in System
    /// Settings without SnapDesk running.
    init(loginItems: any LoginItemService = SMAppService.mainApp) {
        self.loginItems = loginItems
        launchAtLogin = loginItems.status == .enabled
        loginItemMessage = Self.message(for: loginItems.status)
    }

    /// Re-reads the service. `SMAppService` is the source of truth and the user can change it in
    /// System Settings at any time — approve the item, or remove it — while both values here were
    /// computed once in `init`, so the pane kept asking for an approval already given. Called
    /// whenever the Settings window comes to the front. Reads only: the `didSet` on
    /// `launchAtLogin` would otherwise turn mirroring a removal into an `unregister()`.
    func refresh() {
        isApplyingLoginItem = true
        defer { isApplyingLoginItem = false }
        launchAtLogin = loginItems.status == .enabled
        loginItemMessage = Self.message(for: loginItems.status)
    }

    private func applyLoginItem() {
        // Swift fires `didSet` for every assignment that goes through the setter, including the
        // rollback below (it is in a method, not lexically inside the observer). Without this
        // guard a failing register() followed by a failing unregister() recurses until the
        // stack overflows.
        guard !isApplyingLoginItem else { return }
        isApplyingLoginItem = true
        defer { isApplyingLoginItem = false }

        do {
            if launchAtLogin {
                try loginItems.register()
            } else {
                try loginItems.unregister()
            }
            loginItemMessage = Self.message(for: loginItems.status)
        } catch {
            let action = launchAtLogin ? "register" : "unregister"
            Log.settings.error("Login item \(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            loginItemMessage = "Could not change Launch at login: \(error.localizedDescription)"
            launchAtLogin = loginItems.status == .enabled
        }
    }

    private static func message(for status: SMAppService.Status) -> String? {
        switch status {
        case .requiresApproval:
            // register() succeeded, but macOS wants the user to approve the item before it
            // will launch anything. Without this the toggle looks on while nothing happens.
            return "Approve SnapDesk under System Settings › General › Login Items."
        default:
            return nil
        }
    }
}
