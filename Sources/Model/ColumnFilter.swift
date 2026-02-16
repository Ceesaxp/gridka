import Foundation

// MARK: - FilterOperator

enum FilterOperator: Equatable, Hashable {
    // Text operators
    case contains
    case equals
    case startsWith
    case endsWith
    case regex
    case isEmpty
    case isNotEmpty

    // Numeric operators
    case greaterThan
    case lessThan
    case greaterOrEqual
    case lessOrEqual
    case between

    // Null operators
    case isNull
    case isNotNull

    // Boolean operators
    case isTrue
    case isFalse
}

// MARK: - FilterValue

enum FilterValue: Equatable, Hashable {
    case string(String)
    case number(Double)
    case dateRange(String, String)
    case boolean(Bool)
    case none
}

// MARK: - ColumnFilter

struct ColumnFilter: Equatable, Hashable {
    let column: String
    let `operator`: FilterOperator
    let value: FilterValue
}
