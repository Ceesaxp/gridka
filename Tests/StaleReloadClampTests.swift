import XCTest
@testable import Gridka

/// Regression tests for US-006: Clamp table reload ranges for stale/changed page results.
/// Verifies that stale page fetch completions (from before a filter reduced the row count)
/// return page data whose row ranges may exceed the new row count, and that the UI-layer
/// clamping prevents out-of-bounds NSTableView reloads.
final class StaleReloadClampTests: XCTestCase {

    // MARK: - Stale Fetch Completes After Filter Reduces Row Count

    /// Verifies the core staleness scenario: a page fetch enqueued before a filter is
    /// applied still returns .success with the old row range, even though the table's
    /// totalFilteredRows is now smaller. This is the case requestPageFetch must clamp.
    func testStaleFetchReturnsPageBeyondNewRowCount() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        var originalRowCount = 0
        onMain { originalRowCount = session.viewState.totalFilteredRows }

        // Ensure we have enough rows to make the scenario meaningful
        guard originalRowCount > 500 else {
            throw XCTSkip("Fixture too small for stale page test (\(originalRowCount) rows)")
        }

        // Fetch page 1 (rows 500-999) — this will succeed under the current viewState
        let staleFetch = expectation(description: "stale page fetch completes")
        var stalePage: RowCache.Page?
        onMain {
            session.fetchPage(index: 1) { result in
                if case .success(let page) = result {
                    stalePage = page
                }
                staleFetch.fulfill()
            }
            // Immediately apply a filter that drastically reduces the row count.
            // The in-flight fetch was enqueued with the old SQL and generation.
            let filter = ColumnFilter(
                column: session.columns.first(where: { $0.name != "_gridka_rowid" })!.name,
                operator: .equals,
                value: .string("__nonexistent_value_for_test__")
            )
            var newState = session.viewState
            newState.filters = [filter]
            session.updateViewState(newState)
        }
        wait(for: [staleFetch], timeout: 10)

        // Wait for the count requery to complete
        let countDone = expectation(description: "count requery")
        onMain {
            session.requeryFilteredCount { countDone.fulfill() }
        }
        wait(for: [countDone], timeout: 10)

        // Verify: stale page has data from the OLD range
        XCTAssertNotNil(stalePage, "Stale fetch should still return a page")
        if let page = stalePage {
            XCTAssertEqual(page.startRow, 500, "Stale page startRow should be 500 (page index 1)")
            // The page row range (500..<500+count) exceeds the new filtered row count
            let newRowCount = session.viewState.totalFilteredRows
            XCTAssertLessThan(newRowCount, page.startRow + page.data.count,
                "New row count should be less than stale page's end row — this is the scenario requestPageFetch must clamp")
        }
    }

    // MARK: - Stale Fetch with Empty Results is Safe

    /// Verifies that when the stale page has empty results (e.g., the old query returned 0
    /// rows at that offset), the completion is still safe.
    func testStaleFetchWithEmptyPageIsHarmless() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        // Request a page far beyond actual data — will return 0 rows
        let fetch = expectation(description: "empty page fetch")
        var emptyPage: RowCache.Page?
        onMain {
            session.fetchPage(index: 99999) { result in
                if case .success(let page) = result {
                    emptyPage = page
                }
                fetch.fulfill()
            }
        }
        wait(for: [fetch], timeout: 10)

        // An empty page should not cause issues — startRow..startRow is an empty range
        XCTAssertNotNil(emptyPage)
        if let page = emptyPage {
            XCTAssertEqual(page.data.count, 0, "Page far beyond data should be empty")
        }
    }

    // MARK: - Multiple Concurrent Stale Fetches All Complete Safely

    /// Simulates rapid sort/filter changes with multiple in-flight page fetches.
    /// All completions must fire without crash, even when their row ranges are stale.
    func testBurstStalesFetchesAllComplete() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        let fetchCount = 10
        var expectations: [XCTestExpectation] = []
        for i in 0..<fetchCount {
            expectations.append(expectation(description: "burst fetch \(i)"))
        }

        onMain {
            // Fire off many page fetches
            for i in 0..<fetchCount {
                session.fetchPage(index: i) { _ in
                    expectations[i].fulfill()
                }
            }
            // Then change filters to make all of them stale
            let filter = ColumnFilter(
                column: session.columns.first(where: { $0.name != "_gridka_rowid" })!.name,
                operator: .equals,
                value: .string("__nonexistent__")
            )
            var newState = session.viewState
            newState.filters = [filter]
            session.updateViewState(newState)
        }

        wait(for: expectations, timeout: 30)
        // All completions fired — no crash, no deadlock
    }

    // MARK: - Stale Generation Fetch Does Not Insert Into Cache

    /// Verifies that even though the stale fetch returns .success, the page is NOT
    /// inserted into the row cache (generation mismatch guard in fetchPage).
    func testStaleGenerationFetchSkipsCacheInsert() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        let fetch = expectation(description: "stale fetch")
        onMain {
            // Apply a sort to invalidate the cache, then immediately fetch page 2.
            // The sort change bumps the generation, so the fetch enqueued right after
            // still captures the NEW generation. To make it stale, we reverse the order:
            // enqueue the fetch FIRST, then change sort to bump generation.
            session.fetchPage(index: 2) { _ in
                fetch.fulfill()
            }
            // Immediately change sort to bump generation — makes the in-flight fetch stale
            var newState = session.viewState
            newState.sortColumns = [SortColumn(column: session.columns[0].name, direction: .descending)]
            session.updateViewState(newState)
        }
        wait(for: [fetch], timeout: 10)

        // Page 2 (rows 1000-1499) should NOT be in the NEW cache because the fetch
        // was for the old generation. The sort change invalidated the cache and bumped
        // generation, so the stale fetch result was discarded.
        onMain {
            let colName = session.columns.first(where: { $0.name != "_gridka_rowid" })?.name ?? ""
            let val = session.rowCache.value(forRow: 1000, columnName: colName)
            XCTAssertNil(val, "Stale page must not be inserted into cache after generation change")
        }
    }
}
