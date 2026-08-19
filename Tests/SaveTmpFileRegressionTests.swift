import XCTest
@testable import Gridka

/// Regression tests for saving into a directory the app cannot write to.
///
/// DuckDB's `COPY ... TO 'file'` defaults to writing a sibling `tmp_<name>` file
/// and renaming it over the target. Under the App Sandbox the app only holds an
/// extension for the file the user picked — not for its directory — so that
/// sibling write fails with "IO Error: Cannot open file .../tmp_x.csv:
/// Operation not permitted", breaking both Save and Save As.
///
/// A directory with the write bit cleared reproduces the same failure outside the
/// sandbox: overwriting an existing file still works, creating a new one does not.
final class SaveTmpFileRegressionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gridka-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            // Restore write permission so the directory can be removed.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeLoadedSession(named name: String) throws -> (FileSession, URL) {
        let url = directory.appendingPathComponent(name)
        try "id,label\n1,alpha\n2,beta\n".write(to: url, atomically: true, encoding: .utf8)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)
        return (session, url)
    }

    private func lockDirectory() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    }

    func testSaveOverwritesInPlaceWithoutSiblingTempFile() throws {
        let (session, url) = try makeLoadedSession(named: "data.csv")
        try lockDirectory()

        let done = expectation(description: "save")
        var saveError: Error?
        onMain {
            session.save { result in
                if case .failure(let error) = result { saveError = error }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 60)

        XCTAssertNil(saveError, "save must write straight to the target file, not a sibling temp file")
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("alpha"), "saved file should still hold the data: \(written)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("tmp_data.csv").path),
            "no tmp_ sibling should be left behind"
        )
    }

    func testSaveAsOverwritesAnExistingFileInPlace() throws {
        let (session, _) = try makeLoadedSession(named: "source.csv")
        // Save As over a file that already exists — the case that prompts the
        // "already exists, replace?" confirmation and then used to fail.
        let target = directory.appendingPathComponent("target.csv")
        try "stale\n".write(to: target, atomically: true, encoding: .utf8)
        try lockDirectory()

        let done = expectation(description: "saveAs")
        var saveError: Error?
        onMain {
            session.saveAs(to: target, encoding: .utf8, delimiter: ",") { result in
                if case .failure(let error) = result { saveError = error }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 60)

        XCTAssertNil(saveError, "saveAs must write straight to the chosen file, not a sibling temp file")
        let written = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(written.contains("beta"), "target should hold the exported data: \(written)")
    }
}
