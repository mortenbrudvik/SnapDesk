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

    /// An apostrophe in a path — `Morten's Docs` — opens a quote that never closes, and everything
    /// after it was swallowed into one token with the apostrophe deleted: the app was launched with
    /// silently wrong arguments and there is no escape syntax to work around it. An unterminated
    /// quote is treated as the literal character it is.
    func testAnUnterminatedQuoteIsALiteralCharacter() {
        XCTAssertEqual(
            ArgumentTokenizer.tokenize("--dir /Users/m/Morten's Docs"),
            ["--dir", "/Users/m/Morten's", "Docs"]
        )
        XCTAssertEqual(ArgumentTokenizer.tokenize("\"unclosed and then some"), ["\"unclosed", "and", "then", "some"])
    }

    /// Only the unterminated quote is literal: a balanced one in the same string still quotes.
    /// (A trailing apostrophe swallows the rest of the line in a real shell too — this is about
    /// not silently deleting characters, not about out-guessing the user.)
    func testABalancedQuoteStillQuotesAlongsideALiteralApostrophe() {
        XCTAssertEqual(ArgumentTokenizer.tokenize("\"two words\" it's"), ["two words", "it's"])
    }

    /// An explicitly empty argument is one the user asked for, and apps do take them.
    func testAnEmptyQuotedArgumentSurvives() {
        XCTAssertEqual(ArgumentTokenizer.tokenize("--flag \"\" --other"), ["--flag", "", "--other"])
        XCTAssertEqual(ArgumentTokenizer.tokenize("''"), [""])
    }
}
