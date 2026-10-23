import AppKit
import Foundation

// MARK: - Activity heatmap

/// 13 weeks × 7 days, Sunday at the top, month labels above and a Less → More legend below (§4.2).
final class AnalyticsHeatmapView: NSView, NSViewToolTipOwner {
    static let height: CGFloat = 156

    private let cells: [AnalyticsHeatCell]
    private let theme: PanelTheme
    private let colors: [NSColor]
    private let labelColumn: CGFloat = 14
    private let monthRow: CGFloat = 13
    private let weeks = 13
    private var pitch: CGFloat { 18 }
    private var cellSize: CGFloat { max(2, pitch - 1) }

    init(frame: NSRect, cells: [AnalyticsHeatCell], theme: PanelTheme) {
        self.cells = cells
        self.theme = theme
        self.colors = AnalyticsPanelPalette.heatLevels(theme)
        super.init(frame: NSRect(origin: frame.origin, size: NSSize(width: frame.width, height: Self.height)))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        let active = cells.filter { $0.tokens > 0 }.count
        setAccessibilityLabel("Activity heatmap, \(active) active days in the last 3 months")
        for index in cells.indices {
            addToolTip(cellRect(index).insetBy(dx: -0.5, dy: -0.5), owner: self, userData: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func cellRect(_ index: Int) -> NSRect {
        let column = CGFloat(index / 7)
        let row = CGFloat(index % 7)
        return NSRect(x: labelColumn + column * pitch, y: monthRow + row * pitch, width: cellSize, height: cellSize)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = cells.indices.first(where: { cellRect($0).insetBy(dx: -0.5, dy: -0.5).contains(point) }) else { return "" }
        let cell = cells[index]
        let tokens = cell.tokens > 0 ? "\(AnalyticsPanelFormat.grouped(cell.tokens)) tokens" : "No activity"
        return "\(AnalyticsPanelFormat.weekdayDay(cell.day))\n\(tokens) · Level \(cell.level)"
    }

    override func draw(_ dirtyRect: NSRect) {
        drawMonthLabels()
        drawWeekdayLabels()
        for (index, cell) in cells.enumerated() {
            colors[max(0, min(4, cell.level))].setFill()
            let rect = cellRect(index)
            NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2).fill()
        }
        drawLegend()
    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 9, weight: .regular), .foregroundColor: theme.secondaryText]
    }

    private func drawMonthLabels() {
        let calendar = Calendar.current
        var lastLabelX = -CGFloat.greatestFiniteMagnitude
        for (index, cell) in cells.enumerated() where calendar.component(.day, from: cell.day) == 1 {
            let x = labelColumn + CGFloat(index / 7) * pitch
            let text = AnalyticsPanelFormat.monthName(cell.day) as NSString
            let width = text.size(withAttributes: labelAttributes).width
            guard x - lastLabelX >= 22, x + width <= bounds.width else { continue }
            text.draw(at: NSPoint(x: x, y: 0), withAttributes: labelAttributes)
            lastLabelX = x
        }
    }

    private func drawWeekdayLabels() {
        for (row, text) in [(1, "M"), (3, "W"), (5, "F")] {
            let y = monthRow + CGFloat(row) * pitch + cellSize / 2 - 6
            (text as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: labelAttributes)
        }
    }

    private func drawLegend() {
        let y = monthRow + 7 * pitch + 6
        let swatch: CGFloat = 8
        let more = "More" as NSString
        let less = "Less" as NSString
        var x = bounds.width - more.size(withAttributes: labelAttributes).width
        more.draw(at: NSPoint(x: x, y: y - 1), withAttributes: labelAttributes)
        x -= 4 + swatch
        for color in colors.reversed() {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 1, width: swatch, height: swatch), xRadius: 1.5, yRadius: 1.5).fill()
            x -= swatch + 2
        }
        x -= 2 + less.size(withAttributes: labelAttributes).width
        less.draw(at: NSPoint(x: x, y: y - 1), withAttributes: labelAttributes)
    }
}

// MARK: - Usage trend

/// Stacked bars by model, future buckets as faint ghosts, start/end labels and a model legend (§4.5).
final class AnalyticsTrendView: NSView, NSViewToolTipOwner {
    static let height: CGFloat = 122

    private let bars: [AnalyticsTrendBar]
    private let period: AnalyticsPeriod
    private let theme: PanelTheme
    private let chartHeight: CGFloat = 80
    private let chartTop: CGFloat = 4
    private lazy var yMax: Double = computeYMax()
    private lazy var ghostHeights: [Int: Double] = computeGhosts()

    init(frame: NSRect, bars: [AnalyticsTrendBar], period: AnalyticsPeriod, theme: PanelTheme) {
        self.bars = bars
        self.period = period
        self.theme = theme
        super.init(frame: NSRect(origin: frame.origin, size: NSSize(width: frame.width, height: Self.height)))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Usage trend, \(bars.count) bars")
        for index in bars.indices {
            addToolTip(columnRect(index), owner: self, userData: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func total(_ bar: AnalyticsTrendBar) -> Int {
        bar.segments.reduce(0) { $0 + $1.tokens }
    }

    private var gap: CGFloat {
        guard !bars.isEmpty else { return 0 }
        return max(1, min(4, bounds.width / CGFloat(bars.count) * 0.22))
    }

    private var barWidth: CGFloat {
        guard !bars.isEmpty else { return 0 }
        return max(1, (bounds.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
    }

    private func columnRect(_ index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * (barWidth + gap), y: chartTop, width: barWidth, height: chartHeight)
    }

    /// Clips outliers above Q3 + 1.5·IQR when there are at least four values, except for "total".
    private func computeYMax() -> Double {
        let values = bars.filter { !$0.isFuture }.map { Double(total($0)) }.sorted()
        guard let maximum = values.last, maximum > 0 else { return 1 }
        guard period != .total, values.count >= 4 else { return maximum }
        let q1 = quantile(values, 0.25)
        let q3 = quantile(values, 0.75)
        let cap = q3 + 1.5 * (q3 - q1)
        return cap > 0 ? min(maximum, cap) : maximum
    }

    private func quantile(_ sorted: [Double], _ p: Double) -> Double {
        let position = Double(sorted.count - 1) * p
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Future buckets borrow the average active bar and decay ×0.98 per step.
    private func computeGhosts() -> [Int: Double] {
        let active = bars.filter { !$0.isFuture }.map { Double(total($0)) }.filter { $0 > 0 }
        guard !active.isEmpty else { return [:] }
        let base = active.reduce(0, +) / Double(active.count)
        var result: [Int: Double] = [:]
        var step = 0
        for (index, bar) in bars.enumerated() where bar.isFuture {
            step += 1
            result[index] = base * pow(0.98, Double(step))
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        drawGuides()
        for (index, bar) in bars.enumerated() {
            bar.isFuture ? drawGhost(index) : drawBar(bar, index: index)
        }
        drawAxisLabels()
        drawLegend()
    }

    private var smallAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), .foregroundColor: theme.secondaryText]
    }

    private func drawGuides() {
        theme.hairline.setFill()
        NSRect(x: 0, y: chartTop + chartHeight, width: bounds.width, height: 0.5).fill()
        let dash = NSBezierPath()
        dash.move(to: NSPoint(x: 0, y: chartTop + 0.25))
        dash.line(to: NSPoint(x: bounds.width, y: chartTop + 0.25))
        dash.lineWidth = 0.5
        dash.setLineDash([2, 3], count: 2, phase: 0)
        theme.hairline.setStroke()
        dash.stroke()
    }

    private func barRect(_ index: Int, value: Double) -> NSRect {
        let column = columnRect(index)
        let height = value <= 0 ? 0 : max(1.5, CGFloat(min(value / yMax, 1)) * chartHeight)
        return NSRect(x: column.minX, y: column.maxY - height, width: column.width, height: height)
    }

    private func drawBar(_ bar: AnalyticsTrendBar, index: Int) {
        let rect = barRect(index, value: Double(total(bar)))
        guard rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        let radius = min(2, rect.width / 2)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        let sum = CGFloat(total(bar))
        var y = rect.maxY
        for segment in bar.segments where segment.tokens > 0 {
            let height = rect.height * CGFloat(segment.tokens) / sum
            AnalyticsPanelPalette.modelColor(segment.name).setFill()
            NSRect(x: rect.minX, y: y - height, width: rect.width, height: height).fill()
            y -= height
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawGhost(_ index: Int) {
        let rect = barRect(index, value: ghostHeights[index] ?? 0)
        guard rect.height > 0 else { return }
        theme.secondaryText.withAlphaComponent(theme.isDark ? 0.09 : 0.08).setFill()
        let radius = min(2, rect.width / 2)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private func label(for date: Date) -> String {
        switch period {
        case .day: return AnalyticsPanelFormat.hour(date)
        case .week, .month: return AnalyticsPanelFormat.day(date)
        case .total: return AnalyticsPanelFormat.month(date)
        }
    }

    private func drawAxisLabels() {
        guard let first = bars.first, let last = bars.last else { return }
        let y = chartTop + chartHeight + 4
        (label(for: first.start) as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: smallAttributes)
        let end = label(for: last.start) as NSString
        end.draw(at: NSPoint(x: bounds.width - end.size(withAttributes: smallAttributes).width, y: y), withAttributes: smallAttributes)
        let peak = "max \(AnalyticsPanelFormat.compact(Int(yMax)))" as NSString
        let peakWidth = peak.size(withAttributes: smallAttributes).width
        peak.draw(at: NSPoint(x: (bounds.width - peakWidth) / 2, y: y), withAttributes: smallAttributes)
    }

    /// One entry per colour: model families share a colour (§4.5), so they share a legend label.
    private func legendEntries() -> [(name: String, color: NSColor)] {
        var sums: [String: Int] = [:]
        for bar in bars where !bar.isFuture {
            for segment in bar.segments { sums[segment.name, default: 0] += segment.tokens }
        }
        var families: [String: Int] = [:]
        for (name, tokens) in sums where tokens > 0 {
            families[AnalyticsPanelPalette.modelFamily(name), default: 0] += tokens
        }
        return families
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, AnalyticsPanelPalette.modelColor($0.key)) }
    }

    private func drawLegend() {
        let models = legendEntries()
        let font = NSFont.systemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.secondaryText]
        let y = chartTop + chartHeight + 22
        var x: CGFloat = 0
        for (index, model) in models.enumerated() {
            let text = model.name as NSString
            let width = min(110, text.size(withAttributes: attributes).width)
            let remaining = models.count - index - 1
            let reserve: CGFloat = remaining > 0 ? 26 : 0
            guard x + 10 + width + reserve <= bounds.width else {
                ("+\(models.count - index)" as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
                return
            }
            model.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 4, width: 6, height: 6), xRadius: 1.5, yRadius: 1.5).fill()
            text.draw(with: NSRect(x: x + 10, y: y, width: width, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            x += 10 + width + 12
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = bars.indices.first(where: { columnRect($0).contains(point) }) else { return "" }
        let bar = bars[index]
        let sum = total(bar)
        if bar.isFuture { return "\(label(for: bar.start))\nUpcoming" }
        var lines = ["\(label(for: bar.start))", sum > 0 ? "\(AnalyticsPanelFormat.grouped(sum)) tokens" : "No activity"]
        for segment in bar.segments.prefix(4) where segment.tokens > 0 && sum > 0 {
            lines.append("\(segment.name)  \(Int((Double(segment.tokens) / Double(sum) * 100).rounded()))%")
        }
        return lines.joined(separator: "\n")
    }
}
