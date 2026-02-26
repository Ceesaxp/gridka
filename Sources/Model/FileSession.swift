import Foundation

/// Identifies a single edited cell by its stable rowid and column name.
struct EditedCell: Hashable {
    let rowid: Int64
    let column: String
}

final class FileSession {

    // MARK: - Properties

    private(set) var filePath: URL
    private let engine: DuckDBEngine
    private let queryCoordinator = QueryCoordinator()
    private let profilerQueryBuilder = ProfilerQueryBuilder()
    private let queryQueue = DispatchQueue(label: "com.gridka.query-queue")

    /// Generation counter for profiler queries. Incremented when column selection or
    /// filter/search state changes. Results with a stale generation are discarded.
    /// IMPORTANT: Only read/write from the main thread to avoid data races with queryQueue.
    private var profilerGeneration: Int = 0

    private(set) var tableName: String = "data"
    private(set) var columns: [ColumnDescriptor] = []
    private(set) var viewState: ViewState
    private(set) var rowCache = RowCache()
    private(set) var isFullyLoaded = false
    /// Total row count before any filters are applied.
    private(set) var totalRows: Int = 0

    /// Tracks cells that have been edited since the last save.
    /// Cleared when isModified becomes false (i.e., on save).
    var editedCells: Set<EditedCell> = []

    /// Whether the in-memory data has unsaved edits.
    /// Setting this dispatches to main thread to update window.isDocumentEdited.
    var isModified: Bool = false {
        didSet {
            guard isModified != oldValue else { return }
            let modified = isModified
            if !modified {
                editedCells.removeAll()
            }
            DispatchQueue.main.async { [weak self] in
                self?.onModifiedChanged?(modified)
            }
        }
    }

    /// Callback invoked on the main thread when isModified changes.
    /// AppDelegate sets this to update window.isDocumentEdited.
    var onModifiedChanged: ((Bool) -> Void)?

    /// Detected CSV delimiter from sniff_csv.
    private(set) var detectedDelimiter: String = ","
    /// Whether the CSV has a header row (detected by sniff_csv).
    private(set) var detectedHasHeader: Bool = true
    /// User-togglable header setting. Initialized from sniff result.
    var hasHeaders: Bool = true
    /// User-selected delimiter override. nil = auto-detect.
    var customDelimiter: String? = nil
    /// Detected file encoding.
    private(set) var detectedEncoding: String = "UTF-8"
    /// User-selected encoding override. nil = auto-detect (UTF-8).
    /// When set, the file is transcoded to UTF-8 via a temp file before loading into DuckDB.
    var overrideEncoding: String? = nil

    /// The effective delimiter: custom override or detected value.
    var effectiveDelimiter: String {
        return customDelimiter ?? detectedDelimiter
    }

    /// The active encoding name for display (either the override or the detected encoding).
    var activeEncodingName: String {
        return overrideEncoding ?? detectedEncoding
    }

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

    // MARK: - Memory Management

    /// Updates the DuckDB memory limit for this session's engine.
    /// Must be called from outside; executes on the serial query queue.
    func updateMemoryLimit(_ limitBytes: UInt64) {
        queryQueue.async { [weak self] in
            guard let self = self else { return }
            try? self.engine.setMemoryLimit(limitBytes)
        }
    }

    // MARK: - CSV Sniffing

    func sniffCSV(completion: @escaping () -> Void) {
        let path = filePath.path.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT * FROM sniff_csv('\(path)')"

        // Detect encoding from BOM
        detectEncoding()

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)
                if result.rowCount > 0 {
                    // Extract delimiter (column 0)
                    if case .string(let delim) = result.value(row: 0, col: 0) {
                        DispatchQueue.main.async {
                            self.detectedDelimiter = delim
                        }
                    }
                    // Extract HasHeader (column 4)
                    if case .boolean(let hasHeader) = result.value(row: 0, col: 4) {
                        DispatchQueue.main.async {
                            self.detectedHasHeader = hasHeader
                            self.hasHeaders = hasHeader
                        }
                    }
                }
            } catch {
                // Sniff failed — keep defaults
            }

            DispatchQueue.main.async {
                completion()
            }
        }
    }

    private func detectEncoding() {
        guard let handle = FileHandle(forReadingAtPath: filePath.path) else { return }
        let data = handle.readData(ofLength: 4)
        handle.closeFile()

        let bytes = [UInt8](data)
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            detectedEncoding = "UTF-8 (BOM)"
        } else if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            detectedEncoding = "UTF-16 LE"
        } else if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            detectedEncoding = "UTF-16 BE"
        } else {
            detectedEncoding = "UTF-8"
        }
    }

    /// Builds the read_csv_auto parameter string with current header/delimiter settings.
    private func csvReadParams() -> String {
        var params = "ignore_errors = true, header = \(hasHeaders ? "true" : "false")"
        if let delim = customDelimiter {
            let escaped = delim.replacingOccurrences(of: "'", with: "''")
            params += ", delim = '\(escaped)'"
        }
        return params
    }

    // MARK: - Preview Loading

    func loadPreview(completion: @escaping (Result<[ColumnDescriptor], Error>) -> Void) {
        let path = filePath.path.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT * FROM read_csv_auto('\(path)', \(csvReadParams())) LIMIT 1000"

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
        let createSQL = "CREATE TABLE data AS SELECT row_number() OVER () AS _gridka_rowid, * FROM read_csv_auto('\(path)', \(csvReadParams()))"
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

    // MARK: - Reload with Header Toggle

    func reload(withHeaders: Bool, progress: @escaping (Double) -> Void, completion: @escaping (Result<Int, Error>) -> Void) {
        hasHeaders = withHeaders
        reloadTable(progress: progress, completion: completion)
    }

    func reload(withDelimiter delimiter: String?, progress: @escaping (Double) -> Void, completion: @escaping (Result<Int, Error>) -> Void) {
        customDelimiter = delimiter
        reloadTable(progress: progress, completion: completion)
    }

    /// Reload the file with a specific encoding.
    /// For UTF-8 and auto-detect, loads directly. For other encodings, transcodes to a UTF-8 temp file first.
    func reload(withEncoding encodingName: String, swiftEncoding: String.Encoding?, progress: @escaping (Double) -> Void, completion: @escaping (Result<Int, Error>) -> Void) {
        overrideEncoding = encodingName

        if swiftEncoding == nil || swiftEncoding == .utf8 {
            // UTF-8 or auto-detect: load directly, no transcoding needed
            reloadTable(progress: progress, completion: completion)
            return
        }

        // For non-UTF-8 encodings: read file, transcode to UTF-8, write temp file, load temp file
        queryQueue.async { [weak self] in
            guard let self = self else { return }

            DispatchQueue.main.async { progress(0.0) }

            do {
                let fileData = try Data(contentsOf: self.filePath)

                DispatchQueue.main.async { progress(0.2) }

                guard let content = String(data: fileData, encoding: swiftEncoding!) else {
                    DispatchQueue.main.async {
                        completion(.failure(GridkaError.loadFailed("Cannot decode file with encoding \(encodingName)")))
                    }
                    return
                }

                DispatchQueue.main.async { progress(0.4) }

                guard let utf8Data = content.data(using: .utf8) else {
                    DispatchQueue.main.async {
                        completion(.failure(GridkaError.loadFailed("Cannot transcode to UTF-8")))
                    }
                    return
                }

                // Write to temp file in caches directory
                let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("com.gridka.app")
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                let tempFile = cacheDir.appendingPathComponent("transcode-\(UUID().uuidString).csv")
                try utf8Data.write(to: tempFile)

                DispatchQueue.main.async { progress(0.5) }

                // Now reload using the temp file
                let tempPath = tempFile.path.replacingOccurrences(of: "'", with: "''")
                let dropSQL = "DROP TABLE IF EXISTS data"
                let createSQL = "CREATE TABLE data AS SELECT row_number() OVER () AS _gridka_rowid, * FROM read_csv_auto('\(tempPath)', \(self.csvReadParams()))"
                let countSQL = "SELECT COUNT(*) FROM data"

                try self.engine.execute(dropSQL)
                DispatchQueue.main.async { progress(0.7) }

                try self.engine.execute(createSQL)
                DispatchQueue.main.async { progress(0.9) }

                let countResult = try self.engine.execute(countSQL)
                let totalRows: Int
                if countResult.rowCount > 0, case .integer(let count) = countResult.value(row: 0, col: 0) {
                    totalRows = Int(count)
                } else {
                    totalRows = 0
                }

                let colResult = try self.engine.execute("SELECT * FROM data LIMIT 0")
                let cols = self.extractColumns(from: colResult)

                // Clean up temp file
                try? FileManager.default.removeItem(at: tempFile)

                DispatchQueue.main.async {
                    self.columns = cols
                    self.isFullyLoaded = true
                    self.totalRows = totalRows
                    self.viewState = ViewState(
                        sortColumns: [],
                        filters: [],
                        searchTerm: nil,
                        visibleRange: 0..<0,
                        totalFilteredRows: totalRows
                    )
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

    private func reloadTable(progress: @escaping (Double) -> Void, completion: @escaping (Result<Int, Error>) -> Void) {
        let path = filePath.path.replacingOccurrences(of: "'", with: "''")
        let dropSQL = "DROP TABLE IF EXISTS data"
        let createSQL = "CREATE TABLE data AS SELECT row_number() OVER () AS _gridka_rowid, * FROM read_csv_auto('\(path)', \(csvReadParams()))"
        let countSQL = "SELECT COUNT(*) FROM data"

        queryQueue.async { [weak self] in
            guard let self = self else { return }

            DispatchQueue.main.async { progress(0.0) }

            do {
                try self.engine.execute(dropSQL)
                DispatchQueue.main.async { progress(0.3) }

                try self.engine.execute(createSQL)
                DispatchQueue.main.async { progress(0.8) }

                let countResult = try self.engine.execute(countSQL)
                let totalRows: Int
                if countResult.rowCount > 0, case .integer(let count) = countResult.value(row: 0, col: 0) {
                    totalRows = Int(count)
                } else {
                    totalRows = 0
                }

                let colResult = try self.engine.execute("SELECT * FROM data LIMIT 0")
                let cols = self.extractColumns(from: colResult)

                DispatchQueue.main.async {
                    self.columns = cols
                    self.isFullyLoaded = true
                    self.totalRows = totalRows
                    // Reset view state — column names change on header toggle
                    self.viewState = ViewState(
                        sortColumns: [],
                        filters: [],
                        searchTerm: nil,
                        visibleRange: 0..<0,
                        totalFilteredRows: totalRows
                    )
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

    // MARK: - Save

    func save(completion: @escaping (Result<Void, Error>) -> Void) {
        let path = filePath.path.replacingOccurrences(of: "'", with: "''")

        // Build explicit column list excluding _gridka_rowid
        let exportColumns = columns
            .filter { $0.name != "_gridka_rowid" }
            .map { QueryCoordinator.quote($0.name) }
            .joined(separator: ", ")

        let delimiterEscaped = effectiveDelimiter.replacingOccurrences(of: "'", with: "''")
        let headerParam = hasHeaders ? "true" : "false"

        let sql = "COPY (SELECT \(exportColumns) FROM data) TO '\(path)' (FORMAT CSV, HEADER \(headerParam), DELIMITER '\(delimiterEscaped)', FORCE_QUOTE *)"

        queryQueue.async { [weak self] in
            do {
                try self?.engine.execute(sql)
                DispatchQueue.main.async {
                    self?.isModified = false
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Save to a new file with specified encoding and delimiter.
    /// If encoding is UTF-8, uses DuckDB COPY TO directly.
    /// For other encodings, queries all data, transcodes in Swift, writes with FileHandle.
    func saveAs(to url: URL, encoding: String.Encoding, delimiter: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // Build explicit column list excluding _gridka_rowid
        let exportColumns = columns
            .filter { $0.name != "_gridka_rowid" }
            .map { QueryCoordinator.quote($0.name) }
            .joined(separator: ", ")

        let headerParam = hasHeaders ? "true" : "false"
        let delimiterEscaped = delimiter.replacingOccurrences(of: "'", with: "''")

        if encoding == .utf8 {
            // DuckDB COPY TO natively supports UTF-8
            let path = url.path.replacingOccurrences(of: "'", with: "''")
            let sql = "COPY (SELECT \(exportColumns) FROM data) TO '\(path)' (FORMAT CSV, HEADER \(headerParam), DELIMITER '\(delimiterEscaped)', FORCE_QUOTE *)"

            queryQueue.async { [weak self] in
                do {
                    try self?.engine.execute(sql)
                    DispatchQueue.main.async {
                        self?.filePath = url
                        self?.isModified = false
                        completion(.success(()))
                    }
                } catch {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        } else {
            // For non-UTF-8 encodings: query all data as UTF-8, transcode in Swift
            let sql = "SELECT \(exportColumns) FROM data"
            let colNames = columns
                .filter { $0.name != "_gridka_rowid" }
                .map { $0.name }

            queryQueue.async { [weak self] in
                do {
                    let result = try self?.engine.execute(sql)
                    guard let result = result else {
                        DispatchQueue.main.async {
                            completion(.failure(GridkaError.queryFailed("No result from query")))
                        }
                        return
                    }

                    var lines: [String] = []

                    // Header row
                    if self?.hasHeaders ?? true {
                        let escapedNames = colNames.map { name -> String in
                            if name.contains(delimiter) || name.contains("\"") || name.contains("\n") {
                                return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                            }
                            return name
                        }
                        lines.append(escapedNames.joined(separator: delimiter))
                    }

                    // Data rows
                    for row in 0..<result.rowCount {
                        var fields: [String] = []
                        for col in 0..<result.columnCount {
                            let value = result.value(row: row, col: col)
                            let text: String
                            switch value {
                            case .null:
                                text = ""
                            case .string(let s):
                                text = s
                            case .integer(let i):
                                text = String(i)
                            case .double(let d):
                                text = String(d)
                            case .boolean(let b):
                                text = b ? "true" : "false"
                            case .date(let d):
                                text = d
                            }
                            // Force-quote all fields to preserve type info (matches FORCE_QUOTE * in UTF-8 path)
                            fields.append("\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
                        }
                        lines.append(fields.joined(separator: delimiter))
                    }

                    let csvContent = lines.joined(separator: "\n") + "\n"

                    guard let data = csvContent.data(using: encoding) else {
                        DispatchQueue.main.async {
                            completion(.failure(GridkaError.loadFailed("Cannot encode data to the selected encoding")))
                        }
                        return
                    }

                    try data.write(to: url)

                    DispatchQueue.main.async {
                        self?.filePath = url
                        self?.isModified = false
                        completion(.success(()))
                    }
                } catch {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - Add Column

    /// Adds a new column to the data table via ALTER TABLE.
    /// `duckDBType` should be one of: VARCHAR, BIGINT, DOUBLE, DATE, BOOLEAN.
    /// On success, refreshes column descriptors from the updated table schema.
    func addColumn(name: String, duckDBType: String, completion: @escaping (Result<[ColumnDescriptor], Error>) -> Void) {
        let quotedName = QueryCoordinator.quote(name)
        let alterSQL = "ALTER TABLE data ADD COLUMN \(quotedName) \(duckDBType)"
        let schemaSQL = "SELECT * FROM data LIMIT 0"

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.engine.execute(alterSQL)
                let colResult = try self.engine.execute(schemaSQL)
                let cols = self.extractColumns(from: colResult)

                DispatchQueue.main.async {
                    self.columns = cols
                    self.isModified = true
                    self.rowCache.invalidateAll()
                    completion(.success(cols))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Rename Column

    /// Renames a column via ALTER TABLE RENAME COLUMN.
    /// On success, refreshes column descriptors and updates filters/sort referencing the old name.
    func renameColumn(oldName: String, newName: String, completion: @escaping (Result<[ColumnDescriptor], Error>) -> Void) {
        let quotedOld = QueryCoordinator.quote(oldName)
        let quotedNew = QueryCoordinator.quote(newName)
        let renameSQL = "ALTER TABLE data RENAME COLUMN \(quotedOld) TO \(quotedNew)"
        let schemaSQL = "SELECT * FROM data LIMIT 0"

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.engine.execute(renameSQL)
                let colResult = try self.engine.execute(schemaSQL)
                let cols = self.extractColumns(from: colResult)

                DispatchQueue.main.async {
                    self.columns = cols
                    self.isModified = true
                    self.rowCache.invalidateAll()

                    // Update ViewState: rename in sort columns
                    self.viewState.sortColumns = self.viewState.sortColumns.map { sc in
                        if sc.column == oldName {
                            return SortColumn(column: newName, direction: sc.direction)
                        }
                        return sc
                    }

                    // Update ViewState: rename in filters
                    self.viewState.filters = self.viewState.filters.map { f in
                        if f.column == oldName {
                            return ColumnFilter(column: newName, operator: f.`operator`, value: f.value, negate: f.negate)
                        }
                        return f
                    }

                    // Update ViewState: rename selected column
                    if self.viewState.selectedColumn == oldName {
                        self.viewState.selectedColumn = newName
                    }

                    // Update edited cells: rename column references
                    let updatedEdited = Set(self.editedCells.map { cell in
                        if cell.column == oldName {
                            return EditedCell(rowid: cell.rowid, column: newName)
                        }
                        return cell
                    })
                    self.editedCells = updatedEdited

                    completion(.success(cols))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Change Column Type

    /// Changes a column's data type via ALTER TABLE ALTER COLUMN SET DATA TYPE.
    /// If ALTER COLUMN is not supported, uses a workaround: add new column with CAST, drop old, rename.
    /// On success, refreshes column descriptors from the updated table schema.
    func changeColumnType(columnName: String, newDuckDBType: String, completion: @escaping (Result<[ColumnDescriptor], Error>) -> Void) {
        let quotedColumn = QueryCoordinator.quote(columnName)
        let alterSQL = "ALTER TABLE data ALTER COLUMN \(quotedColumn) SET DATA TYPE \(newDuckDBType)"
        let schemaSQL = "SELECT * FROM data LIMIT 0"

        queryQueue.async { [weak self] in
            guard let self = self else { return }

            // Try the direct ALTER COLUMN approach first
            var success = false
            do {
                try self.engine.execute(alterSQL)
                success = true
            } catch {
                // ALTER COLUMN may not be supported — try workaround
            }

            if !success {
                // Workaround: add temp column with CAST, drop original, rename temp
                let tempName = "_gridka_temp_\(columnName)"
                let quotedTemp = QueryCoordinator.quote(tempName)
                let addSQL = "ALTER TABLE data ADD COLUMN \(quotedTemp) \(newDuckDBType)"
                let updateSQL = "UPDATE data SET \(quotedTemp) = CAST(\(quotedColumn) AS \(newDuckDBType))"
                let dropSQL = "ALTER TABLE data DROP COLUMN \(quotedColumn)"
                let renameSQL = "ALTER TABLE data RENAME COLUMN \(quotedTemp) TO \(quotedColumn)"

                do {
                    try self.engine.execute(addSQL)
                    try self.engine.execute(updateSQL)
                    try self.engine.execute(dropSQL)
                    try self.engine.execute(renameSQL)
                } catch {
                    // Clean up temp column if it was added
                    try? self.engine.execute("ALTER TABLE data DROP COLUMN IF EXISTS \(quotedTemp)")
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                    return
                }
            }

            // Refresh schema
            do {
                let colResult = try self.engine.execute(schemaSQL)
                let cols = self.extractColumns(from: colResult)

                DispatchQueue.main.async {
                    self.columns = cols
                    self.isModified = true
                    self.rowCache.invalidateAll()
                    completion(.success(cols))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Delete Column

    /// Deletes a column via ALTER TABLE DROP COLUMN.
    /// On success, refreshes column descriptors and removes references from ViewState.
    func deleteColumn(name: String, completion: @escaping (Result<[ColumnDescriptor], Error>) -> Void) {
        let quotedName = QueryCoordinator.quote(name)
        let dropSQL = "ALTER TABLE data DROP COLUMN \(quotedName)"
        let schemaSQL = "SELECT * FROM data LIMIT 0"

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.engine.execute(dropSQL)
                let colResult = try self.engine.execute(schemaSQL)
                let cols = self.extractColumns(from: colResult)

                DispatchQueue.main.async {
                    self.columns = cols
                    self.isModified = true
                    self.rowCache.invalidateAll()

                    // Remove any sort columns referencing the deleted column
                    self.viewState.sortColumns.removeAll { $0.column == name }

                    // Remove any filters referencing the deleted column
                    self.viewState.filters.removeAll { $0.column == name }

                    // Clear selected column if it was deleted
                    if self.viewState.selectedColumn == name {
                        self.viewState.selectedColumn = nil
                    }

                    // Remove edited cell indicators for the deleted column
                    self.editedCells = self.editedCells.filter { $0.column != name }

                    completion(.success(cols))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Add Row

    /// Inserts a new row with all NULL values except _gridka_rowid.
    /// Returns the new row's _gridka_rowid on success.
    func addRow(completion: @escaping (Result<Int64, Error>) -> Void) {
        let insertSQL = "INSERT INTO data (_gridka_rowid) VALUES ((SELECT COALESCE(MAX(_gridka_rowid), 0) + 1 FROM data))"
        let rowidSQL = "SELECT MAX(_gridka_rowid) FROM data"

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.engine.execute(insertSQL)
                let result = try self.engine.execute(rowidSQL)
                let newRowid: Int64
                if result.rowCount > 0, case .integer(let rid) = result.value(row: 0, col: 0) {
                    newRowid = rid
                } else {
                    newRowid = 1
                }

                DispatchQueue.main.async {
                    self.totalRows += 1
                    self.viewState.totalFilteredRows += 1
                    self.isModified = true
                    // Invalidate last page of cache since the new row appears at the end
                    let lastPageIndex = self.rowCache.pageIndex(forRow: self.viewState.totalFilteredRows - 1)
                    self.rowCache.invalidatePage(lastPageIndex)
                    completion(.success(newRowid))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Delete Rows

    /// Deletes one or more rows by their _gridka_rowid values.
    /// On success, invalidates the row cache and decrements row counts.
    func deleteRows(rowids: [Int64], completion: @escaping (Result<Void, Error>) -> Void) {
        let idList = rowids.map { String($0) }.joined(separator: ", ")
        let deleteSQL = "DELETE FROM data WHERE _gridka_rowid IN (\(idList))"
        let countSQL = "SELECT COUNT(*) FROM data"

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.engine.execute(deleteSQL)
                let countResult = try self.engine.execute(countSQL)
                let newTotal: Int
                if countResult.rowCount > 0, case .integer(let count) = countResult.value(row: 0, col: 0) {
                    newTotal = Int(count)
                } else {
                    newTotal = 0
                }

                DispatchQueue.main.async {
                    self.totalRows = newTotal
                    self.isModified = true
                    self.rowCache.invalidateAll()

                    // Remove edited cell indicators for deleted rows
                    let deletedSet = Set(rowids)
                    self.editedCells = self.editedCells.filter { !deletedSet.contains($0.rowid) }

                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Cell Editing

    /// Updates a single cell value via UPDATE SQL.
    /// The value string is written as-is (empty string for clearing a cell).
    /// `displayRow` is the row index in the current view (respecting sort/filter) used for cache invalidation.
    func updateCell(rowid: Int64, column: String, value: String, displayRow: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        let quotedColumn = QueryCoordinator.quote(column)
        let escapedValue = value.replacingOccurrences(of: "'", with: "''")
        let sql = "UPDATE data SET \(quotedColumn) = '\(escapedValue)' WHERE _gridka_rowid = \(rowid)"

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.engine.execute(sql)
                // Invalidate the cache page containing this display row
                let pageIndex = self.rowCache.pageIndex(forRow: displayRow)
                DispatchQueue.main.async {
                    self.rowCache.invalidatePage(pageIndex)
                    self.editedCells.insert(EditedCell(rowid: rowid, column: column))
                    self.isModified = true
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Profiler Queries

    /// Overview statistics for a column, displayed in the profiler sidebar.
    struct OverviewStats {
        let totalRows: Int
        let uniqueCount: Int
        let nullCount: Int
        let emptyCount: Int

        /// Percentage of non-null values (0.0–1.0).
        var completeness: Double {
            guard totalRows > 0 else { return 0 }
            return Double(totalRows - nullCount) / Double(totalRows)
        }
    }

    /// Increments the profiler generation counter, invalidating any in-flight profiler queries.
    func invalidateProfilerQueries() {
        profilerGeneration += 1
    }

    /// Fetches overview stats (rows, unique, nulls, empty) for the given column.
    /// The completion handler is called on the main thread.
    /// If a new column is selected or filters change before results arrive, stale results are discarded.
    /// Must be called from the main thread (generation counter is main-thread-only).
    func fetchOverviewStats(columnName: String, completion: @escaping (Result<OverviewStats, Error>) -> Void) {
        profilerGeneration += 1
        let generation = profilerGeneration

        let sql = profilerQueryBuilder.buildOverviewQuery(
            columnName: columnName,
            viewState: viewState,
            columns: columns
        )

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)

                // Parse results on queryQueue before dispatching to main
                let totalRows: Int
                if result.rowCount > 0, case .integer(let v) = result.value(row: 0, col: 0) { totalRows = Int(v) }
                else { totalRows = 0 }

                let uniqueCount: Int
                if result.rowCount > 0, case .integer(let v) = result.value(row: 0, col: 1) { uniqueCount = Int(v) }
                else { uniqueCount = 0 }

                let nullCount: Int
                if result.rowCount > 0, case .integer(let v) = result.value(row: 0, col: 2) { nullCount = Int(v) }
                else { nullCount = 0 }

                let emptyCount: Int
                if result.rowCount > 0, case .integer(let v) = result.value(row: 0, col: 3) { emptyCount = Int(v) }
                else { emptyCount = 0 }

                let stats = OverviewStats(
                    totalRows: totalRows,
                    uniqueCount: uniqueCount,
                    nullCount: nullCount,
                    emptyCount: emptyCount
                )

                // Check generation on main thread only — profilerGeneration is main-thread-only
                DispatchQueue.main.async {
                    guard self.profilerGeneration == generation else { return }
                    completion(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.profilerGeneration == generation else { return }
                    completion(.failure(error))
                }
            }
        }
    }

    /// Descriptive statistics for numeric columns, displayed in the profiler sidebar.
    struct DescriptiveStats {
        let min: Double
        let max: Double
        let mean: Double?
        let median: Double?
        let stdDev: Double?
        let q1: Double?
        let q3: Double?

        /// Interquartile range: Q3 - Q1, or nil if either quartile is unavailable.
        var iqr: Double? {
            guard let q1 = q1, let q3 = q3 else { return nil }
            return q3 - q1
        }
    }

    /// Fetches descriptive statistics (min, max, mean, median, stddev, q1, q3) for a numeric column.
    /// The completion handler is called on the main thread.
    /// If a new column is selected or filters change before results arrive, stale results are discarded.
    /// Must be called from the main thread (generation counter is main-thread-only).
    func fetchDescriptiveStats(columnName: String, completion: @escaping (Result<DescriptiveStats, Error>) -> Void) {
        let generation = profilerGeneration

        let sql = profilerQueryBuilder.buildDescriptiveStatsQuery(
            columnName: columnName,
            viewState: viewState,
            columns: columns
        )

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)

                guard result.rowCount > 0 else {
                    DispatchQueue.main.async {
                        guard self.profilerGeneration == generation else { return }
                        completion(.failure(GridkaError.queryFailed("No descriptive stats rows returned")))
                    }
                    return
                }

                // When all values in the column are NULL, DuckDB returns a single row
                // with NULL aggregates. Detect this by checking MIN (col 0) — if it's
                // NULL, there is no meaningful data to display.
                if case .null = result.value(row: 0, col: 0) {
                    DispatchQueue.main.async {
                        guard self.profilerGeneration == generation else { return }
                        completion(.failure(GridkaError.queryFailed("All values are NULL")))
                    }
                    return
                }

                func extractDouble(col: Int) -> Double? {
                    switch result.value(row: 0, col: col) {
                    case .double(let v): return v
                    case .integer(let v): return Double(v)
                    default: return nil
                    }
                }

                // min and max are guaranteed non-nil by the guard above (col 0 checked for .null).
                guard let colMin = extractDouble(col: 0), let colMax = extractDouble(col: 1) else {
                    DispatchQueue.main.async {
                        guard self.profilerGeneration == generation else { return }
                        completion(.failure(GridkaError.queryFailed("All values are NULL")))
                    }
                    return
                }

                let stats = DescriptiveStats(
                    min: colMin,
                    max: colMax,
                    mean: extractDouble(col: 2),
                    median: extractDouble(col: 3),
                    stdDev: extractDouble(col: 4),
                    q1: extractDouble(col: 5),
                    q3: extractDouble(col: 6)
                )

                DispatchQueue.main.async {
                    guard self.profilerGeneration == generation else { return }
                    completion(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.profilerGeneration == generation else { return }
                    completion(.failure(error))
                }
            }
        }
    }

    /// Distribution data for the profiler histogram.
    struct DistributionData {
        struct Bar {
            let label: String
            let count: Int
            var detail: String?
        }
        let bars: [Bar]
        var minLabel: String?
        var maxLabel: String?
        var trailingNote: String?
    }

    /// Fetches distribution data for the given column.
    /// Chooses numeric histogram, boolean counts, or categorical frequency based on column type.
    /// The completion handler is called on the main thread.
    func fetchDistribution(
        columnName: String,
        columnType: DuckDBColumnType,
        uniqueCount: Int,
        completion: @escaping (Result<DistributionData, Error>) -> Void
    ) {
        let generation = profilerGeneration

        let sql: String
        let parseMode: DistributionParseMode

        switch columnType {
        case .boolean:
            sql = profilerQueryBuilder.buildBooleanDistributionQuery(
                columnName: columnName, viewState: viewState, columns: columns
            )
            parseMode = .boolean

        case .integer, .bigint, .float, .double:
            sql = profilerQueryBuilder.buildNumericHistogramQuery(
                columnName: columnName, viewState: viewState, columns: columns
            )
            parseMode = .numeric

        default:
            // Categorical: VARCHAR, DATE, TIMESTAMP, etc.
            let limit = uniqueCount <= 50 ? uniqueCount : 10
            sql = profilerQueryBuilder.buildCategoricalFrequencyQuery(
                columnName: columnName, viewState: viewState, columns: columns, limit: limit
            )
            parseMode = .categorical(uniqueCount: uniqueCount)
        }

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)
                let data = self.parseDistribution(result: result, mode: parseMode)
                DispatchQueue.main.async {
                    guard self.profilerGeneration == generation else { return }
                    completion(.success(data))
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.profilerGeneration == generation else { return }
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Top Values

    /// Data for the top values section of the profiler sidebar.
    struct TopValuesData {
        struct ValueRow {
            let value: String
            let count: Int
            let percentage: Double
        }
        let rows: [ValueRow]
        let isAllUnique: Bool
        let uniqueCount: Int
        var isAllNull: Bool = false
    }

    /// Fetches the top 10 most frequent values for a column.
    /// The completion handler is called on the main thread.
    func fetchTopValues(
        columnName: String,
        totalRows: Int,
        nullCount: Int,
        uniqueCount: Int,
        completion: @escaping (Result<TopValuesData, Error>) -> Void
    ) {
        let generation = profilerGeneration

        // If all non-null values are unique, skip the query.
        // uniqueCount is COUNT(DISTINCT col) which excludes NULLs,
        // so compare against totalRows minus nullCount.
        let nonNullRows = totalRows - nullCount

        // All-NULL column: no non-null values to show
        if nonNullRows <= 0 {
            DispatchQueue.main.async {
                guard self.profilerGeneration == generation else { return }
                completion(.success(TopValuesData(rows: [], isAllUnique: false, uniqueCount: 0, isAllNull: true)))
            }
            return
        }

        if uniqueCount >= nonNullRows {
            DispatchQueue.main.async {
                guard self.profilerGeneration == generation else { return }
                completion(.success(TopValuesData(rows: [], isAllUnique: true, uniqueCount: uniqueCount)))
            }
            return
        }

        let sql = profilerQueryBuilder.buildTopValuesQuery(
            columnName: columnName,
            viewState: viewState,
            columns: columns
        )

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)
                var rows: [TopValuesData.ValueRow] = []

                for row in 0..<result.rowCount {
                    let label: String
                    switch result.value(row: row, col: 0) {
                    case .string(let v): label = v
                    case .integer(let v): label = String(v)
                    case .double(let v): label = String(v)
                    case .boolean(let v): label = v ? "true" : "false"
                    case .date(let v): label = v
                    case .null: label = "(null)"
                    }

                    let count: Int
                    if case .integer(let v) = result.value(row: row, col: 1) { count = Int(v) }
                    else { continue }

                    let pct = nonNullRows > 0 ? Double(count) / Double(nonNullRows) * 100 : 0
                    rows.append(TopValuesData.ValueRow(value: label, count: count, percentage: pct))
                }

                let data = TopValuesData(rows: rows, isAllUnique: false, uniqueCount: uniqueCount)
                DispatchQueue.main.async {
                    guard self.profilerGeneration == generation else { return }
                    completion(.success(data))
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.profilerGeneration == generation else { return }
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Full Frequency Data (for Frequency Panel)

    /// Complete frequency data for the frequency panel table.
    struct FrequencyData {
        struct Row {
            let value: String
            let count: Int
            let percentage: Double
        }
        let rows: [Row]
        let totalNonNull: Int
    }

    /// Fetches the complete value frequency distribution for the frequency panel (no LIMIT).
    /// The completion handler is called on the main thread.
    func fetchFullFrequency(
        columnName: String,
        completion: @escaping (Result<FrequencyData, Error>) -> Void
    ) {
        let sql = profilerQueryBuilder.buildFullFrequencyQuery(
            columnName: columnName,
            viewState: viewState,
            columns: columns
        )

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)
                var rows: [FrequencyData.Row] = []
                var totalCount = 0

                // First pass: collect all rows and compute total
                for row in 0..<result.rowCount {
                    let count: Int
                    if case .integer(let v) = result.value(row: row, col: 1) { count = Int(v) }
                    else { continue }
                    totalCount += count
                }

                // Second pass: compute percentages
                for row in 0..<result.rowCount {
                    let label: String
                    switch result.value(row: row, col: 0) {
                    case .string(let v): label = v
                    case .integer(let v): label = String(v)
                    case .double(let v): label = String(v)
                    case .boolean(let v): label = v ? "true" : "false"
                    case .date(let v): label = v
                    case .null: label = "(null)"
                    }

                    let count: Int
                    if case .integer(let v) = result.value(row: row, col: 1) { count = Int(v) }
                    else { continue }

                    let pct = totalCount > 0 ? Double(count) / Double(totalCount) * 100 : 0
                    rows.append(FrequencyData.Row(value: label, count: count, percentage: pct))
                }

                let data = FrequencyData(rows: rows, totalNonNull: totalCount)
                DispatchQueue.main.async {
                    completion(.success(data))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Fetches binned frequency data for numeric columns.
    func fetchBinnedFrequency(
        columnName: String,
        completion: @escaping (Result<FrequencyData, Error>) -> Void
    ) {
        let sql = profilerQueryBuilder.buildBinnedFrequencyQuery(
            columnName: columnName,
            viewState: viewState,
            columns: columns
        )

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.engine.execute(sql)
                var rows: [FrequencyData.Row] = []
                var totalCount = 0
                var globalMin: Double?
                var globalMax: Double?
                let bucketCount = 10

                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 2

                // First pass: compute total and extract min/max
                for row in 0..<result.rowCount {
                    let count: Int
                    if case .integer(let v) = result.value(row: row, col: 1) { count = Int(v) }
                    else { continue }
                    totalCount += count

                    if globalMin == nil {
                        switch result.value(row: row, col: 2) {
                        case .integer(let v): globalMin = Double(v)
                        case .double(let v): globalMin = v
                        default: break
                        }
                    }
                    if globalMax == nil {
                        switch result.value(row: row, col: 3) {
                        case .integer(let v): globalMax = Double(v)
                        case .double(let v): globalMax = v
                        default: break
                        }
                    }
                }

                // Second pass: build rows with bucket labels
                for row in 0..<result.rowCount {
                    let bucket: Int
                    if case .integer(let v) = result.value(row: row, col: 0) { bucket = Int(v) }
                    else { continue }

                    let count: Int
                    if case .integer(let v) = result.value(row: row, col: 1) { count = Int(v) }
                    else { continue }

                    var label = "Bin \(bucket)"
                    if let mn = globalMin, let mx = globalMax {
                        let range = mx - mn
                        let step = range / Double(bucketCount)
                        let lo = mn + Double(bucket - 1) * step
                        let hi = mn + Double(bucket) * step
                        let loStr = formatter.string(from: NSNumber(value: lo)) ?? "\(lo)"
                        let hiStr = formatter.string(from: NSNumber(value: hi)) ?? "\(hi)"
                        label = "\(loStr) – \(hiStr)"
                    }

                    let pct = totalCount > 0 ? Double(count) / Double(totalCount) * 100 : 0
                    rows.append(FrequencyData.Row(value: label, count: count, percentage: pct))
                }

                let data = FrequencyData(rows: rows, totalNonNull: totalCount)
                DispatchQueue.main.async {
                    completion(.success(data))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private enum DistributionParseMode {
        case numeric
        case boolean
        case categorical(uniqueCount: Int)
    }

    private func parseDistribution(result: DuckDBResult, mode: DistributionParseMode) -> DistributionData {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2

        switch mode {
        case .numeric:
            return parseNumericDistribution(result: result, formatter: formatter)
        case .boolean:
            return parseBooleanDistribution(result: result)
        case .categorical(let uniqueCount):
            return parseCategoricalDistribution(result: result, uniqueCount: uniqueCount, formatter: formatter)
        }
    }

    private func parseNumericDistribution(result: DuckDBResult, formatter: NumberFormatter) -> DistributionData {
        var bars: [DistributionData.Bar] = []
        var globalMin: Double?
        var globalMax: Double?
        let bucketCount = 10

        for row in 0..<result.rowCount {
            let bucket: Int
            if case .integer(let v) = result.value(row: row, col: 0) { bucket = Int(v) }
            else { continue }

            let count: Int
            if case .integer(let v) = result.value(row: row, col: 1) { count = Int(v) }
            else { continue }

            // col_min and col_max from the CTE
            if globalMin == nil {
                switch result.value(row: row, col: 2) {
                case .integer(let v): globalMin = Double(v)
                case .double(let v): globalMin = v
                default: break
                }
            }
            if globalMax == nil {
                switch result.value(row: row, col: 3) {
                case .integer(let v): globalMax = Double(v)
                case .double(let v): globalMax = v
                default: break
                }
            }

            bars.append(DistributionData.Bar(label: "#\(bucket)", count: count))
        }

        // Compute bucket labels from min/max
        if let mn = globalMin, let mx = globalMax, bars.count > 0 {
            let range = mx - mn
            let step = range / Double(bucketCount)
            for i in 0..<bars.count {
                let bucket: Int
                if let parsed = Int(bars[i].label.dropFirst()) { bucket = parsed }
                else { continue }
                let lo = mn + Double(bucket - 1) * step
                let hi = mn + Double(bucket) * step
                let loStr = formatter.string(from: NSNumber(value: lo)) ?? "\(lo)"
                let hiStr = formatter.string(from: NSNumber(value: hi)) ?? "\(hi)"
                bars[i] = DistributionData.Bar(
                    label: loStr,
                    count: bars[i].count,
                    detail: "\(loStr) – \(hiStr)"
                )
            }
        }

        let minStr = globalMin.flatMap { formatter.string(from: NSNumber(value: $0)) }
        let maxStr = globalMax.flatMap { formatter.string(from: NSNumber(value: $0)) }
        return DistributionData(bars: bars, minLabel: minStr, maxLabel: maxStr)
    }

    private func parseBooleanDistribution(result: DuckDBResult) -> DistributionData {
        guard result.rowCount > 0 else {
            return DistributionData(bars: [])
        }
        let trueCount: Int
        if case .integer(let v) = result.value(row: 0, col: 0) { trueCount = Int(v) }
        else { trueCount = 0 }

        let falseCount: Int
        if case .integer(let v) = result.value(row: 0, col: 1) { falseCount = Int(v) }
        else { falseCount = 0 }

        let total = trueCount + falseCount
        let truePct = total > 0 ? Int(round(Double(trueCount) / Double(total) * 100)) : 0
        let falsePct = total > 0 ? 100 - truePct : 0

        return DistributionData(bars: [
            DistributionData.Bar(label: "true (\(truePct)%)", count: trueCount),
            DistributionData.Bar(label: "false (\(falsePct)%)", count: falseCount),
        ])
    }

    private func parseCategoricalDistribution(result: DuckDBResult, uniqueCount: Int, formatter: NumberFormatter) -> DistributionData {
        var bars: [DistributionData.Bar] = []
        for row in 0..<result.rowCount {
            let label: String
            switch result.value(row: row, col: 0) {
            case .string(let v): label = v
            case .integer(let v): label = String(v)
            case .double(let v): label = formatter.string(from: NSNumber(value: v)) ?? String(v)
            case .boolean(let v): label = v ? "true" : "false"
            case .date(let v): label = v
            case .null: label = "(null)"
            }

            let count: Int
            if case .integer(let v) = result.value(row: row, col: 1) { count = Int(v) }
            else { continue }

            bars.append(DistributionData.Bar(label: label, count: count))
        }

        let trailingNote: String?
        if uniqueCount > 50 {
            let remaining = uniqueCount - bars.count
            trailingNote = remaining > 0 ? "and \(remaining) more…" : nil
        } else {
            trailingNote = nil
        }

        return DistributionData(bars: bars, trailingNote: trailingNote)
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

    /// Re-queries the filtered row count. Used after row deletion to update totalFilteredRows.
    func requeryFilteredCount() {
        requeryCount()
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
