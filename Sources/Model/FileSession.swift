import Foundation

final class FileSession {

    // MARK: - Properties

    let filePath: URL
    private let engine: DuckDBEngine
    private let queryCoordinator = QueryCoordinator()
    private let queryQueue = DispatchQueue(label: "com.gridka.query-queue")

    private(set) var tableName: String = "data"
    private(set) var columns: [ColumnDescriptor] = []
    private(set) var viewState: ViewState
    private(set) var rowCache = RowCache()
    private(set) var isFullyLoaded = false
    /// Total row count before any filters are applied.
    private(set) var totalRows: Int = 0

    // MARK: - Init

    init(filePath: URL) throws {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            throw GridkaError.fileNotFound(filePath.path)
        }
        self.filePath = filePath
        self.viewState = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<0,
            totalFilteredRows: 0
        )
        self.engine = try DuckDBEngine()
    }

    // MARK: - Preview Loading

    func loadPreview(completion: @escaping (Result<[ColumnDescriptor], Error>) -> Void) {
        let path = filePath.path.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT * FROM read_csv_auto('\(path)', ignore_errors = true) LIMIT 1000"

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)
                let cols = self.extractColumns(from: result)
                let page = self.extractPage(from: result, startRow: 0, columns: cols)

                DispatchQueue.main.async {
                    self.columns = cols
                    self.viewState.totalFilteredRows = result.rowCount
                    self.rowCache.insertPage(page)
                    completion(.success(cols))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Full Loading

    func loadFull(progress: @escaping (Double) -> Void, completion: @escaping (Result<Int, Error>) -> Void) {
        let path = filePath.path.replacingOccurrences(of: "'", with: "''")
        let createSQL = "CREATE TABLE data AS SELECT row_number() OVER () AS _gridka_rowid, * FROM read_csv_auto('\(path)', ignore_errors = true)"
        let countSQL = "SELECT COUNT(*) FROM data"

        queryQueue.async { [weak self] in
            guard let self = self else { return }

            DispatchQueue.main.async {
                progress(0.0)
            }

            do {
                try self.engine.execute(createSQL)

                DispatchQueue.main.async {
                    progress(0.8)
                }

                let countResult = try self.engine.execute(countSQL)
                let totalRows: Int
                if countResult.rowCount > 0 {
                    let val = countResult.value(row: 0, col: 0)
                    if case .integer(let count) = val {
                        totalRows = Int(count)
                    } else {
                        totalRows = 0
                    }
                } else {
                    totalRows = 0
                }

                // Re-extract columns from the materialized table (includes _gridka_rowid)
                let colResult = try self.engine.execute("SELECT * FROM data LIMIT 0")
                let cols = self.extractColumns(from: colResult)

                DispatchQueue.main.async {
                    self.columns = cols
                    self.isFullyLoaded = true
                    self.totalRows = totalRows
                    self.viewState.totalFilteredRows = totalRows
                    self.rowCache.invalidateAll()
                    progress(1.0)
                    completion(.success(totalRows))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Page Fetching

    func fetchPage(index: Int, completion: @escaping (Result<RowCache.Page, Error>) -> Void) {
        let range = rowCache.pageRange(forPageIndex: index)
        let sql = queryCoordinator.buildQuery(for: viewState, columns: columns, range: range)

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)
                let columnNames = (0..<result.columnCount).map { result.columnName(at: $0) }
                let page = RowCache.Page(
                    startRow: range.lowerBound,
                    data: self.extractRowData(from: result),
                    columnNames: columnNames,
                    lastAccessed: Date()
                )

                DispatchQueue.main.async {
                    self.rowCache.insertPage(page)
                    completion(.success(page))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - View State Updates

    func updateViewState(_ newState: ViewState) {
        let countChanged = newState.filters != viewState.filters
            || newState.searchTerm != viewState.searchTerm
        let cacheInvalidated = countChanged
            || newState.sortColumns != viewState.sortColumns

        viewState = newState

        if cacheInvalidated {
            rowCache.invalidateAll()
        }
        // Only re-query count when filters or search change (sort doesn't affect row count)
        if countChanged {
            requeryCount()
        }
    }

    // MARK: - Private Helpers

    private func requeryCount() {
        let sql = queryCoordinator.buildCountQuery(for: viewState, columns: columns)

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)
                let count: Int
                if result.rowCount > 0, case .integer(let val) = result.value(row: 0, col: 0) {
                    count = Int(val)
                } else {
                    count = 0
                }

                DispatchQueue.main.async {
                    self.viewState.totalFilteredRows = count
                }
            } catch {
                // Count query failed — leave totalFilteredRows unchanged
            }
        }
    }

    private func extractColumns(from result: DuckDBResult) -> [ColumnDescriptor] {
        return (0..<result.columnCount).map { i in
            let name = result.columnName(at: i)
            let duckType = result.columnType(at: i)
            let displayType = mapDisplayType(from: duckType)
            return ColumnDescriptor(name: name, duckDBType: duckType, displayType: displayType, index: i)
        }
    }

    private func extractPage(from result: DuckDBResult, startRow: Int, columns: [ColumnDescriptor]) -> RowCache.Page {
        let columnNames = columns.map { $0.name }
        let data = extractRowData(from: result)
        return RowCache.Page(
            startRow: startRow,
            data: data,
            columnNames: columnNames,
            lastAccessed: Date()
        )
    }

    private func extractRowData(from result: DuckDBResult) -> [[DuckDBValue]] {
        return (0..<result.rowCount).map { row in
            (0..<result.columnCount).map { col in
                result.value(row: row, col: col)
            }
        }
    }

    private func mapDisplayType(from type: DuckDBColumnType) -> DisplayType {
        switch type {
        case .varchar, .blob:
            return .text
        case .integer, .bigint:
            return .integer
        case .double, .float:
            return .float
        case .date, .timestamp:
            return .date
        case .boolean:
            return .boolean
        case .unknown:
            return .unknown
        }
    }
}
