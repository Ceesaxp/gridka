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

    func testAcceptsValidPercentEncodingAndBoundedURLs() {
        XCTAssertNotNil(HTTPURLParser.parse("https://example.com/a%20path?q=a%2Fb"))

        let prefix = "https://example.com/"
        let maximumURL = prefix + String(
            repeating: "a",
            count: HTTPURLParser.maximumClickableURLLength - prefix.utf8.count
        )
        XCTAssertNotNil(HTTPURLParser.parse(maximumURL))

        let oversizedURL = maximumURL + "a"
        XCTAssertNil(HTTPURLParser.parse(oversizedURL))
    }

    func testRejectsUserInfoByDefault() {
        XCTAssertNil(HTTPURLParser.parse("https://user@evil.example/path"))
        XCTAssertNil(HTTPURLParser.parse("https://user:password@evil.example/path"))

        let deceptiveURL = "https://trusted.example" + String(repeating: "a", count: 1_000) + "@evil.example"
        XCTAssertNil(HTTPURLParser.parse(deceptiveURL))
    }

    func testAcceptsUserInfoOnlyWhenExplicitlyAllowed() {
        XCTAssertNotNil(HTTPURLParser.parse("https://user@evil.example/path", allowUserInfo: true))
        XCTAssertNotNil(HTTPURLParser.parse("https://user:password@evil.example/path", allowUserInfo: true))
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

    func testGridCellOnlyOpensUnmodifiedSingleClicks() {
        XCTAssertTrue(GridCellTextField.shouldOpenLink(clickCount: 1, modifierFlags: []))
        XCTAssertFalse(GridCellTextField.shouldOpenLink(clickCount: 2, modifierFlags: []))
        XCTAssertFalse(GridCellTextField.shouldOpenLink(clickCount: 1, modifierFlags: .command))
        XCTAssertFalse(GridCellTextField.shouldOpenLink(clickCount: 1, modifierFlags: .shift))
        XCTAssertFalse(GridCellTextField.shouldOpenLink(clickCount: 1, modifierFlags: .option))
        XCTAssertFalse(GridCellTextField.shouldOpenLink(clickCount: 1, modifierFlags: .control))
    }

    func testGridCellSuppressesEditingOnlyForUnmodifiedLinkDoubleClicks() {
        XCTAssertTrue(GridCellTextField.shouldSuppressEditingForLink(clickCount: 2, modifierFlags: []))
        XCTAssertFalse(GridCellTextField.shouldSuppressEditingForLink(clickCount: 1, modifierFlags: []))
        XCTAssertFalse(GridCellTextField.shouldSuppressEditingForLink(clickCount: 2, modifierFlags: .command))
        XCTAssertFalse(GridCellTextField.shouldSuppressEditingForLink(clickCount: 2, modifierFlags: .shift))
    }

    func testGridCellUsesLinkColorWhenUnselected() {
        XCTAssertEqual(GridCellTextField.linkTextColor(isSelected: false), .linkColor)
    }

    func testGridCellUsesTableTextColorWhenSelected() {
        XCTAssertEqual(GridCellTextField.linkTextColor(isSelected: true), .alternateSelectedControlTextColor)
    }

    func testGridCellUsesUnemphasizedTextColorWhenSelectionIsInactive() {
        XCTAssertEqual(
            GridCellTextField.linkTextColor(isSelected: true, isEmphasized: false),
            .unemphasizedSelectedTextColor
        )
    }

    func testGridCellUpdatesLinkColorWithoutReplacingOtherAttributes() {
        let field = GridCellTextField()
        field.linkURL = URL(string: "https://example.com")
        field.attributedStringValue = NSAttributedString(
            string: "https://example.com",
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
        )

        field.updateLinkTextColor(isSelected: true)

        let attributes = field.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .alternateSelectedControlTextColor)
        XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testGridRowUpdatesLinkColorDuringSelectionChange() {
        let row = GridTableRowView()
        let field = GridCellTextField()
        field.linkURL = URL(string: "https://example.com")
        field.attributedStringValue = NSAttributedString(string: "https://example.com")
        row.addSubview(field)
        row.isEmphasized = true

        row.isSelected = true

        let color = field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .alternateSelectedControlTextColor)
    }

    func testGridRowUpdatesLinkColorWhenSelectionLosesEmphasis() {
        let row = GridTableRowView()
        let field = GridCellTextField()
        field.linkURL = URL(string: "https://example.com")
        field.attributedStringValue = NSAttributedString(string: "https://example.com")
        row.addSubview(field)
        row.isEmphasized = true
        row.isSelected = true

        row.isEmphasized = false

        let color = field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .unemphasizedSelectedTextColor)
    }
}
