import AppKit

@MainActor
final class LaunchHUD: NSObject {
    /// One line of the HUD. `isFailure` is carried alongside the text rather than re-derived from
    /// it: what a row *means* is settled by `SlotStatus`, and reading it back out of the rendered
    /// wording ties the colour to a string that exists to be reworded — the same mistake that once
    /// left four of the five failures silent because the beep matched one specific message.
    struct Row {
        var name: String
        var status: String
        var isFailure: Bool
    }

    let panel: NSPanel
    let dismissButton: NSButton
    let cancelButton: NSButton

    var onDismissClick: () -> Void = {}
    var onCancelClick: () -> Void = {}

    private let rowsStack = NSStackView()
    private let contentStack = NSStackView()

    override init() {
        dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        dismissButton.bezelStyle = .rounded
        cancelButton.bezelStyle = .rounded

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 140),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init()

        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        buildContent()
    }

    func render(rows: [Row]) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            rowsStack.addArrangedSubview(makeRow(row))
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = contentStack.fittingSize
        panel.setContentSize(NSSize(width: max(360, fitting.width), height: max(fitting.height, 88)))
    }

    func show() {
        if !panel.isVisible {
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    @objc private func handleDismiss() {
        onDismissClick()
    }

    @objc private func handleCancel() {
        onCancelClick()
    }

    private func buildContent() {
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 6

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addView(dismissButton, in: .trailing)
        buttonRow.addView(cancelButton, in: .trailing)

        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(rowsStack)
        contentStack.addArrangedSubview(buttonRow)

        guard let contentView = panel.contentView else { return }
        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            contentStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
    }

    private func makeRow(_ row: Row) -> NSView {
        let nameField = NSTextField(labelWithString: row.name)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusField = NSTextField(labelWithString: row.status)
        statusField.alignment = .right
        statusField.textColor = row.isFailure ? .systemRed : .secondaryLabelColor
        statusField.setContentHuggingPriority(.required, for: .horizontal)

        let line = NSStackView()
        line.orientation = .horizontal
        line.spacing = 12
        line.addView(nameField, in: .leading)
        line.addView(statusField, in: .trailing)
        return line
    }
}
