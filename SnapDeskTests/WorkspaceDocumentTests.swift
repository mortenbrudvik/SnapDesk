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

        XCTAssertEqual(doc.version, 1)
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
        XCTAssertEqual(doc.version, 1)
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
        XCTAssertThrowsError(try WorkspaceDocument.decode(Data(v2.utf8))) { error in
            XCTAssertEqual(error as? WorkspaceDocumentError, .unsupportedVersion(2))
        }
    }

    func testTruncatedJSONThrowsCorrupt() {
        XCTAssertThrowsError(try WorkspaceDocument.decode(Data("{".utf8))) { error in
            XCTAssertEqual(error as? WorkspaceDocumentError, .corrupt)
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
}
