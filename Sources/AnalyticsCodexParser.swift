import Foundation

/// Resumable per-file parser state (spec §1.2 cursor fields).
struct AnalyticsCodexStream: Codable, Equatable {
    var lastTotal: AnalyticsCounts?
    var baselines: [AnalyticsCounts] = []
    var selectedModel: String?
    var effectiveModel: String?
    var lastModel: String?
    var serviceTier: String?
    var cwd: String?
    var projectKey: String?
    var sawTokenCount = false
    var compaction: AnalyticsCompaction?
    var compactionConfirmed = false

    var currentModel: String? { effectiveModel ?? selectedModel }

    /// `consumeUsageDelta` (CTU:96-151): recovers per-response deltas from interleaved cumulative streams.
    mutating func consume(last: AnalyticsCounts?, total: AnalyticsCounts?) -> AnalyticsCounts? {
        guard let total else { return last }
        if let index = baselines.firstIndex(of: total) {
            touch(at: index, total)
            return nil
        }
        if let last {
            let previous = Self.subtract(total, last)
            if let previous, let index = baselines.firstIndex(of: previous) {
                touch(at: index, total)
                return last
            }
            if previous != nil {
                touch(at: baselines.firstIndex(of: total), total)
                return last
            }
        }
        if let active = lastTotal, total.total >= active.total {
            let delta = AnalyticsCounts(fields: zip(total.fields, active.fields).map { max(0, $0 - $1) })
            if last == nil || delta.total <= last!.total {
                touch(at: baselines.firstIndex(of: active), total)
                return delta
            }
        }
        touch(at: baselines.firstIndex(of: total), total)
        return last ?? total
    }

    private mutating func touch(at index: Int?, _ usage: AnalyticsCounts) {
        if let index, baselines.indices.contains(index) {
            baselines.remove(at: index)
        } else if let duplicate = baselines.firstIndex(of: usage) {
            baselines.remove(at: duplicate)
        }
        baselines.append(usage)
        if baselines.count > 32 { baselines.removeFirst(baselines.count - 32) }
        lastTotal = usage
    }

    private static func subtract(_ total: AnalyticsCounts, _ last: AnalyticsCounts) -> AnalyticsCounts? {
        let fields = zip(total.fields, last.fields).map { $0 - $1 }
        return fields.contains { $0 < 0 } ? nil : AnalyticsCounts(fields: fields)
    }
}

/// A compaction call held until the next token_count confirms it (`codex-usage-record.js`).
struct AnalyticsCompaction: Codable, Equatable {
    let responseId: String
    let halfHour: Int64
    let model: String
    let tier: String?
    let projectKey: String?
    let usage: AnalyticsCounts
}

struct AnalyticsCodexCursor: Codable {
    var inode: UInt64
    var size: Int64
    var mtime: Double
    var offset: Int64
    /// `AnalyticsFingerprint` of the bytes before `offset` (plain .jsonl only).
    var fingerprint: UInt64?
    /// Read position inside an oversized record being discarded (see `AnalyticsLines.streamRecords`).
    var discardingFrom: Int64?

    var readPosition: Int64 { discardingFrom ?? offset }
    var stream = AnalyticsCodexStream()
    var session = AnalyticsCodexSession()
}

struct AnalyticsCodexEvent {
    let dedupKey: String
    let isCompaction: Bool
    let halfHour: Int64
    let model: String
    let delta: AnalyticsCounts
    let tier: AnalyticsTier?
    let projectKey: String?
}

/// One pass over new bytes of a rollout feeding both the usage buckets (spec §1) and the session
/// collector (§5). Fork state is per pass, as upstream: a resumed scan never sees the replay prefix.
struct AnalyticsCodexParser {
    var cursor: AnalyticsCodexCursor
    private(set) var events: [AnalyticsCodexEvent] = []
    let sessionId: String
    private let rolloutDate: String?
    private let projects: AnalyticsProjectResolver
    private var isForked = false
    private var replayActive: Bool
    private var previousForkedTime: Double?
    private var currentDate: String?

    init(path: String, cursor: AnalyticsCodexCursor, projects: AnalyticsProjectResolver) {
        self.cursor = cursor
        self.projects = projects
        let name = (path as NSString).lastPathComponent
        sessionId = Self.sessionId(fromName: name) ?? path
        rolloutDate = name.hasPrefix("rollout-") && name.count >= 19 && Array(name)[18] == "T"
            ? String(name.dropFirst(8).prefix(10)) : nil
        replayActive = cursor.offset == 0
    }

    static func sessionId(fromName name: String) -> String? {
        guard let range = name.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?=\.jsonl(\.zstd?)?$)"#,
                                     options: .regularExpression) else { return nil }
        return String(name[range])
    }

    mutating func consume(_ line: AnalyticsLine) {
        if let stamp = line.firstStringValue(after: "\"timestamp\":\"", within: 64), let seconds = AnalyticsTime.parse(stamp) {
            cursor.session.bounds.note(seconds)
        }
        if cursor.stream.compaction != nil && !cursor.stream.compactionConfirmed {
            if UnsafeRawBufferPointer(rebasing: line.prefix(256)).contains("\"type\":\"compacted\"") {
                cursor.stream.compactionConfirmed = true
                return
            }
            cursor.stream.compaction = nil
        }
        guard line.contains("\"token_count\"") || line.contains("\"turn_context\"") || line.contains("\"session_meta\"")
                || line.contains("\"thread_settings_applied\"") || line.contains("\"token_usage_record\"")
                || line.contains("\"user_message\"") || line.contains("\"type\":\"function_call\"")
                || line.contains("\"type\":\"custom_tool_call\"") || line.contains("model/rerouted") || line.contains("model_rerouted"),
              let obj = line.jsonObject() else { return }
        let modelEvent = applyModelEvent(obj)
        let attributed = cursor.stream.currentModel
        if let attributed { cursor.stream.lastModel = attributed }
        cursor.session.observe(obj, model: attributed)
        let type = obj.string("type")
        let payload = obj.object("payload")
        if type == "event_msg", payload?.string("type") == "thread_settings_applied",
           let tier = payload?.object("thread_settings")?.trimmedString("service_tier") {
            cursor.stream.serviceTier = tier.lowercased()
            return
        }
        if type == "turn_context" || type == "session_meta" {
            if let payload { applyContext(type: type!, payload) }
            return
        }
        if modelEvent == .rerouted { return }
        if type == "token_usage_record" {
            holdCompaction(obj)
            return
        }
        if let info = Self.tokenInfo(obj), let timestamp = obj.string("timestamp") {
            consumeTokenCount(info, timestamp: timestamp)
        }
    }

    // MARK: Model attribution (codex-model-attribution.js)

    private enum ModelEvent { case turnContext, sessionMeta, rerouted }

    private mutating func applyModelEvent(_ obj: [String: Any]) -> ModelEvent? {
        let type = obj.string("type")
        if type == "turn_context", let payload = obj.object("payload") {
            if let model = payload.trimmedString("model") { cursor.stream.selectedModel = model }
            cursor.stream.effectiveModel = cursor.stream.selectedModel ?? cursor.stream.effectiveModel
            return .turnContext
        }
        if type == "session_meta", let payload = obj.object("payload") {
            guard let model = payload.trimmedString("model"), cursor.stream.selectedModel == nil else { return nil }
            cursor.stream.selectedModel = model
            cursor.stream.effectiveModel = cursor.stream.effectiveModel ?? model
            return .sessionMeta
        }
        guard let reroute = Self.reroute(obj) else { return nil }
        cursor.stream.selectedModel = reroute.from ?? cursor.stream.selectedModel ?? cursor.stream.effectiveModel
        cursor.stream.effectiveModel = reroute.to
        return .rerouted
    }

    private static func reroute(_ obj: [String: Any]) -> (from: String?, to: String)? {
        let payload = obj.object("payload"), msg = payload?.object("msg"), topMsg = obj.object("msg")
        let candidates: [(Any?, Any?)] = [
            (obj["method"], obj["params"]), (obj["type"], obj["payload"]),
            (payload?["method"], payload?["params"]), (payload?["type"], payload),
            (msg?["method"], msg?["params"]), (msg?["type"], msg),
            (topMsg?["method"], topMsg?["params"]), (topMsg?["type"], topMsg),
        ]
        for (name, data) in candidates {
            guard let name = name as? String,
                  name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "/") == "model/rerouted" else { continue }
            let fields = data as? [String: Any] ?? [:]
            guard let to = fields.trimmedString("toModel") ?? fields.trimmedString("to_model") else { return nil }
            return (fields.trimmedString("fromModel") ?? fields.trimmedString("from_model"), to)
        }
        return nil
    }

    private mutating func applyContext(type: String, _ payload: [String: Any]) {
        if type == "session_meta", let forked = payload["forked_from_id"] as? String {
            isForked = !forked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if type == "turn_context", let date = payload.string("current_date")?.trimmingCharacters(in: .whitespaces),
           date.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            currentDate = String(date.prefix(10))
        }
        if let cwd = payload.trimmedString("cwd"), cwd != cursor.stream.cwd {
            cursor.stream.cwd = cwd
            cursor.stream.projectKey = projects.projectKey(forCwd: cwd)
        }
    }

    // MARK: Usage

    private static func tokenInfo(_ obj: [String: Any]) -> [String: Any]? {
        guard let payload = obj.object("payload") else { return nil }
        if payload.string("type") == "token_count" { return payload.object("info") }
        if let msg = payload.object("msg"), msg.string("type") == "token_count" { return msg.object("info") }
        return nil
    }

    /// `canonicalUsage`: six non-negative integers; nil when nothing numeric is present.
    static func canonical(_ value: Any?) -> AnalyticsCounts? {
        guard let usage = value as? [String: Any] else { return nil }
        let creationKey = usage["cache_creation_input_tokens"] == nil || usage["cache_creation_input_tokens"] is NSNull
            ? "cache_write_input_tokens" : "cache_creation_input_tokens"
        let keys = ["input_tokens", "cached_input_tokens", creationKey, "output_tokens", "reasoning_output_tokens", "total_tokens"]
        guard keys.contains(where: usage.hasNumber) else { return nil }
        return AnalyticsCounts(fields: keys.map(usage.count))
    }

    /// §1.6: input excludes cached; the reported total is kept for buckets, recomputed for sessions.
    private static func normalized(_ raw: AnalyticsCounts, recomputeTotal: Bool) -> AnalyticsCounts {
        var counts = raw
        counts.input = max(0, raw.input - raw.cached)
        if recomputeTotal { counts.total = counts.input + counts.cached + counts.cacheCreation + counts.output }
        return counts
    }

    private static func isResetSentinel(last: [String: Any]?, total: [String: Any]?) -> Bool {
        func components(_ usage: [String: Any]?) -> Int {
            guard let usage else { return 0 }
            let creation = usage.hasNumber("cache_creation_input_tokens") ? "cache_creation_input_tokens" : "cache_write_input_tokens"
            return ["input_tokens", "cached_input_tokens", creation, "output_tokens", "reasoning_output_tokens"].reduce(0) { $0 + usage.count($1) }
        }
        return (last?.count("total_tokens") ?? 0) > 0 && (total?.count("total_tokens") ?? 0) == 0
            && components(last) == 0 && components(total) == 0
    }

    private var bucketModel: String { cursor.stream.lastModel ?? "unknown" }

    private mutating func holdCompaction(_ obj: [String: Any]) {
        guard cursor.stream.sawTokenCount else { return }
        cursor.stream.compaction = nil
        cursor.stream.compactionConfirmed = false
        guard let payload = obj.object("payload"), let raw = Self.canonical(payload["usage"]),
              let timestamp = obj.string("timestamp"), let seconds = AnalyticsTime.parse(timestamp),
              let responseId = payload.string("response_id"), !responseId.isEmpty,
              !Self.normalized(raw, recomputeTotal: false).isZero else { return }
        cursor.stream.compaction = AnalyticsCompaction(responseId: responseId, halfHour: AnalyticsTime.halfHour(seconds), model: bucketModel,
                                                       tier: cursor.stream.serviceTier, projectKey: cursor.stream.projectKey, usage: raw)
    }

    private mutating func takeCompaction(total: AnalyticsCounts?) {
        let held = cursor.stream.compaction
        let confirmed = cursor.stream.compactionConfirmed
        cursor.stream.compaction = nil
        cursor.stream.compactionConfirmed = false
        guard let held, confirmed, let previous = cursor.stream.lastTotal, previous == total else { return }
        let tier = AnalyticsTier(serviceTier: held.tier)
        events.append(AnalyticsCodexEvent(dedupKey: "resp:\(held.responseId)", isCompaction: true, halfHour: held.halfHour, model: held.model,
                                          delta: Self.normalized(held.usage, recomputeTotal: false), tier: tier, projectKey: held.projectKey))
        cursor.session.recordCompaction(id: held.responseId, delta: Self.normalized(held.usage, recomputeTotal: true),
                                        rawInput: held.usage.input, model: held.model, tier: tier)
    }

    private mutating func consumeTokenCount(_ info: [String: Any], timestamp: String) {
        let last = Self.canonical(info["last_token_usage"])
        let total = Self.canonical(info["total_token_usage"])
        cursor.stream.sawTokenCount = true
        takeCompaction(total: total)
        let raw = cursor.stream.consume(last: last, total: total)
        let tier = AnalyticsTier(serviceTier: cursor.stream.serviceTier)
        if let raw {
            let signature = AnalyticsHash.of("\(last?.fields ?? [])|\(total?.fields ?? [])")
            if cursor.session.isNewTokenEvent(timestamp: timestamp, signature: signature) {
                cursor.session.recordUsage(Self.normalized(raw, recomputeTotal: true), rawInput: (last ?? raw).input,
                                           model: cursor.stream.currentModel ?? "unknown", tier: tier)
            }
        }
        let sentinel = Self.isResetSentinel(last: info.object("last_token_usage"), total: info.object("total_token_usage"))
        guard let raw, !sentinel else { return }
        let delta = Self.normalized(raw, recomputeTotal: false)
        guard !delta.isZero, !isForkReplay(timestamp), let seconds = AnalyticsTime.parse(timestamp) else { return }
        events.append(AnalyticsCodexEvent(dedupKey: "\(sessionId):\(timestamp)", isCompaction: false, halfHour: AnalyticsTime.halfHour(seconds),
                                          model: bucketModel, delta: delta, tier: tier, projectKey: cursor.stream.projectKey))
    }

    /// §1.5 fork replay skip: a forked rollout opens with a burst replay of the parent's token_counts.
    private mutating func isForkReplay(_ timestamp: String) -> Bool {
        var skip = false
        if isForked && replayActive {
            if let time = AnalyticsTime.parse(timestamp), previousForkedTime.map({ time >= $0 }) ?? true {
                if let previous = previousForkedTime, time - previous >= 0.5 { replayActive = false }
                skip = replayActive && previousForkedTime.map { time - $0 < 0.5 } == true
                previousForkedTime = time
            } else {
                replayActive = false
            }
        }
        if skip { return true }
        if isForked, let rolloutDate, let currentDate, currentDate < rolloutDate { return true }
        return false
    }
}
