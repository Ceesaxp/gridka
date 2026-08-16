import XCTest
@testable import Gridka

final class SettingsManagerTests: XCTestCase {
    private let clickableWebLinksKey = "GridkaClickableWebLinks"
    private let allowCredentialedWebLinksKey = "GridkaAllowCredentialedWebLinks"
    private var previousValues: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in [clickableWebLinksKey, allowCredentialedWebLinksKey] {
            previousValues[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in [clickableWebLinksKey, allowCredentialedWebLinksKey] {
            if let previousValue = previousValues[key] {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
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

    func testCredentialedWebLinksDefaultToDisabled() {
        XCTAssertFalse(SettingsManager.shared.allowCredentialedWebLinks)
    }

    func testCredentialedWebLinksCanBeEnabled() {
        SettingsManager.shared.allowCredentialedWebLinks = true
        XCTAssertTrue(SettingsManager.shared.allowCredentialedWebLinks)
    }
}
