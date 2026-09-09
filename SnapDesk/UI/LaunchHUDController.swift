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
    private(set) var rows: [(name: String, status: String)] = []

    var panel: NSPanel { hud.panel }
    var dismissButton: NSButton { hud.dismissButton }
    var cancelButton: NSButton { hud.cancelButton }

    private let hud: LaunchHUD
    private let delay: any DelayRunning
    private var userDismissed = false
    private var dismissGeneration = 0
    private var previousSlots: [SlotProgress] = []

    init(delay: any DelayRunning = MainActorDelay()) {
        self.delay = delay
        let hud = LaunchHUD()
        self.hud = hud
        hud.onDismissClick = { [weak self] in self?.dismiss() }
        hud.onCancelClick = { [weak self] in
            self?.onCancel?()
        }
    }

    func present(title: String) {
        userDismissed = false
        dismissGeneration += 1
        previousSlots = []
        rows = []
        hud.render(rows: rows)
        panel.title = title
        setVisible(true)
    }

    func update(_ slots: [SlotProgress]) {
        beepIfNeeded(slots)
        previousSlots = slots
        rows = slots.map { ($0.name, Self.statusText(for: $0.status)) }
        hud.render(rows: rows)
        if !userDismissed {
            setVisible(true)
        }
        if !userDismissed, slots.allSatisfy(\.status.isTerminal) {
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

    private func beepIfNeeded(_ slots: [SlotProgress]) {
        for slot in slots {
            guard slot.status == .failed("Could not position") else { continue }
            let alreadyFailed = previousSlots.contains {
                $0.index == slot.index && $0.status == .failed("Could not position")
            }
            if !alreadyFailed {
                NSSound.beep()
            }
        }
    }

    private static func statusText(for status: SlotStatus) -> String {
        switch status {
        case .pending:
            return "Pending"
        case .launching:
            return "Launching"
        case .placed:
            return "Placed"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }
}

extension SlotStatus {
    fileprivate var isTerminal: Bool {
        switch self {
        case .placed, .failed:
            return true
        case .pending, .launching:
            return false
        }
    }
}
