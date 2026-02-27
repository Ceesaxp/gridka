import Foundation
import os.log

// MARK: - DuckDBResult

final class DuckDBResult {
    private var result: duckdb_result

    let rowCount: Int
    let columnCount: Int

    init(_ result: duckdb_result) {
        self.result = result
        self.rowCount = Int(duckdb_row_count(&self.result))
        self.columnCount = Int(duckdb_column_count(&self.result))
    }

    deinit {
        duckdb_destroy_result(&result)
    }

    func columnName(at index: Int) -> String {
        guard index >= 0, index < columnCount else { return "" }
        guard let cString = duckdb_column_name(&result, idx_t(index)) else {
            return ""
        }
        return String(cString: cString)
    }

    func columnType(at index: Int) -> DuckDBColumnType {
        guard index >= 0, index < columnCount else { return .unknown }
        let rawType = duckdb_column_type(&result, idx_t(index))
        return DuckDBColumnType.mapType(from: rawType)
    }

    func value(row: Int, col: Int) -> DuckDBValue {
        guard row >= 0, row < rowCount, col >= 0, col < columnCount else { return .null }
        let r = idx_t(row)
        let c = idx_t(col)

        if duckdb_value_is_null(&result, c, r) {
            return .null
        }

        let rawType = duckdb_column_type(&result, c)
        switch rawType {
        case DUCKDB_TYPE_BOOLEAN:
            return .boolean(duckdb_value_boolean(&result, c, r))

        case DUCKDB_TYPE_TINYINT, DUCKDB_TYPE_SMALLINT, DUCKDB_TYPE_INTEGER,
             DUCKDB_TYPE_UTINYINT, DUCKDB_TYPE_USMALLINT, DUCKDB_TYPE_UINTEGER:
            return .integer(duckdb_value_int64(&result, c, r))

        case DUCKDB_TYPE_BIGINT, DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_HUGEINT, DUCKDB_TYPE_UHUGEINT:
            return .integer(duckdb_value_int64(&result, c, r))

        case DUCKDB_TYPE_FLOAT:
            return .double(Double(duckdb_value_float(&result, c, r)))

        case DUCKDB_TYPE_DOUBLE, DUCKDB_TYPE_DECIMAL:
            return .double(duckdb_value_double(&result, c, r))

        case DUCKDB_TYPE_DATE:
            return extractVarchar(row: r, col: c, wrapper: DuckDBValue.date)

        case DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_S, DUCKDB_TYPE_TIMESTAMP_MS,
             DUCKDB_TYPE_TIMESTAMP_NS, DUCKDB_TYPE_TIMESTAMP_TZ:
            return extractVarchar(row: r, col: c, wrapper: DuckDBValue.string)

        default:
            return extractVarchar(row: r, col: c, wrapper: DuckDBValue.string)
        }
    }

    private func extractVarchar(row: idx_t, col: idx_t, wrapper: (String) -> DuckDBValue) -> DuckDBValue {
        guard let cString = duckdb_value_varchar(&result, col, row) else {
            return .null
        }
        let str = String(cString: cString)
        duckdb_free(UnsafeMutableRawPointer(mutating: cString))
        return wrapper(str)
    }
}

// MARK: - DuckDBEngine

private let logger = Logger(subsystem: "com.gridka.app", category: "DuckDBEngine")

final class DuckDBEngine {
    private var database: duckdb_database?
    private var connection: duckdb_connection?
    private let logSQL: Bool

    init() throws {
        logSQL = ProcessInfo.processInfo.environment["GRIDKA_LOG_SQL"] == "1"

        let openState = duckdb_open(nil, &database)
        guard openState == DuckDBSuccess else {
            throw GridkaError.databaseInitFailed
        }

        guard let db = database else {
            throw GridkaError.databaseInitFailed
        }

        let connectState = duckdb_connect(db, &connection)
        guard connectState == DuckDBSuccess else {
            duckdb_close(&database)
            throw GridkaError.connectionFailed
        }

        do {
            try configureDatabaseSettings()
        } catch {
            duckdb_disconnect(&connection)
            duckdb_close(&database)
            throw error
        }
    }

    deinit {
        if connection != nil {
            duckdb_disconnect(&connection)
        }
        if database != nil {
            duckdb_close(&database)
        }
    }

    @discardableResult
    func execute(_ sql: String) throws -> DuckDBResult {
        guard let conn = connection else {
            throw GridkaError.queryFailed("No active database connection")
        }

        if logSQL {
            logger.info("SQL: \(sql, privacy: .public)")
        }

        let startTime = logSQL ? CFAbsoluteTimeGetCurrent() : 0

        var result = duckdb_result()
        let state = duckdb_query(conn, sql, &result)

        if state == DuckDBError {
            if logSQL {
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                logger.error("SQL failed in \(String(format: "%.1f", elapsed), privacy: .public)ms")
            }
            let errorMessage: String
            if let cError = duckdb_result_error(&result) {
                errorMessage = String(cString: cError)
            } else {
                errorMessage = "Unknown query error"
            }
            duckdb_destroy_result(&result)
            throw GridkaError.queryFailed(errorMessage)
        }

        if logSQL {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.info("SQL completed in \(String(format: "%.1f", elapsed), privacy: .public)ms (\(duckdb_row_count(&result), privacy: .public) rows)")
        }

        return DuckDBResult(result)
    }

    /// Updates the DuckDB memory limit for this engine instance.
    /// Called by TabMemoryManager when tabs are opened or closed.
    func setMemoryLimit(_ limitBytes: UInt64) throws {
        let limitGB = Double(limitBytes) / (1024.0 * 1024.0 * 1024.0)
        let limitStr = String(format: "%.1fGB", limitGB)
        try execute("SET memory_limit = '\(limitStr)'")
    }

    // MARK: - Private

    private func configureDatabaseSettings() throws {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let memoryLimitBytes = totalMemory / 2
        let memoryLimitGB = Double(memoryLimitBytes) / (1024.0 * 1024.0 * 1024.0)
        let memoryLimitStr = String(format: "%.1fGB", memoryLimitGB)
        try execute("SET memory_limit = '\(memoryLimitStr)'")

        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw GridkaError.loadFailed("Unable to locate system cache directory")
        }
        let tempDir = cacheDir.appendingPathComponent("com.gridka.app/duckdb-temp")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try execute("SET temp_directory = '\(tempDir.path)'")

        let threadCount = ProcessInfo.processInfo.activeProcessorCount
        try execute("SET threads = \(threadCount)")
    }
}
