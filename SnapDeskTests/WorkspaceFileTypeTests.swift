import UniformTypeIdentifiers
import XCTest
@testable import SnapDesk

/// The `.snapdesk` type is declared in Info.plist and named in four places in code — the Open
/// panel, the Save panel, the editor's open panel, and the document type. They have to agree, and
/// nothing but a test says so: a mismatch shows up as an Open panel that greys out every workspace.
final class WorkspaceFileTypeTests: XCTestCase {
    func testTheIdentifierIsWhatTheBundleExports() throws {
        let exported = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        )
        let identifiers = exported.compactMap { $0["UTTypeIdentifier"] as? String }

        XCTAssertEqual(identifiers, [WorkspaceFileType.identifier])
    }

    /// Apple's guidance is that a UTI is not also a bundle identifier: LaunchServices registers
    /// both, and a collision between them is a class of bug nobody enjoys diagnosing.
    func testTheIdentifierIsDistinctFromTheBundleIdentifier() {
        XCTAssertNotEqual(WorkspaceFileType.identifier, Bundle.main.bundleIdentifier)
    }

    func testTheExtensionIsDeclaredForTheType() throws {
        let exported = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        )
        let tags = try XCTUnwrap(exported.first?["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], [WorkspaceFileType.fileExtension])
    }

    /// The document type the app opens is the type it exports; a double-clicked file reaches
    /// `application(_:open:)` only if those match.
    func testTheDocumentTypeClaimsTheExportedType() throws {
        let documents = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]]
        )
        let claimed = documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }

        XCTAssertEqual(claimed, [WorkspaceFileType.identifier])
    }

    @MainActor
    func testTheContentTypeResolves() {
        XCTAssertEqual(WorkspaceFileType.contentType.identifier, WorkspaceFileType.identifier)
    }
}
