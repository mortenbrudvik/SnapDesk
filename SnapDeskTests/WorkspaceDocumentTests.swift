import XCTest
@testable import SnapDesk

final class WorkspaceDocumentTests: XCTestCase {
    /// Spec schema example from docs/superpowers/specs/2026-09-09-snapdesk-design.md
    private let specJSON = """
    {
      "version": 1,
      "name": "Coding",
      "moveExistingWindows": true,
      "displays": [
        {
          "id": "37D8832A-2D66-02CA-B9F7-8F30A301B230",
          "name": "Built-in Retina Display",
          "frame": { "x": 0, "y": 0, "width": 1512, "height": 982 },
          "visibleFrame": { "x": 0, "y": 38, "width": 1512, "height": 916 },
          "scale": 2
        }
      ],
      "windows": [
        {
          "bundleIdentifier": "com.apple.Safari",
          "bundlePath": "/System/Cryptexes/App/System/Applications/Safari.app",
          "name": "Safari",
          "title": "GitHub",
          "displayId": "37D8832A-2D66-02CA-B9F7-8F30A301B230",
          "x": 0,
          "y": 0,
          "width": 800,
          "height": 900,
          "minimized": false,
          "zoomed": false,
          "arguments": ""
        }
      ]
    }
    """

    func testDecodeSpecExample() throws {
        let data = Data(specJSON.utf8)
        let doc = try WorkspaceDocument.decode(data)

        XCTAssertEqual(doc.version, WorkspaceDocument.currentVersion)
        XCTAssertEqual(doc.version.rawValue, 1)
        XCTAssertEqual(doc.name, "Coding")
        XCTAssertTrue(doc.moveExistingWindows)
        XCTAssertEqual(doc.displays.count, 1)

        let display = try XCTUnwrap(doc.displays.first)
        XCTAssertEqual(display.id, "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        XCTAssertEqual(display.name, "Built-in Retina Display")
        XCTAssertEqual(display.frame, CodableRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(display.visibleFrame, CodableRect(x: 0, y: 38, width: 1512, height: 916))
        XCTAssertEqual(display.scale, 2)

        XCTAssertEqual(doc.windows.count, 1)
        let window = try XCTUnwrap(doc.windows.first)
        XCTAssertEqual(window.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(window.bundlePath, "/System/Cryptexes/App/System/Applications/Safari.app")
        XCTAssertEqual(window.name, "Safari")
        XCTAssertEqual(window.title, "GitHub")
        XCTAssertEqual(window.displayId, "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        XCTAssertEqual(window.x, 0)
        XCTAssertEqual(window.y, 0)
        XCTAssertEqual(window.width, 800)
        XCTAssertEqual(window.height, 900)
        XCTAssertFalse(window.minimized)
        XCTAssertFalse(window.zoomed)
        XCTAssertEqual(window.arguments, "")
    }

    func testRoundTripEncodeDecode() throws {
        let original = try WorkspaceDocument.decode(Data(specJSON.utf8))
        let roundTripped = try WorkspaceDocument.decode(original.encoded())
        XCTAssertEqual(roundTripped, original)
    }

    func testEncodedIsPrettyAndSortedKeys() throws {
        let doc = try WorkspaceDocument.decode(Data(specJSON.utf8))
        let encoded = try doc.encoded()
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(text.contains("\n"), "encoded JSON should be pretty-printed")

        // Within a frame object, sortedKeys puts "height" before "width"
        let frameRange = try XCTUnwrap(text.range(of: "\"frame\""))
        let afterFrame = text[frameRange.upperBound...]
        let heightRange = try XCTUnwrap(afterFrame.range(of: "\"height\""))
        let widthRange = try XCTUnwrap(afterFrame.range(of: "\"width\""))
        XCTAssertLessThan(heightRange.lowerBound, widthRange.lowerBound)
    }

    /// The version is written as a bare integer, so a file this build writes stays readable by any
    /// other build that only knows the plain JSON schema.
    func testVersionIsEncodedAsPlainInteger() throws {
        let doc = try WorkspaceDocument.decode(Data(specJSON.utf8))
        let text = try XCTUnwrap(String(data: try doc.encoded(), encoding: .utf8))
        XCTAssertTrue(text.contains("\"version\" : 1"), "unexpected version encoding in:\n\(text)")
    }

    func testUnknownRootKeyIgnored() throws {
        let withExtra = """
        {
          "version": 1,
          "name": "Coding",
          "moveExistingWindows": true,
          "future": true,
          "displays": [],
          "windows": []
        }
        """
        let doc = try WorkspaceDocument.decode(Data(withExtra.utf8))
        XCTAssertEqual(doc.version, WorkspaceDocument.currentVersion)
        XCTAssertEqual(doc.name, "Coding")
        XCTAssertTrue(doc.moveExistingWindows)
        XCTAssertEqual(doc.displays, [])
        XCTAssertEqual(doc.windows, [])
    }

    func testUnsupportedVersionThrows() {
        let v2 = """
        {
          "version": 2,
          "name": "Future",
          "moveExistingWindows": false,
          "displays": [],
          "windows": []
        }
        """
        expectUnsupportedVersion(v2, found: 2)
    }

    /// The point of the version check: a real v2 file will not parse as v1. The version has to be
    /// read before the body, or the renamed key throws first and the user is told the file is
    /// corrupt instead of being told to update SnapDesk.
    func testFutureVersionWithReshapedBodyReportsUnsupportedVersionNotCorrupt() {
        let v2 = """
        {
          "version": 2,
          "title": "Future",
          "screens": [],
          "panes": [{ "app": "com.apple.Safari" }]
        }
        """
        let error = expectUnsupportedVersion(v2, found: 2)
        XCTAssertTrue(error?.message.contains("newer") == true, "got: \(error?.message ?? "-")")
    }

    /// A file older than this build must not tell the user their SnapDesk is out of date.
    func testOlderVersionIsNotDescribedAsNewer() {
        let v0 = """
        {
          "version": 0,
          "name": "Ancient",
          "windows": []
        }
        """
        let error = expectUnsupportedVersion(v0, found: 0)
        XCTAssertFalse(error?.message.contains("newer") == true, "got: \(error?.message ?? "-")")
        XCTAssertTrue(error?.message.contains("older") == true, "got: \(error?.message ?? "-")")
    }

    func testTruncatedJSONThrowsCorrupt() {
        XCTAssertThrowsError(try WorkspaceDocument.decode(Data("{".utf8))) { error in
            guard let documentError = error as? WorkspaceDocumentError,
                  case .corrupt(.malformed) = documentError else {
                return XCTFail("expected .corrupt(.malformed), got \(error)")
            }
        }
    }

    /// The decoder knows exactly which key is missing and where; that has to survive so it can be
    /// logged instead of collapsing into one unhelpful message.
    func testMalformedCorruptionCarriesTheDecodingError() {
        let missingKey = specJSON.replacingOccurrences(of: "\"zoomed\": false,", with: "")
        XCTAssertThrowsError(try WorkspaceDocument.decode(Data(missingKey.utf8))) { error in
            guard let documentError = error as? WorkspaceDocumentError,
                  case .corrupt(.malformed(let underlying)) = documentError,
                  let decodingError = underlying as? DecodingError,
                  case .keyNotFound(let key, let context) = decodingError else {
                return XCTFail("expected a DecodingError payload, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "zoomed")
            XCTAssertTrue(
                context.codingPath.contains(where: { $0.stringValue == "windows" }),
                "coding path should name the window: \(context.codingPath)"
            )
        }
    }

    /// An unreadable file is a different problem from a malformed one, and must not escape as a raw
    /// Cocoa error for every call site to guess at.
    func testMissingFileIsReportedAsUnreadable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapdesk-missing-\(UUID().uuidString).snapdesk")
        XCTAssertThrowsError(try WorkspaceDocument.load(from: url)) { error in
            guard let documentError = error as? WorkspaceDocumentError,
                  case .corrupt(.unreadable) = documentError else {
                return XCTFail("expected .corrupt(.unreadable), got \(error)")
            }
        }
    }

    func testNegativeWindowSizeIsRejected() {
        // A negative width slips past FramePlacement.clamp and reaches AXWindow.setSize.
        expectInvalid(specJSON.replacingOccurrences(of: "\"width\": 800", with: "\"width\": -800"))
    }

    /// Restore matches windows by bundle identifier, so a slot without one can never be filled: it
    /// burns the whole window timeout and fails. A document that cannot be restored is refused
    /// on the way in, and the message names the slot.
    func testAWindowWithoutABundleIdentifierIsRejectedAndNamed() {
        let unidentified = specJSON.replacingOccurrences(
            of: "\"bundleIdentifier\": \"com.apple.Safari\"",
            with: "\"bundleIdentifier\": \"\""
        )
        XCTAssertThrowsError(try WorkspaceDocument.decode(Data(unidentified.utf8))) { error in
            guard case .corrupt(.invalid(let reason))? = error as? WorkspaceDocumentError else {
                return XCTFail("expected .corrupt(.invalid), got \(error)")
            }
            XCTAssertTrue(reason.contains("Safari"), "the message must name the slot: \(reason)")
            XCTAssertTrue(reason.contains("bundle identifier"), reason)
        }
    }

    /// Displays are bounded to a range a screen could plausibly occupy; windows were only checked
    /// for finiteness, so a legal-JSON `1e300` reached the frame arithmetic. The same bound holds
    /// for both.
    func testAnAbsurdWindowCoordinateIsRejected() {
        // `"x": 0,` appears in both display rectangles as well, and those were already bounded —
        // so the edit has to name the window's own field, or the test passes on the old rule.
        for json in [
            specJSON.replacingOccurrences(of: "\"width\": 800", with: "\"width\": 1e300"),
            specJSON.replacingOccurrences(of: "\"height\": 900", with: "\"height\": 1e300"),
        ] {
            XCTAssertThrowsError(try WorkspaceDocument.decode(Data(json.utf8))) { error in
                guard case .corrupt(.invalid(let reason))? = error as? WorkspaceDocumentError else {
                    return XCTFail("expected .corrupt(.invalid), got \(error)")
                }
                XCTAssertTrue(reason.contains("window \"Safari\""), "the window is the offender: \(reason)")
            }
        }
    }

    /// `validated()` is the only way to a `ValidatedWorkspace`, and it is the same check.
    func testValidatedWrapsADocumentThatPassesAndThrowsForOneThatDoesNot() throws {
        var document = try WorkspaceDocument.decode(Data(specJSON.utf8))
        XCTAssertEqual(try document.validated().document, document)

        document.windows[0].width = 0
        XCTAssertThrowsError(try document.validated())
    }

    func testZeroDisplayScaleIsRejected() {
        expectInvalid(specJSON.replacingOccurrences(of: "\"scale\": 2", with: "\"scale\": 0"))
    }

    func testWindowReferringToAnAbsentDisplayIsRejected() {
        expectInvalid(specJSON.replacingOccurrences(
            of: "\"displayId\": \"37D8832A-2D66-02CA-B9F7-8F30A301B230\"",
            with: "\"displayId\": \"no-such-display\""
        ))
    }

    func testDuplicateDisplayIdsAreRejected() {
        let duplicated = """
        {
          "version": 1,
          "name": "Coding",
          "moveExistingWindows": true,
          "displays": [
            {
              "id": "same",
              "name": "One",
              "frame": { "x": 0, "y": 0, "width": 1512, "height": 982 },
              "visibleFrame": { "x": 0, "y": 38, "width": 1512, "height": 916 },
              "scale": 2
            },
            {
              "id": "same",
              "name": "Two",
              "frame": { "x": 1512, "y": 0, "width": 1920, "height": 1080 },
              "visibleFrame": { "x": 1512, "y": 0, "width": 1920, "height": 1080 },
              "scale": 1
            }
          ],
          "windows": []
        }
        """
        expectInvalid(duplicated)
    }

    /// This build's capture skips a window it cannot record against a display, but earlier builds
    /// wrote an empty displayId for one, and DisplayMap.resolve falls back to the main display for
    /// it, so such a file must still open.
    func testEmptyWindowDisplayIdIsAccepted() throws {
        let orphaned = specJSON.replacingOccurrences(
            of: "\"displayId\": \"37D8832A-2D66-02CA-B9F7-8F30A301B230\"",
            with: "\"displayId\": \"\""
        )
        let doc = try WorkspaceDocument.decode(Data(orphaned.utf8))
        XCTAssertEqual(doc.windows.first?.displayId, "")
    }

    /// A v1 file written by the previous build on a machine whose display reports no UUID: the id
    /// went to disk as "", and so did the displayId of every window on it. Rejecting that would
    /// break workspaces users already have.
    func testLegacyEmptyDisplayIdIsMigratedInsteadOfRejected() throws {
        let legacy = specJSON
            .replacingOccurrences(of: "\"id\": \"37D8832A-2D66-02CA-B9F7-8F30A301B230\"", with: "\"id\": \"\"")
            .replacingOccurrences(
                of: "\"displayId\": \"37D8832A-2D66-02CA-B9F7-8F30A301B230\"",
                with: "\"displayId\": \"\""
            )

        let doc = try WorkspaceDocument.decode(Data(legacy.utf8))

        let migratedID = try XCTUnwrap(doc.displays.first?.id)
        XCTAssertFalse(migratedID.isEmpty)
        XCTAssertEqual(
            doc.windows.first?.displayId,
            migratedID,
            "the window must still point at the display it was captured on"
        )

        // The migrated document has to be writable, or the user cannot save the file they opened.
        let url = temporaryWorkspaceURL()
        try doc.save(to: url)
        XCTAssertEqual(try WorkspaceDocument.load(from: url), doc)
    }

    /// The empty-id migration derives an identity from the frame, and it runs *before* `validate`,
    /// on numbers straight off disk. `Int(someDouble)` traps past `Int.max`, so a frame carrying a
    /// legal-JSON `1e308` would abort the process on a double-clicked file. Opening a bad workspace
    /// is allowed to fail; it is never allowed to take the app down with it.
    func testLegacyEmptyDisplayIdWithAnAbsurdFrameFailsInsteadOfTrapping() throws {
        let legacy = specJSON
            .replacingOccurrences(of: "\"id\": \"37D8832A-2D66-02CA-B9F7-8F30A301B230\"", with: "\"id\": \"\"")
            .replacingOccurrences(
                of: "\"frame\": { \"x\": 0, \"y\": 0, \"width\": 1512, \"height\": 982 }",
                with: "\"frame\": { \"x\": 1e308, \"y\": 0, \"width\": 1512, \"height\": 982 }"
            )
        XCTAssertTrue(legacy.contains("1e308"), "the fixture edit must actually apply")

        XCTAssertThrowsError(try WorkspaceDocument.decode(Data(legacy.utf8))) { error in
            XCTAssertTrue(
                error is WorkspaceDocumentError,
                "an out-of-range frame must surface as a document error, got \(error)"
            )
        }
    }

    /// Two id-less displays were both "" on disk, so a window's "" cannot be attributed to either.
    /// They still have to migrate to distinct ids, because `validate` rejects a repeated one.
    func testTwoLegacyEmptyDisplayIdsMigrateToDistinctIdsAndLeaveWindowsUnattached() throws {
        let legacy = """
        {
          "version": 1,
          "name": "Capture Cards",
          "moveExistingWindows": true,
          "displays": [
            {
              "id": "",
              "name": "One",
              "frame": { "x": 0, "y": 0, "width": 1512, "height": 982 },
              "visibleFrame": { "x": 0, "y": 38, "width": 1512, "height": 916 },
              "scale": 2
            },
            {
              "id": "",
              "name": "Two",
              "frame": { "x": 1512, "y": 0, "width": 1920, "height": 1080 },
              "visibleFrame": { "x": 1512, "y": 0, "width": 1920, "height": 1080 },
              "scale": 1
            }
          ],
          "windows": [
            {
              "bundleIdentifier": "com.apple.Safari",
              "bundlePath": "/Applications/Safari.app",
              "name": "Safari",
              "title": "GitHub",
              "displayId": "",
              "x": 0,
              "y": 0,
              "width": 800,
              "height": 900,
              "minimized": false,
              "zoomed": false,
              "arguments": ""
            }
          ]
        }
        """

        let doc = try WorkspaceDocument.decode(Data(legacy.utf8))

        let ids = doc.displays.map(\.id)
        XCTAssertEqual(Set(ids).count, 2, "migrated ids must stay distinct: \(ids)")
        XCTAssertFalse(ids.contains(""))
        XCTAssertEqual(doc.windows.first?.displayId, "", "an ambiguous window keeps the main-display fallback")
    }

    /// The editor's numeric fields write straight into the document, so the write side has to hold
    /// the invariant the read side does. Without this the editor writes a file it then refuses to
    /// reopen, and the message names corruption the user did not cause.
    func testSavingAWindowWithANonPositiveSizeIsRefused() throws {
        var document = try WorkspaceDocument.decode(Data(specJSON.utf8))
        document.windows[0].width = 0
        let url = temporaryWorkspaceURL()

        XCTAssertThrowsError(try document.save(to: url)) { error in
            guard case .corrupt(.invalid(let reason))? = error as? WorkspaceDocumentError else {
                return XCTFail("expected .corrupt(.invalid), got \(error)")
            }
            XCTAssertTrue(reason.contains("Safari"), "the message must name the offending window: \(reason)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "nothing may be written when the document is rejected"
        )
    }

    func testSavingADisplayWithANonPositiveScaleIsRefused() throws {
        var document = try WorkspaceDocument.decode(Data(specJSON.utf8))
        document.displays[0].scale = 0

        XCTAssertThrowsError(try document.encoded()) { error in
            guard case .corrupt(.invalid)? = error as? WorkspaceDocumentError else {
                XCTFail("expected .corrupt(.invalid), got \(error)")
                return
            }
        }
    }

    func testLoadSaveRoundTrip() throws {
        let original = try WorkspaceDocument.decode(Data(specJSON.utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapdesk-workspace-doc-test-\(UUID().uuidString).snapdesk")
        defer { try? FileManager.default.removeItem(at: url) }

        try original.save(to: url)
        let loaded = try WorkspaceDocument.load(from: url)
        XCTAssertEqual(loaded, original)
    }

    private func temporaryWorkspaceURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapdesk-workspace-doc-test-\(UUID().uuidString).snapdesk")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func expectUnsupportedVersion(
        _ json: String,
        found: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WorkspaceDocumentError? {
        var thrown: WorkspaceDocumentError?
        XCTAssertThrowsError(try WorkspaceDocument.decode(Data(json.utf8)), file: file, line: line) { error in
            guard let documentError = error as? WorkspaceDocumentError,
                  case .unsupportedVersion(let version, let expected) = documentError else {
                return XCTFail("expected .unsupportedVersion, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(version.rawValue, found, file: file, line: line)
            XCTAssertEqual(expected, WorkspaceDocument.currentVersion, file: file, line: line)
            thrown = documentError
        }
        return thrown
    }

    private func expectInvalid(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try WorkspaceDocument.decode(Data(json.utf8)), file: file, line: line) { error in
            guard let documentError = error as? WorkspaceDocumentError,
                  case .corrupt(.invalid) = documentError else {
                return XCTFail("expected .corrupt(.invalid), got \(error)", file: file, line: line)
            }
        }
    }
}
