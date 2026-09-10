import CoreGraphics
import Foundation

struct CodableRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// JSON happily carries `1e308`, `NaN` is one hand-edit away, and these numbers reach both
    /// `Int(_:)` conversions and `AXWindow.setSize`. Neither survives a value it cannot represent,
    /// so a rectangle is only usable once every component is finite and in a range a screen could
    /// plausibly occupy — the bound is deliberately far past any real display rather than tight.
    var isUsableGeometry: Bool {
        let components = [x, y, width, height]
        return components.allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
    }
}

struct SavedDisplay: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var frame: CodableRect
    var visibleFrame: CodableRect
    var scale: Double
}

struct SavedWindow: Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var bundlePath: String
    var name: String
    var title: String
    var displayId: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var minimized: Bool
    var zoomed: Bool
    var arguments: String
}

/// Version of the on-disk schema. A distinct type is what keeps callers from stamping a document
/// with a version this build then refuses to reopen: `WorkspaceDocument.currentVersion` is the only
/// value code outside this file can name, while decoding still reads whatever a file claims.
struct SchemaVersion: Codable, Equatable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: Int

    fileprivate init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        String(rawValue)
    }
}

enum WorkspaceDocumentError: LocalizedError {
    /// The file names a schema version this build does not implement. The version is carried so the
    /// message can say whether the file is newer or older than this build, and name it.
    case unsupportedVersion(found: SchemaVersion, expected: SchemaVersion)

    /// The file did not become a document. The payload keeps the real cause: a permission error, a
    /// hand-edited typo and a truncated file are three different problems for the user.
    case corrupt(Corruption)

    /// Kept inside `.corrupt` rather than as sibling cases so existing `case .corrupt` call sites
    /// still cover every way a read can fail.
    enum Corruption {
        /// The bytes never arrived: file missing, no permission, volume disconnected.
        case unreadable(any Error)

        /// The bytes are not a workspace this build can parse. The `DecodingError` names the
        /// offending key and its coding path, e.g. `keyNotFound("zoomed")` at `windows[3]`.
        case malformed(any Error)

        /// It parsed, but describes something SnapDesk cannot apply, such as a negative size.
        case invalid(String)
    }

    /// User-facing text. Call sites should prefer this over switching on the case themselves, so an
    /// older file is never described as a newer one.
    var message: String {
        switch self {
        case let .unsupportedVersion(found, expected) where found > expected:
            return "This workspace was saved with a newer SnapDesk (format \(found); this build reads \(expected))."
        case let .unsupportedVersion(found, expected):
            return "This workspace uses an older format (\(found)) that this SnapDesk no longer reads (it reads \(expected))."
        case .corrupt(.unreadable):
            return "Could not open this workspace file."
        case .corrupt(.malformed):
            return "Could not read this workspace."
        case let .corrupt(.invalid(reason)):
            return "This workspace cannot be used: \(reason)."
        }
    }

    var errorDescription: String? {
        message
    }
}

struct WorkspaceDocument: Codable, Equatable, Sendable {
    static let currentVersion = SchemaVersion(1)

    let version: SchemaVersion
    var name: String
    var moveExistingWindows: Bool
    var displays: [SavedDisplay]
    var windows: [SavedWindow]

    /// Just enough of the file to answer "can this build read it at all?". Decoding the whole
    /// document first would throw on a field a future SnapDesk renamed, dropped or retyped, and the
    /// version check that is supposed to explain that would never run.
    private struct VersionProbe: Decodable {
        let version: SchemaVersion
    }

    static func decode(_ data: Data) throws -> WorkspaceDocument {
        let decoder = JSONDecoder()

        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw malformed(error)
        }

        guard probe.version == currentVersion else {
            Log.app.error("workspace claims format \(probe.version.rawValue, privacy: .public), this build reads \(currentVersion.rawValue, privacy: .public)")
            throw WorkspaceDocumentError.unsupportedVersion(found: probe.version, expected: currentVersion)
        }

        let document: WorkspaceDocument
        do {
            document = try decoder.decode(WorkspaceDocument.self, from: data)
        } catch {
            throw malformed(error)
        }

        let migrated = document.migratingEmptyDisplayIds()
        try migrated.validate()
        return migrated
    }

    /// Repairs the one shape an earlier build wrote that this one no longer emits, so a workspace
    /// already on disk keeps opening. That build identified a display reporting no UUID — virtual
    /// displays, capture cards, some VMs report none — as `""`, and stamped `""` into the
    /// `displayId` of every window captured on it. Both get the frame-derived identity
    /// `LiveDisplay` would assign today, so the window still points at its own display's entry;
    /// `DisplayMap.match` ignores an id no attached screen carries and re-matches by name or size,
    /// which is exactly what it did for the empty one.
    ///
    /// Windows are only re-pointed when a single display was id-less: two of them were both `""` on
    /// disk, so there is no telling which one a window meant, and those windows keep the empty
    /// `displayId` that sends them to the main display.
    private func migratingEmptyDisplayIds() -> WorkspaceDocument {
        let idLess = displays.filter { $0.id.isEmpty }
        guard !idLess.isEmpty else { return self }

        Log.app.notice("workspace has \(idLess.count, privacy: .public) display(s) saved without an id; migrating them")

        var migrated = self
        migrated.displays = displays.map { display in
            guard display.id.isEmpty else { return display }
            var repaired = display
            repaired.id = LiveDisplay.fallbackIdentity(number: nil, frame: display.frame.cgRect)
            return repaired
        }
        if idLess.count == 1 {
            let replacement = LiveDisplay.fallbackIdentity(number: nil, frame: idLess[0].frame.cgRect)
            migrated.windows = windows.map { window in
                guard window.displayId.isEmpty else { return window }
                var repaired = window
                repaired.displayId = replacement
                return repaired
            }
        }
        return migrated
    }

    private static func malformed(_ error: any Error) -> WorkspaceDocumentError {
        Log.app.error("could not parse workspace: \(String(describing: error), privacy: .public)")
        return .corrupt(.malformed(error))
    }

    /// Values that decode cleanly but cannot be applied. A negative width survives
    /// `FramePlacement.clamp` — its `width > visible.width` test is false for a negative
    /// number — and reaches `AXWindow.setSize`; duplicate display ids make `DisplayMap.match` pick
    /// arbitrarily. `encoded` runs it too, so the editor cannot write a file this build then
    /// refuses to reopen; it is also the check to run before applying a document that never went
    /// through `decode`, because the editor's in-memory launch reaches `AXWindow` with no file in
    /// between.
    ///
    /// A window's empty `displayId` is tolerated rather than legitimate: this build's capture skips
    /// a window it cannot record against a display, but earlier builds wrote `""` for one, and
    /// `DisplayMap.resolve` falls back to the main display for it, so such a file still opens. An
    /// empty *display* id is the same vintage but is rewritten before this runs
    /// (`migratingEmptyDisplayIds`), so hitting it here means a document assembled in memory.
    func validate() throws {
        func reject(_ reason: String) -> WorkspaceDocumentError {
            Log.app.error("workspace rejected: \(reason, privacy: .public)")
            return .corrupt(.invalid(reason))
        }

        var displayIds: Set<String> = []
        for display in displays {
            guard !display.id.isEmpty else {
                throw reject("a display has an empty id")
            }
            guard displayIds.insert(display.id).inserted else {
                throw reject("display id \"\(display.id)\" is used twice")
            }
            guard display.frame.isUsableGeometry, display.visibleFrame.isUsableGeometry else {
                throw reject("display \"\(display.name)\" has a frame that is not a usable rectangle")
            }
            guard display.frame.width > 0, display.frame.height > 0,
                  display.visibleFrame.width > 0, display.visibleFrame.height > 0 else {
                throw reject("display \"\(display.name)\" has a size that is not positive")
            }
            guard display.scale > 0, display.scale.isFinite else {
                throw reject("display \"\(display.name)\" has a scale that is not positive")
            }
        }

        for window in windows {
            guard window.x.isFinite, window.y.isFinite, window.width.isFinite, window.height.isFinite else {
                throw reject("window \"\(window.name)\" has a frame that is not a usable rectangle")
            }
            guard window.width > 0, window.height > 0 else {
                throw reject("window \"\(window.name)\" has a size that is not positive")
            }
            guard window.displayId.isEmpty || displayIds.contains(window.displayId) else {
                throw reject("window \"\(window.name)\" names display \"\(window.displayId)\", which the file does not describe")
            }
        }
    }

    /// Validates first: without it the editor can write a file `decode` then refuses, handing the
    /// user a workspace their own app created and will not reopen. The thrown error names the
    /// offending window or display, which is what the save alert shows.
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func load(from url: URL) throws -> WorkspaceDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.app.error("could not read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw WorkspaceDocumentError.corrupt(.unreadable(error))
        }
        return try decode(data)
    }

    func save(to url: URL) throws {
        let data = try encoded()
        try data.write(to: url, options: .atomic)
    }
}
