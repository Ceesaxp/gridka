# Changelog

All notable changes to Gridka will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
