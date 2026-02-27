import XCTest
@testable import Gridka

final class FileSessionCrashRegressionTests: XCTestCase {

    private let sensorTelemetryPath = "/Users/andrei/Developer/Swift/Gridka/scripts/screenshots/data/sensor_telemetry.csv"
    private let cbCompaniesPath = "/Users/andrei/Downloads/cb-companies.csv"

    private func ensureFileExists(_ path: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Missing test fixture: \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func waitForLoadFull(_ session: FileSession, timeout: TimeInterval = 180) throws {
        let done = expectation(description: "loadFull")
        var loadError: Error?
        onMain {
            session.loadFull(progress: { _ in }) { result in
                if case .failure(let err) = result {
                    loadError = err
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: timeout)
        if let loadError {
            throw loadError
        }
    }

    private func queueFetch(_ session: FileSession, index: Int, completion: @escaping (Result<RowCache.Page, Error>) -> Void) {
        onMain {
            session.fetchPage(index: index, completion: completion)
        }
    }

    private func queueStateMutation(_ session: FileSession, mutation: @escaping (inout ViewState) -> Void) {
        onMain {
            var state = session.viewState
            mutation(&state)
            session.updateViewState(state)
        }
    }

    func testFetchBurstUnderRapidViewStateChurn_sensorTelemetry() throws {
        let url = try ensureFileExists(sensorTelemetryPath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var fetchedColumns: [ColumnDescriptor] = []
        onMain { fetchedColumns = session.columns }
        guard let sortColumn = fetchedColumns.first(where: { $0.name != "_gridka_rowid" })?.name else {
            XCTFail("No sortable columns found")
            return
        }

        let fetchCount = 60
        let done = expectation(description: "all fetches complete")
        done.expectedFulfillmentCount = fetchCount

        var successCount = 0
        var failureCount = 0
        let lock = NSLock()

        for i in 0..<fetchCount {
            queueFetch(session, index: i % 30) { result in
                lock.lock()
                defer { lock.unlock() }
                switch result {
                case .success:
                    successCount += 1
                case .failure:
                    failureCount += 1
                }
                done.fulfill()
            }

            if i % 3 == 0 {
                let ascending = (i / 3) % 2 == 0
                queueStateMutation(session) { state in
                    state.sortColumns = [SortColumn(column: sortColumn, direction: ascending ? .ascending : .descending)]
                    state.visibleRange = (i * 10)..<(i * 10 + 500)
                }
            }
        }

        wait(for: [done], timeout: 120)
        XCTAssertEqual(successCount + failureCount, fetchCount)
        XCTAssertEqual(failureCount, 0, "fetchPage should remain stable during rapid state churn")
    }

    func testScrollLikeFetchStress_cbCompanies() throws {
        let url = try ensureFileExists(cbCompaniesPath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        let fetchCount = 120
        let done = expectation(description: "scroll stress fetches complete")
        done.expectedFulfillmentCount = fetchCount

        var successCount = 0
        var failureCount = 0
        let lock = NSLock()

        for i in 0..<fetchCount {
            let pageIndex = (i * 7) % 80
            queueFetch(session, index: pageIndex) { result in
                lock.lock()
                defer { lock.unlock() }
                switch result {
                case .success:
                    successCount += 1
                case .failure:
                    failureCount += 1
                }
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 90)
        XCTAssertEqual(successCount + failureCount, fetchCount)
        XCTAssertEqual(failureCount, 0, "scroll-like fetch stress should not fail")
    }

    func testSummarySessionCreateDropDuringActiveFetches_cbCompanies() throws {
        let url = try ensureFileExists(cbCompaniesPath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var columns: [ColumnDescriptor] = []
        onMain { columns = session.columns.filter { $0.name != "_gridka_rowid" } }
        guard !columns.isEmpty else {
            XCTFail("No columns loaded for summary test")
            return
        }

        let definition = GroupByDefinition(
            groupByColumns: [columns[0].name],
            aggregations: [AggregationEntry(columnName: "*", function: .count)]
        )

        let summaryReady = expectation(description: "summary session created")
        var summarySessionResult: Result<FileSession, Error>?
        onMain {
            FileSession.createSummarySession(from: session, definition: definition) { result in
                summarySessionResult = result
                summaryReady.fulfill()
            }
        }
        wait(for: [summaryReady], timeout: 30)

        let summarySession: FileSession
        switch summarySessionResult {
        case .success(let s):
            summarySession = s
        case .failure(let err):
            XCTFail("Failed to create summary session: \(err)")
            return
        case .none:
            XCTFail("Missing summary session result")
            return
        }

        let fetchDone = expectation(description: "summary fetch burst")
        fetchDone.expectedFulfillmentCount = 25
        for i in 0..<25 {
            queueFetch(summarySession, index: i % 10) { _ in
                fetchDone.fulfill()
            }
        }

        onMain {
            summarySession.dropSummaryTable()
        }

        wait(for: [fetchDone], timeout: 30)
    }
}
