import XCTest
@testable import Gridka

/// Regression tests for US-004: FileSession shutdown guards.
/// Verifies that after calling shutdown(), async query completions still fire
/// (for bookkeeping) but do not mutate main-thread session state.
final class FileSessionShutdownTests: XCTestCase {

    // MARK: - Shutdown Flag

    func testShutdownSetsFlag() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        onMain {
            XCTAssertFalse(session.isShutDown)
            session.shutdown()
            XCTAssertTrue(session.isShutDown)
        }
    }

    func testFetchPageSkipsCacheInsertAfterShutdown() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        // Shutdown, then fetch page 5 (which won't be cached yet).
        // The fetch should complete but page 5 must NOT be inserted into the cache.
        let done = expectation(description: "post-shutdown fetch")
        onMain {
            session.shutdown()
            session.fetchPage(index: 5) { _ in
                // After completion: try to read a row from page 5.
                // Page 5 starts at row 2500 (pageSize=500). If inserted, we'd get data.
                let colName = session.columns.first(where: { $0.name != "_gridka_rowid" })?.name ?? ""
                let val = session.rowCache.value(forRow: 2500, columnName: colName)
                XCTAssertNil(val, "Cache must not contain pages inserted after shutdown")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
    }

    // MARK: - Completions Still Fire (AC-3)

    func testFetchPageCompletionFiresAfterShutdown() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        let done = expectation(description: "fetch completes after shutdown")
        onMain {
            session.shutdown()
            session.fetchPage(index: 0) { result in
                // Completion MUST fire regardless of shutdown state (AC-3)
                switch result {
                case .success:
                    break // OK: page data is still valid
                case .failure:
                    break // Also OK: session may report "shut down"
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
    }

    func testRequeryCountCompletionFiresAfterShutdown() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        let done = expectation(description: "requery completes after shutdown")
        onMain {
            let rowsBefore = session.viewState.totalFilteredRows
            session.shutdown()
            session.requeryFilteredCount {
                // Completion fires but totalFilteredRows should not change
                XCTAssertEqual(session.viewState.totalFilteredRows, rowsBefore,
                               "totalFilteredRows must not mutate after shutdown")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
    }

    // MARK: - State Not Mutated After Shutdown (AC-2)

    func testLoadFullDoesNotMutateAfterShutdown() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)

        // Load preview first (puts session in preview state)
        let previewDone = expectation(description: "preview loaded")
        onMain {
            session.loadPreview { _ in previewDone.fulfill() }
        }
        wait(for: [previewDone], timeout: 10)

        // Shutdown before full load completes
        let loadDone = expectation(description: "loadFull completes")
        onMain {
            session.shutdown()
            session.loadFull(progress: { _ in }) { result in
                // Completion fires with the dedicated cancellation error
                if case .failure(let error) = result,
                   let gridkaError = error as? GridkaError,
                   case .sessionShutDown = gridkaError {
                    // Expected: clean cancellation, not a user-visible error
                } else if case .success = result {
                    XCTFail("loadFull should not succeed after shutdown")
                }
                loadDone.fulfill()
            }
        }
        wait(for: [loadDone], timeout: 30)

        // isFullyLoaded should NOT have been set to true by the shut-down loadFull
        onMain {
            XCTAssertFalse(session.isFullyLoaded,
                           "isFullyLoaded must not be set after shutdown")
        }
    }

    func testAddRowDoesNotMutateAfterShutdown() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        var totalRowsBefore = 0
        onMain { totalRowsBefore = session.totalRows }

        let done = expectation(description: "addRow completes after shutdown")
        onMain {
            session.shutdown()
            session.addRow { result in
                if case .failure(let error) = result,
                   let gridkaError = error as? GridkaError,
                   case .sessionShutDown = gridkaError {
                    // Expected: clean cancellation
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)

        onMain {
            XCTAssertEqual(session.totalRows, totalRowsBefore,
                           "totalRows must not change after shutdown")
            XCTAssertFalse(session.isModified,
                           "isModified must not be set after shutdown")
        }
    }

    func testUpdateCellDoesNotMutateAfterShutdown() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        var columns: [ColumnDescriptor] = []
        onMain { columns = session.columns.filter { $0.name != "_gridka_rowid" } }
        guard let colName = columns.first?.name else {
            throw XCTSkip("No columns available")
        }

        let done = expectation(description: "updateCell completes after shutdown")
        onMain {
            session.shutdown()
            session.updateCell(rowid: 1, column: colName, value: "test", displayRow: 0) { result in
                if case .failure(let error) = result,
                   let gridkaError = error as? GridkaError,
                   case .sessionShutDown = gridkaError {
                    // Expected: clean cancellation
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)

        onMain {
            XCTAssertFalse(session.isModified,
                           "isModified must not be set after shutdown")
            XCTAssertTrue(session.editedCells.isEmpty,
                          "editedCells must not be populated after shutdown")
        }
    }

    // MARK: - Burst Operations During Shutdown

    func testBurstFetchesDuringShutdownAllComplete() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        let fetchCount = 30
        let done = expectation(description: "all burst fetches complete")
        done.expectedFulfillmentCount = fetchCount

        onMain {
            // Dispatch a burst of fetches, then immediately shutdown
            for i in 0..<fetchCount {
                session.fetchPage(index: i % 10) { _ in
                    done.fulfill()
                }
            }
            session.shutdown()
        }

        wait(for: [done], timeout: 30)
        // All completions must have fired — if not, the test times out
    }

    func testSummaryComputationDiscardedAfterShutdown() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        // Start summary computation then immediately shutdown
        let settling = expectation(description: "settling")
        onMain {
            session.computeColumnSummaries()
            session.shutdown()

            // Give queryQueue time to complete the computation
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                settling.fulfill()
            }
        }

        wait(for: [settling], timeout: 10)

        onMain {
            XCTAssertTrue(session.columnSummaries.isEmpty,
                          "Summaries must not be stored after shutdown")
        }
    }

    func testShutdownIsIdempotent() throws {
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        onMain {
            session.shutdown()
            // Second call should not crash or change state
            session.shutdown()
            XCTAssertTrue(session.isShutDown)
        }
    }
}
