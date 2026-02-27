import XCTest
@testable import Gridka

// MARK: - Fixture Path Resolution

/// Resolves fixture paths relative to the repo root, derived from #filePath.
/// Works regardless of where the repo is cloned.
enum TestFixtures {
    /// Root of the Tests/ directory.
    private static let testsDir: String = {
        // #filePath → .../Tests/GridkaTestHelpers.swift
        (URL(fileURLWithPath: #filePath).deletingLastPathComponent().path)
    }()

    /// Root of the repository (one level above Tests/).
    private static let repoRoot: String = {
        URL(fileURLWithPath: testsDir).deletingLastPathComponent().path
    }()

    // -- Tests/ fixtures --
    static let largeCsv        = testsDir + "/large.csv"
    static let forexCsv        = testsDir + "/12data_forex.csv"
    static let cbCompaniesCsv  = testsDir + "/cb-companies.csv"
    static let headerlessCsv   = testsDir + "/headerless.csv"

    // -- scripts/screenshots/data/ fixtures --
    static let sensorTelemetryCsv = repoRoot + "/scripts/screenshots/data/sensor_telemetry.csv"
}

// MARK: - Shared XCTestCase Helpers

extension XCTestCase {

    /// Returns the file URL if the fixture exists, otherwise throws XCTSkip.
    func requireFixture(at path: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Missing test fixture: \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    /// Dispatches a block on the main thread (synchronously if already there).
    func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// Loads a FileSession fully and waits for completion. Throws on failure.
    func loadSessionFully(_ session: FileSession, timeout: TimeInterval = 180) throws {
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
        if let loadError { throw loadError }
    }

    /// Queues a page fetch on the main thread (FileSession requires main-thread calls).
    func queueFetch(_ session: FileSession, index: Int, completion: @escaping (Result<RowCache.Page, Error>) -> Void) {
        onMain {
            session.fetchPage(index: index, completion: completion)
        }
    }

    /// Queues a ViewState mutation on the main thread.
    func queueStateMutation(_ session: FileSession, mutation: @escaping (inout ViewState) -> Void) {
        onMain {
            var state = session.viewState
            mutation(&state)
            session.updateViewState(state)
        }
    }
}
