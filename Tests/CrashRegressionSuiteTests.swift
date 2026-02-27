import XCTest
@testable import Gridka

/// US-011: Crash-focused regression suite for teardown and concurrency.
///
/// Targets the crash signatures and deadlock scenarios identified by code review
/// and the 2026-02-26 crash reports:
///   1. SparklineHeaderCell.__ivar_destroyer during tab/window close (US-003)
///   2. Summary computation deadlock via main-thread sync wait (US-005)
///   3. Stale fetch completion producing invalid table reload ranges (US-006)
///   4. Concurrent summary session temp table name collision (US-010)
final class CrashRegressionSuiteTests: XCTestCase {

    // MARK: - 1. Repeated Tab Close While Sparkline Headers Are Populated

    /// Regression for crash Gridka-2026-02-26-185413, 203048, 203500, 210902.
    /// Exercises the exact shutdown sequence from AppDelegate.windowWillClose:
    /// session.shutdown() → invalidateColumnSummaries() → clearSummary() on all headers.
    /// Repeated cycles verify no use-after-free in SparklineHeaderCell.__ivar_destroyer.
    func testRepeatedTabCloseWithPopulatedSparklineHeaders() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)

        for cycle in 0..<5 {
            let session = try FileSession(filePath: url)
            try loadSessionFully(session)

            // Compute column summaries (populates session.columnSummaries)
            let summaryDone = expectation(description: "summaries cycle \(cycle)")
            onMain {
                session.onSummariesComputed = { summaryDone.fulfill() }
                session.computeColumnSummaries()
            }
            wait(for: [summaryDone], timeout: 30)

            onMain {
                // Verify summaries are populated
                XCTAssertFalse(session.columnSummaries.isEmpty,
                               "Summaries should be populated before teardown (cycle \(cycle))")

                // Create SparklineHeaderCells and populate them (simulating configureColumns)
                var cells: [SparklineHeaderCell] = []
                for (name, summary) in session.columnSummaries {
                    let cell = SparklineHeaderCell()
                    cell.stringValue = name
                    cell.columnSummary = summary
                    cells.append(cell)
                }
                XCTAssertFalse(cells.isEmpty, "Should have header cells (cycle \(cycle))")

                // === Simulate AppDelegate.windowWillClose sequence ===

                // Step 0: Mark session as shut down (US-004)
                session.shutdown()
                XCTAssertTrue(session.isShutDown)

                // Step 1: Disconnect callbacks
                session.onSummariesComputed = nil

                // Step 2: Invalidate summaries (bumps generation)
                session.invalidateColumnSummaries()

                // Step 3: Clear sparkline data from all header cells (US-003 fix)
                for cell in cells {
                    cell.clearSummary()
                    XCTAssertNil(cell.columnSummary)
                }

                // Step 4: Release cells (triggers __ivar_destroyer)
                cells.removeAll()
            }
            // Session deallocates at end of loop iteration — no crash = pass
        }
    }

    /// Regression for NSCopyObject-related crash in SparklineHeaderCell.
    /// NSTableHeaderView internally copies header cells via NSCopyObject (bitwise copy),
    /// which doesn't properly retain Swift stored properties. The copy(with:) override
    /// must prevent use-after-free when the copy is deallocated.
    func testSparklineHeaderCellCopyDeallocWithPopulatedSummary() {
        for _ in 0..<20 {
            let cell = SparklineHeaderCell()
            cell.stringValue = "Test Column"
            cell.columnSummary = ColumnSummary(
                columnName: "test",
                detectedType: .integer,
                cardinality: 100,
                nullCount: 5,
                totalRows: 1000,
                distribution: .histogram(buckets: [
                    ("0-10", 100), ("10-20", 200), ("20-30", 150),
                    ("30-40", 180), ("40-50", 120), ("50-60", 90),
                    ("60-70", 80), ("70-80", 50), ("80-90", 20), ("90-100", 10),
                ])
            )

            // Trigger NSCopyObject path (as NSTableHeaderView does internally)
            let copy = cell.copy() as! SparklineHeaderCell
            // Copy should have nil summary (safe to dealloc)
            XCTAssertNil(copy.columnSummary,
                         "Copy should have nil summary to prevent use-after-free on dealloc")
            // Original should retain its summary
            XCTAssertNotNil(cell.columnSummary,
                            "Original should still have its summary after copy")

            // Both cell and copy deallocate here — no crash = pass
        }
    }

    /// Stress test: populate → clear → re-populate → clear cycles on the same cell.
    /// Exercises the didSet observer path that snapshots _distributionSnapshot.
    func testSparklineHeaderCellRapidPopulateClearCycles() {
        let cell = SparklineHeaderCell()
        let summaries: [ColumnSummary] = [
            ColumnSummary(columnName: "int_col", detectedType: .integer, cardinality: 50,
                          nullCount: 0, totalRows: 500,
                          distribution: .histogram(buckets: [("0-50", 250), ("50-100", 250)])),
            ColumnSummary(columnName: "text_col", detectedType: .text, cardinality: 3,
                          nullCount: 10, totalRows: 500,
                          distribution: .frequency(values: [("a", 200), ("b", 180), ("c", 100)])),
            ColumnSummary(columnName: "bool_col", detectedType: .boolean, cardinality: 2,
                          nullCount: 0, totalRows: 500,
                          distribution: .boolean(trueCount: 300, falseCount: 200)),
            ColumnSummary(columnName: "high_card", detectedType: .text, cardinality: 1000,
                          nullCount: 50, totalRows: 5000,
                          distribution: .highCardinality(uniqueCount: 1000)),
        ]

        for _ in 0..<50 {
            for summary in summaries {
                cell.columnSummary = summary
                XCTAssertNotNil(cell.columnSummary)
            }
            cell.clearSummary()
            XCTAssertNil(cell.columnSummary)
        }
    }

    // MARK: - 2. Summary Computation Invalidation Without Deadlock

    /// Regression for US-005 deadlock: computeColumnSummaries dispatches work to queryQueue;
    /// the queryQueue closure used to call DispatchQueue.main.sync to read summaryGeneration.
    /// If the main thread was blocked waiting for queryQueue, this caused a deadlock.
    /// After the fix, summaryGeneration uses os_unfair_lock — no main.sync needed.
    ///
    /// This test exercises rapid compute+invalidate cycles. If the deadlock regression
    /// re-occurs, the test will hang and timeout (= failure).
    func testSummaryComputeInvalidateCyclesNoDeadlock() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        // Rapid-fire compute+invalidate cycles from main thread.
        // Each invalidate bumps summaryGeneration, causing the in-flight computation
        // (on queryQueue) to read summaryGeneration via os_unfair_lock.
        // If the old DispatchQueue.main.sync pattern were still present, this would deadlock
        // because main is busy dispatching the next cycle while queryQueue waits on main.sync.
        let cycleCount = 20
        let allDone = expectation(description: "all compute/invalidate cycles complete")

        onMain {
            for _ in 0..<cycleCount {
                session.computeColumnSummaries()
                session.invalidateColumnSummaries()
            }
            // Final compute — should succeed since no invalidation follows
            session.onSummariesComputed = {
                allDone.fulfill()
            }
            session.computeColumnSummaries()
        }

        // Tight timeout: if deadlocked, this will fail. Normal completion is < 5s.
        wait(for: [allDone], timeout: 15)

        onMain {
            XCTAssertFalse(session.columnSummaries.isEmpty,
                           "Final computation should have stored summaries")
        }
    }

    /// Verify that concurrent queryQueue reads of summaryGeneration (via os_unfair_lock)
    /// do not conflict with main-thread writes (invalidateColumnSummaries).
    /// Each round completes sequentially so the callback isn't overwritten.
    func testSummaryGenerationReadWriteNoContention() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        // Run multiple sequential rounds. Each round:
        // 1. Starts computation (queryQueue reads summaryGeneration via lock)
        // 2. Immediately invalidates (main writes summaryGeneration via lock)
        // 3. Starts fresh computation that should complete
        // If the lock is broken, we either deadlock or get stale data stored.
        for round in 0..<5 {
            let roundDone = expectation(description: "round \(round)")
            onMain {
                session.onSummariesComputed = { roundDone.fulfill() }
                session.computeColumnSummaries()
                session.invalidateColumnSummaries()
                session.computeColumnSummaries()
            }
            wait(for: [roundDone], timeout: 10)

            onMain {
                XCTAssertFalse(session.columnSummaries.isEmpty,
                               "Summaries should be present after round \(round)")
            }
        }
    }

    // MARK: - 3. Stale Fetch Completion Reload Clamping

    /// Regression for US-006: a stale page fetch returning rows beyond the current
    /// table row count must not produce an out-of-bounds NSTableView reload range.
    /// Exercises the full lifecycle: fetch → filter shrinks rows → stale completion
    /// arrives with row range > current count → clamping prevents crash.
    func testStaleFetchClampedAfterFilterReducesRows() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        var originalRowCount = 0
        onMain { originalRowCount = session.viewState.totalFilteredRows }
        guard originalRowCount > 500 else {
            throw XCTSkip("Fixture too small for stale page test (\(originalRowCount) rows)")
        }

        // Dispatch a fetch for page 1 (rows 500-999), then immediately apply a filter
        // that reduces rows to near-zero. The fetch is already queued with the old SQL.
        let fetchDone = expectation(description: "stale fetch completes")
        onMain {
            session.fetchPage(index: 1) { _ in
                fetchDone.fulfill()
            }
            // Immediately shrink row count via impossible filter
            var state = session.viewState
            state.filters = [ColumnFilter(
                column: session.columns.first(where: { $0.name != "_gridka_rowid" })!.name,
                operator: .equals,
                value: .string("__impossible_match_value__")
            )]
            session.updateViewState(state)
        }
        wait(for: [fetchDone], timeout: 10)

        // Wait for count to settle
        let countDone = expectation(description: "count settled")
        onMain {
            session.requeryFilteredCount { countDone.fulfill() }
        }
        wait(for: [countDone], timeout: 10)

        // The stale fetch completed without crash — the row range was clamped.
        onMain {
            let newCount = session.viewState.totalFilteredRows
            XCTAssertLessThan(newCount, 500,
                              "Filter should have reduced rows below the stale page's start row")
        }
    }

    /// Burst version: many concurrent stale fetches all resolve safely after filter change.
    func testBurstStaleFetchesWithFilterChange() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        let burstSize = 20
        let allDone = expectation(description: "burst stale fetches")
        allDone.expectedFulfillmentCount = burstSize

        onMain {
            for i in 0..<burstSize {
                session.fetchPage(index: i) { _ in allDone.fulfill() }
            }
            // Make all in-flight fetches stale
            var state = session.viewState
            state.sortColumns = [SortColumn(
                column: session.columns.first(where: { $0.name != "_gridka_rowid" })!.name,
                direction: .descending
            )]
            session.updateViewState(state)
        }

        wait(for: [allDone], timeout: 30)
        // All completions fired, no crash, no deadlock
    }

    // MARK: - 4. Concurrent Summary Session Creation Name Uniqueness

    /// Regression for US-010: static summaryCounter was unprotected shared mutable state.
    /// Concurrent createSummarySession calls must produce unique temp table names.
    func testConcurrentSummarySessionNamesAreUnique() throws {
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

        let sessionCount = 10
        let allCreated = expectation(description: "all summary sessions created")
        allCreated.expectedFulfillmentCount = sessionCount

        let lock = NSLock()
        var createdSessions: [FileSession] = []

        for _ in 0..<sessionCount {
            onMain {
                FileSession.createSummarySession(from: session, definition: definition) { result in
                    if case .success(let s) = result {
                        lock.lock()
                        createdSessions.append(s)
                        lock.unlock()
                    }
                    allCreated.fulfill()
                }
            }
        }

        wait(for: [allCreated], timeout: 60)

        XCTAssertEqual(createdSessions.count, sessionCount,
                       "All summary sessions should have been created successfully")

        let names = createdSessions.compactMap { $0.summaryTableName }
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count,
                       "All summary table names must be unique — got duplicates: \(names)")

        // Cleanup
        for s in createdSessions {
            onMain { s.dropSummaryTable() }
        }
    }

    /// Stress test: nextSummaryCounter() under true concurrency must return unique values.
    func testNextSummaryCounterConcurrentUniqueness() {
        let iterations = 500
        let values = UnsafeMutableBufferPointer<Int>.allocate(capacity: iterations)
        values.initialize(repeating: 0)
        defer { values.deallocate() }

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            values[i] = FileSession.nextSummaryCounter()
        }

        let collected = Set(Array(values))
        XCTAssertEqual(collected.count, iterations,
                       "All \(iterations) counter values must be unique under concurrency")
    }

    // MARK: - 5. Full Teardown Lifecycle (Integration)

    /// Integration: simulates the complete window-close lifecycle with active summaries,
    /// in-flight fetches, and sparkline headers. Exercises the full crash-prevention chain:
    /// US-003 (sparkline teardown) + US-004 (shutdown guards) + US-005 (no deadlock).
    func testFullWindowCloseLifecycleWithActiveSummariesAndFetches() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)

        for cycle in 0..<3 {
            let session = try FileSession(filePath: url)
            try loadSessionFully(session)

            // Start summary computation
            let summaryDone = expectation(description: "summaries cycle \(cycle)")
            onMain {
                session.onSummariesComputed = { summaryDone.fulfill() }
                session.computeColumnSummaries()
            }
            wait(for: [summaryDone], timeout: 30)

            // Populate sparkline headers
            var cells: [SparklineHeaderCell] = []
            onMain {
                for (name, summary) in session.columnSummaries {
                    let cell = SparklineHeaderCell()
                    cell.stringValue = name
                    cell.columnSummary = summary
                    cells.append(cell)
                }
            }

            // Start in-flight fetches (simulate scrolling)
            let fetchCount = 5
            let fetchesDone = expectation(description: "fetches cycle \(cycle)")
            fetchesDone.expectedFulfillmentCount = fetchCount
            for i in 0..<fetchCount {
                queueFetch(session, index: i) { _ in fetchesDone.fulfill() }
            }

            // === Simulate windowWillClose DURING active fetches ===
            onMain {
                // Step 0: Shutdown session
                session.shutdown()

                // Step 1: Disconnect callbacks
                session.onSummariesComputed = nil

                // Step 2: Invalidate summaries
                session.invalidateColumnSummaries()

                // Step 3: Clear sparkline headers
                for cell in cells {
                    cell.clearSummary()
                }
                cells.removeAll()
            }

            // In-flight fetches must still complete (for bookkeeping)
            wait(for: [fetchesDone], timeout: 15)
            // No crash, no deadlock = pass
        }
    }
}
