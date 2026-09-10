import AppKit

@MainActor
protocol DelayRunning: AnyObject {
    func run(after duration: Duration, _ work: @escaping @MainActor () -> Void)
}

@MainActor
final class MainActorDelay: DelayRunning {
    /// The most recently scheduled delay, so a caller can cancel or await it. Exposed for tests;
    /// the HUD invalidates a pending auto-dismiss by generation instead.
    private(set) var pending: Task<Void, Never>?

    func run(after duration: Duration, _ work: @escaping @MainActor () -> Void) {
        pending = Task { @MainActor in
            do {
                try await Task.sleep(for: duration)
            } catch {
                // Cancelled. `try?` here ran the work anyway — and instantly, because a cancelled
                // sleep returns at once — which for the auto-dismiss meant hiding a HUD that by
                // then belonged to a different restore.
                return
            }
            work()
        }
    }
}

@MainActor
final class LaunchHUDController {
    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var isVisible = false
    private(set) var rows: [LaunchHUD.Row] = []

    var panel: NSPanel { hud.panel }
    var dismissButton: NSButton { hud.dismissButton }
    var cancelButton: NSButton { hud.cancelButton }

    private let hud: LaunchHUD
    private let delay: any DelayRunning
    private let beep: @MainActor () -> Void
    private var userDismissed = false
    private var dismissGeneration = 0
    private var previousSlots: [SlotProgress] = []
    private var isCancellable = true

    init(
        delay: any DelayRunning = MainActorDelay(),
        beep: @escaping @MainActor () -> Void = { NSSound.beep() }
    ) {
        self.delay = delay
        self.beep = beep
        let hud = LaunchHUD()
        self.hud = hud
        hud.onDismissClick = { [weak self] in self?.dismiss() }
        hud.onCancelClick = { [weak self] in
            guard let self, self.isCancellable else { return }
            self.onCancel?()
        }
    }

    func present(title: String) {
        userDismissed = false
        dismissGeneration += 1
        previousSlots = []
        rows = []
        hud.render(rows: rows)
        panel.title = title
        setCancellable(true)
        setVisible(true)
    }

    func update(_ slots: [SlotProgress]) {
        let hasNewFailure = slots.contains { slot in
            guard slot.status.failure != nil else { return false }
            return !previousSlots.contains(where: { $0.index == slot.index && $0.status.failure != nil })
        }
        previousSlots = slots
        rows = slots.map { LaunchHUD.Row(name: $0.name, status: $0.status) }
        hud.render(rows: rows)
        if !userDismissed {
            setVisible(true)
            // Once per update, not once per newly failed slot: a single snapshot can turn several
            // slots terminal at once — every slot of an app whose bundle is missing — and one beep
            // per slot stacks into a noise a user reads as a crash. A HUD the user has already
            // dismissed says nothing more at all.
            if hasNewFailure {
                beep()
            }
        }

        let finished = slots.allSatisfy(\.status.isTerminal)
        // Nothing is left to cancel once every slot is terminal, and the HUD outlives that moment.
        // A button that stays live there offers an action that can no longer do anything.
        setCancellable(!finished)

        // A restore that lost a slot stays on screen. Auto-dismissing it after 600ms looks exactly
        // like a clean run, so the one case the HUD exists for is the one the user never sees.
        //
        // A slot that took a window it is not named after, or landed on a display the workspace
        // was not captured on, counts here too: it is not a *failure*, so it does not beep, but it
        // is the whole explanation for a layout that came back looking wrong — and the correction
        // pass runs for four seconds after this, which a dismissed HUD would never show. A
        // cancelled slot is neither: the user knows why it stopped and should not have to dismiss
        // the HUD a second time to be rid of it.
        let needsAttention = slots.contains { slot in
            if slot.status.failure != nil { return true }
            if case .placed(let note) = slot.status { return note != .clean }
            return false
        }
        if !userDismissed, finished, !needsAttention {
            scheduleAutoDismiss()
        } else {
            dismissGeneration += 1
        }
    }

    func dismiss() {
        dismissGeneration += 1
        userDismissed = true
        setVisible(false)
        onDismiss?()
    }

    private func setCancellable(_ cancellable: Bool) {
        isCancellable = cancellable
        cancelButton.isEnabled = cancellable
    }

    private func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            hud.show()
        } else {
            hud.hide()
        }
    }

    private func scheduleAutoDismiss() {
        dismissGeneration += 1
        let generation = dismissGeneration
        delay.run(after: .milliseconds(600)) { [weak self] in
            guard let self, self.dismissGeneration == generation else { return }
            self.dismiss()
        }
    }

    nonisolated static func statusText(for status: SlotStatus) -> String {
        switch status {
        case .pending:
            return "Pending"
        case .launching:
            return "Launching"
        case .matched:
            return "Ready"
        case .placed(let note):
            var text = "Placed"
            if let display = note.substituteDisplay {
                text += " on \(display)"
            }
            if note.isGuess {
                text += " (other window)"
            }
            return text
        case .cancelled:
            return "Cancelled"
        case .failed(let reason):
            return "Failed: \(reason.displayText)"
        }
    }
}

extension SlotStatus {
    fileprivate var isTerminal: Bool {
        switch self {
        case .placed, .cancelled, .failed:
            return true
        case .pending, .launching, .matched:
            return false
        }
    }
}
