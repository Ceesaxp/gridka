import XCTest

final class GridkaUITests: XCTestCase {

    // MARK: - Fixture Paths (derived from repo root)

    /// Repo root derived from this file's location: <repo>/UITests/GridkaUITests.swift
    private static let repoRoot: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // UITests/
            .deletingLastPathComponent()  // repo root
            .path
    }()

    private static let sensorTelemetryPath = repoRoot + "/scripts/screenshots/data/sensor_telemetry.csv"
    private static let cbCompaniesPath     = repoRoot + "/Tests/cb-companies.csv"
    private static let forexPath           = repoRoot + "/Tests/12data_forex.csv"

    // MARK: - Lifecycle

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app = app, app.state != .notRunning {
            app.terminate()
        }
        app = nil
    }

    // MARK: - Launch Helpers

    private func launchApp(files: [String] = []) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment["GRIDKA_UI_TEST_MODE"] = "1"
        if !files.isEmpty {
            application.launchEnvironment["GRIDKA_UI_TEST_FILES"] = files.joined(separator: "::")
        }
        application.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        application.launch()
        app = application
        return application
    }

    // MARK: - Element Accessors

    private func mainTable(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "mainTableView").firstMatch
    }

    private func mainScrollView(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "mainTableScrollView").firstMatch
    }

    private func rowCountLabel(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "statusBarRowCount").firstMatch
    }

    // MARK: - Assertions

    /// Waits for the main table to appear in the accessibility tree.
    private func assertMainTableReady(_ app: XCUIApplication, timeout: TimeInterval = 120) {
        let table = mainTable(app)
        XCTAssertTrue(table.waitForExistence(timeout: timeout), "Main table did not appear within \(timeout)s")
    }

    /// Waits for the row count label to contain "rows", indicating data has loaded.
    private func assertDataLoaded(_ app: XCUIApplication, timeout: TimeInterval = 120) {
        let label = rowCountLabel(app)
        guard label.waitForExistence(timeout: timeout) else {
            XCTFail("Row count label did not appear within \(timeout)s")
            return
        }
        let predicate = NSPredicate(format: "value CONTAINS[c] 'rows'")
        let loaded = expectation(for: predicate, evaluatedWith: label)
        wait(for: [loaded], timeout: timeout)
    }

    // MARK: - Navigation Helpers

    /// Exercises scroll navigation via scroll gestures to stress page fetching.
    private func exerciseTableNavigation(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Main window did not appear")

        let scroll = mainScrollView(app)
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), "Main table scroll view did not appear")

        // Use coordinate-based scroll gestures rather than scrollBar.adjust(),
        // which only works on Slider elements, not ScrollBar containers.
        let center = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Scroll down then back up
        center.scroll(byDeltaX: 0, deltaY: -300)
        center.scroll(byDeltaX: 0, deltaY: 300)

        // Scroll right then back left
        center.scroll(byDeltaX: -200, deltaY: 0)
        center.scroll(byDeltaX: 200, deltaY: 0)
    }

    private func requireFixture(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Missing fixture: \(path)")
        }
    }

    // MARK: - Tests: Empty State

    func testLaunchEmptyState() throws {
        let app = launchApp()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Main window should appear on empty launch")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    // MARK: - Tests: Single File Load + Navigation

    func testLaunchWithSensorTelemetryAndVerifyDataLoaded() throws {
        try requireFixture(at: Self.sensorTelemetryPath)

        let app = launchApp(files: [Self.sensorTelemetryPath])
        assertMainTableReady(app)
        assertDataLoaded(app)
        exerciseTableNavigation(app)

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "App should still be running after navigation")
    }

    // MARK: - Tests: Scroll Stress

    func testHorizontalVerticalNavigationStressOnCbCompanies() throws {
        try requireFixture(at: Self.cbCompaniesPath)

        let app = launchApp(files: [Self.cbCompaniesPath])
        assertMainTableReady(app)
        assertDataLoaded(app)

        for _ in 0..<4 {
            exerciseTableNavigation(app)
        }

        // After heavy scrolling the accessibility snapshot can be expensive;
        // just verify the app survived the stress without crashing.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "App should still be running after scroll stress")
    }

    // MARK: - Tests: Multi-Tab Lifecycle

    func testCloseTabAfterNavigationStressWithTwoFiles() throws {
        try requireFixture(at: Self.cbCompaniesPath)
        try requireFixture(at: Self.forexPath)

        let app = launchApp(files: [Self.cbCompaniesPath, Self.forexPath])
        assertMainTableReady(app)
        assertDataLoaded(app)

        exerciseTableNavigation(app)

        // Close active tab; another tab/window should remain and app must stay alive.
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertGreaterThanOrEqual(app.windows.count, 1)
    }
}
