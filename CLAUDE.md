# CLAUDE.md

## Project Overview

Gridka is a native macOS CSV viewer built with Swift (AppKit) and DuckDB (C API). It handles very large files (100M+ rows) via virtual scrolling and SQL-backed data access. The UI is purely AppKit — no SwiftUI, no web views, no Electron.

## Architecture Rules

- **Single process.** DuckDB is embedded via C API through a bridging header. No IPC, no separate backend.
- **AppKit only.** Use `NSTableView` (view-based, with data source delegate), `NSView`, `NSViewController`. Never use SwiftUI.
- **Every user interaction is SQL.** Sort, filter, search all mutate a `ViewState` struct which is translated to a SQL query by `QueryCoordinator`. No in-memory data manipulation in Swift.
- **Serial query execution.** All DuckDB calls go through a single serial `DispatchQueue`. DuckDB connections are not thread-safe. UI updates dispatch back to main.
- **Page-based row cache.** `RowCache` fetches pages of 500 rows. Max 20 pages cached. LRU eviction. Never load all rows into memory.

## Key Domain Types

- `FileSession` — represents one opened file, owns the DuckDB connection and table
- `ViewState` — current sort, filters, search term, visible range. Immutable value type. Every change produces a new ViewState.
- `QueryCoordinator` — pure function: `ViewState → SQL String`. No side effects. Highly testable.
- `RowCache` — LRU cache of fetched row pages. Cache key is page index. Invalidated when ViewState changes filters/sort.
- `DuckDBEngine` — thin wrapper around DuckDB C API. Owns database and connection lifecycle.
- `ColumnDescriptor` — column name, DuckDB type, display type, index.
- `ColumnFilter` — column name, operator, value. Type-aware operators.

## Code Conventions

- Swift 5.10+, target macOS 14.0+
- No third-party dependencies beyond DuckDB static library
- Use `final class` for all classes unless inheritance is explicitly needed
- Prefer value types (structs, enums) for model layer
- Error handling: define errors in `GridkaError` enum, throw from engine layer, handle in UI layer
- Use `DispatchQueue` for concurrency (not async/await — AppKit delegate patterns don't mix well)
- All SQL strings are parameterized or escaped via helper functions. Never interpolate user input directly.

## DuckDB Integration

- DuckDB is vendored as a static library in `Libraries/` (`duckdb.h` + `libduckdb.a`)
- Bridging header at `Sources/Bridging/Gridka-Bridging-Header.h` contains `#include "duckdb.h"`
- All DuckDB C API calls are wrapped in `DuckDBEngine.swift` — no raw C API calls elsewhere
- File loading uses `read_csv_auto()` with `ignore_errors = true` and `store_rejects = true`
- A synthetic `_gridka_rowid` column is added via `row_number() OVER ()` for stable row identity
- Memory limit set to 50% of system RAM: `SET memory_limit = '...'`
- Temp directory for disk spilling: `~/Library/Caches/com.gridka.app/duckdb-temp/`

## File Loading Pattern

1. **Preview (immediate):** `SELECT * FROM read_csv_auto('path') LIMIT 1000` — populate table instantly
2. **Full load (background):** `CREATE TABLE data AS SELECT row_number() OVER () AS _gridka_rowid, * FROM read_csv_auto('path')` — on serial query queue
3. **Swap:** Once materialized, swap data source from preview to full table. Update row count in status bar.

## SQL Generation

All queries follow this template:

```sql
SELECT * FROM data
[WHERE <filter conditions> AND (<search conditions>)]
[ORDER BY <sort columns>]
LIMIT <page_size> OFFSET <page_start>
```

Filters combine with AND. Global search ORs across all columns cast to TEXT with ILIKE. Sort supports multi-column via shift+click.

## Testing

- `QueryCoordinatorTests` — verify SQL generation for all filter/sort/search combinations
- `RowCacheTests` — verify page math, eviction, invalidation
- `DuckDBEngineTests` — verify file loading, type detection, error handling with known CSV fixtures
- Performance tests use `XCTest measure {}` blocks with 1M/10M row synthetic CSVs
- Test CSVs live in `Tests/Fixtures/` — include edge cases: empty files, no headers, mixed encodings, malformed rows, wide tables (1000+ columns), large cells

## Common Tasks

### Adding a new filter operator

1. Add case to `FilterOperator` enum in `ColumnFilter.swift`
2. Add SQL generation in `QueryCoordinator.buildWhereClause()`
3. Add UI entry in `ColumnHeaderView` filter menu
4. Add test case in `QueryCoordinatorTests`

### Adding a new file format (v2)

1. Add format detection in `FileSession.detectFormat()`
2. Map to appropriate DuckDB `read_*` function in `DuckDBEngine.loadFile()`
3. Rest of the pipeline (ViewState, QueryCoordinator, cache) is format-agnostic

### Debugging DuckDB queries

Set `GRIDKA_LOG_SQL=1` environment variable to log all generated SQL to console via `os_log`.

## Things to Avoid

- **No SwiftUI.** AppKit only. NSTableView for data display.
- **No async/await.** Use DispatchQueue for threading.
- **No loading all rows into memory.** Always use paginated queries with LIMIT/OFFSET.
- **No direct C API calls outside DuckDBEngine.** All access goes through the wrapper.
- **No third-party UI frameworks.** Stock AppKit with system appearance.
- **No Cocoapods/SPM for DuckDB.** The static library is vendored.
