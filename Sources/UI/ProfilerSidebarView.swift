import AppKit

/// Right sidebar showing column profiler information.
/// Displays column type, stats, distribution, and top values for the selected column.
/// Content sections are stacked vertically in a scrollable view.
final class ProfilerSidebarView: NSView {

    // MARK: - Properties

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        return sv
    }()

    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let separator: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }()

    /// Placeholder label shown when no column is selected.
    private let placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Click a column header to inspect")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// Column name header label.
    private let columnNameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    /// Column type badge.
    private let typeBadge: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        return label
    }()

    // Overview stats labels (2x2 grid)
    private let rowsValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let rowsTitleLabel = ProfilerSidebarView.makeStatTitleLabel("Rows")
    private let uniqueValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let uniqueTitleLabel = ProfilerSidebarView.makeStatTitleLabel("Unique")
    private let nullsValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let nullsTitleLabel = ProfilerSidebarView.makeStatTitleLabel("Nulls")
    private let emptyValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let emptyTitleLabel = ProfilerSidebarView.makeStatTitleLabel("Empty")

    /// Completeness bar background (gray track).
    private let completenessTrack: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.layer?.cornerRadius = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// Completeness bar fill (colored portion).
    private let completenessFill: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let completenessLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// Width constraint for the completeness fill bar, updated dynamically.
    private var completenessFillWidth: NSLayoutConstraint?

    /// Container for the overview section (visible only when stats are loaded).
    private var overviewSection: NSView?

    /// Container for the distribution section.
    private var distributionSection: NSView?

    /// Container for the descriptive statistics section (numeric columns only).
    private var statisticsSection: NSView?

    // Descriptive statistics labels (4x2 grid: Min, Max, Mean, Median, Std Dev, Q1, Q3, IQR)
    private let minValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let minTitleLabel = ProfilerSidebarView.makeStatTitleLabel("Min")
    private let maxValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let maxTitleLabel = ProfilerSidebarView.makeStatTitleLabel("Max")
    private let meanValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let meanTitleLabel = ProfilerSidebarView.makeStatTitleLabel("Mean")
    private let medianValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let medianTitleLabel = ProfilerSidebarView.makeStatTitleLabel("Median")
    private let stdDevValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let stdDevTitleLabel = ProfilerSidebarView.makeStatTitleLabel("Std Dev")
    private let q1ValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let q1TitleLabel = ProfilerSidebarView.makeStatTitleLabel("Q1")
    private let q3ValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let q3TitleLabel = ProfilerSidebarView.makeStatTitleLabel("Q3")
    private let iqrValueLabel = ProfilerSidebarView.makeStatValueLabel()
    private let iqrTitleLabel = ProfilerSidebarView.makeStatTitleLabel("IQR")

    /// Histogram bar chart for value distribution.
    private let histogramView = HistogramView()

    /// Loading indicator shown while profiler queries are in flight.
    private let loadingLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Loading…")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        addSubview(separator)
        addSubview(scrollView)
        addSubview(placeholderLabel)

        scrollView.documentView = stackView

        // Use flipped document view so content starts at the top
        let flipper = FlippedClipView()
        flipper.documentView = stackView
        flipper.drawsBackground = false
        scrollView.contentView = flipper

        // Separator on the left edge
        separator.frame = .zero
        separator.autoresizingMask = [.height]

        // Build the header row: column name + type badge
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.alignment = .firstBaseline
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(columnNameLabel)
        headerRow.addArrangedSubview(typeBadge)

        stackView.addArrangedSubview(headerRow)

        // Loading indicator
        stackView.addArrangedSubview(loadingLabel)

        // Build overview stats section
        let section = buildOverviewSection()
        overviewSection = section
        stackView.addArrangedSubview(section)

        // Build distribution section
        let distSection = buildDistributionSection()
        distributionSection = distSection
        stackView.addArrangedSubview(distSection)

        // Build descriptive statistics section (numeric columns only)
        let statsSection = buildStatisticsSection()
        statisticsSection = statsSection
        stackView.addArrangedSubview(statsSection)

        showPlaceholder()
    }

    override func layout() {
        super.layout()
        let b = bounds
        separator.frame = NSRect(x: 0, y: 0, width: 1, height: b.height)
        scrollView.frame = NSRect(x: 1, y: 0, width: max(0, b.width - 1), height: b.height)

        // Pin stackView width to scrollView content width so sections expand horizontally
        if let docWidth = scrollView.contentView.documentVisibleRect.width as CGFloat? {
            stackView.frame.size.width = max(docWidth, 0)
        }

        placeholderLabel.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height)

        // Update completeness bar track color for dark/light mode
        completenessTrack.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    // MARK: - Public API

    /// Updates the sidebar to show profiler info for the given column.
    func showColumn(name: String, typeName: String) {
        placeholderLabel.isHidden = true
        scrollView.isHidden = false

        columnNameLabel.stringValue = name
        typeBadge.stringValue = "  \(typeName)  "
        typeBadge.textColor = .white
        typeBadge.layer?.backgroundColor = badgeColor(for: typeName).cgColor

        // Reset overview stats, distribution, and statistics while loading
        overviewSection?.isHidden = true
        distributionSection?.isHidden = true
        statisticsSection?.isHidden = true
        loadingLabel.isHidden = false
    }

    /// Shows the placeholder text when no column is selected.
    func showPlaceholder() {
        placeholderLabel.isHidden = false
        scrollView.isHidden = true
    }

    /// Shows a loading indicator in the sidebar.
    func showLoading() {
        loadingLabel.isHidden = false
        overviewSection?.isHidden = true
        distributionSection?.isHidden = true
        statisticsSection?.isHidden = true
    }

    /// Updates the overview stats section with fetched data.
    func updateOverviewStats(totalRows: Int, uniqueCount: Int, nullCount: Int, emptyCount: Int) {
        loadingLabel.isHidden = true
        overviewSection?.isHidden = false

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","

        rowsValueLabel.stringValue = formatter.string(from: NSNumber(value: totalRows)) ?? "\(totalRows)"
        uniqueValueLabel.stringValue = formatter.string(from: NSNumber(value: uniqueCount)) ?? "\(uniqueCount)"
        nullsValueLabel.stringValue = formatter.string(from: NSNumber(value: nullCount)) ?? "\(nullCount)"
        emptyValueLabel.stringValue = formatter.string(from: NSNumber(value: emptyCount)) ?? "\(emptyCount)"

        // Update completeness bar
        let completeness: Double
        if totalRows > 0 {
            completeness = Double(totalRows - nullCount) / Double(totalRows)
        } else {
            completeness = 0
        }

        let pct = Int(round(completeness * 100))
        completenessLabel.stringValue = "\(pct)% complete"

        // Color the completeness bar: green >= 90%, orange 50-89%, red < 50%
        let barColor: NSColor
        if completeness >= 0.9 {
            barColor = .systemGreen
        } else if completeness >= 0.5 {
            barColor = .systemOrange
        } else {
            barColor = .systemRed
        }
        completenessFill.layer?.backgroundColor = barColor.cgColor

        // Update the fill width as a proportion of the track
        // The track has a fixed width constraint relative to the section,
        // and the fill width is proportional to completeness.
        completenessFillWidth?.isActive = false
        completenessFillWidth = completenessFill.widthAnchor.constraint(
            equalTo: completenessTrack.widthAnchor, multiplier: max(CGFloat(completeness), 0.001)
        )
        completenessFillWidth?.isActive = true
    }

    /// Updates the distribution histogram with fetched data.
    func updateDistribution(bars: [HistogramView.Bar], minLabel: String?, maxLabel: String?, trailingNote: String?) {
        distributionSection?.isHidden = false
        histogramView.bars = bars
        histogramView.minLabel = minLabel
        histogramView.maxLabel = maxLabel
        histogramView.trailingNote = trailingNote
    }

    /// Updates the descriptive statistics section with fetched data.
    /// Only called for numeric columns (INTEGER, FLOAT).
    func updateDescriptiveStats(min: Double, max: Double, mean: Double, median: Double,
                                stdDev: Double, q1: Double, q3: Double, iqr: Double,
                                isInteger: Bool) {
        statisticsSection?.isHidden = false

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = isInteger ? 0 : 2
        formatter.minimumFractionDigits = isInteger ? 0 : 2

        minValueLabel.stringValue = formatter.string(from: NSNumber(value: min)) ?? "\(min)"
        maxValueLabel.stringValue = formatter.string(from: NSNumber(value: max)) ?? "\(max)"
        meanValueLabel.stringValue = formatter.string(from: NSNumber(value: mean)) ?? "\(mean)"
        medianValueLabel.stringValue = formatter.string(from: NSNumber(value: median)) ?? "\(median)"
        stdDevValueLabel.stringValue = formatter.string(from: NSNumber(value: stdDev)) ?? "\(stdDev)"
        q1ValueLabel.stringValue = formatter.string(from: NSNumber(value: q1)) ?? "\(q1)"
        q3ValueLabel.stringValue = formatter.string(from: NSNumber(value: q3)) ?? "\(q3)"
        iqrValueLabel.stringValue = formatter.string(from: NSNumber(value: iqr)) ?? "\(iqr)"
    }

    /// Hides the statistics section (for non-numeric columns).
    func hideStatisticsSection() {
        statisticsSection?.isHidden = true
    }

    // MARK: - Distribution Section Builder

    private func buildDistributionSection() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let sectionTitle = NSTextField(labelWithString: "DISTRIBUTION")
        sectionTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        sectionTitle.textColor = .tertiaryLabelColor
        sectionTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sectionTitle)
        container.addSubview(histogramView)

        NSLayoutConstraint.activate([
            sectionTitle.topAnchor.constraint(equalTo: container.topAnchor),
            sectionTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sectionTitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            histogramView.topAnchor.constraint(equalTo: sectionTitle.bottomAnchor, constant: 8),
            histogramView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            histogramView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            histogramView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        container.isHidden = true
        return container
    }

    // MARK: - Statistics Section Builder

    private func buildStatisticsSection() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let sectionTitle = NSTextField(labelWithString: "STATISTICS")
        sectionTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        sectionTitle.textColor = .tertiaryLabelColor
        sectionTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sectionTitle)

        // 4x2 grid: Min/Max, Mean/Median, Std Dev/Q1, Q3/IQR
        let row1Left = makeStatCell(valueLabel: minValueLabel, titleLabel: minTitleLabel)
        let row1Right = makeStatCell(valueLabel: maxValueLabel, titleLabel: maxTitleLabel)
        let row2Left = makeStatCell(valueLabel: meanValueLabel, titleLabel: meanTitleLabel)
        let row2Right = makeStatCell(valueLabel: medianValueLabel, titleLabel: medianTitleLabel)
        let row3Left = makeStatCell(valueLabel: stdDevValueLabel, titleLabel: stdDevTitleLabel)
        let row3Right = makeStatCell(valueLabel: q1ValueLabel, titleLabel: q1TitleLabel)
        let row4Left = makeStatCell(valueLabel: q3ValueLabel, titleLabel: q3TitleLabel)
        let row4Right = makeStatCell(valueLabel: iqrValueLabel, titleLabel: iqrTitleLabel)

        let gridRow1 = NSStackView(views: [row1Left, row1Right])
        gridRow1.orientation = .horizontal
        gridRow1.distribution = .fillEqually
        gridRow1.spacing = 8
        gridRow1.translatesAutoresizingMaskIntoConstraints = false

        let gridRow2 = NSStackView(views: [row2Left, row2Right])
        gridRow2.orientation = .horizontal
        gridRow2.distribution = .fillEqually
        gridRow2.spacing = 8
        gridRow2.translatesAutoresizingMaskIntoConstraints = false

        let gridRow3 = NSStackView(views: [row3Left, row3Right])
        gridRow3.orientation = .horizontal
        gridRow3.distribution = .fillEqually
        gridRow3.spacing = 8
        gridRow3.translatesAutoresizingMaskIntoConstraints = false

        let gridRow4 = NSStackView(views: [row4Left, row4Right])
        gridRow4.orientation = .horizontal
        gridRow4.distribution = .fillEqually
        gridRow4.spacing = 8
        gridRow4.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSStackView(views: [gridRow1, gridRow2, gridRow3, gridRow4])
        grid.orientation = .vertical
        grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)

        NSLayoutConstraint.activate([
            sectionTitle.topAnchor.constraint(equalTo: container.topAnchor),
            sectionTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sectionTitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            grid.topAnchor.constraint(equalTo: sectionTitle.bottomAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        container.isHidden = true
        return container
    }

    // MARK: - Overview Section Builder

    private func buildOverviewSection() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Section title
        let sectionTitle = NSTextField(labelWithString: "OVERVIEW")
        sectionTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        sectionTitle.textColor = .tertiaryLabelColor
        sectionTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sectionTitle)

        // 2x2 grid of stat cells
        let topLeft = makeStatCell(valueLabel: rowsValueLabel, titleLabel: rowsTitleLabel)
        let topRight = makeStatCell(valueLabel: uniqueValueLabel, titleLabel: uniqueTitleLabel)
        let bottomLeft = makeStatCell(valueLabel: nullsValueLabel, titleLabel: nullsTitleLabel)
        let bottomRight = makeStatCell(valueLabel: emptyValueLabel, titleLabel: emptyTitleLabel)

        let topRow = NSStackView(views: [topLeft, topRight])
        topRow.orientation = .horizontal
        topRow.distribution = .fillEqually
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView(views: [bottomLeft, bottomRight])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fillEqually
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSStackView(views: [topRow, bottomRow])
        grid.orientation = .vertical
        grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)

        // Completeness bar section
        let completenessContainer = NSView()
        completenessContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(completenessContainer)

        completenessContainer.addSubview(completenessLabel)
        completenessContainer.addSubview(completenessTrack)
        completenessTrack.addSubview(completenessFill)

        // Layout constraints
        NSLayoutConstraint.activate([
            // Section title
            sectionTitle.topAnchor.constraint(equalTo: container.topAnchor),
            sectionTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sectionTitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            // Grid
            grid.topAnchor.constraint(equalTo: sectionTitle.bottomAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // Completeness container
            completenessContainer.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            completenessContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            completenessContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            completenessContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Completeness label
            completenessLabel.topAnchor.constraint(equalTo: completenessContainer.topAnchor),
            completenessLabel.leadingAnchor.constraint(equalTo: completenessContainer.leadingAnchor),

            // Track bar
            completenessTrack.topAnchor.constraint(equalTo: completenessLabel.bottomAnchor, constant: 4),
            completenessTrack.leadingAnchor.constraint(equalTo: completenessContainer.leadingAnchor),
            completenessTrack.trailingAnchor.constraint(equalTo: completenessContainer.trailingAnchor),
            completenessTrack.heightAnchor.constraint(equalToConstant: 6),
            completenessTrack.bottomAnchor.constraint(equalTo: completenessContainer.bottomAnchor),

            // Fill bar (pinned to left edge of track)
            completenessFill.topAnchor.constraint(equalTo: completenessTrack.topAnchor),
            completenessFill.bottomAnchor.constraint(equalTo: completenessTrack.bottomAnchor),
            completenessFill.leadingAnchor.constraint(equalTo: completenessTrack.leadingAnchor),
        ])

        // Initial fill width (zero)
        completenessFillWidth = completenessFill.widthAnchor.constraint(equalToConstant: 0)
        completenessFillWidth?.isActive = true

        container.isHidden = true
        return container
    }

    private func makeStatCell(valueLabel: NSTextField, titleLabel: NSTextField) -> NSView {
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.wantsLayer = true
        cell.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        cell.layer?.cornerRadius = 6

        cell.addSubview(valueLabel)
        cell.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            valueLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            valueLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),

            titleLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
        ])

        return cell
    }

    // MARK: - Factory Helpers

    private static func makeStatValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "–")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func makeStatTitleLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Helpers

    private func badgeColor(for typeName: String) -> NSColor {
        let upper = typeName.uppercased()
        if upper.contains("INT") { return .systemGreen }
        if upper.contains("VARCHAR") || upper.contains("TEXT") || upper.contains("CHAR") { return .systemBlue }
        if upper.contains("FLOAT") || upper.contains("DOUBLE") || upper.contains("DECIMAL") || upper.contains("NUMERIC") { return .systemOrange }
        if upper.contains("BOOL") { return .systemPurple }
        if upper.contains("DATE") || upper.contains("TIME") { return .systemRed }
        return .systemGray
    }
}

// MARK: - FlippedClipView

/// NSClipView subclass with flipped coordinate system so scroll content starts at the top.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
