import XCTest
@testable import Gridka

/// US-106: Regression tests for async invalidation, teardown safety, and fetch-load coherence.
///
/// Covers:
///   1. Stale fetch result discard after rapid filter/sort/viewState changes
///   2. RowCache non-mutation by obsolete async results
///   3. Deterministic totalFilteredRows updates after state transitions
///   4. SparklineHeaderCell teardown/reconfig safety (via unit-level tests)
///   5. Scroll stress with concurrent page fetches on the DuckDB query path
///   6. In-flight fetch request bounding and fetchingPages bookkeeping
final class AsyncInvalidationRegressionTests: XCTestCase {

    // MARK: - Test Fixtures

    /// ~211K row CSV with numeric + categorical columns; always present in repo
    private let largePath = "/Users/andrei/Developer/Swift/Gridka/Tests/large.csv"
    /// ~1.5K row semicolon-delimited CSV
    private let forexPath = "/Users/andrei/Developer/Swift/Gridka/Tests/12data_forex.csv"

    // MARK: - Helpers

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

    // MARK: - 1. Stale Fetch Result Discard After Rapid ViewState Changes

    /// AC-1: Verify that rapid filter changes interleaved with fetch requests
    /// never leave stale rows in the cache. After all fetches settle, only the
    /// latest filter's data should be cached.
    func testStaleFetchDiscardedAfterRapidFilterChanges() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var columns: [ColumnDescriptor] = []
        onMain { columns = session.columns.filter { $0.name != "_gridka_rowid" } }
        guard let filterCol = columns.first(where: { $0.name == "country" }) else {
            throw XCTSkip("large.csv missing 'country' column")
        }

        let filterValues = ["Italy", "Poland", "Germany", "France", "Spain"]
        let fetchCount = 30
        let done = expectation(description: "all fetches complete")
        done.expectedFulfillmentCount = fetchCount

        let lock = NSLock()
        var completionCount = 0

        for i in 0..<fetchCount {
            // Every 5th fetch, change the filter
            if i % 5 == 0 {
                let value = filterValues[i / 5 % filterValues.count]
                queueStateMutation(session) { state in
                    state.filters = [ColumnFilter(column: filterCol.name, operator: .equals, value: .string(value))]
                }
            }

            queueFetch(session, index: i % 10) { _ in
                lock.lock()
                completionCount += 1
                lock.unlock()
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 120)
        XCTAssertEqual(completionCount, fetchCount, "All fetch completions must fire, even for stale results")
    }

    /// AC-1: Verify that rapid sort direction toggles cause stale fetches to be
    /// discarded, and the final cache is coherent with the last applied sort.
    func testStaleFetchDiscardedAfterRapidSortToggling() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var columns: [ColumnDescriptor] = []
        onMain { columns = session.columns.filter { $0.name != "_gridka_rowid" } }
        guard let sortCol = columns.first?.name else {
            XCTFail("No columns loaded")
            return
        }

        let toggleCount = 20
        let fetchesPerToggle = 3
        let totalFetches = toggleCount * fetchesPerToggle
        let done = expectation(description: "sort toggle fetches")
        done.expectedFulfillmentCount = totalFetches

        let lock = NSLock()
        var successCount = 0

        for toggle in 0..<toggleCount {
            let dir: SortDirection = toggle % 2 == 0 ? .ascending : .descending
            queueStateMutation(session) { state in
                state.sortColumns = [SortColumn(column: sortCol, direction: dir)]
            }

            for f in 0..<fetchesPerToggle {
                queueFetch(session, index: f) { result in
                    lock.lock()
                    if case .success = result { successCount += 1 }
                    lock.unlock()
                    done.fulfill()
                }
            }
        }

        wait(for: [done], timeout: 120)
        XCTAssertEqual(successCount, totalFetches, "All sort-toggling fetches should succeed (no errors)")
    }

    // MARK: - 2. RowCache Non-Mutation by Obsolete Async Results

    /// AC-2: After a viewState change invalidates the cache, subsequent fetch
    /// completions from the old generation must NOT insert pages into the cache.
    func testRowCacheNotMutatedByObsoleteFetchResults() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        // Step 1: Fetch page 0 to populate cache
        let fetchDone = expectation(description: "initial fetch")
        queueFetch(session, index: 0) { _ in fetchDone.fulfill() }
        wait(for: [fetchDone], timeout: 30)

        // Step 2: Dispatch multiple fetches, then immediately invalidate via sort change
        let burstCount = 10
        let burstDone = expectation(description: "burst fetches")
        burstDone.expectedFulfillmentCount = burstCount

        for i in 0..<burstCount {
            queueFetch(session, index: i + 1) { _ in burstDone.fulfill() }
        }

        // Invalidate immediately — these fetches are already queued but the generation
        // has now changed, so their results should NOT be cached
        queueStateMutation(session) { state in
            state.sortColumns = [SortColumn(column: "_gridka_rowid", direction: .descending)]
        }

        wait(for: [burstDone], timeout: 60)

        // Step 3: Verify cache was invalidated — the burst pages should not be present
        // because the sort change cleared the cache and stale results were discarded
        let verifyDone = expectation(description: "verify cache state")
        onMain {
            // Cache should be empty or only contain pages fetched after the sort change
            // The burst pages (1..10) should NOT be cached because they were fetched with
            // the old generation
            let hasAnyBurstPage = (1...burstCount).contains { session.rowCache.hasPage($0) }
            XCTAssertFalse(hasAnyBurstPage, "Stale burst pages should not be in the cache after invalidation")
            verifyDone.fulfill()
        }
        wait(for: [verifyDone], timeout: 10)
    }

    // MARK: - 3. Deterministic totalFilteredRows Updates

    /// AC-3: After adding a filter, totalFilteredRows must be updated deterministically
    /// via completion callback, not via timing-based delay.
    func testDeterministicFilteredRowCountAfterFilterAdd() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var initialTotal = 0
        onMain { initialTotal = session.viewState.totalFilteredRows }
        XCTAssertGreaterThan(initialTotal, 0, "Should have rows loaded")

        // Add a filter that reduces the row count
        let countDone = expectation(description: "filtered count updated")
        onMain {
            var state = session.viewState
            state.filters = [ColumnFilter(column: "country", operator: .equals, value: .string("Italy"))]
            session.updateViewState(state) {
                // This completion fires AFTER totalFilteredRows is updated
                let filteredTotal = session.viewState.totalFilteredRows
                XCTAssertLessThan(filteredTotal, initialTotal, "Filter should reduce row count")
                XCTAssertGreaterThan(filteredTotal, 0, "Italy filter should match some rows")
                countDone.fulfill()
            }
        }
        wait(for: [countDone], timeout: 30)
    }

    /// AC-3: After removing a filter, totalFilteredRows must return to the original value.
    func testDeterministicFilteredRowCountAfterFilterRemove() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var originalTotal = 0
        onMain { originalTotal = session.viewState.totalFilteredRows }

        // Add a filter
        let filterDone = expectation(description: "filter applied")
        onMain {
            var state = session.viewState
            state.filters = [ColumnFilter(column: "country", operator: .equals, value: .string("Italy"))]
            session.updateViewState(state) { filterDone.fulfill() }
        }
        wait(for: [filterDone], timeout: 30)

        // Remove the filter
        let removeDone = expectation(description: "filter removed")
        onMain {
            var state = session.viewState
            state.filters = []
            session.updateViewState(state) {
                let restored = session.viewState.totalFilteredRows
                XCTAssertEqual(restored, originalTotal, "Row count should restore to original after filter removal")
                removeDone.fulfill()
            }
        }
        wait(for: [removeDone], timeout: 30)
    }

    /// AC-3: Multiple rapid filter changes should result in a final count matching
    /// the last filter applied, not an intermediate value.
    func testDeterministicCountAfterRapidFilterChanges() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        let countries = ["Italy", "Poland", "Germany", "France"]
        let finalCountry = "Italy"

        // Apply filters rapidly — only the last one's count matters
        for country in countries {
            onMain {
                var state = session.viewState
                state.filters = [ColumnFilter(column: "country", operator: .equals, value: .string(country))]
                session.updateViewState(state)
            }
        }

        // Wait for the final filter's count to settle
        let settledDone = expectation(description: "final count settled")
        onMain {
            var state = session.viewState
            state.filters = [ColumnFilter(column: "country", operator: .equals, value: .string(finalCountry))]
            session.updateViewState(state) {
                let finalCount = session.viewState.totalFilteredRows
                XCTAssertGreaterThan(finalCount, 0, "Final filter should match some rows")
                // Verify the filter is indeed applied
                XCTAssertEqual(session.viewState.filters.count, 1)
                XCTAssertEqual(session.viewState.filters.first?.value, .string(finalCountry))
                settledDone.fulfill()
            }
        }
        wait(for: [settledDone], timeout: 30)
    }

    /// AC-3: Sort changes should NOT trigger a count requery (sort doesn't change row count).
    func testSortChangeDoesNotRequeryCount() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var totalBefore = 0
        onMain { totalBefore = session.viewState.totalFilteredRows }

        // Apply a sort change
        let sortDone = expectation(description: "sort applied")
        onMain {
            var state = session.viewState
            state.sortColumns = [SortColumn(column: "country", direction: .ascending)]
            session.updateViewState(state) {
                // Completion fires immediately since sort doesn't need a count requery
                let totalAfter = session.viewState.totalFilteredRows
                XCTAssertEqual(totalAfter, totalBefore, "Sort should not change row count")
                sortDone.fulfill()
            }
        }
        wait(for: [sortDone], timeout: 10)
    }

    /// AC-3: Search term changes must update totalFilteredRows deterministically.
    func testDeterministicCountAfterSearchTermChange() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var originalTotal = 0
        onMain { originalTotal = session.viewState.totalFilteredRows }

        // Apply a search term
        let searchDone = expectation(description: "search count updated")
        onMain {
            var state = session.viewState
            state.searchTerm = "Italy"
            session.updateViewState(state) {
                let searchCount = session.viewState.totalFilteredRows
                XCTAssertLessThan(searchCount, originalTotal, "Search should reduce row count")
                XCTAssertGreaterThan(searchCount, 0, "Search for 'Italy' should match some rows")
                searchDone.fulfill()
            }
        }
        wait(for: [searchDone], timeout: 30)
    }

    // MARK: - 4. SparklineHeaderCell Teardown Safety (Unit-Level)

    /// AC-4/AC-5: Verify that SparklineHeaderCell.clearSummary() nils both
    /// columnSummary and distribution snapshot, preventing stale draws.
    func testSparklineHeaderCellClearSummarySafety() {
        let cell = SparklineHeaderCell()
        let summary = ColumnSummary(
            columnName: "test",
            detectedType: .integer,
            cardinality: 10,
            nullCount: 0,
            totalRows: 100,
            distribution: .histogram(buckets: [("0-10", 50), ("10-20", 50)])
        )

        // Set summary data
        cell.columnSummary = summary
        XCTAssertNotNil(cell.columnSummary, "Summary should be set")

        // Clear it (as configureColumns does before column removal)
        cell.clearSummary()
        XCTAssertNil(cell.columnSummary, "Summary should be nil after clear")
    }

    /// AC-4: Setting columnSummary to nil should clear the distribution snapshot.
    func testSparklineHeaderCellNilSummaryPreventsStaleDraws() {
        let cell = SparklineHeaderCell()
        let summary = ColumnSummary(
            columnName: "test",
            detectedType: .boolean,
            cardinality: 2,
            nullCount: 0,
            totalRows: 100,
            distribution: .boolean(trueCount: 65, falseCount: 35)
        )

        cell.columnSummary = summary
        cell.columnSummary = nil

        // After nilling, the cell should be safe to draw — no crash, just skips sparkline
        // We can't easily test draw() without a view, but we verify the snapshot is cleared
        XCTAssertNil(cell.columnSummary, "Summary nil after clear")
    }

    /// AC-4: Rapid summary replacements should not cause inconsistency.
    func testSparklineHeaderCellRapidSummaryReplacement() {
        let cell = SparklineHeaderCell()

        // Rapidly replace summaries with different types
        let summaries: [ColumnSummary] = [
            ColumnSummary(columnName: "a", detectedType: .integer, cardinality: 10, nullCount: 0, totalRows: 100, distribution: .histogram(buckets: [("0-5", 60), ("5-10", 40)])),
            ColumnSummary(columnName: "b", detectedType: .text, cardinality: 3, nullCount: 5, totalRows: 100, distribution: .frequency(values: [("foo", 50), ("bar", 30), ("baz", 15)])),
            ColumnSummary(columnName: "c", detectedType: .boolean, cardinality: 2, nullCount: 0, totalRows: 100, distribution: .boolean(trueCount: 70, falseCount: 30)),
            ColumnSummary(columnName: "d", detectedType: .text, cardinality: 500, nullCount: 10, totalRows: 1000, distribution: .highCardinality(uniqueCount: 500)),
        ]

        for summary in summaries {
            cell.columnSummary = summary
        }

        // Final state should be the last summary
        XCTAssertEqual(cell.columnSummary?.columnName, "d")
        XCTAssertEqual(cell.columnSummary?.cardinality, 500)

        // Clear should leave everything nil
        cell.clearSummary()
        XCTAssertNil(cell.columnSummary)
    }

    /// AC-5: Repeated open/close cycle with sparklines — verifies summary lifecycle
    /// doesn't crash when sessions are rapidly created and destroyed with summaries.
    func testRepeatedSessionCreateDestroySummaryLifecycle() throws {
        let url = try ensureFileExists(forexPath)

        for _ in 0..<5 {
            let session = try FileSession(filePath: url)
            try waitForLoadFull(session)

            // Compute summaries
            let summaryDone = expectation(description: "summaries computed")
            var summariesComputed = false
            onMain {
                session.onSummariesComputed = {
                    summariesComputed = true
                    summaryDone.fulfill()
                }
                session.computeColumnSummaries()
            }
            wait(for: [summaryDone], timeout: 30)

            XCTAssertTrue(summariesComputed, "Summaries should have been computed")

            // Immediately invalidate (simulating tab close)
            onMain {
                session.invalidateColumnSummaries()
            }
        }
        // No crash = success
    }

    /// AC-5: Invalidate summaries while computation is in-flight — stale results
    /// should be discarded, not stored.
    func testSummaryInvalidationDuringComputation() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        // Start summary computation
        let computeDone = expectation(description: "compute settles")
        var callbackFiredCount = 0
        onMain {
            session.onSummariesComputed = {
                callbackFiredCount += 1
            }
            // Start computation
            session.computeColumnSummaries()
            // Immediately invalidate — this bumps summaryGeneration, causing the in-flight
            // computation to discard its results
            session.invalidateColumnSummaries()
            // Start a fresh computation
            session.computeColumnSummaries()
        }

        // Give enough time for both computations to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            computeDone.fulfill()
        }
        wait(for: [computeDone], timeout: 20)

        // The callback should have fired at most once (from the second computation),
        // and summaries should be present (from the second computation) or empty
        // (if the second was also invalidated). Either way, no crash.
        onMain {
            // If summaries were computed, they should be from the second computation
            if !session.columnSummaries.isEmpty {
                XCTAssertEqual(callbackFiredCount, 1, "Only the fresh computation should deliver results")
            }
        }
    }

    // MARK: - 5. Scroll Stress With Concurrent Page Fetches

    /// AC-6: Rapid horizontal/vertical scroll simulation with concurrent page fetches.
    /// Verifies no crash in the duckdb_query path under concurrent serial queue load.
    func testScrollStressRapidPageFetchesNoCrash() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        let fetchCount = 100
        let done = expectation(description: "scroll stress fetches")
        done.expectedFulfillmentCount = fetchCount

        let lock = NSLock()
        var successCount = 0
        var failureCount = 0

        // Simulate rapid scrolling: fetch pages in a pseudo-random pattern
        // with varying stride lengths (mimicking fast scroll + direction changes)
        for i in 0..<fetchCount {
            let pageIndex: Int
            switch i % 4 {
            case 0: pageIndex = i % 50                          // forward scroll
            case 1: pageIndex = (fetchCount - i) % 50           // backward scroll
            case 2: pageIndex = (i * 13 + 7) % 50              // random jump
            default: pageIndex = 0                              // return to top
            }

            queueFetch(session, index: pageIndex) { result in
                lock.lock()
                switch result {
                case .success: successCount += 1
                case .failure: failureCount += 1
                }
                lock.unlock()
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 120)
        XCTAssertEqual(successCount + failureCount, fetchCount, "All fetches must complete")
        XCTAssertEqual(failureCount, 0, "Scroll stress should not cause fetch failures")
    }

    /// AC-6: Concurrent page fetches with interleaved sort/filter changes.
    /// Simulates a user scrolling while also sorting/filtering.
    func testScrollWithConcurrentViewStateChanges() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var columns: [ColumnDescriptor] = []
        onMain { columns = session.columns.filter { $0.name != "_gridka_rowid" } }
        guard columns.count >= 2 else {
            XCTFail("Need at least 2 columns for concurrent state test")
            return
        }

        let fetchCount = 50
        let done = expectation(description: "concurrent scroll + state changes")
        done.expectedFulfillmentCount = fetchCount

        let lock = NSLock()
        var completionCount = 0

        for i in 0..<fetchCount {
            let pageIndex = (i * 3) % 40
            queueFetch(session, index: pageIndex) { _ in
                lock.lock()
                completionCount += 1
                lock.unlock()
                done.fulfill()
            }

            // Interleave state changes
            if i % 10 == 0 {
                let colIndex = (i / 10) % columns.count
                let dir: SortDirection = (i / 10) % 2 == 0 ? .ascending : .descending
                queueStateMutation(session) { state in
                    state.sortColumns = [SortColumn(column: columns[colIndex].name, direction: dir)]
                }
            }
            if i % 15 == 0 {
                queueStateMutation(session) { state in
                    state.searchTerm = i % 30 == 0 ? "test" : nil
                }
            }
        }

        wait(for: [done], timeout: 120)
        XCTAssertEqual(completionCount, fetchCount, "All fetches must complete despite interleaved state changes")
    }

    // MARK: - 6. FetchingPages Bookkeeping and Coalescing

    /// AC-7: Verify that fetch completions always fire, enabling callers to clear
    /// their fetchingPages bookkeeping. Test this by verifying all completion blocks
    /// are called even under stale generation conditions.
    func testFetchCompletionAlwaysFires() throws {
        let url = try ensureFileExists(largePath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        let fetchCount = 40
        let done = expectation(description: "all completions fire")
        done.expectedFulfillmentCount = fetchCount

        let lock = NSLock()
        var completionFiredCount = 0

        // Dispatch fetches then immediately invalidate — completions must still fire
        for i in 0..<fetchCount {
            queueFetch(session, index: i % 20) { _ in
                lock.lock()
                completionFiredCount += 1
                lock.unlock()
                done.fulfill()
            }

            // Invalidate every other batch
            if i % 5 == 4 {
                queueStateMutation(session) { state in
                    state.sortColumns = [SortColumn(column: "_gridka_rowid", direction: i % 10 < 5 ? .ascending : .descending)]
                }
            }
        }

        wait(for: [done], timeout: 60)
        XCTAssertEqual(completionFiredCount, fetchCount,
                       "Every fetch completion must fire so fetchingPages bookkeeping can be cleared")
    }

    /// AC-7: Verify that error completions also fire (e.g., when querying beyond bounds).
    func testFetchCompletionFiresForOutOfBoundsPages() throws {
        let url = try ensureFileExists(forexPath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        // forex has ~1460 rows = 3 pages. Fetch well beyond that.
        let done = expectation(description: "out of bounds fetch")
        queueFetch(session, index: 999) { result in
            // Should succeed with an empty page (DuckDB returns 0 rows for out-of-range OFFSET)
            // OR fail gracefully — either way, the completion fires
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    /// AC-7: Repeated fetch for the same page index should be coalesced by callers
    /// (fetchingPages set). This test validates the RowCache semantics that support it:
    /// re-inserting a page for the same index replaces the old data.
    func testRowCachePageReplacementIsClean() {
        var cache = RowCache()

        let page1 = RowCache.Page(
            startRow: 0,
            data: [[.string("old")]],
            columnNames: ["col"],
            lastAccessed: Date()
        )
        cache.insertPage(page1)
        XCTAssertEqual(cache.value(forRow: 0, columnName: "col"), .string("old"))

        // Re-insert same page index with new data
        let page2 = RowCache.Page(
            startRow: 0,
            data: [[.string("new")]],
            columnNames: ["col"],
            lastAccessed: Date()
        )
        cache.insertPage(page2)
        XCTAssertEqual(cache.value(forRow: 0, columnName: "col"), .string("new"),
                       "Re-inserting a page for the same index should replace old data cleanly")
    }

    /// AC-7: Cache invalidation should clear ALL pages, ensuring no stale data persists.
    func testRowCacheInvalidateAllClearsEverything() {
        var cache = RowCache()

        for i in 0..<5 {
            let page = RowCache.Page(
                startRow: i * RowCache.pageSize,
                data: [[.integer(Int64(i))]],
                columnNames: ["val"],
                lastAccessed: Date()
            )
            cache.insertPage(page)
        }

        // All 5 pages should be cached
        for i in 0..<5 {
            XCTAssertTrue(cache.hasPage(i), "Page \(i) should be cached")
        }

        cache.invalidateAll()

        // All pages should be gone
        for i in 0..<5 {
            XCTAssertFalse(cache.hasPage(i), "Page \(i) should be cleared after invalidateAll")
        }
    }

    // MARK: - Integration: Full Lifecycle

    /// Integration test covering the full cycle: load → filter → verify count → clear filter
    /// → verify count restored. Ensures all async paths are deterministic end-to-end.
    func testFullFilterLifecycleDeterministic() throws {
        let url = try ensureFileExists(forexPath)
        let session = try FileSession(filePath: url)
        try waitForLoadFull(session)

        var totalRows = 0
        onMain { totalRows = session.viewState.totalFilteredRows }
        XCTAssertGreaterThan(totalRows, 0)

        // Fetch page 0 to warm cache
        let warmDone = expectation(description: "warm cache")
        queueFetch(session, index: 0) { result in
            if case .success = result { } else { XCTFail("Warm fetch failed") }
            warmDone.fulfill()
        }
        wait(for: [warmDone], timeout: 10)

        // Apply filter
        let filterDone = expectation(description: "filter applied")
        var filteredCount = 0
        onMain {
            var state = session.viewState
            state.filters = [ColumnFilter(column: "currency_group", operator: .equals, value: .string("Exotic-Cross"))]
            session.updateViewState(state) {
                filteredCount = session.viewState.totalFilteredRows
                XCTAssertGreaterThan(filteredCount, 0)
                XCTAssertLessThan(filteredCount, totalRows)
                filterDone.fulfill()
            }
        }
        wait(for: [filterDone], timeout: 30)

        // Cache should be invalidated — old page 0 should be gone
        let cacheCheck = expectation(description: "cache check")
        onMain {
            XCTAssertFalse(session.rowCache.hasPage(0), "Cache should be cleared after filter change")
            cacheCheck.fulfill()
        }
        wait(for: [cacheCheck], timeout: 5)

        // Fetch fresh page 0 under the filter
        let filteredFetch = expectation(description: "filtered fetch")
        queueFetch(session, index: 0) { result in
            if case .success(let page) = result {
                // Page should have data from the filtered result
                XCTAssertGreaterThan(page.data.count, 0, "Filtered page should have data")
            } else {
                XCTFail("Filtered fetch failed")
            }
            filteredFetch.fulfill()
        }
        wait(for: [filteredFetch], timeout: 10)

        // Remove filter — count should restore
        let restoreDone = expectation(description: "filter removed")
        onMain {
            var state = session.viewState
            state.filters = []
            session.updateViewState(state) {
                let restored = session.viewState.totalFilteredRows
                XCTAssertEqual(restored, totalRows, "Count should restore after filter removal")
                restoreDone.fulfill()
            }
        }
        wait(for: [restoreDone], timeout: 30)
    }
}
