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

// MARK: - ComputedColumn

struct ComputedColumn: Equatable, Hashable {
    let name: String
    let expression: String
}

// MARK: - ViewState

struct ViewState: Equatable {
    var sortColumns: [SortColumn]
    var filters: [ColumnFilter]
    var searchTerm: String?
    var visibleRange: Range<Int>
    var totalFilteredRows: Int
    /// The currently selected column name (clicked header). Drives the Profiler sidebar.
    var selectedColumn: String? = nil
    /// Computed columns defined by the user via Add Computed Column dialog.
    var computedColumns: [ComputedColumn] = []

    static func == (lhs: ViewState, rhs: ViewState) -> Bool {
        lhs.sortColumns == rhs.sortColumns
            && lhs.filters == rhs.filters
            && lhs.searchTerm == rhs.searchTerm
            && lhs.visibleRange == rhs.visibleRange
            && lhs.totalFilteredRows == rhs.totalFilteredRows
            && lhs.selectedColumn == rhs.selectedColumn
            && lhs.computedColumns == rhs.computedColumns
    }
}
