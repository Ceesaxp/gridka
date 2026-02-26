import AppKit

/// Custom NSView that draws horizontal bars for the frequency bar chart.
/// Each bar corresponds to a row in the frequency table. Bar width is proportional
/// to count (largest value = full width). Scrolls in sync with the table.
///
/// US-012: Frequency bar chart alongside table.
final class FrequencyBarChartView: NSView {

    override var isFlipped: Bool { true }

    struct Bar {
        let value: String
        let count: Int
    }

    /// The bars to draw. Set this and call `invalidateIntrinsicContentSize()` + `needsDisplay = true`.
    private(set) var bars: [Bar] = []
    /// Maximum count across all bars (for proportional width calculation).
    private var maxCount: Int = 1

    /// Row height must match the table's rowHeight + intercellSpacing.
    var rowHeight: CGFloat = 22

    /// Inset from top to match the table header height.
    var headerOffset: CGFloat = 0

    func update(bars: [Bar], maxCount: Int) {
        self.bars = bars
        self.maxCount = max(maxCount, 1)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let height = headerOffset + CGFloat(bars.count) * rowHeight
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let barColor = NSColor.controlAccentColor
        let barInsetY: CGFloat = 3
        let barInsetX: CGFloat = 4
        let cornerRadius: CGFloat = 3

        for (i, bar) in bars.enumerated() {
            let y = headerOffset + CGFloat(i) * rowHeight + barInsetY
            let barHeight = rowHeight - barInsetY * 2

            // Skip bars outside dirty rect
            let rowRect = CGRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            guard rowRect.intersects(dirtyRect) else { continue }

            let proportion = CGFloat(bar.count) / CGFloat(maxCount)
            let availableWidth = bounds.width - barInsetX * 2
            let barWidth = max(availableWidth * proportion, 2)

            let barRect = CGRect(
                x: barInsetX,
                y: y,
                width: barWidth,
                height: barHeight
            )
            let path = CGPath(roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(path)
            context.setFillColor(barColor.withAlphaComponent(0.6).cgColor)
            context.fillPath()
        }
    }
}
