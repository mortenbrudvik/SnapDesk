import AppKit

@MainActor
final class LaunchHUD: NSObject {
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

    func render(rows: [(name: String, status: String)]) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            rowsStack.addArrangedSubview(makeRow(name: row.name, status: row.status))
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

    private func makeRow(name: String, status: String) -> NSView {
        let nameField = NSTextField(labelWithString: name)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusField = NSTextField(labelWithString: status)
        statusField.alignment = .right
        statusField.textColor = status.hasPrefix("Failed") ? .systemRed : .secondaryLabelColor
        statusField.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.addView(nameField, in: .leading)
        row.addView(statusField, in: .trailing)
        return row
    }
}
