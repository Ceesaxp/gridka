# Gridka

A fast, native macOS CSV viewer powered by DuckDB. Opens files of any size with instant scrolling, sorting, filtering, and search.

## Why Gridka?

Most CSV tools either choke on large files (Excel, Numbers), consume absurd memory (Electron apps), or lack a GUI entirely (csvkit, xsv). Gridka uses DuckDB's analytical engine behind AppKit's `NSTableView` to handle 100M+ row files while staying under 500MB RAM.

## Features (v1)

- **Open any CSV/TSV** — auto-detects delimiter, encoding, headers, and column types
- **Virtual scrolling** — 60fps at any file size, only visible rows are in memory
- **Column sorting** — click to sort, shift+click for multi-column sort
- **Filtering** — type-aware filters per column (text, numeric, date, boolean operators)
- **Global search** — ⌘F to search across all columns with match highlighting
- **Column management** — resize, reorder, hide/show, pin, auto-fit
- **Cell inspection** — detail pane for long text, URLs, JSON content

## Architecture

Single-process Swift app. DuckDB embedded via C API (static library). No IPC, no Electron, no web views.

```
User interaction → ViewState mutation → SQL generation → DuckDB query → NSTableView reload
```

Every sort, filter, and search is a SQL query. DuckDB does the heavy lifting.

## Performance Targets

| Operation | 1M rows | 100M rows |
|-----------|---------|-----------|
| First rows visible | < 200ms | < 2s |
| Sort (first page) | < 100ms | < 3s |
| Filter apply | < 100ms | < 2s |
| Scroll (cached) | < 1ms | < 1ms |

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0+ with Swift 5.10+
- DuckDB static library (see Building)

## Building

```bash
# 1. Clone
git clone https://github.com/yourusername/gridka.git
cd gridka

# 2. Download DuckDB static library
# Get the latest macOS release from https://github.com/duckdb/duckdb/releases
# Place duckdb.h and libduckdb.a in Libraries/

# 3. Open and build
open Gridka.xcodeproj
# Or: xcodebuild -scheme Gridka -configuration Release
```

## Project Structure

```
Gridka/
├── Sources/
│   ├── App/              # AppDelegate, MainMenu
│   ├── Engine/           # DuckDB wrapper, query coordinator, row cache
│   ├── Model/            # FileSession, ViewState, ColumnFilter
│   ├── UI/               # NSTableView, filter bar, search, status bar
│   └── Bridging/         # C API bridging header, Swift type wrappers
├── Libraries/            # Vendored duckdb.h + libduckdb.a
├── Resources/            # Assets
└── Tests/                # Unit + integration tests
```

## Roadmap

**v2:** Aggregate views, pivot tables, OLAP (ROLLUP/CUBE), multi-file support, export (CSV/Parquet/JSON), SQL console, column statistics.

## License

TBD
