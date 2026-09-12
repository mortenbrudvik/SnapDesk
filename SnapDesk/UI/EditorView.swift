import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var host: EditorHost
    var onCapture: () -> Void
    var onOpen: () -> Void
    var onSelectRecent: (URL) -> Void
    var onRemoveRecent: () -> Void
    var onReveal: () -> Void
    var onTrash: () -> Void
    var onLaunch: () -> Void
    var onSave: () -> Void
    var onSaveAs: () -> Void
    var onRemoveWindow: (Int) -> Void

    var body: some View {
        EditorSplitView(
            host: host,
            session: host.session,
            onCapture: onCapture,
            onOpen: onOpen,
            onSelectRecent: onSelectRecent,
            onRemoveRecent: onRemoveRecent,
            onReveal: onReveal,
            onTrash: onTrash,
            onLaunch: onLaunch,
            onSave: onSave,
            onSaveAs: onSaveAs,
            onRemoveWindow: onRemoveWindow
        )
    }
}

private struct EditorSplitView: View {
    @ObservedObject var host: EditorHost
    @ObservedObject var session: EditorSession
    var onCapture: () -> Void
    var onOpen: () -> Void
    var onSelectRecent: (URL) -> Void
    var onRemoveRecent: () -> Void
    var onReveal: () -> Void
    var onTrash: () -> Void
    var onLaunch: () -> Void
    var onSave: () -> Void
    var onSaveAs: () -> Void
    var onRemoveWindow: (Int) -> Void

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 420)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $host.selectedRecentID) {
                Section("Recents") {
                    if host.recents.isEmpty {
                        Text("No Recents")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(host.recents) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .lineLimit(1)
                                Text(item.filename)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .tag(item.id)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: host.selectedRecentID) { _, newID in
                guard let newID, let item = host.recents.first(where: { $0.id == newID }) else { return }
                onSelectRecent(item.url)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button("Capture", action: onCapture)
                Button("Open…", action: onOpen)
                Button("Remove from Recents", action: onRemoveRecent)
                    .disabled(host.selectedRecentID == nil && session.fileURL == nil)
                Button("Reveal in Finder", action: onReveal)
                    .disabled(host.selectedRecentID == nil && session.fileURL == nil)
                Button("Move to Trash", action: onTrash)
                    .disabled(host.selectedRecentID == nil && session.fileURL == nil)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                TextField("Name", text: $session.document.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Toggle("Move existing windows", isOn: $session.document.moveExistingWindows)
                Spacer()
            }

            HSplitView {
                windowList
                    .frame(minWidth: 320)
                WorkspacePreview(
                    displays: session.document.displays,
                    windows: session.document.windows,
                    selectedIndex: host.selectedWindowIndex,
                    onSelect: { host.selectedWindowIndex = $0 }
                )
                .frame(minWidth: 220, minHeight: 180)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("Launch", action: onLaunch)
                Spacer()
                Button("Save", action: onSave)
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As", action: onSaveAs)
            }
        }
        .padding(16)
    }

    private var windowList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.document.windows.isEmpty {
                        Text("No windows")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(zip(session.rowIDs, session.document.windows.indices)), id: \.0) { rowID, index in
                        // Removing a row shrinks the array the by-index binding reads, so re-check
                        // the index before subscripting it.
                        if session.document.windows.indices.contains(index) {
                            WindowSlotRow(
                                window: $session.document.windows[index],
                                displays: session.document.displays,
                                isSelected: host.selectedWindowIndex == index,
                                onSelect: { host.selectedWindowIndex = index },
                                onRemove: { onRemoveWindow(index) }
                            )
                            .id(rowID)
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            .onChange(of: host.selectedWindowIndex) { _, new in
                if let new, session.rowIDs.indices.contains(new) {
                    proxy.scrollTo(session.rowIDs[new], anchor: .center)
                }
            }
        }
    }
}

private struct WindowSlotRow: View {
    @Binding var window: SavedWindow
    var displays: [SavedDisplay]
    var isSelected: Bool
    var onSelect: () -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: window.bundlePath))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $window.name)
                        .textFieldStyle(.plain)
                        .font(.headline)
                    Text(window.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Remove", role: .destructive, action: onRemove)
            }

            TextField("Title", text: $window.title)
                .textFieldStyle(.roundedBorder)

            Picker("Display", selection: $window.displayId) {
                ForEach(displays) { display in
                    Text(display.name).tag(display.id)
                }
                if !displays.contains(where: { $0.id == window.displayId }) {
                    Text(window.displayId.isEmpty ? "Unknown" : window.displayId)
                        .tag(window.displayId)
                }
            }

            HStack {
                labeledNumber("X", value: $window.x)
                labeledNumber("Y", value: $window.y)
                labeledNumber("W", value: WindowSizeField.binding($window.width))
                labeledNumber("H", value: WindowSizeField.binding($window.height))
            }

            HStack {
                Toggle("Minimized", isOn: $window.minimized)
                Toggle("Zoomed", isOn: $window.zoomed)
                Toggle("Fullscreen", isOn: WindowFullscreenField.binding($window.fullscreen))
            }

            TextField("Arguments", text: $window.arguments)
                .textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }

    private func labeledNumber(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 56)
        }
    }
}

/// The Fullscreen toggle of a window row. The stored field is `Bool?` and the toggle is `Bool`,
/// and the missing third state is the point: nil means the workspace was written before fullscreen
/// was recorded, which restore reads as "leave this window alone" rather than as false. A
/// two-state toggle has nowhere to show that, so it displays nil as off — and a write always
/// records an explicit value, because a user reaching for the toggle is an intent where an
/// untouched old file is not.
enum WindowFullscreenField {
    static func binding(_ source: Binding<Bool?>) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue ?? false },
            set: { source.wrappedValue = $0 }
        )
    }
}

/// The W and H fields of a window row. `WorkspaceDocument.validate` refuses a side that is not
/// positive on both the load and the save path, and the launch path hands the value straight to
/// `AXWindow.setSize`, so the field has to keep one out of the document in the first place rather
/// than let the user reach an unsaveable state and be told about it at Save.
enum WindowSizeField {
    /// One point. Clamping to the smallest legal side rather than rejecting the edit leaves a
    /// half-typed "-" or "0" usable: the next keystroke replaces it.
    static let minimum: Double = 1

    static func clamped(_ value: Double) -> Double {
        // `max` returns NaN unchanged, and NaN also fails `validate`'s `> 0` test.
        guard value.isFinite else { return minimum }
        return max(value, minimum)
    }

    static func binding(_ value: Binding<Double>) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = clamped($0) })
    }
}

struct WorkspacePreview: View {
    var displays: [SavedDisplay]
    var windows: [SavedWindow]
    var selectedIndex: Int?
    var onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let bounds = Self.unionFrames(displays.map(\.frame.cgRect))
            if bounds.isNull || bounds.width <= 0 || bounds.height <= 0 {
                Text("No displays")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let padding: CGFloat = 16
                let available = CGSize(
                    width: max(geo.size.width - padding * 2, 1),
                    height: max(geo.size.height - padding * 2, 1)
                )
                let scale = min(available.width / bounds.width, available.height / bounds.height)
                let origin = CGPoint(
                    x: padding + (available.width - bounds.width * scale) / 2,
                    y: padding + (available.height - bounds.height * scale) / 2
                )

                ZStack(alignment: .topLeading) {
                    ForEach(displays) { display in
                        let rect = Self.previewRect(
                            cocoa: display.frame.cgRect,
                            bounds: bounds,
                            scale: scale,
                            origin: origin
                        )
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.6))
                            )
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                        Text(display.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .offset(x: rect.minX + 6, y: rect.minY + 4)
                    }

                    ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                        let cocoa = Self.windowCocoaFrame(window, displays: displays)
                        let rect = Self.previewRect(
                            cocoa: cocoa,
                            bounds: bounds,
                            scale: scale,
                            origin: origin
                        )
                        let selected = index == selectedIndex
                        ZStack {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(selected ? 0.4 : 0.2))
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(selected ? Color.accentColor : Color.accentColor.opacity(0.7))
                            Text(window.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                        }
                        .frame(width: max(rect.width, 10), height: max(rect.height, 10))
                        .offset(x: rect.minX, y: rect.minY)
                        .onTapGesture { onSelect(index) }
                    }
                }
            }
        }
    }

    static func windowCocoaFrame(_ window: SavedWindow, displays: [SavedDisplay]) -> CGRect {
        let display = displays.first(where: { $0.id == window.displayId }) ?? displays.first
        let visible = display?.visibleFrame.cgRect ?? .zero
        let relative = CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
        return FramePlacement.cocoa(relative: relative, visibleFrame: visible)
    }

    static func unionFrames(_ frames: [CGRect]) -> CGRect {
        frames.reduce(into: CGRect.null) { $0 = $0.union($1) }
    }

    static func previewRect(
        cocoa: CGRect,
        bounds: CGRect,
        scale: CGFloat,
        origin: CGPoint
    ) -> CGRect {
        CGRect(
            x: origin.x + (cocoa.minX - bounds.minX) * scale,
            y: origin.y + (bounds.maxY - cocoa.maxY) * scale,
            width: cocoa.width * scale,
            height: cocoa.height * scale
        )
    }
}
