# Gridka — Technical Design Document

**Version:** 1.0  
**Date:** February 2026  
**Status:** Draft

---

## 1. Architecture Overview

Gridka is a single-process native macOS application. Swift (AppKit) owns the UI and application lifecycle. DuckDB is embedded via its C API, accessed through a thin Swift bridging layer. There is no IPC, no serialization boundary, and no separate backend process.

```
┌──────────────────────────────────────────────────────┐
│                    Gridka.app                         │
│                                                      │
│  ┌─────────────────────┐  ┌────────────────────────┐ │
│  │     AppKit UI        │  │    DuckDB Engine       │ │
│  │                      │  │                        │ │
│  │  NSTableView         │  │  In-memory database    │ │
│  │  (virtual scrolling) │◄─┤  C API via bridging    │ │
│  │                      │  │  header                │ │
│  │  Filter Bar          │  │                        │ │
│  │  Search Bar          │──►  SQL generation        │ │
│  │  Status Bar          │  │                        │ │
│  │  Detail Pane         │  │  read_csv_auto()       │ │
│  └─────────────────────┘  └────────────────────────┘ │
│                                                      │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Query Coordinator                   │ │
│  │  View State → SQL → Execute → DataSource update  │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

### Why This Architecture

The analogy: Gridka is like a database client (pgAdmin, DataGrip) where the database happens to be embedded and the "table" is a CSV file. Every user interaction translates to SQL. The UI is a thin projection of query results.

---

## 2. Domain Model

```
FileSession
├── filePath: URL
├── duckDBConnection: OpaquePointer      // duckdb_connection
├── tableName: String                     // sanitized identifier
├── columns: [ColumnDescriptor]           // name, type, index
└── viewState: ViewState

ViewState
├── sortColumns: [(column: String, direction: SortDirection)]
├── filters: [ColumnFilter]
├── searchTerm: String?
├── visibleRange: Range<Int>              // current viewport rows
└── totalFilteredRows: Int                // cached count

ColumnDescriptor
├── name: String
├── duckDBType: DuckDBColumnType          // VARCHAR, INTEGER, DOUBLE, DATE, etc.
├── displayType: DisplayType              // .text, .integer, .float, .date, .boolean
└── index: Int

ColumnFilter
├── column: String
├── operator: FilterOperator              // .contains, .greaterThan, .between, etc.
└── value: FilterValue                    // .string, .number, .dateRange, etc.
```

Every user action mutates `ViewState`. A `QueryCoordinator` observes changes, derives SQL, executes it, and tells the `NSTableView` data source to reload.

---

## 3. DuckDB Integration

### 3.1 Bridging Layer

DuckDB ships a single-file C API (`duckdb.h`). We wrap it in a Swift class:

```swift
// DuckDBEngine.swift — thin wrapper around DuckDB C API

import Foundation

final class DuckDBEngine {
    private var database: duckdb_database?
    private var connection: duckdb_connection?
    
    init() throws {
        var db: duckdb_database?
        guard duckdb_open(nil, &db) == DuckDBSuccess else {
            throw GridkaError.databaseInitFailed
        }
        self.database = db
        
        var conn: duckdb_connection?
        guard duckdb_connect(db, &conn) == DuckDBSuccess else {
            throw GridkaError.connectionFailed
        }
        self.connection = conn
    }
    
    func execute(_ sql: String) throws -> DuckDBResult {
        var result = duckdb_result()
        guard duckdb_query(connection, sql, &result) == DuckDBSuccess else {
            let error = String(cString: duckdb_result_error(&result))
            duckdb_destroy_result(&result)
            throw GridkaError.queryFailed(error)
        }
        return DuckDBResult(result)
    }
    
    deinit {
        if connection != nil { duckdb_disconnect(&connection) }
        if database != nil { duckdb_close(&database) }
    }
}
```

### 3.2 File Loading

```sql
-- Phase 1: Create table from CSV with auto-detection
CREATE TABLE data AS SELECT * FROM read_csv_auto(
    '/path/to/file.csv',
    sample_size = -1,        -- scan all rows for type detection on large files
    ignore_errors = true,    -- don't fail on malformed rows
    store_rejects = true     -- track bad rows for user notification
);

-- Phase 2: Introspect schema
SELECT column_name, data_type FROM information_schema.columns 
WHERE table_name = 'data' ORDER BY ordinal_position;

-- Phase 3: Get row count
SELECT COUNT(*) FROM data;
```

### 3.3 Large File Strategy

For files that exceed available RAM, DuckDB handles this automatically through its buffer manager and disk spilling. However, we optimize the loading experience:

**Progressive loading approach:**

1. **Instant preview (< 100ms):** `SELECT * FROM read_csv_auto('file.csv') LIMIT 1000` — shows data immediately while full load proceeds.
2. **Background full load:** `CREATE TABLE data AS SELECT * FROM read_csv_auto(...)` runs on a background thread. Progress is estimated from bytes read vs. file size.
3. **Swap on completion:** Once the full table is created, swap the data source from the preview query to the materialized table. User sees no interruption.

**Memory management:**

- DuckDB's default memory limit is 80% of system RAM. We cap it at 50% via `SET memory_limit = '...'` to leave room for macOS and other apps.
- For files larger than available memory, DuckDB automatically spills to a temp directory. We configure this to a user-visible location and show disk usage in the status bar.
- `SET threads = N` where N = physical cores (not hyperthreaded) for optimal query performance.

**Indexing for sort performance:**

After full table load, we create indexes on frequently sorted columns in the background:

```sql
-- Created lazily when user first sorts a column
CREATE INDEX idx_data_col1 ON data (col1);
```

DuckDB's columnar storage already makes full-table scans fast, but ART indexes help for very large files (100M+ rows) where sort latency matters.

---

## 4. UI Architecture

### 4.1 NSTableView with Virtual Scrolling

`NSTableView` in view-based mode with a data source delegate. The table never holds more than ~200 rows in memory (visible rows + buffer above/below).

```swift
// TableDataSource.swift

final class TableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    
    private let engine: DuckDBEngine
    private var viewState: ViewState
    private var rowCache: RowCache  // LRU cache of fetched pages
    
    // NSTableViewDataSource — called for every visible row
    func numberOfRows(in tableView: NSTableView) -> Int {
        return viewState.totalFilteredRows
    }
    
    func tableView(_ tableView: NSTableView, 
                   viewFor tableColumn: NSTableColumn?, 
                   row: Int) -> NSView? {
        // Fetch from cache or query DuckDB
        let value = rowCache.value(forRow: row, column: tableColumn!.identifier)
        
        if value == nil {
            // Cache miss — fetch page asynchronously
            fetchPage(containing: row)
            return makePlaceholderCell()
        }
        
        return makeCell(value: value!, type: columnType(for: tableColumn!))
    }
}
```

### 4.2 Page-Based Fetching

Rather than querying individual rows, we fetch pages of 500 rows:

```swift
struct RowCache {
    private var pages: [Int: Page]          // pageIndex → Page
    private let pageSize = 500
    private let maxCachedPages = 20         // 10,000 rows in memory max
    
    struct Page {
        let startRow: Int
        let data: [[DuckDBValue]]           // rows × columns
        let lastAccessed: Date
    }
    
    func value(forRow row: Int, column: String) -> DuckDBValue? {
        let pageIndex = row / pageSize
        guard let page = pages[pageIndex] else { return nil }
        let localRow = row - page.startRow
        return page.data[localRow][columnIndex(for: column)]
    }
    
    mutating func evictIfNeeded() {
        while pages.count > maxCachedPages {
            // Evict least recently accessed page
            let oldest = pages.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })!
            pages.removeValue(forKey: oldest.key)
        }
    }
}
```

### 4.3 Query Generation

The `QueryCoordinator` translates `ViewState` into SQL:

```swift
final class QueryCoordinator {
    
    func buildQuery(for state: ViewState, range: Range<Int>) -> String {
        var clauses: [String] = []
        
        // WHERE clause from filters
        let whereConditions = state.filters.map { filter in
            switch filter.operator {
            case .contains:
                return "\(quote(filter.column)) ILIKE '%\(escape(filter.value))%'"
            case .greaterThan:
                return "\(quote(filter.column)) > \(filter.value)"
            case .between(let low, let high):
                return "\(quote(filter.column)) BETWEEN \(low) AND \(high)"
            // ... other operators
            }
        }
        
        // Global search (OR across all text-cast columns)
        if let search = state.searchTerm, !search.isEmpty {
            let searchConditions = state.columns.map { col in
                "\(quote(col.name))::TEXT ILIKE '%\(escape(search))%'"
            }
            whereConditions.append("(\(searchConditions.joined(separator: " OR ")))")
        }
        
        var sql = "SELECT * FROM data"
        
        if !whereConditions.isEmpty {
            sql += " WHERE \(whereConditions.joined(separator: " AND "))"
        }
        
        // ORDER BY from sort state
        if !state.sortColumns.isEmpty {
            let orderClauses = state.sortColumns.map { sort in
                "\(quote(sort.column)) \(sort.direction == .ascending ? "ASC" : "DESC") NULLS LAST"
            }
            sql += " ORDER BY \(orderClauses.joined(separator: ", "))"
        }
        
        // Pagination
        sql += " LIMIT \(range.count) OFFSET \(range.lowerBound)"
        
        return sql
    }
    
    func buildCountQuery(for state: ViewState) -> String {
        // Same WHERE clause, just SELECT COUNT(*)
        // ... 
    }
}
```

### 4.4 Concurrency Model

```
Main Thread (UI)
  │
  ├── User scrolls → requests page from RowCache
  │     └── cache miss → dispatch to query queue
  │
  ├── User changes filter → invalidate cache, update count
  │     └── dispatch count query + first page fetch
  │
  └── Receives results → reload table view rows

Query Queue (serial DispatchQueue)
  │
  ├── Executes DuckDB queries (DuckDB is not thread-safe per connection)
  │
  └── Posts results back to main thread via DispatchQueue.main.async
```

Key rule: **one DuckDB connection, one serial queue.** DuckDB connections are not thread-safe. All queries go through a single serial dispatch queue. Results are dispatched back to main for UI updates.

For long-running queries (initial file load, complex sorts on huge files), we use a separate connection so the UI query connection remains responsive.

---

## 5. Performance Design

### 5.1 Benchmarks to Target

| Operation | 1M rows | 10M rows | 100M rows |
|-----------|---------|----------|-----------|
| File open (first rows visible) | < 200ms | < 500ms | < 2s |
| File fully loaded | < 2s | < 15s | < 120s |
| Sort (first sorted page) | < 100ms | < 500ms | < 3s |
| Filter apply | < 100ms | < 300ms | < 2s |
| Scroll (cache hit) | < 1ms | < 1ms | < 1ms |
| Scroll (cache miss, page fetch) | < 50ms | < 100ms | < 200ms |
| Global search | < 500ms | < 2s | < 10s |

### 5.2 Optimization Techniques

**Pre-fetching:** When scrolling, predict direction and pre-fetch 2 pages ahead. If user is scrolling down and viewing page 5, fetch pages 6 and 7 in the background.

**Count caching:** After applying filters, cache `COUNT(*)` result. Only re-query when filters change.

**Column-level type caching:** Store DuckDB column types once at load time. Use them for cell formatting without re-querying.

**Debouncing:** Filter and search inputs debounce at 300ms. Sort is immediate (user expects instant feedback on click).

**Row number column:** Add a synthetic `rowid` column via `CREATE TABLE data AS SELECT row_number() OVER () AS _gridka_rowid, * FROM read_csv_auto(...)`. This enables stable row identity across sorts and is essentially free in DuckDB.

### 5.3 Memory Budget

```
Target: < 500MB RSS for a 10GB file

Breakdown:
  DuckDB buffer pool:     ~300MB (capped via SET memory_limit)
  Row cache (20 pages):   ~50MB  (500 rows × 20 pages × ~5KB/row)
  NSTableView cells:      ~20MB  (visible cells only, recycled)
  App overhead:           ~30MB
  Headroom:               ~100MB
```

DuckDB spills to disk beyond the buffer pool limit. Temp directory defaults to `~/Library/Caches/com.gridka.app/duckdb-temp/`.

---

## 6. File Format Support

### 6.1 v1 Formats

| Format | Detection | Method |
|--------|-----------|--------|
| CSV | `.csv` extension or comma-detected | `read_csv_auto()` |
| TSV | `.tsv`/`.tab` extension or tab-detected | `read_csv_auto(delim='\t')` |
| Pipe-delimited | Pipe-detected | `read_csv_auto(delim='\|')` |
| Custom delimiter | User override in preferences | `read_csv_auto(delim='...')` |

DuckDB's `read_csv_auto()` handles: delimiter detection, header detection, type inference, encoding detection (UTF-8, Latin-1), quote character detection, null string detection, and skip rows.

### 6.2 v2 Formats (Planned)

Parquet, JSON/JSONL, Excel (`.xlsx` via DuckDB's `spatial` extension or dedicated reader). These are nearly free with DuckDB — just different `read_*` functions.

---

## 7. Application Lifecycle

### 7.1 Startup

1. App launches → empty window with drop target ("Drop a CSV file or ⌘O to open")
2. Initialize DuckDB in-memory database
3. Register for file open events (drag-drop, File > Open, `open` CLI command, file association)

### 7.2 File Open Flow

```
User opens file
  │
  ├── 1. Show empty table with "Loading..." status
  │
  ├── 2. Preview query: SELECT * FROM read_csv_auto('...') LIMIT 1000
  │     └── Display immediately, infer columns, populate headers
  │
  ├── 3. Background: CREATE TABLE data AS SELECT row_number() OVER () AS _rowid, *
  │     │  FROM read_csv_auto('...')
  │     └── Progress bar: bytes_read / file_size (estimated from fstat)
  │
  ├── 4. On completion: SELECT COUNT(*) FROM data
  │     └── Update status bar, switch data source to materialized table
  │
  └── 5. Ready for sort/filter/search
```

### 7.3 File Watching

Monitor opened file with `DispatchSource.makeFileSystemObjectSource` for changes. If file is modified externally, show a non-intrusive notification bar: "File changed on disk. Reload?" This re-runs the CREATE TABLE pipeline.

---

## 8. Build and Distribution

### 8.1 Dependencies

| Dependency | Integration | Version |
|------------|-------------|---------|
| DuckDB | C library (static link via `.a`) | Latest stable (1.2.x) |
| Swift | System (Xcode toolchain) | 5.10+ |
| AppKit | System framework | macOS 14+ |

**No package managers for DuckDB.** Download the prebuilt static library from DuckDB releases and include it in the Xcode project. This avoids Swift Package Manager complexity with C libraries and ensures reproducible builds.

### 8.2 Project Structure

```
Gridka/
├── Gridka.xcodeproj
├── Sources/
│   ├── App/
│   │   ├── AppDelegate.swift
│   │   └── MainMenu.xib
│   ├── Engine/
│   │   ├── DuckDBEngine.swift          // C API wrapper
│   │   ├── QueryCoordinator.swift      // ViewState → SQL
│   │   └── RowCache.swift              // LRU page cache
│   ├── Model/
│   │   ├── FileSession.swift
│   │   ├── ViewState.swift
│   │   ├── ColumnDescriptor.swift
│   │   └── ColumnFilter.swift
│   ├── UI/
│   │   ├── TableViewController.swift   // NSTableView data source/delegate
│   │   ├── FilterBarView.swift         // Active filter chips
│   │   ├── SearchBarView.swift         // ⌘F search
│   │   ├── StatusBarView.swift         // Row counts, query time
│   │   ├── DetailPaneView.swift        // Cell content inspector
│   │   └── ColumnHeaderView.swift      // Sort indicators, filter menus
│   └── Bridging/
│       ├── Gridka-Bridging-Header.h    // #include "duckdb.h"
│       └── DuckDBTypes.swift           // Swift-friendly type wrappers
├── Libraries/
│   ├── duckdb.h
│   └── libduckdb.a                     // or libduckdb_static.a
├── Resources/
│   └── Assets.xcassets
└── Tests/
    ├── QueryCoordinatorTests.swift
    ├── RowCacheTests.swift
    └── DuckDBEngineTests.swift
```

### 8.3 Distribution

- **Direct download:** Notarized `.dmg` from project website
- **Homebrew cask:** `brew install --cask gridka`
- **Mac App Store:** Possible but sandboxing may limit temp directory for DuckDB spill. Evaluate after v1.

---

## 9. Testing Strategy

**Unit tests:** QueryCoordinator (SQL generation from ViewState), RowCache (eviction, page math), DuckDB type mapping.

**Integration tests:** Load known CSV files, verify row counts, sort orders, filter results against expected SQL output. Use DuckDB's in-memory mode with small synthetic datasets.

**Performance tests:** XCTest `measure {}` blocks for file load, sort, filter, and scroll operations at 1M, 10M, and 100M row scales. Run in CI with threshold alerts.

**Manual test matrix:** Various CSV edge cases — empty files, single column, no headers, mixed encodings, malformed rows, very wide rows (1000+ columns), very long cell values (>1MB), files with only headers.

---

## 10. v2 Technical Extensions

### Aggregate/Pivot/OLAP

These map directly to DuckDB SQL with no engine changes:

```sql
-- Aggregate view
SELECT department, COUNT(*), AVG(salary), SUM(revenue)
FROM data GROUP BY department;

-- Pivot
PIVOT data ON quarter USING SUM(revenue) GROUP BY product;

-- OLAP rollup
SELECT region, product, SUM(sales) 
FROM data GROUP BY ROLLUP (region, product);
```

The UI challenge is building a visual query builder that generates these queries. The engine layer is already done.

### Multi-File Support

Each opened file gets its own `FileSession` with a named table (`data_1`, `data_2`, etc.) in the same DuckDB database. Cross-file queries become natural joins:

```sql
SELECT a.*, b.extra_col FROM data_1 a JOIN data_2 b ON a.id = b.id;
```

### SQL Console

Embed a text view with syntax highlighting (can use `NSTextView` with custom `NSLayoutManager`). Execute arbitrary SQL against the in-memory database. Results display in the same NSTableView.

---

## 11. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| DuckDB C API instability between versions | Build breaks | Pin to specific release, vendor the static library |
| Very wide CSVs (1000+ columns) | NSTableView performance degrades | Lazy column loading, only create NSTableColumn for visible columns |
| Malformed CSV data crashes DuckDB | App crash | `ignore_errors = true`, wrap all DuckDB calls in error handling |
| Memory pressure from multiple large files | System swap | Enforce single-file in v1, shared memory budget across files in v2 |
| App Store sandboxing limits temp directory | DuckDB can't spill to disk | Use app container temp dir, or skip App Store for v1 |
| DuckDB license (MIT) | None | MIT is permissive, compatible with closed-source distribution |
