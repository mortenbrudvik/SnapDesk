import XCTest
@testable import SnapDesk

final class ArgumentTokenizerTests: XCTestCase {
    func testEmptyIsNoArguments() {
        XCTAssertEqual(ArgumentTokenizer.tokenize(""), [])
        XCTAssertEqual(ArgumentTokenizer.tokenize("   "), [])
    }

    func testWhitespaceSplit() {
        XCTAssertEqual(ArgumentTokenizer.tokenize("--reuse-window /tmp/a"), ["--reuse-window", "/tmp/a"])
    }

    func testDoubleQuotesKeepSpaces() {
        XCTAssertEqual(ArgumentTokenizer.tokenize("\"hello world\" --flag"), ["hello world", "--flag"])
    }

    func testSingleQuotesKeepSpaces() {
        XCTAssertEqual(ArgumentTokenizer.tokenize("'hello world'"), ["hello world"])
    }

    func testNoTildeOrDollarExpansion() {
        XCTAssertEqual(ArgumentTokenizer.tokenize("$HOME ~"), ["$HOME", "~"])
    }
}
