import AppKit

/// A custom view for the profiler sidebar that displays the top N most frequent values
/// in a column. Each row shows value text, a mini proportional bar, count, and percentage.
/// Clicking a row triggers a filter callback.
final class TopValuesView: NSView {

    // MARK: - Types

    struct ValueRow {
        let value: String
        let count: Int
        let percentage: Double
    }

    // MARK: - Properties

    /// The rows to display. Setting this triggers a redraw.
    var rows: [ValueRow] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Message shown when all values are unique.
    var allUniqueMessage: String? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Callback when a value row is clicked. Parameter is the value string.
    var onValueClicked: ((String) -> Void)?

    /// Callback when "Show full frequency" link is clicked.
    var onShowFullFrequency: (() -> Void)?

    /// Whether to show the "Show full frequency" link.
    var showFrequencyLink: Bool = true {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    // MARK: - Layout Constants

    private let rowHeight: CGFloat = 22
    private let rowSpacing: CGFloat = 1
    private let barHeight: CGFloat = 12
    private let barCornerRadius: CGFloat = 2
    private let linkHeight: CGFloat = 24

    // MARK: - Tracking

    private var rowTrackingAreas: [NSTrackingArea] = []
    private var hoveredRow: Int = -1
    private var linkTrackingArea: NSTrackingArea?
    private var isLinkHovered = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        if let _ = allUniqueMessage {
            var h: CGFloat = rowHeight
            if showFrequencyLink { h += linkHeight }
            return NSSize(width: NSView.noIntrinsicMetric, height: h)
        }

        var height = CGFloat(rows.count) * (rowHeight + rowSpacing)
        if showFrequencyLink {
            height += linkHeight
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 0))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Remove old tracking areas
        for area in rowTrackingAreas {
            removeTrackingArea(area)
        }
        rowTrackingAreas.removeAll()
        if let linkArea = linkTrackingArea {
            removeTrackingArea(linkArea)
            linkTrackingArea = nil
        }

        let w = bounds.width

        // All-unique message
        if let message = allUniqueMessage {
            drawAllUniqueMessage(message, width: w)
            drawFrequencyLink(yOffset: rowHeight, width: w)
            return
        }

        guard !rows.isEmpty else { return }

        let maxCount = rows.map(\.count).max() ?? 1
        let valueFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","

        let countWidth: CGFloat = 50
        let pctWidth: CGFloat = 48
        let barMinWidth: CGFloat = 20
        let valueMaxWidth = max(w * 0.4, 60)
        let barAreaWidth = max(w - valueMaxWidth - countWidth - pctWidth - 12, barMinWidth)

        for (i, row) in rows.enumerated() {
            let y = CGFloat(i) * (rowHeight + rowSpacing)

            // Hover highlight
            if i == hoveredRow {
                ctx.saveGState()
                let hoverRect = NSRect(x: 0, y: y, width: w, height: rowHeight)
                let hoverPath = CGPath(roundedRect: hoverRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.addPath(hoverPath)
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }

            let textY = y + (rowHeight - 14) / 2

            // Value label (left, truncated)
            let valueRect = NSRect(x: 4, y: textY, width: valueMaxWidth - 8, height: 14)
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: valueFont,
                .foregroundColor: NSColor.labelColor,
            ]
            (row.value as NSString).draw(
                with: valueRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: valueAttrs,
                context: nil
            )

            // Mini bar (proportional to count)
            let barX = valueMaxWidth
            let proportion = maxCount > 0 ? CGFloat(row.count) / CGFloat(maxCount) : 0
            let barW = max(barAreaWidth * proportion, 2)
            let barY = y + (rowHeight - barHeight) / 2
            let barRect = NSRect(x: barX, y: barY, width: barW, height: barHeight)

            ctx.saveGState()
            let barPath = CGPath(roundedRect: barRect, cornerWidth: barCornerRadius, cornerHeight: barCornerRadius, transform: nil)
            ctx.addPath(barPath)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            // Count (right of bar area)
            let countX = valueMaxWidth + barAreaWidth + 4
            let countRect = NSRect(x: countX, y: textY, width: countWidth - 4, height: 14)
            let countStr = formatter.string(from: NSNumber(value: row.count)) ?? "\(row.count)"
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: countFont,
                .foregroundColor: NSColor.labelColor,
            ]
            (countStr as NSString).draw(
                with: countRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: countAttrs,
                context: nil
            )

            // Percentage
            let pctX = countX + countWidth
            let pctRect = NSRect(x: pctX, y: textY, width: pctWidth - 4, height: 14)
            let pctStr = String(format: "%.1f%%", row.percentage)
            let pctAttrs: [NSAttributedString.Key: Any] = [
                .font: pctFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            (pctStr as NSString).draw(
                with: pctRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: pctAttrs,
                context: nil
            )

            // Tracking area for click + hover
            let rowRect = NSRect(x: 0, y: y, width: w, height: rowHeight)
            let area = NSTrackingArea(
                rect: rowRect,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self,
                userInfo: ["rowIndex": i]
            )
            addTrackingArea(area)
            rowTrackingAreas.append(area)
        }

        // "Show full frequency →" link
        let yOffset = CGFloat(rows.count) * (rowHeight + rowSpacing)
        drawFrequencyLink(yOffset: yOffset, width: w)
    }

    private func drawAllUniqueMessage(_ message: String, width: CGFloat) {
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let color = NSColor.secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let rect = NSRect(x: 4, y: 4, width: width - 8, height: rowHeight - 8)
        (message as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs,
            context: nil
        )
    }

    private func drawFrequencyLink(yOffset: CGFloat, width: CGFloat) {
        guard showFrequencyLink else { return }

        let linkText = "Show full frequency \u{2192}"
        let linkFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let linkColor = isLinkHovered ? NSColor.controlAccentColor.withAlphaComponent(0.8) : NSColor.controlAccentColor
        var attrs: [NSAttributedString.Key: Any] = [
            .font: linkFont,
            .foregroundColor: linkColor,
        ]
        if isLinkHovered {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        let linkRect = NSRect(x: 4, y: yOffset + 6, width: width - 8, height: 14)
        (linkText as NSString).draw(
            with: linkRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs,
            context: nil
        )

        // Tracking area for link hover
        let fullLinkRect = NSRect(x: 0, y: yOffset, width: width, height: linkHeight)
        let area = NSTrackingArea(
            rect: fullLinkRect,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: ["link": true]
        )
        addTrackingArea(area)
        linkTrackingArea = area
    }

    // MARK: - Mouse Events

    override func mouseEntered(with event: NSEvent) {
        if let rowIndex = event.trackingArea?.userInfo?["rowIndex"] as? Int {
            hoveredRow = rowIndex
            NSCursor.pointingHand.push()
            needsDisplay = true
        } else if event.trackingArea?.userInfo?["link"] as? Bool == true {
            isLinkHovered = true
            NSCursor.pointingHand.push()
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["rowIndex"] != nil {
            hoveredRow = -1
            NSCursor.pop()
            needsDisplay = true
        } else if event.trackingArea?.userInfo?["link"] as? Bool == true {
            isLinkHovered = false
            NSCursor.pop()
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check if link was clicked
        if showFrequencyLink {
            let yOffset: CGFloat
            if allUniqueMessage != nil {
                yOffset = rowHeight
            } else {
                yOffset = CGFloat(rows.count) * (rowHeight + rowSpacing)
            }
            let linkRect = NSRect(x: 0, y: yOffset, width: bounds.width, height: linkHeight)
            if linkRect.contains(point) {
                onShowFullFrequency?()
                return
            }
        }

        // Check if a value row was clicked
        guard allUniqueMessage == nil else { return }
        for (i, row) in rows.enumerated() {
            let y = CGFloat(i) * (rowHeight + rowSpacing)
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            if rowRect.contains(point) {
                onValueClicked?(row.value)
                return
            }
        }
    }
}
