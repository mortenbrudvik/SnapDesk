import AppKit

@MainActor
protocol DelayRunning: AnyObject {
    func run(after duration: Duration, _ work: @escaping @MainActor () -> Void)
}

@MainActor
final class MainActorDelay: DelayRunning {
    func run(after duration: Duration, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: duration)
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
        rows = slots.map {
            LaunchHUD.Row(
                name: $0.name,
                status: Self.statusText(for: $0.status),
                isFailure: $0.status.failure != nil
            )
        }
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

        let anyFailed = slots.contains { $0.status.failure != nil }
        // A restore that lost a slot stays on screen. Auto-dismissing it after 600ms looks exactly
        // like a clean run, so the one case the HUD exists for is the one the user never sees. A
        // cancelled slot is not one of those: the user knows why it stopped and should not have to
        // dismiss the HUD a second time to be rid of it.
        if !userDismissed, finished, !anyFailed {
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

    private static func statusText(for status: SlotStatus) -> String {
        switch status {
        case .pending:
            return "Pending"
        case .launching:
            return "Launching"
        case .matched:
            return "Ready"
        case .placed:
            return "Placed"
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
