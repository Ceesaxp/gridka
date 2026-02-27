# Changelog

All notable changes to Gridka will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-02-27

### Security
- Unified computed-expression validator — rejects multi-statement SQL payloads while allowing semicolons inside string literals

### Fixed
- SparklineHeaderCell teardown crash during tab/window close (4 crash signatures resolved)
- FileSession shutdown guards — async callbacks safely no-op when session is deallocated
- Deadlock from `DispatchQueue.main.sync` in summary computation replaced with non-blocking atomic check
- Stale page reload clamping — out-of-bounds row indexes from stale fetch callbacks safely ignored
- Queue ownership enforcement — main-thread config snapshotted before dispatch to queryQueue
- DuckDB engine lifecycle — force unwraps replaced with guarded error handling
- Bounds-safe DuckDB result accessors — row/column index validation before C API calls
- Summary counter synchronization — atomic counter prevents temp table name collisions

### Added
- 78 new crash-focused regression tests (teardown, shutdown, concurrency, reload clamping, injection)
- 172 total unit tests

## [1.1.0] - 2026-02-27

### Added
- Save group-by summary results to CSV via File > Save As
- Close prompt for summary tabs — warns before discarding group-by results
- Toggle sparklines on/off in Settings

### Fixed
- SparklineHeaderCell crash from NSCopyObject bitwise copy of Swift stored properties
- Silent save failures from `[weak self]` in async closures
- Sandbox entitlement changed from read-only to read-write for user-selected files

## [0.6] - 2026-02-27

### Added
- UI test infrastructure with XCUITest target and env-var based file auto-open hook
- Shared test helpers (`GridkaTestHelpers.swift`) with `#filePath`-based portable fixture paths
- Regression tests for async invalidation, stale fetch discard, and scroll stress (20 tests)
- Crash regression tests for FileSession under concurrent load (3 tests)
- Accessibility identifiers on status bar, filter bar, search bar for UI test coverage
- Empty state launch test and data-load verification in UI tests

### Changed
- Test fixture paths use `#filePath` resolution instead of hardcoded absolute paths
- UI tests use coordinate-based scroll gestures instead of scroll bar adjustment
- Bundle ID prefix updated to `org.ceesaxp.gridka`

### Fixed
- `cb-companies.csv` fixture path pointed to `~/Downloads/` instead of `Tests/`

## [0.5] - 2026-02-15

### Added
- Column sparklines — mini distribution charts rendered in every column header
- Column profiler sidebar (`Shift+Cmd+P`) — statistics, distribution histogram, and top values
- Value frequency panel — histogram and sortable value-count table with click-to-filter
- Computed columns (`Option+Cmd+F`) — user-defined formula columns using DuckDB SQL expressions with live preview
- Group By aggregation (`Option+Cmd+G`) — visual builder with column zones, multiple aggregation functions (COUNT, SUM, AVG, MIN, MAX, STDDEV), results open as a new tab
- Analysis toolbar (`Option+Cmd+T`) — quick access to frequency, profiler, computed column, and group by features
- Click-to-filter from frequency panel and column profiler
- Column type badges (color-coded: green=INTEGER, blue=VARCHAR, orange=FLOAT, purple=BOOLEAN, red=DATE)
- Read-only enforcement on summary/group-by tabs (blocks editing, column mutation, and computed column operations)

### Fixed
- View-state generation token prevents stale page fetch results from corrupting row cache
- Single-thread ownership assertions enforce main-thread/serial-queue boundaries
- SparklineHeaderCell summary lifetime hardened — clears state before column removal
- Force unwrap/cast crash points eliminated in 6 hot paths (replaced with optional chaining)
- Row count updates use deterministic completion callbacks instead of timing-based delays
- Fetch page completions always fire, even for stale generations, preventing fetchingPages bookkeeping leaks

## [0.4] - 2025-12-15

### Fixed
- Settings window exclusivity (multiple settings windows could open simultaneously)
- CSV quoting edge cases when saving edited files
- Edit menu column operations (copy column was not working correctly)
- Cell edit cursor jumping to unexpected positions

## [0.3] - 2025-11-20

### Added
- Multi-tab interface for opening multiple files simultaneously
- Cell editing with inline editor
- Column operations: insert, delete, rename, reorder
- Row operations: insert, delete
- Save edited files back to CSV
- Memory management improvements for large files

### Fixed
- Tab close crash caused by NSWindow release-when-closed and ARC conflict
- App icon updated with transparent background

## [0.2] - 2025-10-15

### Added
- Settings window with customizable preferences
- Status bar with file info (row count, column count, file size)
- Help window with keyboard shortcuts
- Row numbers column
- Cell highlight on selection
- App icon and CSV file association
- Quick Look preview extension for CSV files

### Fixed
- Search/filter bar visibility on file reload
- Status bar layering issues

## [0.1] - 2025-09-01

### Added
- Initial release
- Open any CSV/TSV file with auto-detection of delimiter, encoding, headers, and column types
- Virtual scrolling powered by DuckDB for files of any size (100M+ rows)
- Column sorting (click header) and multi-column sort (Shift+click)
- Type-aware column filtering (text, numeric, date, boolean operators)
- Global search across all columns with match highlighting (Cmd+F)
- Column management: resize, reorder, hide/show, pin, auto-fit
- Detail pane for inspecting long text, URLs, and JSON content
- Drag-and-drop file opening
- Filter bar with visual filter chips
- DuckDB-powered SQL engine for all data operations
