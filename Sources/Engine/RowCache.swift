import Foundation

struct RowCache {

    // MARK: - Constants

    static let pageSize = 500
    static let maxCachedPages = 20

    // MARK: - Page

    struct Page {
        let startRow: Int
        let data: [[DuckDBValue]]
        let columnNames: [String]
        var lastAccessed: Date
    }

    // MARK: - State

    private var pages: [Int: Page] = [:]

    // MARK: - Lookup

    func value(forRow row: Int, columnName: String) -> DuckDBValue? {
        let index = pageIndex(forRow: row)
        guard var page = pages[index] else { return nil }
        guard let colIndex = page.columnNames.firstIndex(of: columnName) else { return nil }
        let rowOffset = row - page.startRow
        guard rowOffset >= 0 && rowOffset < page.data.count else { return nil }
        // Note: lastAccessed is updated via mutating insertPage or explicit touch;
        // value lookup alone doesn't mutate since RowCache is a value type used via mutating methods
        return page.data[rowOffset][colIndex]
    }

    mutating func touchPage(forRow row: Int) {
        let index = pageIndex(forRow: row)
        pages[index]?.lastAccessed = Date()
    }

    /// Returns true if the given page index is currently cached.
    func hasPage(_ index: Int) -> Bool {
        return pages[index] != nil
    }

    // MARK: - Insert & Eviction

    mutating func insertPage(_ page: Page) {
        let index = pageIndex(forRow: page.startRow)
        pages[index] = page

        if pages.count > RowCache.maxCachedPages {
            evictOldest()
        }
    }

    // MARK: - Invalidation

    mutating func invalidateAll() {
        pages.removeAll()
    }

    /// Removes a single cached page so it will be re-fetched on next access.
    mutating func invalidatePage(_ index: Int) {
        pages.removeValue(forKey: index)
    }

    // MARK: - Page Math

    func pageIndex(forRow row: Int) -> Int {
        return row / RowCache.pageSize
    }

    func pageRange(forPageIndex index: Int) -> Range<Int> {
        let start = index * RowCache.pageSize
        return start..<(start + RowCache.pageSize)
    }

    // MARK: - Private

    private mutating func evictOldest() {
        guard let oldestKey = pages.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key else {
            return
        }
        pages.removeValue(forKey: oldestKey)
    }
}
