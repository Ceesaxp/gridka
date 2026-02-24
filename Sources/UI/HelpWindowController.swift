import AppKit

final class HelpWindowController: NSWindowController {

    private static var shared: HelpWindowController?

    static func showHelp() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = HelpWindowController()
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Gridka Help"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 400)

        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView(frame: contentView.bounds)
        tabView.autoresizingMask = [.width, .height]
        tabView.tabViewType = .topTabsBezelBorder

        tabView.addTabViewItem(makeTab("Getting Started", buildGettingStarted()))
        tabView.addTabViewItem(makeTab("Keyboard Shortcuts", buildKeyboardShortcuts()))
        tabView.addTabViewItem(makeTab("Filtering & Search", buildFilteringSearch()))
        tabView.addTabViewItem(makeTab("Tips & Tricks", buildTipsTricks()))
        tabView.addTabViewItem(makeTab("About", buildAbout()))

        contentView.addSubview(tabView)
    }

    private func makeTab(_ label: String, _ content: NSAttributedString) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = label

        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false

        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textStorage?.setAttributedString(content)

        item.view = scrollView
        return item
    }

    // MARK: - Fonts & Styles

    private var sectionFont: NSFont { NSFont.systemFont(ofSize: 14, weight: .semibold) }
    private var bodyFont: NSFont { NSFont.systemFont(ofSize: 12) }
    private var shortcutFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .medium) }
    private var sectionColor: NSColor { .labelColor }
    private var bodyColor: NSColor { .secondaryLabelColor }
    private var accentColor: NSColor { .controlAccentColor }

    private func styledSection(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title + "\n", attributes: [.font: sectionFont, .foregroundColor: sectionColor])
    }

    private func styledBody(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: bodyFont, .foregroundColor: bodyColor])
    }

    private func styledShortcut(_ key: String, _ description: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "  \(key)", attributes: [.font: shortcutFont, .foregroundColor: accentColor]))
        result.append(NSAttributedString(string: "  —  ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        result.append(NSAttributedString(string: description + "\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        return result
    }

    private func spacing() -> NSAttributedString {
        NSAttributedString(string: "\n")
    }

    // MARK: - Tab Content

    private func buildGettingStarted() -> NSAttributedString {
        let result = NSMutableAttributedString()

        result.append(styledSection("What is Gridka?"))
        result.append(styledBody("""
        Gridka is a fast, native macOS CSV viewer powered by DuckDB. It opens files of any \
        size — from a few rows to hundreds of millions — with instant scrolling, sorting, \
        filtering, and search. Unlike spreadsheet apps, Gridka never loads the entire file \
        into memory, so it stays fast and responsive even with massive datasets.
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Opening Files"))
        result.append(styledBody("""
        There are several ways to open a CSV or TSV file:

        \u{2022} File \u{2192} Open (Cmd+O) — use the file picker
        \u{2022} Drag and drop — drag a CSV file onto the Gridka window
        \u{2022} Double-click — if CSV files are associated with Gridka in Finder
        \u{2022} Quick Look — press Space on a CSV file in Finder to preview

        Gridka auto-detects the delimiter (comma, tab, semicolon, etc.), character \
        encoding, whether the file has a header row, and the data type of each column.
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Supported Formats"))
        result.append(styledBody("""
        \u{2022} CSV (comma-separated values)
        \u{2022} TSV (tab-separated values)
        \u{2022} Any delimited text file (auto-detected)
        """))

        return result
    }

    private func buildKeyboardShortcuts() -> NSAttributedString {
        let result = NSMutableAttributedString()

        result.append(styledSection("File"))
        result.append(styledShortcut("\u{2318}O", "Open file"))
        result.append(styledShortcut("\u{2318}W", "Close window"))
        result.append(styledShortcut("\u{2318}Q", "Quit"))
        result.append(spacing())

        result.append(styledSection("Edit"))
        result.append(styledShortcut("\u{2318}C", "Copy cell value"))
        result.append(styledShortcut("\u{21E7}\u{2318}C", "Copy entire row"))
        result.append(styledShortcut("\u{2325}\u{2318}C", "Copy column (visible rows)"))
        result.append(spacing())

        result.append(styledSection("Search"))
        result.append(styledShortcut("\u{2318}F", "Toggle search bar"))
        result.append(styledShortcut("\u{2318}G", "Find next"))
        result.append(styledShortcut("\u{21E7}\u{2318}G", "Find previous"))
        result.append(spacing())

        result.append(styledSection("View"))
        result.append(styledShortcut("\u{21E7}\u{2318}D", "Toggle detail pane"))
        result.append(styledShortcut("\u{2318},", "Settings"))
        result.append(spacing())

        result.append(styledSection("Table"))
        result.append(styledShortcut("Click header", "Sort ascending (click again: descending, again: clear)"))
        result.append(styledShortcut("\u{21E7}+Click header", "Add secondary sort column"))
        result.append(styledShortcut("Double-click divider", "Auto-fit column width"))
        result.append(styledShortcut("Right-click header", "Filter / hide column"))
        result.append(styledShortcut("Right-click cell", "Copy / filter by value"))
        result.append(spacing())

        result.append(styledSection("Navigation"))
        result.append(styledShortcut("Drag & drop", "Open CSV file by dragging onto window"))

        return result
    }

    private func buildFilteringSearch() -> NSAttributedString {
        let result = NSMutableAttributedString()

        result.append(styledSection("Column Filters"))
        result.append(styledBody("""
        Right-click any column header and choose a filter to apply. Filters are type-aware: \
        text columns offer text operators, numeric columns offer comparison operators, etc.
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Filter Operators"))
        result.append(styledBody("""
        Text columns:
        \u{2022} Contains / Does not contain
        \u{2022} Equals / Does not equal
        \u{2022} Starts with / Ends with
        \u{2022} Is empty / Is not empty

        Numeric columns:
        \u{2022} Equals / Does not equal
        \u{2022} Greater than / Less than
        \u{2022} Greater or equal / Less or equal
        \u{2022} Between

        Date columns:
        \u{2022} Equals / Before / After / Between

        Boolean columns:
        \u{2022} Is true / Is false
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Multiple Filters"))
        result.append(styledBody("""
        You can apply filters to multiple columns simultaneously. Active filters appear \
        as chips in the filter bar below the toolbar. Click the \u{2715} on a chip to \
        remove it. All filters combine with AND logic.
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Global Search"))
        result.append(styledBody("""
        Press Cmd+F to open the search bar. Type your search term and press Enter. \
        Search looks across all columns using case-insensitive matching (ILIKE). \
        Use Cmd+G / Shift+Cmd+G to navigate between matches.

        Search and filters can be used together: search results are further narrowed \
        by any active column filters.
        """))

        return result
    }

    private func buildTipsTricks() -> NSAttributedString {
        let result = NSMutableAttributedString()

        result.append(styledSection("Multi-Column Sort"))
        result.append(styledBody("""
        Click a column header to sort by that column. Hold Shift and click another \
        header to add a secondary sort. You can build a multi-level sort order this way. \
        Click a sorted column again to reverse its direction, or a third time to remove it.
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Column Management"))
        result.append(styledBody("""
        \u{2022} Drag column headers to reorder columns
        \u{2022} Double-click the divider between headers to auto-fit column width
        \u{2022} Right-click a header to hide a column or access filter options
        \u{2022} Resize columns by dragging the header dividers
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Detail Pane"))
        result.append(styledBody("""
        Press Shift+Cmd+D to toggle the detail pane. When a cell is selected, the \
        detail pane shows the full cell content, which is useful for long text, \
        URLs, or JSON data that doesn't fit in the table cell.
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Large File Performance"))
        result.append(styledBody("""
        Gridka handles large files (100M+ rows) efficiently:

        \u{2022} Only visible rows are loaded into memory via page-based caching
        \u{2022} DuckDB materializes the file into a columnar table for fast queries
        \u{2022} Initial preview appears instantly while the full file loads in the background
        \u{2022} Memory is capped at 50% of system RAM; excess spills to disk
        \u{2022} If a file opens slowly, the status bar shows loading progress
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Quick Filter by Value"))
        result.append(styledBody("""
        Right-click any cell and choose "Filter by This Value" to instantly create \
        a filter matching that cell's content. This is the fastest way to drill down \
        into your data.
        """))

        return result
    }

    private func buildAbout() -> NSAttributedString {
        let result = NSMutableAttributedString()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

        let titleFont = NSFont.systemFont(ofSize: 18, weight: .bold)
        result.append(NSAttributedString(string: "Gridka\n", attributes: [.font: titleFont, .foregroundColor: sectionColor]))
        result.append(styledBody("Version \(version) (build \(build))\n"))
        result.append(spacing())

        result.append(styledSection("About"))
        result.append(styledBody("""
        Gridka is a native macOS CSV viewer built for speed. It uses DuckDB's \
        analytical SQL engine to handle files of any size without loading everything \
        into memory.
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("Powered by DuckDB"))
        result.append(styledBody("""
        DuckDB is an in-process SQL OLAP database management system. Gridka embeds \
        DuckDB to perform all data operations — sorting, filtering, searching, and \
        aggregation — using SQL queries under the hood.

        Learn more: https://duckdb.org
        """))
        result.append(spacing())
        result.append(spacing())

        result.append(styledSection("License"))
        result.append(styledBody("""
        Gridka is open source software released under the MIT License.

        https://github.com/Ceesaxp/gridka
        """))

        return result
    }
}
