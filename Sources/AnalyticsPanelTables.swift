import AppKit
import Foundation

struct AnalyticsTableColumn {
    let title: String
    /// 0 takes the remaining width.
    let width: CGFloat
    let alignment: NSTextAlignment
}

struct AnalyticsTableRow {
    let cells: [String]
    var muted = false
    /// 0...1, drawn as a thin bar under the first column.
    var bar: Double?
    var barColor: NSColor?
    var toolTip: String?
}

/// A compact, drawn table: a header, monospaced digits, a first text column and right-aligned numbers.
final class AnalyticsTableView: NSView, NSViewToolTipOwner {
    private let columns: [AnalyticsTableColumn]
    private let rows: [AnalyticsTableRow]
    private let theme: PanelTheme
    private let rowHeight: CGFloat
    private let headerHeight: CGFloat = 24
    private let padding: CGFloat = 12
    private let columnGap: CGFloat = 6

    static func height(rows: Int, rowHeight: CGFloat) -> CGFloat {
        24 + CGFloat(rows) * rowHeight + 4
    }

    init(frame: NSRect, columns: [AnalyticsTableColumn], rows: [AnalyticsTableRow], rowHeight: CGFloat = 20, theme: PanelTheme, accessibilityLabel: String) {
        self.columns = columns
        self.rows = rows
        self.theme = theme
        self.rowHeight = rowHeight
        super.init(frame: NSRect(origin: frame.origin, size: NSSize(width: frame.width, height: Self.height(rows: rows.count, rowHeight: rowHeight))))
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
        setAccessibilityLabel(accessibilityLabel)
        for (index, row) in rows.enumerated() where row.toolTip != nil {
            addToolTip(rowRect(index), owner: self, userData: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 0, y: headerHeight + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }

    private func columnFrames() -> [(x: CGFloat, width: CGFloat)] {
        let fixed = columns.reduce(0) { $0 + $1.width } + columnGap * CGFloat(columns.count - 1)
        let flexible = max(0, bounds.width - padding * 2 - fixed)
        var x = padding
        return columns.map { column in
            let width = column.width > 0 ? column.width : flexible
            defer { x += width + columnGap }
            return (x, width)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        rows.indices.first(where: { rowRect($0).contains(point) }).flatMap { rows[$0].toolTip } ?? ""
    }

    override func draw(_ dirtyRect: NSRect) {
        let frames = columnFrames()
        drawHeader(frames)
        for (index, row) in rows.enumerated() {
            drawRow(row, rect: rowRect(index), frames: frames)
        }
    }

    private func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    private func drawText(_ text: String, in rect: NSRect, alignment: NSTextAlignment, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph(alignment)]
        let height = ceil(font.ascender - font.descender + font.leading)
        (text as NSString).draw(with: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private func drawHeader(_ frames: [(x: CGFloat, width: CGFloat)]) {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        for (column, frame) in zip(columns, frames) {
            drawText(column.title, in: NSRect(x: frame.x, y: 2, width: frame.width, height: headerHeight - 4), alignment: column.alignment, font: font, color: theme.secondaryText)
        }
        theme.hairline.setFill()
        NSRect(x: padding, y: headerHeight - 1, width: bounds.width - padding * 2, height: 0.5).fill()
    }

    private func drawRow(_ row: AnalyticsTableRow, rect: NSRect, frames: [(x: CGFloat, width: CGFloat)]) {
        let textFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        let textRect = row.bar == nil ? rect : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 6)
        for (index, (cell, frame)) in zip(row.cells, frames).enumerated() {
            let isFirst = index == 0
            let color: NSColor
            if row.muted {
                color = theme.tertiaryText
            } else {
                color = isFirst || index == 1 ? theme.primaryText : theme.secondaryText
            }
            drawText(cell, in: NSRect(x: frame.x, y: textRect.minY, width: frame.width, height: textRect.height), alignment: columns[index].alignment, font: isFirst ? textFont : digitFont, color: color)
        }
        if let bar = row.bar, let first = frames.first {
            let track = NSRect(x: first.x, y: rect.maxY - 7, width: first.width, height: 3)
            theme.trackFill.setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            let fraction = CGFloat(max(0.02, min(1, bar)))
            (row.barColor ?? theme.accent).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
