import Foundation

struct AnalyticsRates: Equatable {
    var input = 0.0
    var output = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0
    var priorityMultiplier = 0.0
    var ultrafastMultiplier = 0.0

    init(_ json: [String: Any]) {
        input = (json["input"] as? NSNumber)?.doubleValue ?? 0
        output = (json["output"] as? NSNumber)?.doubleValue ?? 0
        cacheRead = (json["cache_read"] as? NSNumber)?.doubleValue ?? 0
        cacheWrite = (json["cache_write"] as? NSNumber)?.doubleValue ?? 0
        priorityMultiplier = (json["priority_multiplier"] as? NSNumber)?.doubleValue ?? 0
        ultrafastMultiplier = (json["ultrafast_multiplier"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// Usage of one priced row plus the observed request subsets that carry premiums (spec §6).
/// Bucket rows only fill the tier subsets; session rows also fill the long-context ones.
struct AnalyticsUsageDetail: Codable, Equatable {
    var counts = AnalyticsCounts()
    var priority = AnalyticsCounts()
    var ultrafast = AnalyticsCounts()
    var long = AnalyticsCounts()
    var priorityLong = AnalyticsCounts()
    var ultrafastLong = AnalyticsCounts()

    init() {}

    init(bucket: AnalyticsBucket) {
        counts = bucket.counts
        priority = bucket.priority
        ultrafast = bucket.ultrafast
    }

    mutating func add(_ delta: AnalyticsCounts, tier: AnalyticsTier?, isLong: Bool) {
        counts.add(delta)
        if isLong { long.add(delta) }
        switch tier {
        case .priority:
            priority.add(delta)
            if isLong { priorityLong.add(delta) }
        case .ultrafast:
            ultrafast.add(delta)
            if isLong { ultrafastLong.add(delta) }
        case nil:
            break
        }
    }

    mutating func add(_ other: AnalyticsUsageDetail) {
        counts.add(other.counts)
        priority.add(other.priority)
        ultrafast.add(other.ultrafast)
        long.add(other.long)
        priorityLong.add(other.priorityLong)
        ultrafastLong.add(other.ultrafastLong)
    }
}

/// Port of TokenTracker's pricing matcher and `computeRowCost` (spec §6), USD only.
final class AnalyticsPricing {
    private let exact: [String: AnalyticsRates]
    private let fuzzy: [(match: String, ref: String)]
    private let litellm: [String: AnalyticsRates]
    private let litellmByLength: [(key: String, lower: String)]
    private var cache: [String: AnalyticsRates?] = [:]
    private let lock = NSLock()

    static let shared = AnalyticsPricing.load()

    static func load() -> AnalyticsPricing {
        let repoCopy = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/analytics-pricing.json")
        let candidates = [Bundle.main.url(forResource: "analytics-pricing", withExtension: "json"), repoCopy]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let pricing = try? AnalyticsPricing(data: data) { return pricing }
        }
        return AnalyticsPricing(exact: [:], fuzzy: [], litellm: [])
    }

    convenience init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        let exact = (json["exact"] as? [String: [String: Any]] ?? [:]).mapValues(AnalyticsRates.init)
        let fuzzy = (json["fuzzy"] as? [[String: String]] ?? []).compactMap { entry -> (String, String)? in
            guard let match = entry["match"], let ref = entry["ref"] else { return nil }
            return (match, ref)
        }
        let litellm = (json["litellm"] as? [[Any]] ?? []).compactMap { pair -> (String, AnalyticsRates)? in
            guard pair.count == 2, let key = pair[0] as? String, let rates = pair[1] as? [String: Any] else { return nil }
            return (key, AnalyticsRates(rates))
        }
        self.init(exact: exact, fuzzy: fuzzy, litellm: litellm)
    }

    private init(exact: [String: AnalyticsRates], fuzzy: [(String, String)], litellm: [(String, AnalyticsRates)]) {
        self.exact = exact
        self.fuzzy = fuzzy.map { (match: $0.0, ref: $0.1) }
        self.litellm = Dictionary(litellm, uniquingKeysWith: { first, _ in first })
        let ordered = litellm.enumerated().map { (index: $0.offset, key: $0.element.0) }
        litellmByLength = ordered
            .sorted { $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.index < $1.index }
            .map { (key: $0.key, lower: $0.key.lowercased()) }
    }

    /// nil means unpriced (status "unpriced" upstream); the cost then counts as 0 and marks partial.
    func rates(model: String, source: AnalyticsSource) -> AnalyticsRates? {
        let cacheKey = "\(source.rawValue)\u{0}\(model)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[cacheKey] { return cached }
        let result = lookup(model, source: source)
        cache[cacheKey] = .some(result)
        return result
    }

    private func lookup(_ model: String, source: AnalyticsSource) -> AnalyticsRates? {
        guard !model.isEmpty else { return nil }
        let lookupModel = source == .claude ? Self.normalizeClaude(model) : model
        let lower = lookupModel.lowercased()
        let dotForm = Self.dotForm(lookupModel)
        if let hit = exact[lookupModel] ?? caseInsensitive(exact, dotForm) { return hit }
        if let hit = litellm[lookupModel] ?? caseInsensitive(litellm, dotForm) { return hit }
        if let hit = containedExact(dotForm) { return hit }
        for entry in fuzzy {
            let needle = entry.match.lowercased()
            guard let hit = exact[entry.ref] else { continue }
            if lower.contains(needle) || (!dotForm.isEmpty && dotForm.contains(needle)) { return hit }
        }
        let stripped = Self.stripReasoningSuffix(lookupModel)
        if stripped != lookupModel, let hit = litellm[stripped] { return hit }
        let suffix = "/" + lower
        let prefixed = litellm.keys.filter { $0.count > suffix.count && $0.lowercased().hasSuffix(suffix) }.min()
        if let key = prefixed { return litellm[key] }
        for entry in litellmByLength where lower.contains(entry.lower) || (!dotForm.isEmpty && dotForm.contains(entry.lower)) {
            return litellm[entry.key]
        }
        return nil
    }

    private func caseInsensitive(_ table: [String: AnalyticsRates], _ model: String) -> AnalyticsRates? {
        guard !model.isEmpty else { return nil }
        if let hit = table[model] { return hit }
        let lower = model.lowercased()
        return table.first { $0.key.lowercased() == lower }?.value
    }

    private func containedExact(_ model: String) -> AnalyticsRates? {
        guard !model.isEmpty else { return nil }
        let lower = model.lowercased()
        for key in exact.keys.sorted(by: { $0.count > $1.count }) {
            guard let range = lower.range(of: key.lowercased()) else { continue }
            if let next = lower[range.upperBound...].first, next == "." || next.isNumber { continue }
            return exact[key]
        }
        return nil
    }

    // MARK: Model normalization (matcher.js)

    static func normalizeClaude(_ model: String) -> String {
        let base = model.contains("/") ? String(model[model.index(after: model.lastIndex(of: "/")!)...]) : model
        var m = base.trimmingCharacters(in: .whitespacesAndNewlines)
        m = replace(m, #"\([^)]*\)"#, " ").lowercased()
        m = replace(m, "[^a-z0-9.]+", "-")
        m = replace(m, "^-+|-+$", "")
        m = replace(m, "-{2,}", "-")
        let dotted = #"^(claude-(?:sonnet|opus|haiku)-\d+)\.(\d+)"#
        if matches(m, #"^claude-(sonnet|opus|haiku)-\d+\.\d+"#) { return replace(m, dotted, "$1-$2") }
        if matches(m, #"^(sonnet|opus|haiku)-\d+[.-]\d+"#) {
            return replace(replace(m, "^(sonnet|opus|haiku)-", "claude-$1-"), dotted, "$1-$2")
        }
        if matches(m, #"^claude-(?:[4-9]|\d{2,})[.-]\d+-(?:sonnet|opus|haiku)"#) {
            return replace(m, #"^claude-(\d+)[.-](\d+)-(sonnet|opus|haiku)"#, "claude-$3-$1-$2")
        }
        return m
    }

    static func dotForm(_ model: String) -> String {
        let lower = model.lowercased()
        let restored = replace(lower, #"(\d+)-(\d+)"#, "$1.$2")
        return restored == lower ? "" : restored
    }

    static func stripReasoningSuffix(_ model: String) -> String {
        for suffix in ["-xhigh-fast", "-high-fast", "-medium-fast", "-low-fast", "-xhigh", "-high", "-medium", "-low", "-fast"] where model.hasSuffix(suffix) {
            return String(model.dropLast(suffix.count))
        }
        return model
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // MARK: Cost (pricing/index.js computeRowCost)

    /// USD for one row; nil rates (unpriced) cost 0.
    func cost(source: AnalyticsSource, model: String, usage: AnalyticsUsageDetail) -> Double {
        guard let p = rates(model: model, source: source) else { return 0 }
        let t = usage.counts
        let codex = source == .codex
        let reasoningCost = codex ? 0 : Double(t.reasoning) * p.output
        let base = (Double(t.input) * p.input + Double(t.output) * p.output + Double(t.cached) * p.cacheRead
            + Double(t.cacheCreation) * p.cacheWrite + reasoningCost) / 1_000_000
        // Reasoning/speed suffixes (`gpt-5.6-high`, `-fast`) name the same model, so they keep its long-context tier.
        let lowered = Self.stripReasoningSuffix(model.lowercased())
        let usesLong = lowered == "gpt-5.6" || ["gpt-5.6-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6.1-sol"].contains { lowered.contains($0) }
        let hasPriority = p.priorityMultiplier > 1
        let hasUltrafast = p.ultrafastMultiplier > 1
        guard usesLong || hasPriority || hasUltrafast else { return base }
        func bounded(_ value: Int, _ total: Int) -> Double { Double(min(max(0, value), max(0, total))) }
        let longIn = bounded(usage.long.input, t.input)
        let longCached = bounded(usage.long.cached, t.cached)
        let longWrite = bounded(usage.long.cacheCreation, t.cacheCreation)
        let longOut = bounded(usage.long.output, t.output)
        let longReasoning = codex ? 0 : bounded(usage.long.reasoning, t.reasoning)
        let longPremium = usesLong
            ? (longIn * p.input + longCached * p.cacheRead + longWrite * p.cacheWrite + 0.5 * longOut * p.output + 0.5 * longReasoning * p.output) / 1_000_000
            : 0
        func premium(_ multiplier: Double, _ tier: AnalyticsCounts, _ tierLong: AnalyticsCounts) -> Double {
            guard multiplier > 1 else { return 0 }
            let input = bounded(tier.input, t.input), cached = bounded(tier.cached, t.cached)
            let write = bounded(tier.cacheCreation, t.cacheCreation), output = bounded(tier.output, t.output)
            let reasoning = codex ? 0 : bounded(tier.reasoning, t.reasoning)
            let tierBase = (input * p.input + cached * p.cacheRead + write * p.cacheWrite + output * p.output + reasoning * p.output) / 1_000_000
            guard usesLong else { return (multiplier - 1) * tierBase }
            func both(_ value: Int, _ a: Double, _ b: Double) -> Double { bounded(value, Int(min(a, b))) }
            let tierLong = (both(tierLong.input, input, longIn) * p.input + both(tierLong.cached, cached, longCached) * p.cacheRead
                + both(tierLong.cacheCreation, write, longWrite) * p.cacheWrite + 0.5 * both(tierLong.output, output, longOut) * p.output
                + 0.5 * both(tierLong.reasoning, reasoning, longReasoning) * p.output) / 1_000_000
            return (multiplier - 1) * (tierBase + tierLong)
        }
        return base + longPremium + premium(p.priorityMultiplier, usage.priority, usage.priorityLong)
            + premium(p.ultrafastMultiplier, usage.ultrafast, usage.ultrafastLong)
    }
}
