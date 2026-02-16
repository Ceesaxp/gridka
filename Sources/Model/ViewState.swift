import Foundation

// MARK: - SortDirection

enum SortDirection: Equatable, Hashable {
    case ascending
    case descending
}

// MARK: - SortColumn

struct SortColumn: Equatable, Hashable {
    let column: String
    let direction: SortDirection
}

// MARK: - ViewState

struct ViewState: Equatable {
    var sortColumns: [SortColumn]
    var filters: [ColumnFilter]
    var searchTerm: String?
    var visibleRange: Range<Int>
    var totalFilteredRows: Int

    static func == (lhs: ViewState, rhs: ViewState) -> Bool {
        lhs.sortColumns == rhs.sortColumns
            && lhs.filters == rhs.filters
            && lhs.searchTerm == rhs.searchTerm
            && lhs.visibleRange == rhs.visibleRange
            && lhs.totalFilteredRows == rhs.totalFilteredRows
    }
}
