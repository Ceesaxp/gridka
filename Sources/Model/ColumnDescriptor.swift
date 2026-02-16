import Foundation

struct ColumnDescriptor: Equatable, Hashable {
    let name: String
    let duckDBType: DuckDBColumnType
    let displayType: DisplayType
    let index: Int
}
