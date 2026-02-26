import AppKit

/// Custom NSTableHeaderCell that draws a mini sparkline visualization below the column name.
/// Sparklines render from pre-cached ColumnSummary data — no queries on draw.
///
/// **Lifetime safety (US-103):**
/// - `columnSummary` is stored as a private property with a public setter that
///   snapshots the distribution into a local enum, so draw() only touches value-type
///   data captured at assignment time.
/// - `clearSummary()` nils both the summary and snapshot, called before the owning
///   NSTableColumn is removed from the table to prevent stale draws during teardown.
/// - `draw(withFrame:in:)` captures the snapshot once at entry; if nil, the sparkline
///   area is skipped. No further property access occurs during drawing.
final class SparklineHeaderCell: NSTableHeaderCell {

    /// The column summary data that drives sparkline rendering.
    /// Set this after column summaries are computed; nil means no sparkline shown.
    /// The setter immediately snapshots the distribution for safe use during draw().
    var columnSummary: ColumnSummary? {
        didSet {
            _distributionSnapshot = columnSummary?.distribution
        }
    }

    /// Snapshot of the distribution at the time columnSummary was last set.
    /// draw() reads only this value — never re-accesses columnSummary during rendering.
    private var _distributionSnapshot: Distribution?

    /// Clears all summary data. Call before the owning column is removed from the table
    /// to prevent stale data from being drawn during header cell teardown/deallocation.
    func clearSummary() {
        columnSummary = nil
        _distributionSnapshot = nil
    }

    /// Height reserved for the sparkline area below the text.
    static let sparklineHeight: CGFloat = 16

    /// Total header height including text + sparkline.
    static let totalHeaderHeight: CGFloat = 44

    /// Vertical padding above the sparkline.
    private static let sparklineTopPadding: CGFloat = 1

    /// Horizontal padding for sparkline content.
    private static let sparklineHPadding: CGFloat = 6

    /// Corner radius for histogram/frequency bars.
    private static let barCornerRadius: CGFloat = 1.5

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Draw the standard header background and text in the top portion.
        let textHeight = cellFrame.height - Self.sparklineHeight - Self.sparklineTopPadding
        let textFrame = NSRect(
            x: cellFrame.origin.x,
            y: cellFrame.origin.y,
            width: cellFrame.width,
            height: textHeight
        )
        super.draw(withFrame: textFrame, in: controlView)

        // Snapshot distribution once at draw entry — no further property access.
        guard let distribution = _distributionSnapshot else { return }

        let sparklineFrame = NSRect(
            x: cellFrame.origin.x + Self.sparklineHPadding,
            y: cellFrame.origin.y + textHeight + Self.sparklineTopPadding,
            width: cellFrame.width - Self.sparklineHPadding * 2,
            height: Self.sparklineHeight
        )

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: sparklineFrame)

        switch distribution {
        case .histogram(let buckets):
            drawHistogramSparkline(ctx: ctx, frame: sparklineFrame, buckets: buckets)
        case .frequency(let values):
            drawFrequencySparkline(ctx: ctx, frame: sparklineFrame, values: values)
        case .boolean(let trueCount, let falseCount):
            drawBooleanSparkline(ctx: ctx, frame: sparklineFrame, trueCount: trueCount, falseCount: falseCount)
        case .highCardinality(let uniqueCount):
            drawHighCardinalityBadge(frame: sparklineFrame, uniqueCount: uniqueCount)
        }

        ctx.restoreGState()
    }

    // MARK: - Histogram Sparkline (Numeric Columns)

    /// Draws 8-10 mini vertical bars representing a numeric distribution.
    private func drawHistogramSparkline(ctx: CGContext, frame: NSRect, buckets: [(range: String, count: Int)]) {
        guard !buckets.isEmpty else { return }

        let maxCount = buckets.map(\.count).max() ?? 1
        guard maxCount > 0 else { return }

        let barCount = CGFloat(buckets.count)
        let gap: CGFloat = 1
        let totalGaps = gap * max(barCount - 1, 0)
        let barWidth = max((frame.width - totalGaps) / barCount, 2)
        let barColor = NSColor.systemBlue.withAlphaComponent(0.6)

        for (i, bucket) in buckets.enumerated() {
            let proportion = CGFloat(bucket.count) / CGFloat(maxCount)
            let barHeight = max(frame.height * proportion, 1)
            let x = frame.origin.x + CGFloat(i) * (barWidth + gap)
            let y = frame.origin.y + frame.height - barHeight

            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = CGPath(roundedRect: barRect, cornerWidth: Self.barCornerRadius, cornerHeight: Self.barCornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(barColor.cgColor)
            ctx.fillPath()
        }
    }

    // MARK: - Frequency Sparkline (Low-Cardinality Categorical)

    /// Draws mini horizontal bars for top values, sorted by frequency (decreasing height).
    private func drawFrequencySparkline(ctx: CGContext, frame: NSRect, values: [(value: String, count: Int)]) {
        guard !values.isEmpty else { return }

        let maxCount = values.map(\.count).max() ?? 1
        guard maxCount > 0 else { return }

        let barCount = CGFloat(min(values.count, 15))
        let gap: CGFloat = 1
        let totalGaps = gap * max(barCount - 1, 0)
        let barWidth = max((frame.width - totalGaps) / barCount, 2)
        let barColor = NSColor.systemTeal.withAlphaComponent(0.6)

        for (i, value) in values.prefix(15).enumerated() {
            let proportion = CGFloat(value.count) / CGFloat(maxCount)
            let barHeight = max(frame.height * proportion, 1)
            let x = frame.origin.x + CGFloat(i) * (barWidth + gap)
            let y = frame.origin.y + frame.height - barHeight

            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = CGPath(roundedRect: barRect, cornerWidth: Self.barCornerRadius, cornerHeight: Self.barCornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(barColor.cgColor)
            ctx.fillPath()
        }
    }

    // MARK: - Boolean Sparkline

    /// Draws a two-segment horizontal bar with proportional true/false widths.
    private func drawBooleanSparkline(ctx: CGContext, frame: NSRect, trueCount: Int, falseCount: Int) {
        let total = trueCount + falseCount
        guard total > 0 else { return }

        let trueProportion = CGFloat(trueCount) / CGFloat(total)
        let barHeight: CGFloat = 8
        let barY = frame.origin.y + (frame.height - barHeight) / 2
        let cornerRadius: CGFloat = 3

        // Full background bar (false portion — red/secondary)
        let fullRect = CGRect(x: frame.origin.x, y: barY, width: frame.width, height: barHeight)
        let fullPath = CGPath(roundedRect: fullRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(fullPath)
        ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.35).cgColor)
        ctx.fillPath()

        // True portion (green, overlaid from left)
        let trueWidth = frame.width * trueProportion
        if trueWidth > 0 {
            let trueRect = CGRect(x: frame.origin.x, y: barY, width: trueWidth, height: barHeight)
            ctx.saveGState()
            // Clip to the full rounded rect shape so the true bar respects corner radius
            ctx.addPath(fullPath)
            ctx.clip()
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.6).cgColor)
            ctx.fill(trueRect)
            ctx.restoreGState()
        }

        // Percentage labels
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let truePercent = Int(round(trueProportion * 100))

        if truePercent > 15 {
            let trueStr = "\(truePercent)%"
            let trueAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8),
            ]
            let trueSize = (trueStr as NSString).size(withAttributes: trueAttrs)
            let trueTextX = frame.origin.x + 3
            let trueTextY = barY + (barHeight - trueSize.height) / 2
            (trueStr as NSString).draw(at: NSPoint(x: trueTextX, y: trueTextY), withAttributes: trueAttrs)
        }

        let falsePercent = 100 - truePercent
        if falsePercent > 15 {
            let falseStr = "\(falsePercent)%"
            let falseAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8),
            ]
            let falseSize = (falseStr as NSString).size(withAttributes: falseAttrs)
            let falseTextX = frame.origin.x + frame.width - falseSize.width - 3
            let falseTextY = barY + (barHeight - falseSize.height) / 2
            (falseStr as NSString).draw(at: NSPoint(x: falseTextX, y: falseTextY), withAttributes: falseAttrs)
        }
    }

    // MARK: - High Cardinality Badge

    /// Draws a text badge showing "N unique" for high-cardinality columns.
    private func drawHighCardinalityBadge(frame: NSRect, uniqueCount: Int) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let countStr = formatter.string(from: NSNumber(value: uniqueCount)) ?? "\(uniqueCount)"
        let text = "\(countStr) unique"

        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let color = NSColor.secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]

        let textSize = (text as NSString).size(withAttributes: attrs)
        let textX = frame.origin.x
        let textY = frame.origin.y + (frame.height - textSize.height) / 2
        (text as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
    }
}
