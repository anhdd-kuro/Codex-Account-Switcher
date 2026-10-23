import AppKit
import Foundation

extension AnalyticsPanelBuilder {
    // MARK: - 7. Daily breakdown | Project usage

    func breakdownSection(_ snapshot: AnalyticsSnapshot, into body: NSView, y: CGFloat) -> CGFloat {
        let isDaily = breakdown == .daily
        let title = makeLabel(isDaily ? "Daily breakdown" : "Project usage", size: 11, weight: .semibold, color: theme.secondaryText)
        body.place(title, x: inset + 4, y: y + 4, width: 160)
        let select = selectBreakdown
        let toggle = SegmentedTabsView(
            frame: NSRect(x: inset + width - 150, y: y, width: 150, height: 22),
            theme: theme,
            segments: [
                .init(title: "Daily", badge: nil, isSelected: isDaily) { select(.daily) },
                .init(title: "Projects", badge: nil, isSelected: !isDaily) { select(.projects) }
            ],
            fontSize: 11
        )
        body.addSubview(toggle)
        let tableY = y + 22 + 6
        let table = isDaily ? dailyTable(snapshot) : projectTable(snapshot)
        let card = tile(y: tableY, height: table.frame.height + 4)
        card.place(table, x: 0, y: 2)
        body.addSubview(card)
        return card.frame.maxY + sectionGap
    }

    private func dailyTable(_ snapshot: AnalyticsSnapshot) -> AnalyticsTableView {
        let columns = [
            AnalyticsTableColumn(title: "Date", width: 0, alignment: .left),
            AnalyticsTableColumn(title: "Total", width: 52, alignment: .right),
            AnalyticsTableColumn(title: "In", width: 48, alignment: .right),
            AnalyticsTableColumn(title: "Out", width: 48, alignment: .right),
            AnalyticsTableColumn(title: "Cached", width: 52, alignment: .right),
            AnalyticsTableColumn(title: "Convs", width: 40, alignment: .right)
        ]
        let calendar = Calendar.current
        let rows = snapshot.daily.map { day -> AnalyticsTableRow in
            let totals = day.totals
            let label = calendar.isDateInToday(day.day) ? "Today" : AnalyticsPanelFormat.day(day.day)
            guard totals.total > 0 || totals.conversations > 0 else {
                return AnalyticsTableRow(cells: [label, "—", "—", "—", "—", "—"], muted: true, toolTip: "\(AnalyticsPanelFormat.weekdayDay(day.day))\nNo usage")
            }
            let cells = [
                label,
                AnalyticsPanelFormat.compact(totals.total),
                AnalyticsPanelFormat.compact(totals.input),
                AnalyticsPanelFormat.compact(totals.output),
                AnalyticsPanelFormat.compact(totals.cached),
                AnalyticsPanelFormat.grouped(totals.conversations)
            ]
            return AnalyticsTableRow(cells: cells, toolTip: dayToolTip(day))
        }
        let frame = NSRect(x: 0, y: 0, width: width, height: 0)
        guard !rows.isEmpty else {
            return AnalyticsTableView(frame: frame, columns: columns, rows: [AnalyticsTableRow(cells: ["No days yet"], muted: true)], theme: theme, accessibilityLabel: "Daily breakdown")
        }
        return AnalyticsTableView(frame: frame, columns: columns, rows: rows, theme: theme, accessibilityLabel: "Daily breakdown, last \(rows.count) days")
    }

    private func dayToolTip(_ day: AnalyticsDay) -> String {
        var lines = [AnalyticsPanelFormat.weekdayDay(day.day), totalsToolTip(day.totals)]
        if day.totals.costUSD > 0 { lines.append("Cost ≈ \(AnalyticsPanelFormat.usd(day.totals.costUSD))") }
        let total = max(1, day.modelTokens.values.reduce(0, +))
        let models = day.modelTokens.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(4)
        lines += models.map { "\($0.key)  \(Int((Double($0.value) / Double(total) * 100).rounded()))%" }
        return lines.joined(separator: "\n")
    }

    private func projectTable(_ snapshot: AnalyticsSnapshot) -> AnalyticsTableView {
        let columns = [
            AnalyticsTableColumn(title: "Project", width: 0, alignment: .left),
            AnalyticsTableColumn(title: "Tokens", width: 58, alignment: .right),
            AnalyticsTableColumn(title: "Share", width: 50, alignment: .right)
        ]
        let frame = NSRect(x: 0, y: 0, width: width, height: 0)
        guard let largest = snapshot.projects.map(\.totals.total).max(), largest > 0 else {
            return AnalyticsTableView(frame: frame, columns: columns, rows: [AnalyticsTableRow(cells: ["No projects with a git remote"], muted: true)], theme: theme, accessibilityLabel: "Project usage")
        }
        let periodTotal = max(1, snapshot.totals.total)
        let rows = snapshot.projects.map { project in
            AnalyticsTableRow(
                cells: [
                    project.name,
                    AnalyticsPanelFormat.compact(project.totals.total),
                    AnalyticsPanelFormat.share(Double(project.totals.total) / Double(periodTotal) * 100)
                ],
                bar: Double(project.totals.total) / Double(largest),
                barColor: theme.accent,
                toolTip: "\(project.name)\n\(totalsToolTip(project.totals))"
            )
        }
        return AnalyticsTableView(frame: frame, columns: columns, rows: rows, rowHeight: 30, theme: theme, accessibilityLabel: "Project usage, \(rows.count) projects")
    }

    // MARK: - 8. Session efficiency

    func efficiency(_ snapshot: AnalyticsSnapshot, into body: NSView, y startY: CGFloat) -> CGFloat {
        var y = sectionHeader("Session efficiency", into: body, y: startY)
        guard let efficiency = snapshot.efficiency, efficiency.sessions > 0 else {
            let card = tile(y: y, height: 44)
            card.place(makeLabel("No sessions in this period", size: 12, color: theme.tertiaryText), x: tilePadding, y: 13)
            body.addSubview(card)
            return card.frame.maxY + 4
        }
        let editRate = Double(efficiency.editSessions) / Double(efficiency.sessions)
        let firstPass = efficiency.editSessions > 0 ? Double(efficiency.firstPassSessions) / Double(efficiency.editSessions) : nil
        let items: [(String, String, String)] = [
            ("Edit sessions", AnalyticsPanelFormat.percent(editRate), "\(efficiency.editSessions)/\(efficiency.sessions)"),
            ("First-pass", AnalyticsPanelFormat.percent(firstPass), "\(efficiency.firstPassSessions)/\(efficiency.editSessions)"),
            ("Cost / edit", efficiency.costPerEditUSD.map { efficiency.costIsPartial ? AnalyticsPanelFormat.estimatedCost($0, isPartial: true) : AnalyticsPanelFormat.usd($0) } ?? "—", efficiency.editTurns == 1 ? "1 edit turn" : "\(AnalyticsPanelFormat.grouped(efficiency.editTurns)) edit turns")
        ]
        let gap: CGFloat = 8
        let tileWidth = (width - gap * 2) / 3
        for (index, item) in items.enumerated() {
            let card = tile(y: y, height: 64, x: inset + CGFloat(index) * (tileWidth + gap), width: tileWidth, radius: 10)
            card.place(makeLabel(item.0, size: 10.5, color: theme.secondaryText), x: 10, y: 8, width: tileWidth - 20)
            card.place(makeLabel(item.1, size: 16, weight: .semibold, color: theme.primaryText, monospacedDigits: true), x: 10, y: 23, width: tileWidth - 20)
            card.place(makeLabel(item.2, size: 10.5, color: theme.tertiaryText, monospacedDigits: true), x: 10, y: 45, width: tileWidth - 20)
            body.addSubview(card)
        }
        y += 64 + 8
        guard !efficiency.byModel.isEmpty else { return y + 4 }
        let table = efficiencyTable(efficiency.byModel)
        let card = tile(y: y, height: table.frame.height + 4)
        card.place(table, x: 0, y: 2)
        body.addSubview(card)
        return card.frame.maxY + 12
    }

    private func efficiencyTable(_ models: [AnalyticsEfficiencyModel]) -> AnalyticsTableView {
        let columns = [
            AnalyticsTableColumn(title: "Model", width: 0, alignment: .left),
            AnalyticsTableColumn(title: "Edit", width: 56, alignment: .right),
            AnalyticsTableColumn(title: "1st pass", width: 50, alignment: .right),
            AnalyticsTableColumn(title: "Tok/edit", width: 56, alignment: .right)
        ]
        let rows = models.prefix(5).map { model in
            AnalyticsTableRow(cells: [
                model.model,
                "\(model.editSessions)/\(model.sessions)",
                AnalyticsPanelFormat.percent(model.firstPassRate),
                model.tokensPerEdit.map(AnalyticsPanelFormat.compact) ?? "—"
            ], toolTip: "\(model.model)\n\(model.editSessions) of \(model.sessions) sessions edited files")
        }
        return AnalyticsTableView(frame: NSRect(x: 0, y: 0, width: width, height: 0), columns: columns, rows: Array(rows), theme: theme, accessibilityLabel: "Efficiency by model")
    }

    // MARK: - 9. Empty, scanning and error states

    func emptyTile(into body: NSView, y: CGFloat) -> CGFloat {
        let status = model.status
        let card = tile(y: y, height: status.isScanning ? 84 : 92)
        if status.isScanning {
            card.place(makeLabel("Indexing logs…", size: 12.5, weight: .semibold, color: theme.primaryText), x: tilePadding, y: 14)
            if status.totalBytes > 0 {
                let bytes = makeLabel(AnalyticsPanelFormat.bytes(processed: status.processedBytes, total: status.totalBytes), size: 11.5, color: theme.secondaryText, alignment: .right, monospacedDigits: true)
                card.place(bytes, x: width - tilePadding - 140, y: 15, width: 140)
            }
            let track = NSRect(x: tilePadding, y: 42, width: width - tilePadding * 2, height: 6)
            card.addSubview(TileView(frame: track, fill: theme.trackFill, cornerRadius: 3))
            let fraction = status.totalBytes > 0 ? min(1, max(0.02, Double(status.processedBytes) / Double(status.totalBytes))) : 0.02
            card.addSubview(TileView(frame: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(fraction), height: track.height), fill: theme.accent, cornerRadius: 3))
            card.place(makeLabel("First scan reads every Codex and Claude log once", size: 11, color: theme.tertiaryText), x: tilePadding, y: 58, width: width - tilePadding * 2)
        } else {
            card.place(makeLabel("No analytics yet", size: 12.5, weight: .semibold, color: theme.primaryText), x: tilePadding, y: 14)
            card.place(makeLabel("Token usage from local Codex and Claude logs", size: 11, color: theme.secondaryText), x: tilePadding, y: 33, width: width - tilePadding * 2)
            let refresh = model.refresh
            let button = GlassButton(title: "Scan logs", style: .secondary, theme: theme, height: 24, fontSize: 11.5) { refresh() }
            card.place(button, x: tilePadding, y: 56)
        }
        body.addSubview(card)
        return card.frame.maxY + 4
    }

    func errorTile(_ error: String, into body: NSView, y: CGFloat) -> CGFloat {
        let card = TileView(frame: NSRect(x: inset, y: y, width: width, height: 44), fill: theme.tint(.red), border: theme.tileBorder, cornerRadius: 10)
        card.addSubview(SymbolIconView(frame: NSRect(x: 12, y: 14, width: 16, height: 16), symbol: "exclamationmark.triangle.fill", color: theme.text(.red), pointSize: 11))
        let refresh = model.refresh
        let retry = GlassButton(title: "Retry", style: .secondary, theme: theme, height: 24, fontSize: 11.5) { refresh() }
        card.place(retry, x: width - 10 - retry.frame.width, y: 10)
        let label = makeLabel(error, size: 11.5, color: theme.text(.red))
        label.toolTip = error
        card.place(label, x: 34, y: (44 - label.frame.height) / 2, width: width - 34 - retry.frame.width - 20)
        body.addSubview(card)
        return card.frame.maxY + 12
    }
}
