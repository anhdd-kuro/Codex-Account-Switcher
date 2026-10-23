import Foundation

/// Read side (spec §4): folds the stored half-hour buckets into local days and builds the snapshot.
/// Days are numbered from 1970-01-01 in the current time zone.
struct AnalyticsSnapshotBuilder {
    let pricing: AnalyticsPricing
    let timeZone: TimeZone
    let now: Date

    private struct Row {
        let source: AnalyticsSource
        let model: String
        let halfHour: Int64
        let bucket: AnalyticsBucket
        let day: Int
        let cost: Double
        let unpriced: Bool
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func day(of seconds: Double) -> Int {
        let local = seconds + Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: seconds)))
        return Int((local / 86_400).rounded(.down))
    }

    func date(ofDay day: Int) -> Date {
        let (y, m, d) = Self.civil(day)
        return calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? Date(timeIntervalSince1970: Double(day) * 86_400)
    }

    private static func civil(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    private static func weekday(_ day: Int) -> Int { ((day % 7) + 7 + 4) % 7 }

    private func range(_ period: AnalyticsPeriod, today: Int) -> ClosedRange<Int> {
        let (y, m, _) = Self.civil(today)
        func first(_ year: Int, _ month: Int) -> Int { day(of: date(year, month).timeIntervalSince1970) }
        switch period {
        case .day:
            return today...today
        case .week:
            let monday = today - (Self.weekday(today) + 6) % 7
            return monday...(monday + 6)
        case .month:
            let start = first(y, m)
            let next = m == 12 ? first(y + 1, 1) : first(y, m + 1)
            return start...(next - 1)
        case .total:
            let index = y * 12 + (m - 1) - 23
            return first(index / 12, index % 12 + 1)...today
        }
    }

    private func date(_ year: Int, _ month: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
    }

    // MARK: Build

    func build(store: AnalyticsStore, sessions: [AnalyticsSessionRecord], period: AnalyticsPeriod) -> AnalyticsSnapshot {
        let today = day(of: now.timeIntervalSince1970)
        let span = range(period, today: today)
        let rows = foldedRows(store.buckets)
        var daily: [Int: (totals: AnalyticsTotals, models: [String: Int])] = [:]
        for row in rows {
            var entry = daily[row.day] ?? (AnalyticsTotals(), [:])
            Self.add(row, to: &entry.totals)
            entry.models[row.model] = (entry.models[row.model] ?? 0).saturatingAdd(row.bucket.counts.total)
            daily[row.day] = entry
        }
        let inPeriod = rows.filter { span.contains($0.day) }
        var totals = AnalyticsTotals()
        inPeriod.forEach { Self.add($0, to: &totals) }
        let sum = { (days: ClosedRange<Int>) in days.saturatingSum { daily[$0]?.totals.total ?? 0 } }
        let last30 = (today - 29)...today
        let active30 = last30.filter { daily[$0] != nil }.count
        let heat = heatmap(daily, today: today)
        return AnalyticsSnapshot(
            period: period,
            from: date(ofDay: span.lowerBound),
            to: date(ofDay: span.upperBound),
            totals: totals,
            costIsPartial: inPeriod.contains { $0.unpriced },
            sources: sourceShares(inPeriod),
            topModels: topModels(inPeriod),
            last7dTokens: sum((today - 6)...today),
            last30dTokens: sum(last30),
            averageDailyTokens: active30 > 0 ? Int((Double(sum(last30)) / Double(active30)).rounded()) : 0,
            started: daily.filter { $0.value.totals.total > 0 }.keys.min().map(date(ofDay:)),
            activeDays: heat.filter { $0.tokens > 0 }.count,
            heatmap: heat,
            trend: trend(period, span: span, today: today, rows: rows, daily: daily),
            daily: last30.reversed().map { day in
                AnalyticsDay(day: date(ofDay: day), totals: daily[day]?.totals ?? AnalyticsTotals(), modelTokens: daily[day]?.models ?? [:])
            },
            projects: projects(store.projectBuckets, span: span),
            efficiency: AnalyticsEfficiencySummary.summarize(sessions, from: span.lowerBound, to: span.upperBound, day: day(of:), pricing: pricing),
            scannedAt: Date(timeIntervalSince1970: store.lastScanAt ?? now.timeIntervalSince1970)
        )
    }

    private static func add(_ row: Row, to totals: inout AnalyticsTotals) {
        let c = row.bucket.counts
        totals.input = totals.input.saturatingAdd(c.input)
        totals.cached = totals.cached.saturatingAdd(c.cached)
        totals.cacheCreation = totals.cacheCreation.saturatingAdd(c.cacheCreation)
        totals.output = totals.output.saturatingAdd(c.output)
        totals.reasoning = totals.reasoning.saturatingAdd(c.reasoning)
        totals.total = totals.total.saturatingAdd(c.total)
        totals.conversations = totals.conversations.saturatingAdd(row.bucket.conversations)
        totals.costUSD += row.cost
    }

    /// §0.2: within one (source, half-hour), "unknown" folds into the dominant real model.
    private func foldedRows(_ buckets: [AnalyticsBucketKey: AnalyticsBucket]) -> [Row] {
        var groups: [String: [(String, AnalyticsBucket)]] = [:]
        for (key, bucket) in buckets {
            groups["\(key.source.rawValue)|\(key.halfHour)", default: []].append((key.model, bucket))
        }
        var rows: [Row] = []
        var dayCache: [Int64: Int] = [:]
        for (key, members) in groups {
            let parts = key.split(separator: "|")
            guard let source = AnalyticsSource(rawValue: String(parts[0])), let halfHour = Int64(parts[1]) else { continue }
            var models = Dictionary(members, uniquingKeysWith: { a, b in var m = a; m.add(b); return m })
            if let unknown = models["unknown"], models.count > 1 {
                models["unknown"] = nil
                let dominant = models.max { a, b in
                    a.value.counts.total != b.value.counts.total ? a.value.counts.total < b.value.counts.total : a.key > b.key
                }!.key
                models[dominant]?.add(unknown)
            }
            let day = dayCache[halfHour] ?? self.day(of: Double(halfHour))
            dayCache[halfHour] = day
            for (model, bucket) in models {
                let rates = pricing.rates(model: model, source: source)
                let cost = pricing.cost(source: source, model: model, usage: AnalyticsUsageDetail(bucket: bucket))
                rows.append(Row(source: source, model: model, halfHour: halfHour, bucket: bucket, day: day, cost: cost,
                                unpriced: rates == nil && bucket.counts.total > 0))
            }
        }
        return rows
    }

    private func sourceShares(_ rows: [Row]) -> [AnalyticsSourceShare] {
        let all = rows.saturatingSum { $0.bucket.counts.total }
        return AnalyticsSource.allCases.map { source in
            let mine = rows.filter { $0.source == source }
            let tokens = mine.saturatingSum { $0.bucket.counts.total }
            let models = Set(mine.filter { $0.bucket.counts.total > 0 }.map(\.model)).count
            return AnalyticsSourceShare(source: source, tokens: tokens, share: all > 0 ? Double(tokens) / Double(all) * 100 : 0, modelCount: models)
        }.sorted { $0.tokens > $1.tokens }
    }

    /// §4.6: merge by trimmed lowercase name; `vendor/x` folds into bare `x`; heaviest spelling wins.
    private func topModels(_ rows: [Row]) -> [AnalyticsModelShare] {
        var spellings: [String: [String: Int]] = [:]
        for row in rows where row.bucket.counts.total > 0 {
            let name = row.model.trimmingCharacters(in: .whitespaces)
            spellings[name.lowercased(), default: [:]][name] = (spellings[name.lowercased()]?[name] ?? 0).saturatingAdd(row.bucket.counts.total)
        }
        for key in spellings.keys where key.contains("/") {
            let bare = String(key[key.index(after: key.lastIndex(of: "/")!)...])
            guard bare != key, let moved = spellings[key], spellings[bare] != nil else { continue }
            spellings[key] = nil
            spellings[bare]!.merge(moved) { $0.saturatingAdd($1) }
        }
        let merged = spellings.values.map { names -> (String, Int) in
            let display = names.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
            return (display, names.values.saturatingSum { $0 })
        }
        let all = merged.saturatingSum { $0.1 }
        return merged
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(3)
            .map { AnalyticsModelShare(name: $0.0, tokens: $0.1, share: all > 0 ? Double($0.1) / Double(all) * 100 : 0) }
    }

    /// §4.2: 5 week columns starting on Sunday; levels are quantiles over non-zero days.
    private func heatmap(_ daily: [Int: (totals: AnalyticsTotals, models: [String: Int])], today: Int) -> [AnalyticsHeatCell] {
        let start = today - Self.weekday(today) - 7 * 4
        let values = (start...today).map { max(0, daily[$0]?.totals.total ?? 0) }
        let sorted = values.filter { $0 > 0 }.sorted()
        func quantile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let position = Double(sorted.count - 1) * p
            let lower = Int(position.rounded(.down))
            let a = Double(sorted[lower]), b = Double(sorted[min(sorted.count - 1, lower + 1)])
            return (a + (b - a) * (position - Double(lower))).rounded()
        }
        let (q50, q75, q90) = (quantile(0.5), quantile(0.75), quantile(0.9))
        return zip(start...today, values).map { day, value in
            let v = Double(value)
            let level = value <= 0 ? 0 : v <= q50 ? 1 : v <= q75 ? 2 : v <= q90 ? 3 : 4
            return AnalyticsHeatCell(day: date(ofDay: day), tokens: value, level: level)
        }
    }

    // MARK: Trend (§4.5)

    private func trend(_ period: AnalyticsPeriod, span: ClosedRange<Int>, today: Int, rows: [Row],
                       daily: [Int: (totals: AnalyticsTotals, models: [String: Int])]) -> [AnalyticsTrendBar] {
        switch period {
        case .day:
            let dayStart = date(ofDay: today)
            let hourCount = Int((date(ofDay: today + 1).timeIntervalSince(dayStart) / 3600).rounded())
            var hours: [Int: [String: Int]] = [:]
            for row in rows where row.day == today {
                let hour = Int((Double(row.halfHour) - dayStart.timeIntervalSince1970) / 3600)
                hours[hour, default: [:]][row.model] = (hours[hour]?[row.model] ?? 0).saturatingAdd(row.bucket.counts.total)
            }
            // 23 or 25 bars on DST transition days: the bars follow elapsed hours, not wall-clock labels.
            return (0..<hourCount).map { hour in
                let start = dayStart.addingTimeInterval(Double(hour) * 3600)
                return AnalyticsTrendBar(start: start, segments: segments(hours[hour] ?? [:]), isFuture: start > now)
            }
        case .week, .month:
            return span.map { day in
                AnalyticsTrendBar(start: date(ofDay: day), segments: segments(daily[day]?.models ?? [:]), isFuture: day > today)
            }
        case .total:
            var months: [Int: [String: Int]] = [:]
            for (day, entry) in daily where span.contains(day) {
                let (y, m, _) = Self.civil(day)
                months[y * 12 + m - 1, default: [:]].merge(entry.models) { $0.saturatingAdd($1) }
            }
            let (y, m, _) = Self.civil(today)
            let current = y * 12 + m - 1
            let bars = ((current - 23)...current).map { index in
                AnalyticsTrendBar(start: date(index / 12, index % 12 + 1), segments: segments(months[index] ?? [:]), isFuture: false)
            }
            return Array(bars.drop { $0.segments.isEmpty })
        }
    }

    private func segments(_ models: [String: Int]) -> [AnalyticsModelShare] {
        var merged: [String: (name: String, tokens: Int)] = [:]
        for (model, tokens) in models where tokens > 0 {
            let key = model.lowercased()
            let existing = merged[key]
            merged[key] = (existing?.name ?? model, (existing?.tokens ?? 0).saturatingAdd(tokens))
        }
        let all = merged.values.saturatingSum { $0.tokens }
        return merged.values
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }
            .map { AnalyticsModelShare(name: $0.name, tokens: $0.tokens, share: all > 0 ? Double($0.tokens) / Double(all) * 100 : 0) }
    }

    /// `project-usage-summary` (§3): grouped by project key, observer pseudo-project excluded, top 10.
    private func projects(_ buckets: [AnalyticsProjectBucketKey: AnalyticsBucket], span: ClosedRange<Int>) -> [AnalyticsProject] {
        var totals: [String: AnalyticsTotals] = [:]
        var dayCache: [Int64: Int] = [:]
        for (key, bucket) in buckets where !key.project.contains(AnalyticsProjectResolver.observerSegment) {
            let day = dayCache[key.halfHour] ?? self.day(of: Double(key.halfHour))
            dayCache[key.halfHour] = day
            guard span.contains(day) else { continue }
            var entry = totals[key.project] ?? AnalyticsTotals()
            let c = bucket.counts
            entry.input = entry.input.saturatingAdd(c.input)
            entry.cached = entry.cached.saturatingAdd(c.cached)
            entry.cacheCreation = entry.cacheCreation.saturatingAdd(c.cacheCreation)
            entry.output = entry.output.saturatingAdd(c.output)
            entry.reasoning = entry.reasoning.saturatingAdd(c.reasoning)
            entry.total = entry.total.saturatingAdd(c.total)
            entry.conversations = entry.conversations.saturatingAdd(bucket.conversations)
            totals[key.project] = entry
        }
        return totals
            .sorted { $0.value.total != $1.value.total ? $0.value.total > $1.value.total : $0.key < $1.key }
            .prefix(10)
            .map { AnalyticsProject(name: $0.key, totals: $0.value) }
    }
}
