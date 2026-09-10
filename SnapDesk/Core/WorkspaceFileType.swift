import Foundation
import UniformTypeIdentifiers

/// The `.snapdesk` document type, in one place. Four call sites name it — the status menu's Open
/// panel, the editor's Open panel, the Save panel, and the document type in Info.plist — and a
/// mismatch between any of them and the bundle's declaration shows up only as an Open panel that
/// greys out every workspace the user has.
///
/// The identifier is deliberately *not* the bundle identifier: LaunchServices registers both, and
/// Apple's guidance is that they stay distinct.
enum WorkspaceFileType {
    static let identifier = "com.brudvik.snapdesk.workspace"
    static let fileExtension = "snapdesk"

    /// The exported type, or a plain JSON type if LaunchServices has not registered ours — which
    /// happens for a build that has never been launched from Finder. Panels then show every JSON
    /// file rather than none, and the log says why.
    @MainActor
    static var contentType: UTType {
        if let declared = UTType(identifier) {
            return declared
        }
        if fallbackLog.shouldLog(identifier) {
            Log.app.error(
                "the \(identifier, privacy: .public) type is not registered; file panels will fall back to JSON"
            )
        }
        return .json
    }

    @MainActor
    private static let fallbackLog = OnceGate()
}
