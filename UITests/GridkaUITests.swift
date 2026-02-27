import XCTest

final class GridkaUITests: XCTestCase {

    private let sensorTelemetryPath = "/Users/andrei/Developer/Swift/Gridka/scripts/screenshots/data/sensor_telemetry.csv"
    private let cbCompaniesPath = "/Users/andrei/Downloads/cb-companies.csv"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(files: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GRIDKA_UI_TEST_MODE"] = "1"
        app.launchEnvironment["GRIDKA_UI_TEST_FILES"] = files.joined(separator: "::")
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    private func mainTable(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "mainTableView").firstMatch
    }

    private func mainScrollView(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "mainTableScrollView").firstMatch
    }

    private func assertMainTableReady(_ app: XCUIApplication, timeout: TimeInterval = 120) {
        let table = mainTable(app)
        XCTAssertTrue(table.waitForExistence(timeout: timeout), "Main table did not appear")
    }

    private func exerciseTableNavigation(_ app: XCUIApplication, steps: Int) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Main window did not appear")

        // Click inside the table area without re-querying the accessibility tree each step.
        let tableArea = window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.40))
        tableArea.click()
        let scroll = mainScrollView(app)
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), "Main table scroll view did not appear")

        // Drive both directions via scroll bars to avoid flaky key-synthesis timeouts.
        // 0.0 = top/left, 1.0 = bottom/right.
        let bars = scroll.scrollBars.allElementsBoundByIndex
        guard !bars.isEmpty else { return }

        for bar in bars.prefix(2) {
            if bar.exists {
                bar.adjust(toNormalizedSliderPosition: 0.8)
                usleep(40_000)
                bar.adjust(toNormalizedSliderPosition: 0.2)
                usleep(40_000)
            }
        }
    }

    func testLaunchWithSensorTelemetryAndNavigateTable() throws {
        guard FileManager.default.fileExists(atPath: sensorTelemetryPath) else {
            throw XCTSkip("Missing fixture: \(sensorTelemetryPath)")
        }

        let app = launchApp(files: [sensorTelemetryPath])
        assertMainTableReady(app)
        exerciseTableNavigation(app, steps: 2)

        XCTAssertGreaterThanOrEqual(app.windows.count, 1)
    }

    func testHorizontalVerticalNavigationStressOnCbCompanies() throws {
        guard FileManager.default.fileExists(atPath: cbCompaniesPath) else {
            throw XCTSkip("Missing fixture: \(cbCompaniesPath)")
        }

        let app = launchApp(files: [cbCompaniesPath])
        assertMainTableReady(app)

        for _ in 0..<4 {
            exerciseTableNavigation(app, steps: 2)
        }

        XCTAssertGreaterThanOrEqual(app.windows.count, 1)
    }

    func testCloseTabAfterNavigationStressWithTwoFiles() throws {
        guard FileManager.default.fileExists(atPath: sensorTelemetryPath) else {
            throw XCTSkip("Missing fixture: \(sensorTelemetryPath)")
        }
        guard FileManager.default.fileExists(atPath: cbCompaniesPath) else {
            throw XCTSkip("Missing fixture: \(cbCompaniesPath)")
        }

        let app = launchApp(files: [sensorTelemetryPath, cbCompaniesPath])
        assertMainTableReady(app)

        exerciseTableNavigation(app, steps: 2)

        // Close active tab; another tab/window should remain and app must stay alive.
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertGreaterThanOrEqual(app.windows.count, 1)
    }
}
