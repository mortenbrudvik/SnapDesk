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

enum WorkspaceDocumentError: Error, Equatable {
    case unsupportedVersion(Int)
    case corrupt
}

struct WorkspaceDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var name: String
    var moveExistingWindows: Bool
    var displays: [SavedDisplay]
    var windows: [SavedWindow]

    static func decode(_ data: Data) throws -> WorkspaceDocument {
        do {
            let doc = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
            guard doc.version == currentVersion else {
                throw WorkspaceDocumentError.unsupportedVersion(doc.version)
            }
            return doc
        } catch let error as WorkspaceDocumentError {
            throw error
        } catch {
            throw WorkspaceDocumentError.corrupt
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func load(from url: URL) throws -> WorkspaceDocument {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    func save(to url: URL) throws {
        let data = try encoded()
        try data.write(to: url, options: .atomic)
    }
}
