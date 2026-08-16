import XCTest
@testable import Gridka

final class SettingsManagerTests: XCTestCase {
    private let clickableWebLinksKey = "GridkaClickableWebLinks"
    private var previousValue: Any?

    override func setUp() {
        super.setUp()
        previousValue = UserDefaults.standard.object(forKey: clickableWebLinksKey)
        UserDefaults.standard.removeObject(forKey: clickableWebLinksKey)
    }

    override func tearDown() {
        if let previousValue {
            UserDefaults.standard.set(previousValue, forKey: clickableWebLinksKey)
        } else {
            UserDefaults.standard.removeObject(forKey: clickableWebLinksKey)
        }
        super.tearDown()
    }

    func testClickableWebLinksDefaultToEnabled() {
        XCTAssertTrue(SettingsManager.shared.clickableWebLinks)
    }

    func testClickableWebLinksCanBeDisabled() {
        SettingsManager.shared.clickableWebLinks = false
        XCTAssertFalse(SettingsManager.shared.clickableWebLinks)
    }
}
