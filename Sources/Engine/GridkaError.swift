import Foundation

enum GridkaError: LocalizedError {
    case databaseInitFailed
    case connectionFailed
    case queryFailed(String)
    case fileNotFound(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseInitFailed:
            return "Failed to initialize DuckDB database"
        case .connectionFailed:
            return "Failed to create DuckDB connection"
        case .queryFailed(let message):
            return "Query failed: \(message)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .loadFailed(let message):
            return "Failed to load file: \(message)"
        }
    }
}
