import AppKit
import XCTest
@testable import Gridka

final class HTTPURLParserTests: XCTestCase {
    func testAcceptsHTTPAndHTTPSURLs() {
        XCTAssertNotNil(HTTPURLParser.parse("http://example.com"))
        XCTAssertNotNil(HTTPURLParser.parse("https://example.com/path?query=value#fragment"))
        XCTAssertNotNil(HTTPURLParser.parse("HTTPS://EXAMPLE.COM"))
    }

    func testAcceptsStandardHostAndPortForms() {
        XCTAssertNotNil(HTTPURLParser.parse("http://localhost:8080/path"))
        XCTAssertNotNil(HTTPURLParser.parse("https://127.0.0.1:443"))
        XCTAssertNotNil(HTTPURLParser.parse("https://[2001:db8::1]/resource"))
        XCTAssertNotNil(HTTPURLParser.parse("https://xn--bcher-kva.example/path"))
    }

    func testAcceptsValidPercentEncodingAndLongURLs() {
        XCTAssertNotNil(HTTPURLParser.parse("https://example.com/a%20path?q=a%2Fb"))

        let longURL = "https://example.com/?q=" + String(repeating: "a", count: 100_000)
        XCTAssertNotNil(HTTPURLParser.parse(longURL))
    }

    func testRejectsUnsupportedOrRelativeURLs() {
        XCTAssertNil(HTTPURLParser.parse("ftp://example.com/file"))
        XCTAssertNil(HTTPURLParser.parse("file:///tmp/example"))
        XCTAssertNil(HTTPURLParser.parse("mailto:user@example.com"))
        XCTAssertNil(HTTPURLParser.parse("www.example.com"))
        XCTAssertNil(HTTPURLParser.parse("/relative/path"))
    }

    func testRejectsMissingOrMalformedHosts() {
        XCTAssertNil(HTTPURLParser.parse("https://"))
        XCTAssertNil(HTTPURLParser.parse("https:///path"))
        XCTAssertNil(HTTPURLParser.parse("https://exa mple.com"))
        XCTAssertNil(HTTPURLParser.parse("https://example.com/%GG"))
    }

    func testRejectsWhitespaceAndCharactersRequiringAutomaticEncoding() {
        XCTAssertNil(HTTPURLParser.parse(" https://example.com"))
        XCTAssertNil(HTTPURLParser.parse("https://example.com "))
        XCTAssertNil(HTTPURLParser.parse("https://example.com/a path"))
        XCTAssertNil(HTTPURLParser.parse("https://b\u{00FC}cher.example"))
    }

    func testOrdinaryLargeCellUsesNonURLFastPath() {
        let value = String(repeating: "not a URL ", count: 100_000)
        XCTAssertNil(HTTPURLParser.parse(value))
    }

    func testGridCellLinkHitAreaExcludesTrailingWhitespace() {
        let field = GridCellTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        field.isBordered = false
        field.stringValue = "https://example.com"
        field.linkURL = URL(string: field.stringValue)

        XCTAssertTrue(field.isLink(at: NSPoint(x: 5, y: 10)))
        XCTAssertFalse(field.isLink(at: NSPoint(x: 290, y: 10)))
    }

    func testGridCellWithoutLinkHasNoLinkHitArea() {
        let field = GridCellTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        field.stringValue = "https://example.com"

        XCTAssertFalse(field.isLink(at: NSPoint(x: 5, y: 10)))
    }
}
