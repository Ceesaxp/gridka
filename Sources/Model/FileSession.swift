import Foundation

/// Identifies a single edited cell by its stable rowid and column name.
struct EditedCell: Hashable {
    let rowid: Int64
    let column: String
}

final class FileSession {

    // MARK: - Properties

    // ── Thread Ownership ────────────────────────────────────────────────
    //
    // FileSession uses two execution contexts:
    //
    //   • **Main thread** — owns ALL mutable state: viewState, rowCache,
    //     columns, totalRows, isFullyLoaded, generation counters,
    //     columnSummaries, editedCells, isModified, and configuration
    //     properties (hasHeaders, customDelimiter, overrideEncoding, etc.).
    //     Every public method that reads or writes these properties MUST be
    //     called on the main thread.
    //
    //   • **queryQueue** (serial) — owns DuckDB engine access. All SQL
    //     execution happens here. Closures dispatched to queryQueue must
    //     NOT read or write main-thread state; they capture snapshots of
    //     the values they need *before* the async dispatch and return
    //     results back to main via DispatchQueue.main.async.
    //
    // Key public methods assert `dispatchPrecondition(condition: .onQueue(.main))`
    // to catch violations at runtime during development.
    // ─────────────────────────────────────────────────────────────────────

    private(set) var filePath: URL
    private let engine: DuckDBEngine
    private let queryCoordinator = QueryCoordinator()
    private let profilerQueryBuilder = ProfilerQueryBuilder()
    private let queryQueue: DispatchQueue

    /// Monotonic generation token for page fetches. Incremented when viewState changes
    /// invalidate the row cache (sort/filter/search/computed columns). Fetch callbacks
    /// that carry a stale generation are discarded so rowCache never receives stale data.
    /// Main-thread only.
    private var viewStateGeneration: Int = 0

    /// Generation counter for profiler queries. Incremented when column selection or
    /// filter/search state changes. Results with a stale generation are discarded.
    /// Main-thread only.
    private var profilerGeneration: Int = 0

    /// Generation counter for column summary computation. Incremented when summaries are
    /// invalidated (data mutations, reload). Prevents stale summary results from being stored.
    /// Main-thread only.
    private var summaryGeneration: Int = 0

    /// Cached column summaries keyed by column name. Computed once after full file load.
    /// Invalidated when underlying data changes (cell edit, row delete, column add/delete, reload).
    /// Main-thread only.
    private(set) var columnSummaries: [String: ColumnSummary] = [:]

    /// Callback invoked on the main thread when column summaries finish computing.
    var onSummariesComputed: (() -> Void)?

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

    /// Name of the summary temp table (non-nil only for summary sessions created by Group By).
    /// Summary sessions share the engine and queryQueue with their source session.
    private(set) var summaryTableName: String?

    /// Whether this is a summary session (Group By result tab).
    var isSummarySession: Bool { summaryTableName != nil }

    /// Counter for unique summary table names across the app lifetime.
    private static var summaryCounter = 0

    // MARK: - Init

    init(filePath: URL) throws {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            throw GridkaError.fileNotFound(filePath.path)
        }
        self.filePath = filePath
        self.queryQueue = DispatchQueue(label: "com.gridka.query-queue")
        self.viewState = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<0,
            totalFilteredRows: 0
        )
        self.engine = try DuckDBEngine()
    }

    /// Private init for summary sessions that share an existing engine and queryQueue.
    private init(engine: DuckDBEngine, queryQueue: DispatchQueue, summaryTableName: String, filePath: URL) {
        self.engine = engine
        self.queryQueue = queryQueue
        self.summaryTableName = summaryTableName
        self.tableName = summaryTableName
        self.filePath = filePath
        self.viewState = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<0,
            totalFilteredRows: 0
        )
        self.isFullyLoaded = true
        // Route all queries to the summary temp table instead of "data"
        self.queryCoordinator.tableName = summaryTableName
        self.profilerQueryBuilder.tableName = summaryTableName
    }

    // MARK: - Summary Session Factory (US-023)

    /// Creates a summary session backed by a temp table with Group By results.
    /// The summary session shares the source session's DuckDB engine and queryQueue.
    /// Runs the aggregation query on the source's queryQueue; calls completion on main thread.
    static func createSummarySession(
        from sourceSession: FileSession,
        definition: GroupByDefinition,
        completion: @escaping (Result<FileSession, Error>) -> Void
    ) {
        summaryCounter += 1
        let tempName = "summary_\(summaryCounter)"

        let source = sourceSession.queryCoordinator.buildSourceExpression(for: sourceSession.viewState)
        let whereClause = sourceSession.queryCoordinator.buildWhereSQL(for: sourceSession.viewState, columns: sourceSession.columns)
        let whereSQL = whereClause.isEmpty ? "" : " WHERE \(whereClause)"

        // Build SELECT clause: group-by columns + aggregation expressions
        var selectParts: [String] = []
        for col in definition.groupByColumns {
            selectParts.append(QueryCoordinator.quote(col))
        }
        for agg in definition.aggregations {
            let fn = agg.function.rawValue
            let colExpr = agg.columnName == "*" ? "*" : QueryCoordinator.quote(agg.columnName)
            let alias = agg.columnName == "*"
                ? "\(fn)(*)"
                : "\(fn)(\(agg.columnName))"
            selectParts.append("\(fn)(\(colExpr)) AS \(QueryCoordinator.quote(alias))")
        }

        let groupBySQL: String
        if definition.groupByColumns.isEmpty {
            groupBySQL = ""
        } else {
            let groupCols = definition.groupByColumns.map { QueryCoordinator.quote($0) }.joined(separator: ", ")
            groupBySQL = " GROUP BY \(groupCols)"
        }

        let createSQL = "CREATE TEMP TABLE \(QueryCoordinator.quote(tempName)) AS SELECT \(selectParts.joined(separator: ", ")) FROM \(source)\(whereSQL)\(groupBySQL)"
        let countSQL = "SELECT COUNT(*) FROM \(QueryCoordinator.quote(tempName))"

        sourceSession.queryQueue.async {
            do {
                try sourceSession.engine.execute(createSQL)
                let countResult = try sourceSession.engine.execute(countSQL)

                let totalRows: Int
                if countResult.rowCount > 0, case .integer(let val) = countResult.value(row: 0, col: 0) {
                    totalRows = Int(val)
                } else {
                    totalRows = 0
                }

                // Extract column metadata from the temp table
                let colResult = try sourceSession.engine.execute("SELECT * FROM \(QueryCoordinator.quote(tempName)) LIMIT 0")
                let cols = sourceSession.extractColumns(from: colResult)

                DispatchQueue.main.async {
                    let session = FileSession(
                        engine: sourceSession.engine,
                        queryQueue: sourceSession.queryQueue,
                        summaryTableName: tempName,
                        filePath: sourceSession.filePath
                    )
                    session.columns = cols
                    session.totalRows = totalRows
                    session.viewState.totalFilteredRows = totalRows
                    completion(.success(session))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Drops the summary temp table. Called when a summary tab is closed.
    /// Uses strong captures so the engine stays alive until the DROP executes,
    /// even if the FileSession is deallocated before the queue runs.
    func dropSummaryTable() {
        guard let name = summaryTableName else { return }
        let engine = self.engine
        queryQueue.async {
            try? engine.execute("DROP TABLE IF EXISTS \(QueryCoordinator.quote(name))")
        }
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
        dispatchPrecondition(condition: .onQueue(.main))
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
        dispatchPrecondition(condition: .onQueue(.main))
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
        dispatchPrecondition(condition: .onQueue(.main))
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
                    self.invalidateRowCache()
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
        dispatchPrecondition(condition: .onQueue(.main))
        let range = rowCache.pageRange(forPageIndex: index)
        let sql = queryCoordinator.buildQuery(for: viewState, columns: columns, range: range)
        let generation = viewStateGeneration

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
                    // Skip cache insert for stale results: if viewState changed
                    // since this fetch was dispatched, the cache was already
                    // invalidated and these rows are from an obsolete state.
                    // Always call completion so callers can clear bookkeeping
                    // state (e.g. fetchingPages in TableViewController).
                    if generation == self.viewStateGeneration {
                        self.rowCache.insertPage(page)
                    }
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
        dispatchPrecondition(condition: .onQueue(.main))
        hasHeaders = withHeaders
        reloadTable(progress: progress, completion: completion)
    }

    func reload(withDelimiter delimiter: String?, progress: @escaping (Double) -> Void, completion: @escaping (Result<Int, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        customDelimiter = delimiter
        reloadTable(progress: progress, completion: completion)
    }

    /// Reload the file with a specific encoding.
    /// For UTF-8 and auto-detect, loads directly. For other encodings, transcodes to a UTF-8 temp file first.
    func reload(withEncoding encodingName: String, swiftEncoding: String.Encoding?, progress: @escaping (Double) -> Void, completion: @escaping (Result<Int, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
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

                guard let encoding = swiftEncoding,
                      let content = String(data: fileData, encoding: encoding) else {
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
                    self.invalidateRowCache()
                    self.invalidateColumnSummaries()
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
        dispatchPrecondition(condition: .onQueue(.main))
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
                    self.invalidateRowCache()
                    self.invalidateColumnSummaries()
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
        dispatchPrecondition(condition: .onQueue(.main))
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
                guard let self = self else {
                    DispatchQueue.main.async { completion(.failure(GridkaError.queryFailed("Session deallocated"))) }
                    return
                }
                try self.engine.execute(sql)
                DispatchQueue.main.async {
                    self.isModified = false
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
        dispatchPrecondition(condition: .onQueue(.main))
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
                    guard let self = self else {
                        DispatchQueue.main.async { completion(.failure(GridkaError.queryFailed("Session deallocated"))) }
                        return
                    }
                    try self.engine.execute(sql)
                    DispatchQueue.main.async {
                        self.filePath = url
                        self.isModified = false
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

    // MARK: - Export with Computed Columns

    /// Exports all rows including computed columns to a new CSV file via DuckDB COPY.
    /// The query includes computed column expressions: SELECT *, (expr1) AS name1, ... FROM data.
    /// The original file is never modified.
    func exportWithComputedColumns(to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let source = queryCoordinator.buildSourceExpression(for: viewState)

        // Build explicit column list excluding _gridka_rowid
        var exportColumns = columns
            .filter { $0.name != "_gridka_rowid" }
            .map { QueryCoordinator.quote($0.name) }
        // Append computed column names
        for cc in viewState.computedColumns {
            exportColumns.append(QueryCoordinator.quote(cc.name))
        }
        let columnList = exportColumns.joined(separator: ", ")

        let path = url.path.replacingOccurrences(of: "'", with: "''")
        let sql = "COPY (SELECT \(columnList) FROM \(source)) TO '\(path)' (FORMAT CSV, HEADER true, DELIMITER ',', FORCE_QUOTE *)"

        queryQueue.async { [weak self] in
            do {
                guard let self = self else {
                    DispatchQueue.main.async { completion(.failure(GridkaError.queryFailed("Session deallocated"))) }
                    return
                }
                try self.engine.execute(sql)
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Exports all rows from the summary temp table to a CSV file via DuckDB COPY.
    /// Only valid for summary sessions (isSummarySession == true).
    func exportSummaryResults(to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let tableName = summaryTableName else {
            completion(.failure(GridkaError.queryFailed("Not a summary session")))
            return
        }

        let exportColumns = columns
            .filter { $0.name != "_gridka_rowid" }
            .map { QueryCoordinator.quote($0.name) }
            .joined(separator: ", ")

        let path = url.path.replacingOccurrences(of: "'", with: "''")
        let sql = "COPY (SELECT \(exportColumns) FROM \(QueryCoordinator.quote(tableName))) TO '\(path)' (FORMAT CSV, HEADER true, DELIMITER ',', FORCE_QUOTE *)"

        queryQueue.async { [weak self] in
            do {
                guard let self = self else {
                    DispatchQueue.main.async { completion(.failure(GridkaError.queryFailed("Session deallocated"))) }
                    return
                }
                try self.engine.execute(sql)
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Add Column

    /// Adds a new column to the data table via ALTER TABLE.
    /// `duckDBType` should be one of: VARCHAR, BIGINT, DOUBLE, DATE, BOOLEAN.
    /// On success, refreshes column descriptors from the updated table schema.
    func addColumn(name: String, duckDBType: String, completion: @escaping (Result<[ColumnDescriptor], Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
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
                    self.invalidateRowCache()
                    self.invalidateColumnSummaries()
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
        dispatchPrecondition(condition: .onQueue(.main))
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
                    self.invalidateRowCache()
                    self.invalidateColumnSummaries()

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
        dispatchPrecondition(condition: .onQueue(.main))
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
                    self.invalidateRowCache()
                    self.invalidateColumnSummaries()
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
        dispatchPrecondition(condition: .onQueue(.main))
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
                    self.invalidateRowCache()
                    self.invalidateColumnSummaries()

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
        dispatchPrecondition(condition: .onQueue(.main))
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
                    self.invalidateColumnSummaries()
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
        dispatchPrecondition(condition: .onQueue(.main))
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
                    self.invalidateRowCache()
                    self.invalidateColumnSummaries()

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

    // MARK: - Column Summary Computation (US-014)

    /// Clears cached column summaries. Called when underlying data changes.
    /// Must be called on the main thread.
    func invalidateColumnSummaries() {
        dispatchPrecondition(condition: .onQueue(.main))
        summaryGeneration += 1
        columnSummaries.removeAll()
    }

    /// Computes lightweight summary data for all columns after full file load.
    /// Runs batched queries on the serial query queue and caches results.
    /// Safe to call multiple times — stale results are discarded via generation counter.
    func computeColumnSummaries() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isFullyLoaded else { return }

        // Clear stale cache immediately so the UI never shows old summaries
        // from a previous dataset while new computation is in flight.
        invalidateColumnSummaries()
        let generation = summaryGeneration
        let currentColumns = columns.filter { $0.name != "_gridka_rowid" }
        let currentTotalRows = totalRows

        guard !currentColumns.isEmpty else { return }

        // Phase 1: Batch cardinality/null query for all columns at once
        let cardinalitySQL = profilerQueryBuilder.buildBatchCardinalityQuery(columns: currentColumns)

        queryQueue.async { [weak self] in
            guard let self = self else { return }

            // Step 1: Fetch cardinality and null counts for all columns
            var cardinalityMap: [String: (distinct: Int, nulls: Int)] = [:]
            do {
                let result = try self.engine.execute(cardinalitySQL)
                for row in 0..<result.rowCount {
                    let colName: String
                    if case .string(let name) = result.value(row: row, col: 0) { colName = name }
                    else { continue }

                    let distinct: Int
                    if case .integer(let v) = result.value(row: row, col: 1) { distinct = Int(v) }
                    else { distinct = 0 }

                    let nulls: Int
                    if case .integer(let v) = result.value(row: row, col: 2) { nulls = Int(v) }
                    else { nulls = 0 }

                    cardinalityMap[colName] = (distinct: distinct, nulls: nulls)
                }
            } catch {
                // If batch cardinality query fails, abort summary computation
                return
            }

            // Check generation before proceeding to per-column distribution queries
            var earlyAbort = false
            DispatchQueue.main.sync {
                if self.summaryGeneration != generation { earlyAbort = true }
            }
            if earlyAbort { return }

            // Step 2: Per-column distribution queries
            var summaries: [String: ColumnSummary] = [:]

            for col in currentColumns {
                // Check generation before each column query
                var shouldAbort = false
                DispatchQueue.main.sync {
                    if self.summaryGeneration != generation { shouldAbort = true }
                }
                if shouldAbort { return }

                let card = cardinalityMap[col.name] ?? (distinct: 0, nulls: 0)
                let displayType = self.mapDisplayType(from: col.duckDBType)

                let distribution: Distribution
                switch displayType {
                case .boolean:
                    distribution = self.computeBooleanDistribution(columnName: col.name)

                case .integer, .float:
                    distribution = self.computeNumericDistribution(columnName: col.name, bucketCount: 10)

                case .text, .date:
                    if card.distinct <= 15 {
                        distribution = self.computeCategoricalDistribution(columnName: col.name, limit: 15)
                    } else {
                        distribution = .highCardinality(uniqueCount: card.distinct)
                    }

                case .unknown:
                    distribution = .highCardinality(uniqueCount: card.distinct)
                }

                summaries[col.name] = ColumnSummary(
                    columnName: col.name,
                    detectedType: displayType,
                    cardinality: card.distinct,
                    nullCount: card.nulls,
                    totalRows: currentTotalRows,
                    distribution: distribution
                )
            }

            // Dispatch results to main thread, checking generation for staleness
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard self.summaryGeneration == generation else { return }
                self.columnSummaries = summaries
                self.onSummariesComputed?()
            }
        }
    }

    // MARK: - Summary Distribution Helpers (run on queryQueue)

    private func computeBooleanDistribution(columnName: String) -> Distribution {
        let sql = profilerQueryBuilder.buildSummaryBooleanDistributionQuery(columnName: columnName)
        do {
            let result = try engine.execute(sql)
            guard result.rowCount > 0 else {
                return .boolean(trueCount: 0, falseCount: 0)
            }
            let trueCount: Int
            if case .integer(let v) = result.value(row: 0, col: 0) { trueCount = Int(v) }
            else { trueCount = 0 }
            let falseCount: Int
            if case .integer(let v) = result.value(row: 0, col: 1) { falseCount = Int(v) }
            else { falseCount = 0 }
            return .boolean(trueCount: trueCount, falseCount: falseCount)
        } catch {
            return .boolean(trueCount: 0, falseCount: 0)
        }
    }

    private func computeNumericDistribution(columnName: String, bucketCount: Int) -> Distribution {
        let sql = profilerQueryBuilder.buildSummaryNumericHistogramQuery(columnName: columnName, bucketCount: bucketCount)
        do {
            let result = try engine.execute(sql)
            guard result.rowCount > 0 else {
                return .histogram(buckets: [])
            }

            // Extract min/max from first row
            let colMin: Double
            if case .double(let v) = result.value(row: 0, col: 2) { colMin = v }
            else if case .integer(let v) = result.value(row: 0, col: 2) { colMin = Double(v) }
            else { return .histogram(buckets: []) }

            let colMax: Double
            if case .double(let v) = result.value(row: 0, col: 3) { colMax = v }
            else if case .integer(let v) = result.value(row: 0, col: 3) { colMax = Double(v) }
            else { return .histogram(buckets: []) }

            let step = (colMax - colMin) / Double(bucketCount)

            var buckets: [(range: String, count: Int)] = []
            for row in 0..<result.rowCount {
                let bucket: Int
                if case .integer(let v) = result.value(row: row, col: 0) { bucket = Int(v) }
                else { continue }

                let count: Int
                if case .integer(let v) = result.value(row: row, col: 1) { count = Int(v) }
                else { continue }

                let low = colMin + Double(bucket - 1) * step
                let high = colMin + Double(bucket) * step
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = step == step.rounded() ? 0 : 1
                let lowStr = formatter.string(from: NSNumber(value: low)) ?? "\(low)"
                let highStr = formatter.string(from: NSNumber(value: high)) ?? "\(high)"
                buckets.append((range: "\(lowStr)–\(highStr)", count: count))
            }
            return .histogram(buckets: buckets)
        } catch {
            return .histogram(buckets: [])
        }
    }

    private func computeCategoricalDistribution(columnName: String, limit: Int) -> Distribution {
        let sql = profilerQueryBuilder.buildSummaryCategoricalFrequencyQuery(columnName: columnName, limit: limit)
        do {
            let result = try engine.execute(sql)
            var values: [(value: String, count: Int)] = []
            for row in 0..<result.rowCount {
                let value: String
                if case .string(let v) = result.value(row: row, col: 0) { value = v }
                else { value = "" }

                let count: Int
                if case .integer(let v) = result.value(row: row, col: 1) { count = Int(v) }
                else { continue }

                values.append((value: value, count: count))
            }
            return .frequency(values: values)
        } catch {
            return .frequency(values: [])
        }
    }

    // MARK: - Cell Editing

    /// Updates a single cell value via UPDATE SQL.
    /// The value string is written as-is (empty string for clearing a cell).
    /// `displayRow` is the row index in the current view (respecting sort/filter) used for cache invalidation.
    func updateCell(rowid: Int64, column: String, value: String, displayRow: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let quotedColumn = QueryCoordinator.quote(column)
        let escapedValue = value.replacingOccurrences(of: "'", with: "''")
        let sql = "UPDATE data SET \(quotedColumn) = '\(escapedValue)' WHERE _gridka_rowid = \(rowid)"
        // Compute page index on main thread — rowCache is main-thread-only.
        let pageIndex = rowCache.pageIndex(forRow: displayRow)

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.engine.execute(sql)
                DispatchQueue.main.async {
                    self.rowCache.invalidatePage(pageIndex)
                    self.editedCells.insert(EditedCell(rowid: rowid, column: column))
                    self.isModified = true
                    self.invalidateColumnSummaries()
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
    /// Must be called on the main thread.
    func invalidateProfilerQueries() {
        dispatchPrecondition(condition: .onQueue(.main))
        profilerGeneration += 1
    }

    /// Fetches overview stats (rows, unique, nulls, empty) for the given column.
    /// The completion handler is called on the main thread.
    /// If a new column is selected or filters change before results arrive, stale results are discarded.
    /// Must be called on the main thread.
    func fetchOverviewStats(columnName: String, completion: @escaping (Result<OverviewStats, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
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
    /// Must be called on the main thread.
    func fetchDescriptiveStats(columnName: String, completion: @escaping (Result<DescriptiveStats, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
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
    /// Must be called on the main thread.
    func fetchDistribution(
        columnName: String,
        columnType: DuckDBColumnType,
        uniqueCount: Int,
        completion: @escaping (Result<DistributionData, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
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
    /// Must be called on the main thread.
    func fetchTopValues(
        columnName: String,
        totalRows: Int,
        nullCount: Int,
        uniqueCount: Int,
        completion: @escaping (Result<TopValuesData, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
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
    /// Must be called on the main thread.
    func fetchFullFrequency(
        columnName: String,
        completion: @escaping (Result<FrequencyData, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
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
    /// Must be called on the main thread.
    func fetchBinnedFrequency(
        columnName: String,
        completion: @escaping (Result<FrequencyData, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
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

    // MARK: - Computed Column Preview (US-018)

    /// Result of a computed column preview query.
    struct ComputedColumnPreview {
        /// Column names in the result (context columns + computed column).
        let columnNames: [String]
        /// Rows of string values (up to 5 rows).
        let rows: [[String]]
    }

    /// Returns true if `sql` contains a semicolon outside of quoted contexts and SQL comments.
    /// Tracked contexts: single-quoted string literals (`'...'`), double-quoted identifiers
    /// (`"..."`), `--` line comments, and `/* */` block comments. Both quote styles handle
    /// SQL-standard doubled-character escaping (`''` and `""`).
    static func containsSemicolonOutsideQuotes(_ sql: String) -> Bool {
        var quoteChar: Character? = nil  // non-nil when inside '...' or "..."
        var i = sql.startIndex
        while i < sql.endIndex {
            let ch = sql[i]
            if let q = quoteChar {
                // Inside a quoted region — only the matching quote can end it
                if ch == q {
                    let next = sql.index(after: i)
                    if next < sql.endIndex && sql[next] == q {
                        // Doubled quote escape (''/"""), skip both
                        i = sql.index(after: next)
                        continue
                    }
                    quoteChar = nil
                }
            } else {
                if ch == "'" || ch == "\"" {
                    quoteChar = ch
                } else if ch == "-" {
                    // Check for -- line comment
                    let next = sql.index(after: i)
                    if next < sql.endIndex && sql[next] == "-" {
                        // Skip to end of line
                        i = sql.index(after: next)
                        while i < sql.endIndex && sql[i] != "\n" {
                            i = sql.index(after: i)
                        }
                        continue
                    }
                } else if ch == "/" {
                    // Check for /* block comment */
                    let next = sql.index(after: i)
                    if next < sql.endIndex && sql[next] == "*" {
                        i = sql.index(after: next)
                        while i < sql.endIndex {
                            if sql[i] == "*" {
                                let afterStar = sql.index(after: i)
                                if afterStar < sql.endIndex && sql[afterStar] == "/" {
                                    i = sql.index(after: afterStar)
                                    break
                                }
                            }
                            i = sql.index(after: i)
                        }
                        continue
                    }
                } else if ch == ";" {
                    return true
                }
            }
            i = sql.index(after: i)
        }
        return false
    }

    /// Executes a preview query for a computed column expression.
    /// Selects up to 3 existing columns for context plus the expression result, LIMIT 5.
    /// Completion is called on the main thread with either the preview data or an error.
    func fetchComputedColumnPreview(
        expression: String,
        columnName: String,
        completion: @escaping (Result<ComputedColumnPreview, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Reject semicolons outside string literals to prevent multi-statement injection
        // (e.g. "1); COMMIT; DELETE FROM data; --") that could escape the read-only
        // transaction below. Semicolons inside single-quoted literals are safe
        // (e.g. REPLACE(col, ';', ',')).
        if Self.containsSemicolonOutsideQuotes(expression) {
            DispatchQueue.main.async {
                completion(.failure(GridkaError.invalidExpression("Expression must not contain semicolons outside of string literals")))
            }
            return
        }

        // Pick up to 3 context columns (skip _gridka_rowid)
        let contextCols = columns
            .filter { $0.name != "_gridka_rowid" }
            .prefix(3)
            .map { QueryCoordinator.quote($0.name) }

        let quotedName = QueryCoordinator.quote(columnName.isEmpty ? "computed" : columnName)
        let selectParts = contextCols + ["(\(expression)) AS \(quotedName)"]
        let sql = "SELECT \(selectParts.joined(separator: ", ")) FROM data LIMIT 5"

        queryQueue.async { [weak self] in
            guard let self = self else { return }

            // SAFETY: Wrap preview in a read-only transaction so that even if the
            // expression contains injected statements (e.g. "; DELETE FROM data; --"),
            // DuckDB will reject any write operations. The ROLLBACK in the defer
            // ensures the transaction is always closed, even on error.
            do {
                try self.engine.execute("BEGIN TRANSACTION READ ONLY")
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            defer { try? self.engine.execute("ROLLBACK") }

            do {
                let result = try self.engine.execute(sql)
                var colNames: [String] = []
                for i in 0..<result.columnCount {
                    colNames.append(result.columnName(at: i))
                }
                var rows: [[String]] = []
                for r in 0..<result.rowCount {
                    var row: [String] = []
                    for c in 0..<result.columnCount {
                        row.append(result.value(row: r, col: c).description)
                    }
                    rows.append(row)
                }
                let preview = ComputedColumnPreview(columnNames: colNames, rows: rows)
                DispatchQueue.main.async {
                    completion(.success(preview))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Group By Preview (US-022)

    /// Result of a Group By preview query.
    struct GroupByPreview {
        /// Column names in the result (group-by columns + aggregation columns).
        let columnNames: [String]
        /// Rows of string values (up to 5 rows, ordered by COUNT(*) DESC).
        let rows: [[String]]
        /// Total number of groups (not just the preview rows).
        let totalGroups: Int
    }

    /// Fetches a preview of the Group By aggregation: top 5 groups by count descending,
    /// plus the total group count. Runs on the serial queryQueue; completion on main thread.
    func fetchGroupByPreview(
        groupByColumns: [String],
        aggregations: [AggregationEntry],
        completion: @escaping (Result<GroupByPreview, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !aggregations.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(GridkaError.queryFailed("No aggregations specified")))
            }
            return
        }

        let source = queryCoordinator.buildSourceExpression(for: viewState)
        let whereClause = queryCoordinator.buildWhereSQL(for: viewState, columns: columns)
        let whereSQL = whereClause.isEmpty ? "" : " WHERE \(whereClause)"

        // Build SELECT clause: group-by columns + aggregation expressions
        var selectParts: [String] = []
        for col in groupByColumns {
            selectParts.append(QueryCoordinator.quote(col))
        }
        for agg in aggregations {
            let fn = agg.function.rawValue
            let colExpr = agg.columnName == "*" ? "*" : QueryCoordinator.quote(agg.columnName)
            let alias = agg.columnName == "*"
                ? "\(fn)(*)"
                : "\(fn)(\(agg.columnName))"
            selectParts.append("\(fn)(\(colExpr)) AS \(QueryCoordinator.quote(alias))")
        }

        let groupBySQL: String
        if groupByColumns.isEmpty {
            groupBySQL = ""
        } else {
            let groupCols = groupByColumns.map { QueryCoordinator.quote($0) }.joined(separator: ", ")
            groupBySQL = " GROUP BY \(groupCols)"
        }

        // Preview query: top 5 groups by COUNT(*) DESC
        let previewSQL = "SELECT \(selectParts.joined(separator: ", ")) FROM \(source)\(whereSQL)\(groupBySQL) ORDER BY COUNT(*) DESC LIMIT 5"

        // Count query: total number of groups
        let countSQL: String
        if groupByColumns.isEmpty {
            // No group-by means a single aggregated row
            countSQL = "SELECT 1"
        } else {
            let groupCols = groupByColumns.map { QueryCoordinator.quote($0) }.joined(separator: ", ")
            countSQL = "SELECT COUNT(*) FROM (SELECT 1 FROM \(source)\(whereSQL) GROUP BY \(groupCols))"
        }

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let previewResult = try self.engine.execute(previewSQL)
                let countResult = try self.engine.execute(countSQL)

                var colNames: [String] = []
                for i in 0..<previewResult.columnCount {
                    colNames.append(previewResult.columnName(at: i))
                }
                var rows: [[String]] = []
                for r in 0..<previewResult.rowCount {
                    var row: [String] = []
                    for c in 0..<previewResult.columnCount {
                        row.append(previewResult.value(row: r, col: c).description)
                    }
                    rows.append(row)
                }

                let totalGroups: Int
                if countResult.rowCount > 0, case .integer(let val) = countResult.value(row: 0, col: 0) {
                    totalGroups = Int(val)
                } else {
                    totalGroups = groupByColumns.isEmpty ? 1 : rows.count
                }

                let preview = GroupByPreview(columnNames: colNames, rows: rows, totalGroups: totalGroups)
                DispatchQueue.main.async {
                    completion(.success(preview))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - View State Updates

    /// Updates the view state and optionally re-queries the filtered row count.
    /// - Parameters:
    ///   - newState: The new view state to apply.
    ///   - completion: Called on the main thread after the filtered count is updated
    ///     (if a requery was needed), or immediately if no count requery is required.
    func updateViewState(_ newState: ViewState, completion: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let countChanged = newState.filters != viewState.filters
            || newState.searchTerm != viewState.searchTerm
        let computedColumnsChanged = newState.computedColumns != viewState.computedColumns
        // Computed column changes affect count when a search term is active
        // because search ORs across computed column aliases
        let computedAffectsCount = computedColumnsChanged
            && (newState.searchTerm ?? "").isEmpty == false
        let cacheInvalidated = countChanged
            || newState.sortColumns != viewState.sortColumns
            || computedColumnsChanged

        viewState = newState

        if cacheInvalidated {
            invalidateRowCache()
        }
        // Re-query count when filters/search change, or when computed columns
        // change while a search term is active (search includes computed aliases)
        if countChanged || computedAffectsCount {
            requeryCount(completion: completion)
        } else {
            completion?()
        }
    }

    /// Re-queries the filtered row count. Used after row deletion to update totalFilteredRows.
    /// Must be called on the main thread.
    /// - Parameter completion: Called on the main thread after totalFilteredRows is updated.
    func requeryFilteredCount(completion: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        requeryCount(completion: completion)
    }

    // MARK: - Private Helpers

    /// Invalidates the entire row cache and bumps the view-state generation so that
    /// any in-flight page fetches dispatched before this point are discarded on arrival.
    /// Must be called on the main thread.
    private func invalidateRowCache() {
        dispatchPrecondition(condition: .onQueue(.main))
        viewStateGeneration += 1
        rowCache.invalidateAll()
    }

    private func requeryCount(completion: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
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
                    completion?()
                }
            } catch {
                DispatchQueue.main.async {
                    completion?()
                }
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
