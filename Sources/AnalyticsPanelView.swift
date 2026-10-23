import AppKit
import Foundation

/// What the panel needs from the analytics engine; built by the app delegate like `ClaudePanelModel`.
struct AnalyticsPanelModel {
    let snapshot: AnalyticsSnapshot?
    let status: AnalyticsScanStatus
    let period: AnalyticsPeriod
    let selectPeriod: (AnalyticsPeriod) -> Void
    let refresh: () -> Void

    static let empty = AnalyticsPanelModel(
        snapshot: nil,
        status: AnalyticsScanStatus(isScanning: false, processedBytes: 0, totalBytes: 0, lastError: nil),
        period: .month,
        selectPeriod: { _ in },
        refresh: {}
    )

    /// Toolbar subtitle and whether it is a warning.
    var subtitle: (String, Bool) {
        if let error = status.lastError, !error.isEmpty { return (error, true) }
        if status.isScanning {
            guard status.totalBytes > 0 else { return ("Indexing logs…", false) }
            return ("Indexing logs… \(AnalyticsPanelFormat.bytes(processed: status.processedBytes, total: status.totalBytes))", false)
        }
        guard let snapshot else { return ("Not scanned yet", false) }
        let seconds = Int(Date().timeIntervalSince(snapshot.scannedAt))
        if seconds < 60 { return ("Scanned just now", false) }
        if seconds < 3600 { return ("Scanned \(seconds / 60)m ago", false) }
        if seconds < 86_400 { return ("Scanned \(seconds / 3600)h ago", false) }
        return ("Scanned \(AnalyticsPanelFormat.day(snapshot.scannedAt))", false)
    }
}

enum AnalyticsBreakdownMode {
    case daily
    case projects
}

/// Lays out the Analytics tab body: period, headline, tiles, top models, heatmap, trend, tables.
struct AnalyticsPanelBuilder {
    let model: AnalyticsPanelModel
    let theme: PanelTheme
    let inset: CGFloat
    let width: CGFloat
    let breakdown: AnalyticsBreakdownMode
    let selectBreakdown: (AnalyticsBreakdownMode) -> Void

    let tilePadding: CGFloat = 14
    let sectionGap: CGFloat = 16

    func build(into body: NSView) -> CGFloat {
        var y = periodSelector(into: body, y: 0)
        if let error = model.status.lastError, !error.isEmpty {
            y = errorTile(error, into: body, y: y)
        }
        guard let snapshot = model.snapshot else {
            return model.status.lastError == nil ? emptyTile(into: body, y: y) : y
        }
        y = headline(snapshot, into: body, y: y)
        y = summaryTiles(snapshot, into: body, y: y)
        y = topModels(snapshot, into: body, y: y)
        y = heatmap(snapshot, into: body, y: y)
        y = trend(snapshot, into: body, y: y)
        y = breakdownSection(snapshot, into: body, y: y)
        return y
    }

    // MARK: - Shared pieces

    func sectionHeader(_ title: String, trailing: String? = nil, into body: NSView, y: CGFloat) -> CGFloat {
        let header = makeLabel(title, size: 11, weight: .semibold, color: theme.secondaryText)
        body.place(header, x: inset + 4, y: y, width: 200)
        if let trailing {
            let label = makeLabel(trailing, size: 10.5, color: theme.tertiaryText, alignment: .right)
            body.place(label, x: inset + width - 4 - 180, y: y + 1, width: 180)
        }
        return y + header.frame.height + 6
    }

    func tile(y: CGFloat, height: CGFloat, x: CGFloat? = nil, width tileWidth: CGFloat? = nil, radius: CGFloat = 12) -> TileView {
        TileView(frame: NSRect(x: x ?? inset, y: y, width: tileWidth ?? width, height: height), fill: theme.tileFill, border: theme.tileBorder, cornerRadius: radius)
    }

    // MARK: - 1. Period

    private func periodSelector(into body: NSView, y: CGFloat) -> CGFloat {
        let titles: [(AnalyticsPeriod, String)] = [(.day, "Day"), (.week, "Week"), (.month, "Month"), (.total, "Total")]
        let select = model.selectPeriod
        let segments = titles.map { period, title in
            SegmentedTabsView.Segment(title: title, badge: nil, isSelected: model.period == period) { select(period) }
        }
        body.addSubview(SegmentedTabsView(frame: NSRect(x: inset, y: y, width: width, height: 26), theme: theme, segments: segments, fontSize: 11.5))
        return y + 26 + 12
    }

    // MARK: - 2. Headline

    private func headline(_ snapshot: AnalyticsSnapshot, into body: NSView, y: CGFloat) -> CGFloat {
        let card = tile(y: y, height: 148)
        let caption = makeLabel("TOTAL TOKENS", size: 10, weight: .semibold, color: theme.secondaryText, kern: 0.6)
        card.place(caption, x: tilePadding, y: 13)
        let range = makeLabel(AnalyticsPanelFormat.range(from: snapshot.from, to: snapshot.to), size: 11, color: theme.secondaryText, alignment: .right, monospacedDigits: true)
        card.place(range, x: width - tilePadding - 200, y: 12, width: 200)

        let number = makeLabel(AnalyticsPanelFormat.compact(snapshot.totals.total), size: 30, weight: .semibold, color: theme.primaryText, monospacedDigits: true, kern: -0.8)
        number.toolTip = totalsToolTip(snapshot.totals)
        card.place(number, x: tilePadding - 1, y: 28)
        let cost = makeLabel(AnalyticsPanelFormat.estimatedCost(snapshot.totals.costUSD, isPartial: snapshot.costIsPartial), size: 13, weight: .medium, color: theme.text(.green), monospacedDigits: true)
        cost.toolTip = snapshot.costIsPartial ? "Estimated from list prices; some models have no price" : "Estimated from list prices"
        card.place(cost, x: number.frame.maxX + 10, y: number.frame.maxY - cost.frame.height - 6, width: width - number.frame.maxX - 10 - tilePadding)

        let shares = AnalyticsSource.allCases.map { source in
            snapshot.sources.first(where: { $0.source == source }) ?? AnalyticsSourceShare(source: source, tokens: 0, share: 0, modelCount: 0)
        }
        let barSegments = shares.map { (CGFloat($0.tokens), AnalyticsPanelPalette.sourceColor($0.source, theme: theme)) }
        let barFrame = NSRect(x: tilePadding, y: 76, width: width - tilePadding * 2, height: 5)
        card.addSubview(TileView(frame: barFrame, fill: theme.trackFill, cornerRadius: 2.5))
        card.addSubview(StackedBarView(frame: barFrame, segments: barSegments))

        let gap: CGFloat = 8
        let sourceWidth = (width - tilePadding * 2 - gap) / 2
        for (index, share) in shares.enumerated() {
            let x = tilePadding + CGFloat(index) * (sourceWidth + gap)
            card.addSubview(sourceTile(share, frame: NSRect(x: x, y: 92, width: sourceWidth, height: 44)))
        }
        body.addSubview(card)
        return card.frame.maxY + 10
    }

    private func sourceTile(_ share: AnalyticsSourceShare, frame: NSRect) -> NSView {
        let view = TileView(frame: frame, fill: theme.controlFill, border: theme.controlBorder, cornerRadius: 8)
        let isClaude = share.source == .claude
        let logoColor = isClaude ? MenuBarGlyph.claudeOrange : (theme.isDark ? .white : theme.primaryText)
        if let image = MenuBarGlyph.logo(isClaude ? "logo-claude" : "logo-openai", size: 12, color: logoColor) {
            let logo = NSImageView(frame: NSRect(x: 10, y: 9, width: 12, height: 12))
            logo.image = image
            view.addSubview(logo)
        }
        view.place(makeLabel(isClaude ? "Claude" : "Codex", size: 12, weight: .semibold, color: theme.primaryText), x: 28, y: 7)
        let percent = makeLabel(String(format: "%.1f%%", share.share), size: 12, weight: .medium, color: theme.primaryText, alignment: .right, monospacedDigits: true)
        view.place(percent, x: frame.width - 10 - 60, y: 7, width: 60)
        let models = makeLabel(share.modelCount == 1 ? "1 model" : "\(share.modelCount) models", size: 10.5, color: theme.secondaryText)
        view.place(models, x: 28, y: 24)
        let tokens = makeLabel(AnalyticsPanelFormat.compact(share.tokens), size: 10.5, color: theme.secondaryText, alignment: .right, monospacedDigits: true)
        view.place(tokens, x: frame.width - 10 - 70, y: 24, width: 70)
        view.toolTip = "\(isClaude ? "Claude" : "Codex"): \(AnalyticsPanelFormat.grouped(share.tokens)) tokens"
        return view
    }

    func totalsToolTip(_ totals: AnalyticsTotals) -> String {
        [
            "Total \(AnalyticsPanelFormat.grouped(totals.total))",
            "Input \(AnalyticsPanelFormat.grouped(totals.input))",
            "Output \(AnalyticsPanelFormat.grouped(totals.output))",
            "Cached \(AnalyticsPanelFormat.grouped(totals.cached))",
            "Cache write \(AnalyticsPanelFormat.grouped(totals.cacheCreation))",
            "Reasoning \(AnalyticsPanelFormat.grouped(totals.reasoning))",
            "Convs \(AnalyticsPanelFormat.grouped(totals.conversations))"
        ].joined(separator: "\n")
    }

    // MARK: - 3. Summary tiles

    private func summaryTiles(_ snapshot: AnalyticsSnapshot, into body: NSView, y: CGFloat) -> CGFloat {
        let convs = snapshot.totals.conversations
        let items: [(String, String, String)] = [
            ("Last 7d", AnalyticsPanelFormat.compact(snapshot.last7dTokens), "\(AnalyticsPanelFormat.grouped(snapshot.last7dTokens)) tokens, today and the 6 days before"),
            ("Last 30d", AnalyticsPanelFormat.compact(snapshot.last30dTokens), "\(AnalyticsPanelFormat.grouped(snapshot.last30dTokens)) tokens over 30 days"),
            ("Daily avg", AnalyticsPanelFormat.compact(snapshot.averageDailyTokens), "30-day tokens per active day"),
            ("Convs", convs >= 100_000 ? AnalyticsPanelFormat.compact(convs) : AnalyticsPanelFormat.grouped(convs), "Conversations in the selected period")
        ]
        let gap: CGFloat = 8
        let tileWidth = (width - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
        for (index, item) in items.enumerated() {
            let card = tile(y: y, height: 50, x: inset + CGFloat(index) * (tileWidth + gap), width: tileWidth, radius: 10)
            card.place(makeLabel(item.0, size: 10.5, color: theme.secondaryText), x: 10, y: 8, width: tileWidth - 20)
            card.place(makeLabel(item.1, size: 15, weight: .semibold, color: theme.primaryText, monospacedDigits: true), x: 10, y: 23, width: tileWidth - 20)
            card.toolTip = item.2
            body.addSubview(card)
        }
        return y + 50 + sectionGap
    }

    // MARK: - 4. Top models

    private func topModels(_ snapshot: AnalyticsSnapshot, into body: NSView, y startY: CGFloat) -> CGFloat {
        let y = sectionHeader("Top models", into: body, y: startY)
        let rowHeight: CGFloat = 28
        let rows = max(1, snapshot.topModels.count)
        let footerHeight: CGFloat = 32
        let card = tile(y: y, height: CGFloat(rows) * rowHeight + footerHeight + 4)
        if snapshot.topModels.isEmpty {
            card.place(makeLabel("No usage in this period", size: 12, color: theme.tertiaryText), x: tilePadding, y: 9)
        }
        for (index, model) in snapshot.topModels.prefix(5).enumerated() {
            let rowY = 4 + CGFloat(index) * rowHeight
            card.place(makeLabel("\(index + 1)", size: 11, weight: .medium, color: theme.tertiaryText, monospacedDigits: true), x: tilePadding, y: rowY + 7)
            card.addSubview(DotView(frame: NSRect(x: 28, y: rowY + 11, width: 7, height: 7), color: AnalyticsPanelPalette.modelColor(model.name)))
            card.place(makeLabel(model.name, size: 12.5, weight: .medium, color: theme.primaryText), x: 42, y: rowY + 6, width: width - 42 - 130)
            card.place(makeLabel(AnalyticsPanelFormat.compact(model.tokens), size: 11.5, color: theme.secondaryText, alignment: .right, monospacedDigits: true), x: width - tilePadding - 120, y: rowY + 7, width: 64)
            card.place(makeLabel(AnalyticsPanelFormat.share(model.share), size: 12, weight: .medium, color: theme.primaryText, alignment: .right, monospacedDigits: true), x: width - tilePadding - 52, y: rowY + 6, width: 52)
        }
        let footerY = card.frame.height - footerHeight
        card.addSubview(HairlineView(frame: NSRect(x: tilePadding, y: footerY, width: width - tilePadding * 2, height: 0.5), color: theme.hairline))
        let started = snapshot.started.map { AnalyticsPanelFormat.dayWithYear($0) } ?? "—"
        placePair("Started", started, into: card, x: tilePadding, y: footerY + 9, alignRight: false)
        placePair("Active days", "\(snapshot.activeDays)", into: card, x: width - tilePadding, y: footerY + 9, alignRight: true)
        body.addSubview(card)
        return card.frame.maxY + sectionGap
    }

    private func placePair(_ key: String, _ value: String, into view: NSView, x: CGFloat, y: CGFloat, alignRight: Bool) {
        let keyLabel = makeLabel(key, size: 11, color: theme.secondaryText)
        let valueLabel = makeLabel(value, size: 11.5, weight: .medium, color: theme.primaryText, monospacedDigits: true)
        let total = keyLabel.frame.width + 6 + valueLabel.frame.width
        let startX = alignRight ? x - total : x
        view.place(keyLabel, x: startX, y: y + 1)
        view.place(valueLabel, x: startX + keyLabel.frame.width + 6, y: y)
    }

    // MARK: - 5. Heatmap

    private func heatmap(_ snapshot: AnalyticsSnapshot, into body: NSView, y startY: CGFloat) -> CGFloat {
        let y = sectionHeader("Activity", trailing: "Last 6 months", into: body, y: startY)
        let card = tile(y: y, height: AnalyticsHeatmapView.height(width: width - 24) + 22)
        card.addSubview(AnalyticsHeatmapView(frame: NSRect(x: 12, y: 12, width: width - 24, height: 0), cells: snapshot.heatmap, theme: theme))
        body.addSubview(card)
        return card.frame.maxY + sectionGap
    }

    // MARK: - 6. Trend

    private func trend(_ snapshot: AnalyticsSnapshot, into body: NSView, y startY: CGFloat) -> CGFloat {
        let granularity: String
        switch snapshot.period {
        case .day: granularity = "Hourly · by model"
        case .week, .month: granularity = "Daily · by model"
        case .total: granularity = "Monthly · by model"
        }
        let y = sectionHeader("Usage trend", trailing: granularity, into: body, y: startY)
        let card = tile(y: y, height: AnalyticsTrendView.height + 20)
        if snapshot.trend.isEmpty {
            card.frame.size.height = 44
            card.place(makeLabel("No usage in this period", size: 12, color: theme.tertiaryText), x: tilePadding, y: 13)
        } else {
            card.addSubview(AnalyticsTrendView(frame: NSRect(x: tilePadding, y: 12, width: width - tilePadding * 2, height: 0), bars: snapshot.trend, period: snapshot.period, theme: theme))
        }
        body.addSubview(card)
        return card.frame.maxY + sectionGap
    }
}
