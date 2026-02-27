import XCTest
@testable import Gridka

/// Smoke tests that verify basic infrastructure works.
final class GridkaTests: XCTestCase {

    func testFixturePathResolution() {
        // Verify TestFixtures resolves to existing directories
        let testsDir = URL(fileURLWithPath: TestFixtures.largeCsv).deletingLastPathComponent().path
        XCTAssertTrue(FileManager.default.fileExists(atPath: testsDir), "Tests directory should exist at \(testsDir)")
    }
}
