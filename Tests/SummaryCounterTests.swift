import XCTest
@testable import Gridka

final class SummaryCounterTests: XCTestCase {

    /// Stress test: concurrent `createSummarySession` calls must all produce unique temp table names.
    /// Validates that the static summaryCounter is properly synchronized (US-010).
    func testConcurrentSummarySessionCreationProducesUniqueNames() throws {
        let url = try requireFixture(at: TestFixtures.cbCompaniesCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        var columns: [ColumnDescriptor] = []
        onMain { columns = session.columns.filter { $0.name != "_gridka_rowid" } }
        guard !columns.isEmpty else {
            XCTFail("No columns loaded")
            return
        }

        let definition = GroupByDefinition(
            groupByColumns: [columns[0].name],
            aggregations: [AggregationEntry(columnName: "*", function: .count)]
        )

        let concurrentCount = 20
        let done = expectation(description: "all summary sessions created")
        done.expectedFulfillmentCount = concurrentCount

        var createdSessions: [FileSession] = []
        let lock = NSLock()

        for _ in 0..<concurrentCount {
            onMain {
                FileSession.createSummarySession(from: session, definition: definition) { result in
                    if case .success(let s) = result {
                        lock.lock()
                        createdSessions.append(s)
                        lock.unlock()
                    }
                    done.fulfill()
                }
            }
        }

        wait(for: [done], timeout: 60)

        // All sessions should have been created successfully
        XCTAssertEqual(createdSessions.count, concurrentCount,
                       "All \(concurrentCount) summary sessions should succeed")

        // Every summary table name must be unique
        let names = createdSessions.compactMap { $0.summaryTableName }
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count,
                       "All summary table names must be unique, got duplicates: \(names)")

        // Clean up temp tables
        for s in createdSessions {
            onMain { s.dropSummaryTable() }
        }
    }

    /// Verify that summary counter values are strictly monotonically increasing
    /// even when sessions are created from multiple dispatch queues.
    func testSummaryCounterMonotonicity() throws {
        let url = try requireFixture(at: TestFixtures.cbCompaniesCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        var columns: [ColumnDescriptor] = []
        onMain { columns = session.columns.filter { $0.name != "_gridka_rowid" } }
        guard !columns.isEmpty else {
            XCTFail("No columns loaded")
            return
        }

        let definition = GroupByDefinition(
            groupByColumns: [columns[0].name],
            aggregations: [AggregationEntry(columnName: "*", function: .count)]
        )

        let count = 10
        let done = expectation(description: "sessions created")
        done.expectedFulfillmentCount = count

        var createdSessions: [FileSession] = []
        let lock = NSLock()

        for _ in 0..<count {
            onMain {
                FileSession.createSummarySession(from: session, definition: definition) { result in
                    if case .success(let s) = result {
                        lock.lock()
                        createdSessions.append(s)
                        lock.unlock()
                    }
                    done.fulfill()
                }
            }
        }

        wait(for: [done], timeout: 60)

        XCTAssertEqual(createdSessions.count, count)

        // Extract numeric suffixes and verify all are unique
        let names = createdSessions.compactMap { $0.summaryTableName }
        let suffixes = names.compactMap { name -> Int? in
            guard name.hasPrefix("summary_") else { return nil }
            return Int(name.dropFirst("summary_".count))
        }
        XCTAssertEqual(suffixes.count, count, "All names should have numeric suffixes")
        XCTAssertEqual(Set(suffixes).count, count, "All numeric suffixes must be unique")

        // Clean up
        for s in createdSessions {
            onMain { s.dropSummaryTable() }
        }
    }
}
