import XCTest
@testable import Gridka

/// Tests that DuckDBResult accessors safely handle out-of-bounds
/// and negative indices without crashing via C-API conversions.
final class DuckDBResultBoundsTests: XCTestCase {

    private var engine: DuckDBEngine!

    override func setUpWithError() throws {
        engine = try DuckDBEngine()
    }

    override func tearDown() {
        engine = nil
    }

    // MARK: - Helper

    /// Returns a result with known dimensions: 3 rows, 2 columns (id INTEGER, name VARCHAR).
    private func makeResult() throws -> DuckDBResult {
        try engine.execute("CREATE TABLE bounds_test (id INTEGER, name VARCHAR)")
        try engine.execute("INSERT INTO bounds_test VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma')")
        return try engine.execute("SELECT id, name FROM bounds_test")
    }

    /// Returns a result with zero rows and 2 columns.
    private func makeEmptyResult() throws -> DuckDBResult {
        try engine.execute("CREATE TABLE IF NOT EXISTS bounds_empty (id INTEGER, name VARCHAR)")
        return try engine.execute("SELECT id, name FROM bounds_empty")
    }

    // MARK: - columnName bounds

    func testColumnNameNegativeIndex() throws {
        let result = try makeResult()
        XCTAssertEqual(result.columnName(at: -1), "")
    }

    func testColumnNameOutOfRange() throws {
        let result = try makeResult()
        XCTAssertEqual(result.columnCount, 2)
        XCTAssertEqual(result.columnName(at: 2), "")
        XCTAssertEqual(result.columnName(at: 100), "")
    }

    func testColumnNameValidIndices() throws {
        let result = try makeResult()
        XCTAssertEqual(result.columnName(at: 0), "id")
        XCTAssertEqual(result.columnName(at: 1), "name")
    }

    // MARK: - columnType bounds

    func testColumnTypeNegativeIndex() throws {
        let result = try makeResult()
        XCTAssertEqual(result.columnType(at: -1), .unknown)
    }

    func testColumnTypeOutOfRange() throws {
        let result = try makeResult()
        XCTAssertEqual(result.columnType(at: 2), .unknown)
        XCTAssertEqual(result.columnType(at: 999), .unknown)
    }

    func testColumnTypeValidIndices() throws {
        let result = try makeResult()
        XCTAssertEqual(result.columnType(at: 0), .integer)
        XCTAssertEqual(result.columnType(at: 1), .varchar)
    }

    // MARK: - value() row bounds

    func testValueNegativeRow() throws {
        let result = try makeResult()
        XCTAssertEqual(result.value(row: -1, col: 0), .null)
    }

    func testValueRowOutOfRange() throws {
        let result = try makeResult()
        XCTAssertEqual(result.rowCount, 3)
        XCTAssertEqual(result.value(row: 3, col: 0), .null)
        XCTAssertEqual(result.value(row: 1000, col: 0), .null)
    }

    // MARK: - value() column bounds

    func testValueNegativeCol() throws {
        let result = try makeResult()
        XCTAssertEqual(result.value(row: 0, col: -1), .null)
    }

    func testValueColOutOfRange() throws {
        let result = try makeResult()
        XCTAssertEqual(result.value(row: 0, col: 2), .null)
        XCTAssertEqual(result.value(row: 0, col: 500), .null)
    }

    // MARK: - Both out of range

    func testValueBothOutOfRange() throws {
        let result = try makeResult()
        XCTAssertEqual(result.value(row: -1, col: -1), .null)
        XCTAssertEqual(result.value(row: 100, col: 100), .null)
    }

    // MARK: - Empty result

    func testEmptyResultValueAccess() throws {
        let result = try makeEmptyResult()
        XCTAssertEqual(result.rowCount, 0)
        XCTAssertEqual(result.columnCount, 2)
        // Row 0 is out of bounds on an empty result
        XCTAssertEqual(result.value(row: 0, col: 0), .null)
    }

    func testEmptyResultColumnNameStillWorks() throws {
        let result = try makeEmptyResult()
        // Columns exist even with zero rows
        XCTAssertEqual(result.columnName(at: 0), "id")
        XCTAssertEqual(result.columnName(at: 1), "name")
        // But out of bounds is still safe
        XCTAssertEqual(result.columnName(at: 2), "")
    }

    // MARK: - Valid access still works

    func testValidAccessReturnsCorrectValues() throws {
        let result = try makeResult()
        XCTAssertEqual(result.value(row: 0, col: 0), .integer(1))
        XCTAssertEqual(result.value(row: 0, col: 1), .string("alpha"))
        XCTAssertEqual(result.value(row: 2, col: 0), .integer(3))
        XCTAssertEqual(result.value(row: 2, col: 1), .string("gamma"))
    }

    // MARK: - Int.max / Int.min edge cases

    func testExtremeIndices() throws {
        let result = try makeResult()
        XCTAssertEqual(result.value(row: Int.max, col: 0), .null)
        XCTAssertEqual(result.value(row: 0, col: Int.max), .null)
        XCTAssertEqual(result.value(row: Int.min, col: 0), .null)
        XCTAssertEqual(result.value(row: 0, col: Int.min), .null)
        XCTAssertEqual(result.columnName(at: Int.max), "")
        XCTAssertEqual(result.columnName(at: Int.min), "")
        XCTAssertEqual(result.columnType(at: Int.max), .unknown)
        XCTAssertEqual(result.columnType(at: Int.min), .unknown)
    }
}
