import XCTest
@testable import Gridka

final class SummaryCounterTests: XCTestCase {

    /// True concurrency stress test: hammer nextSummaryCounter() from many threads
    /// simultaneously using DispatchQueue.concurrentPerform. Every returned value
    /// must be unique — a duplicate proves the lock is broken.
    func testNextSummaryCounterUniquenessUnderConcurrentAccess() {
        let iterations = 1000
        let values = UnsafeMutableBufferPointer<Int>.allocate(capacity: iterations)
        values.initialize(repeating: 0)
        defer { values.deallocate() }

        // concurrentPerform dispatches iterations across all available cores
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            values[i] = FileSession.nextSummaryCounter()
        }

        let collected = Array(values)
        let uniqueValues = Set(collected)
        XCTAssertEqual(uniqueValues.count, iterations,
                       "All \(iterations) counter values must be unique; got \(uniqueValues.count) unique out of \(iterations)")
    }

    /// Verify that concurrent nextSummaryCounter() calls never return zero
    /// (which would indicate reading before the first increment completes).
    func testNextSummaryCounterNeverReturnsZero() {
        let iterations = 500
        let values = UnsafeMutableBufferPointer<Int>.allocate(capacity: iterations)
        values.initialize(repeating: 0)
        defer { values.deallocate() }

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            values[i] = FileSession.nextSummaryCounter()
        }

        for i in 0..<iterations {
            XCTAssertGreaterThan(values[i], 0, "Counter value at index \(i) must be > 0")
        }
    }

    /// End-to-end integration: createSummarySession produces sessions with unique
    /// table names. Calls are serialized on main (matching real app usage), so this
    /// tests the naming pipeline rather than lock contention.
    func testSummarySessionCreationProducesUniqueNames() throws {
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

        let names = createdSessions.compactMap { $0.summaryTableName }
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count,
                       "All summary table names must be unique, got: \(names)")

        // Clean up
        for s in createdSessions {
            onMain { s.dropSummaryTable() }
        }
    }
}
