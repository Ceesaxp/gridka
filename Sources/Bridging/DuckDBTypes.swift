import Foundation

// MARK: - DuckDBColumnType

enum DuckDBColumnType: Equatable, Hashable {
    case varchar
    case integer
    case bigint
    case double
    case float
    case boolean
    case date
    case timestamp
    case blob
    case unknown

    static func mapType(from type: duckdb_type) -> DuckDBColumnType {
        switch type {
        case DUCKDB_TYPE_VARCHAR:
            return .varchar
        case DUCKDB_TYPE_TINYINT, DUCKDB_TYPE_SMALLINT, DUCKDB_TYPE_INTEGER,
             DUCKDB_TYPE_UTINYINT, DUCKDB_TYPE_USMALLINT, DUCKDB_TYPE_UINTEGER:
            return .integer
        case DUCKDB_TYPE_BIGINT, DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_HUGEINT, DUCKDB_TYPE_UHUGEINT:
            return .bigint
        case DUCKDB_TYPE_DOUBLE, DUCKDB_TYPE_DECIMAL:
            return .double
        case DUCKDB_TYPE_FLOAT:
            return .float
        case DUCKDB_TYPE_BOOLEAN:
            return .boolean
        case DUCKDB_TYPE_DATE:
            return .date
        case DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_S, DUCKDB_TYPE_TIMESTAMP_MS,
             DUCKDB_TYPE_TIMESTAMP_NS, DUCKDB_TYPE_TIMESTAMP_TZ:
            return .timestamp
        case DUCKDB_TYPE_BLOB:
            return .blob
        default:
            return .unknown
        }
    }
}

// MARK: - DisplayType

enum DisplayType: Equatable, Hashable {
    case text
    case integer
    case float
    case date
    case boolean
    case unknown
}

// MARK: - DuckDBValue

enum DuckDBValue: Equatable, CustomStringConvertible {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case date(String)
    case null

    var description: String {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .boolean(let value):
            return value ? "true" : "false"
        case .date(let value):
            return value
        case .null:
            return "NULL"
        }
    }
}
