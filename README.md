# Gridka

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange)
![MIT License](https://img.shields.io/badge/license-MIT-green)

A fast, native macOS CSV viewer powered by [DuckDB](https://duckdb.org). Opens files of any size with instant scrolling, sorting, filtering, and search.

<!-- ![Gridka screenshot](docs/screenshots/gridka-main.png) -->

## Why Gridka?

Most CSV tools either choke on large files (Excel, Numbers), consume absurd memory (Electron apps), or lack a GUI entirely (csvkit, xsv). Gridka uses DuckDB's analytical engine behind AppKit's `NSTableView` to handle **100M+ row files** while staying under 500 MB RAM.

## Features

- **Open any CSV/TSV** — auto-detects delimiter, encoding, headers, and column types
- **Virtual scrolling** — 60 fps at any file size; only visible rows are in memory
- **Column sorting** — click to sort, Shift+click for multi-column sort
- **Filtering** — type-aware filters per column (text, numeric, date, boolean operators)
- **Global search** — `Cmd+F` to search across all columns with match highlighting
- **Column management** — resize, reorder, hide/show, rename, delete, auto-fit
- **Cell inspection** — detail pane for long text, URLs, JSON content
- **Cell editing** — double-click to edit, save back to CSV
- **Multi-tab** — open multiple files in tabs within a single window
- **Quick Look** — preview CSV files in Finder via Quick Look extension

### Analysis

- **Column sparklines** — mini distribution charts in every column header; click to open profiler
- **Column profiler** — sidebar with stats (min, max, mean, median, stddev), distribution histogram, and top values
- **Value frequency** — floating panel with histogram and sortable value-count table; click a value to filter
- **Computed columns** — add formula columns using DuckDB SQL expressions with live preview
- **Group By** — visual aggregation builder (COUNT, SUM, AVG, MIN, MAX, STDDEV); results open as a new tab

## Installation

### Mac App Store

*Coming soon.*

### Download

Grab the latest `.zip` from [Releases](https://github.com/Ceesaxp/gridka/releases), unzip, and drag `Gridka.app` to `/Applications`.

### Building from Source

```bash
# 1. Clone
git clone https://github.com/Ceesaxp/gridka.git
cd gridka

# 2. Ensure DuckDB libraries are in Libraries/
#    Download the macOS release from https://github.com/duckdb/duckdb/releases
#    Place duckdb.h, libduckdb.a, and libduckdb.dylib in Libraries/

# 3. Generate Xcode project (requires XcodeGen)
xcodegen generate

# 4. Build
xcodebuild -scheme Gridka -configuration Release build

# Or open in Xcode:
open Gridka.xcodeproj
```

**Requirements:** macOS 14.0 (Sonoma)+, Xcode 15.0+, Swift 5.10+

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+O` | Open file |
| `Cmd+S` | Save |
| `Shift+Cmd+S` | Save As |
| `Cmd+T` | New tab |
| `Cmd+W` | Close tab |
| `Cmd+F` | Toggle search bar |
| `Cmd+G` / `Shift+Cmd+G` | Find next / previous |
| `Cmd+C` | Copy cell value |
| `Shift+Cmd+C` | Copy entire row |
| `Option+Cmd+C` | Copy column (visible rows) |
| `Shift+Cmd+D` | Toggle detail pane |
| `Shift+Cmd+P` | Toggle column profiler |
| `Option+Cmd+T` | Show analysis toolbar |
| `Option+Cmd+F` | Add computed column |
| `Option+Cmd+G` | Group By |
| `Option+Cmd+N` | Add column |
| `Option+Cmd+R` | Add row |
| `Cmd+Delete` | Delete selected row(s) |
| Click header | Sort ascending/descending/clear |
| Shift+click header | Multi-column sort |
| Right-click header | Filter / hide / rename / frequency |
| Right-click cell | Copy / filter by value / exclude value |
| Double-click divider | Auto-fit column width |
| Double-click cell | Inline edit |
| Drag & drop | Open CSV by dragging onto window |

## Architecture

Single-process Swift app. DuckDB embedded via C API (static library). No IPC, no Electron, no web views.

```
User interaction → ViewState mutation → SQL generation → DuckDB query → NSTableView reload
```

Every sort, filter, and search is a SQL query. DuckDB does the heavy lifting. See [CLAUDE.md](CLAUDE.md) for full architectural documentation.

## Project Structure

```
Gridka/
├── Sources/
│   ├── App/              # AppDelegate, MainMenu
│   ├── Engine/           # DuckDB wrapper, query coordinator, row cache
│   ├── Model/            # FileSession, ViewState, ColumnFilter
│   ├── UI/               # NSTableView, filter bar, search, status bar, help
│   └── Bridging/         # C API bridging header, Swift type wrappers
├── QuickLookExtension/   # Quick Look preview for CSV files
├── Libraries/            # Vendored DuckDB (duckdb.h + libduckdb)
├── Resources/            # Assets, Info.plist, PrivacyInfo
├── Tests/                # Unit, integration, and regression tests
├── UITests/              # XCUITest UI automation
├── scripts/              # Build and release automation
└── docs/                 # App Store submission guide
```

## Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes
4. Push and open a Pull Request

## License

[MIT](LICENSE.md)
