import XCTest
@testable import Gridka

final class RowCacheTests: XCTestCase {

    private let columnNames = ["name", "age", "salary"]

    private func makePage(startRow: Int, rowCount: Int = 5, lastAccessed: Date = Date()) -> RowCache.Page {
        let data = (0..<rowCount).map { i -> [DuckDBValue] in
            [
                .string("row\(startRow + i)"),
                .integer(Int64(20 + i)),
                .double(50000.0 + Double(i) * 1000),
            ]
        }
        return RowCache.Page(
            startRow: startRow,
            data: data,
            columnNames: columnNames,
            lastAccessed: lastAccessed
        )
    }

    // MARK: - Cache Miss

    func testCacheMissReturnsNil() {
        let cache = RowCache()
        XCTAssertNil(cache.value(forRow: 0, columnName: "name"))
    }

    func testCacheMissForWrongColumn() {
        var cache = RowCache()
        cache.insertPage(makePage(startRow: 0))
        XCTAssertNil(cache.value(forRow: 0, columnName: "nonexistent"))
    }

    // MARK: - Insert and Hit

    func testInsertThenHitReturnsValue() {
        var cache = RowCache()
        cache.insertPage(makePage(startRow: 0))

        let value = cache.value(forRow: 0, columnName: "name")
        XCTAssertEqual(value, .string("row0"))
    }

    func testInsertThenHitDifferentColumns() {
        var cache = RowCache()
        cache.insertPage(makePage(startRow: 0))

        XCTAssertEqual(cache.value(forRow: 0, columnName: "age"), .integer(20))
        XCTAssertEqual(cache.value(forRow: 0, columnName: "salary"), .double(50000.0))
    }

    func testInsertThenHitMultipleRows() {
        var cache = RowCache()
        cache.insertPage(makePage(startRow: 0))

        XCTAssertEqual(cache.value(forRow: 0, columnName: "name"), .string("row0"))
        XCTAssertEqual(cache.value(forRow: 3, columnName: "name"), .string("row3"))
        XCTAssertEqual(cache.value(forRow: 4, columnName: "age"), .integer(24))
    }

    // MARK: - Page Math

    func testPageIndexForRow() {
        let cache = RowCache()

        XCTAssertEqual(cache.pageIndex(forRow: 0), 0)
        XCTAssertEqual(cache.pageIndex(forRow: 499), 0)
        XCTAssertEqual(cache.pageIndex(forRow: 500), 1)
        XCTAssertEqual(cache.pageIndex(forRow: 999), 1)
        XCTAssertEqual(cache.pageIndex(forRow: 1000), 2)
        XCTAssertEqual(cache.pageIndex(forRow: 9999), 19)
    }

    func testPageRange() {
        let cache = RowCache()

        XCTAssertEqual(cache.pageRange(forPageIndex: 0), 0..<500)
        XCTAssertEqual(cache.pageRange(forPageIndex: 1), 500..<1000)
        XCTAssertEqual(cache.pageRange(forPageIndex: 5), 2500..<3000)
    }

    // MARK: - LRU Eviction

    func testEvictionAt21PagesEvictsOldest() {
        var cache = RowCache()
        let baseDate = Date(timeIntervalSince1970: 1000000)

        // Insert 20 pages with increasing timestamps
        for i in 0..<20 {
            let page = makePage(
                startRow: i * RowCache.pageSize,
                rowCount: 5,
                lastAccessed: baseDate.addingTimeInterval(Double(i))
            )
            cache.insertPage(page)
        }

        // All 20 pages should be accessible
        for i in 0..<20 {
            XCTAssertNotNil(cache.value(forRow: i * RowCache.pageSize, columnName: "name"),
                            "Page \(i) should exist before eviction")
        }

        // Insert 21st page — should evict page 0 (oldest lastAccessed)
        let newPage = makePage(
            startRow: 20 * RowCache.pageSize,
            rowCount: 5,
            lastAccessed: baseDate.addingTimeInterval(20)
        )
        cache.insertPage(newPage)

        // Page 0 (startRow=0) should be evicted
        XCTAssertNil(cache.value(forRow: 0, columnName: "name"),
                     "Page 0 should be evicted")

        // Page 1 should still be there
        XCTAssertNotNil(cache.value(forRow: RowCache.pageSize, columnName: "name"),
                        "Page 1 should still exist")

        // New page should be accessible
        XCTAssertNotNil(cache.value(forRow: 20 * RowCache.pageSize, columnName: "name"),
                        "Newly inserted page should exist")
    }

    // MARK: - Invalidate All

    func testInvalidateAllClearsEverything() {
        var cache = RowCache()
        cache.insertPage(makePage(startRow: 0))
        cache.insertPage(makePage(startRow: 500))
        cache.insertPage(makePage(startRow: 1000))

        XCTAssertNotNil(cache.value(forRow: 0, columnName: "name"))
        XCTAssertNotNil(cache.value(forRow: 500, columnName: "name"))

        cache.invalidateAll()

        XCTAssertNil(cache.value(forRow: 0, columnName: "name"))
        XCTAssertNil(cache.value(forRow: 500, columnName: "name"))
        XCTAssertNil(cache.value(forRow: 1000, columnName: "name"))
    }

    // MARK: - Out of Bounds

    func testRowOutOfPageBoundsReturnsNil() {
        var cache = RowCache()
        // Page has only 5 rows (0..4) but pageSize is 500
        cache.insertPage(makePage(startRow: 0, rowCount: 5))

        XCTAssertNotNil(cache.value(forRow: 4, columnName: "name"))
        XCTAssertNil(cache.value(forRow: 5, columnName: "name"))
    }

    // MARK: - Page Constants

    func testPageSizeIs500() {
        XCTAssertEqual(RowCache.pageSize, 500)
    }

    func testMaxCachedPagesIs20() {
        XCTAssertEqual(RowCache.maxCachedPages, 20)
    }
}
