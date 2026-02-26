import AppKit

/// A horizontal bar chart drawn with Core Graphics for the profiler sidebar.
/// Accepts an array of (label, count) tuples and renders bars proportional to the max count.
final class HistogramView: NSView {

    // MARK: - Types

    struct Bar {
        let label: String
        let count: Int
        /// Optional secondary label (e.g., bucket range for numeric histograms).
        var detail: String?
    }

    // MARK: - Properties

    /// The bars to display. Setting this triggers a redraw.
    var bars: [Bar] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Optional min/max labels shown below the chart for numeric columns.
    var minLabel: String?
    var maxLabel: String?

    /// Optional trailing note shown below the bars (e.g., "and 42 more…").
    var trailingNote: String?

    /// Bar appearance constants.
    private let barHeight: CGFloat = 14
    private let barSpacing: CGFloat = 3
    private let labelWidth: CGFloat = 70
    private let countLabelWidth: CGFloat = 50
    private let barCornerRadius: CGFloat = 2
    private let horizontalPadding: CGFloat = 0
    private let minMaxRowHeight: CGFloat = 14
    private let trailingNoteHeight: CGFloat = 16

    /// Tooltip tracking areas, rebuilt on each draw.
    private var barTrackingAreas: [NSTrackingArea] = []
    private var barTooltips: [NSRect: String] = [:]

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        var height = CGFloat(bars.count) * (barHeight + barSpacing)
        if minLabel != nil || maxLabel != nil {
            height += minMaxRowHeight
        }
        if trailingNote != nil {
            height += trailingNoteHeight
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 0))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width - horizontalPadding * 2
        guard w > 0, !bars.isEmpty else { return }

        // Remove old tracking areas
        for area in barTrackingAreas {
            removeTrackingArea(area)
        }
        barTrackingAreas.removeAll()
        barTooltips.removeAll()

        let maxCount = bars.map(\.count).max() ?? 1
        let barAreaWidth = w - labelWidth - countLabelWidth - 8 // 8px gap

        let barColor = NSColor.systemBlue
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let labelColor = NSColor.secondaryLabelColor
        let countColor = NSColor.labelColor

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","

        for (i, bar) in bars.enumerated() {
            let y = CGFloat(i) * (barHeight + barSpacing)
            let x = horizontalPadding

            // Draw label (left-aligned, truncated)
            let labelRect = NSRect(x: x, y: y, width: labelWidth - 4, height: barHeight)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: labelColor,
            ]
            let truncatedLabel = bar.label
            (truncatedLabel as NSString).draw(
                with: labelRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: labelAttrs,
                context: nil
            )

            // Draw bar
            let barX = x + labelWidth
            let proportion = maxCount > 0 ? CGFloat(bar.count) / CGFloat(maxCount) : 0
            let barW = max(barAreaWidth * proportion, 2) // minimum 2px for visibility
            let barRect = NSRect(x: barX, y: y + 1, width: barW, height: barHeight - 2)

            ctx.saveGState()
            let path = CGPath(roundedRect: barRect, cornerWidth: barCornerRadius, cornerHeight: barCornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(barColor.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            // Draw count label (right-aligned)
            let countX = x + labelWidth + barAreaWidth + 4
            let countRect = NSRect(x: countX, y: y, width: countLabelWidth, height: barHeight)
            let countStr = formatter.string(from: NSNumber(value: bar.count)) ?? "\(bar.count)"
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: countFont,
                .foregroundColor: countColor,
            ]
            (countStr as NSString).draw(
                with: countRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: countAttrs,
                context: nil
            )

            // Tracking area for tooltip
            let fullBarRect = NSRect(x: barX, y: y, width: barAreaWidth, height: barHeight)
            let tooltip: String
            if let detail = bar.detail {
                tooltip = "\(detail): \(countStr)"
            } else {
                tooltip = "\(bar.label): \(countStr)"
            }
            barTooltips[fullBarRect] = tooltip
            let area = NSTrackingArea(
                rect: fullBarRect,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self,
                userInfo: ["tooltip": tooltip]
            )
            addTrackingArea(area)
            barTrackingAreas.append(area)
        }

        // Draw min/max labels for numeric histograms
        var yOffset = CGFloat(bars.count) * (barHeight + barSpacing)
        if let minStr = minLabel, let maxStr = maxLabel {
            let minMaxFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            let minMaxColor = NSColor.tertiaryLabelColor
            let attrs: [NSAttributedString.Key: Any] = [
                .font: minMaxFont,
                .foregroundColor: minMaxColor,
            ]

            let minRect = NSRect(x: horizontalPadding + labelWidth, y: yOffset, width: barAreaWidth / 2, height: minMaxRowHeight)
            (minStr as NSString).draw(with: minRect, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)

            let maxSize = (maxStr as NSString).size(withAttributes: attrs)
            let maxX = horizontalPadding + labelWidth + barAreaWidth - maxSize.width
            let maxRect = NSRect(x: maxX, y: yOffset, width: maxSize.width + 4, height: minMaxRowHeight)
            (maxStr as NSString).draw(with: maxRect, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)

            yOffset += minMaxRowHeight
        }

        // Draw trailing note
        if let note = trailingNote {
            let noteFont = NSFont.systemFont(ofSize: 10, weight: .regular)
            let noteColor = NSColor.tertiaryLabelColor
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .font: noteFont,
                .foregroundColor: noteColor,
            ]
            let noteRect = NSRect(x: horizontalPadding, y: yOffset + 2, width: w, height: trailingNoteHeight)
            (note as NSString).draw(with: noteRect, options: [.usesLineFragmentOrigin], attributes: noteAttrs, context: nil)
        }
    }

    // MARK: - Tooltips

    override func mouseEntered(with event: NSEvent) {
        if let tooltip = event.trackingArea?.userInfo?["tooltip"] as? String {
            self.toolTip = tooltip
        }
    }

    override func mouseExited(with event: NSEvent) {
        self.toolTip = nil
    }
}
