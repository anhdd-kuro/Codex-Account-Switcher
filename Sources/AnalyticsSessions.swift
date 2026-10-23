import Foundation

/// Session efficiency (spec §5). Each log file keeps a resumable collector in its cursor, so a
/// growing session is extended from its last offset; an inode change or truncation restarts it.
struct AnalyticsSessionBounds: Codable, Equatable {
    var startedAt: Double?
    var endedAt: Double?

    mutating func note(_ seconds: Double) {
        if startedAt.map({ seconds < $0 }) ?? true { startedAt = seconds }
        if endedAt.map({ seconds > $0 }) ?? true { endedAt = seconds }
    }
}

enum AnalyticsEditTools {
    static let edits: Set<String> = ["apply_patch", "edit", "write", "multiedit", "notebookedit", "search_replace", "str_replace", "create_file", "write_file"]
    static let codexSignals = edits.union(["spawn_agent", "multi_agent_v1__spawn_agent"])
    static let openAILongContextInput = 272_000

    /// Whitespace-collapsed prompt fingerprint for retry detection (§5.2); only compared for equality.
    static func fingerprint(_ prompt: String) -> UInt64 {
        AnalyticsHash.of(prompt.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}

struct AnalyticsCodexSession: Codable, Equatable {
    var bounds = AnalyticsSessionBounds()
    var turns = 0
    var editTurns = 0
    var retryTurns = 0
    var usageTurns = 0
    var turnOpen = false
    var turnKey: String?
    var hadEdit = false
    var hasTurnContext = false
    var lastPrompt: UInt64?
    var turnModel: String?
    var editTurnsByModel: [String: Int] = [:]
    var models: [String: AnalyticsUsageDetail] = [:]
    var compactionIds: [String] = []
    var lastTokenTimestamp: String?
    var lastTimestampSignatures: [UInt64] = []

    private mutating func closeTurn() {
        if turnOpen && hadEdit {
            editTurns += 1
            editTurnsByModel[turnModel ?? "unknown", default: 0] += 1
        }
        hadEdit = false
    }

    private mutating func beginTurn(_ key: String?, model: String?) {
        if turnOpen, let key, turnKey == key { return }
        if turnOpen { closeTurn() }
        turnOpen = true
        turnKey = key
        turnModel = model
        turns += 1
    }

    /// `createCodexDeliverySignalCollector().consume` (SA:706-791).
    mutating func observe(_ obj: [String: Any], model: String?) {
        let type = obj.string("type")
        let timestamp = obj.string("timestamp")
        let payload = obj.object("payload")
        if type == "turn_context" {
            hasTurnContext = true
            beginTurn(payload?.string("turn_id") ?? timestamp ?? String(turns + 1), model: model)
            return
        }
        if turnOpen, let model, model != turnModel { turnModel = model }
        if type == "event_msg", payload?.string("type") == "user_message", let prompt = Self.prompt(payload ?? [:]) {
            let print = AnalyticsEditTools.fingerprint(prompt)
            if lastPrompt == print { retryTurns += 1 }
            lastPrompt = print
            if !hasTurnContext { beginTurn(timestamp ?? String(turns + 1), model: model) }
            return
        }
        guard type == "response_item", let payload else { return }
        let names = Self.signalTools(payload)
        guard !names.isEmpty else { return }
        if !turnOpen { beginTurn(timestamp ?? String(turns + 1), model: model) }
        if names.contains(where: AnalyticsEditTools.edits.contains) { hadEdit = true }
    }

    private static func prompt(_ payload: [String: Any]) -> String? {
        if let message = payload["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let elements = payload["text_elements"] as? [Any] ?? []
        let text = elements.compactMap { item -> String? in
            if let string = item as? String { return string }
            let dict = item as? [String: Any]
            return dict?.string("text") ?? dict?.string("value")
        }.filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func canonicalTool(_ name: String?) -> String {
        var value = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["functions.", "functions:", "functions/"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        for prefix in ["tools.", "tools:", "tools/"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        return value
    }

    /// Current Codex wraps calls as `custom_tool_call name:"exec"`; edits show up as `tools.apply_patch(` in its input.
    private static func signalTools(_ payload: [String: Any]) -> [String] {
        guard let kind = payload.string("type"), kind == "function_call" || kind == "custom_tool_call" else { return [] }
        let name = canonicalTool(payload.string("name"))
        if !name.isEmpty && name != "exec" { return [name] }
        guard name == "exec", let input = payload.string("input") else { return [] }
        return AnalyticsEditTools.codexSignals.filter { tool in
            input.range(of: #"\btools\.\#(tool)\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Per-session usage dedup: an identical `(timestamp, last, total)` event counts once.
    mutating func isNewTokenEvent(timestamp: String, signature: UInt64) -> Bool {
        if timestamp != lastTokenTimestamp {
            lastTokenTimestamp = timestamp
            lastTimestampSignatures = [signature]
            return true
        }
        guard !lastTimestampSignatures.contains(signature) else { return false }
        lastTimestampSignatures.append(signature)
        return true
    }

    mutating func recordUsage(_ delta: AnalyticsCounts, rawInput: Int, model: String, tier: AnalyticsTier?) {
        guard delta.total > 0 else { return }
        models[model, default: AnalyticsUsageDetail()].add(delta, tier: tier, isLong: rawInput > AnalyticsEditTools.openAILongContextInput)
        usageTurns += 1
    }

    mutating func recordCompaction(id: String, delta: AnalyticsCounts, rawInput: Int, model: String, tier: AnalyticsTier?) {
        guard !compactionIds.contains(id) else { return }
        compactionIds.append(id)
        recordUsage(delta, rawInput: rawInput, model: model, tier: tier)
    }

    func record(id: String) -> AnalyticsSessionRecord {
        var copy = self
        copy.closeTurn()
        return AnalyticsSessionRecord(source: .codex, id: id, bounds: bounds, turns: copy.turns > 0 ? copy.turns : usageTurns,
                                      editTurns: copy.editTurns, retryTurns: retryTurns, models: models, editTurnsByModel: copy.editTurnsByModel)
    }
}

struct AnalyticsClaudeSession: Codable, Equatable {
    var bounds = AnalyticsSessionBounds()
    var turns = 0
    var editTurns = 0
    var retryTurns = 0
    var hadEdit = false
    var turnModel: String?
    var model = "unknown"
    var lastPrompt: UInt64?
    var recentKeys: [UInt64] = []
    var editTurnsByModel: [String: Int] = [:]
    var models: [String: AnalyticsUsageDetail] = [:]

    private mutating func closeTurn() {
        if hadEdit {
            editTurns += 1
            editTurnsByModel[turnModel ?? "unknown", default: 0] += 1
        }
        hadEdit = false
    }

    /// `scanClaudeSession` (SA:544-704) with the port fix: `tool_use` blocks are read on every line,
    /// while usage stays deduplicated by `message.id:requestId` (spec §5.2).
    mutating func observe(_ obj: [String: Any], dedupKey: String?, usage: AnalyticsCounts?) {
        let type = obj.string("type")
        if type == "user" {
            guard let prompt = Self.prompt(obj) else { return }
            let print = AnalyticsEditTools.fingerprint(prompt)
            if lastPrompt == print { retryTurns += 1 }
            lastPrompt = print
            closeTurn()
            turns += 1
            return
        }
        guard type == "assistant", let message = obj.object("message") else { return }
        if isFirstSighting(dedupKey) {
            if let candidate = AnalyticsClaudeSession.sessionModel(message.string("model")) { model = candidate }
            turnModel = model
            if let usage, usage.total > 0 { models[model, default: AnalyticsUsageDetail()].add(usage, tier: nil, isLong: false) }
        }
        for block in message["content"] as? [[String: Any]] ?? [] where block.string("type") == "tool_use" {
            if AnalyticsEditTools.edits.contains((block.string("name") ?? "").lowercased()) { hadEdit = true }
        }
    }

    /// Claude writes one line per content block of a response, consecutively; a short window of
    /// recent keys reproduces the per-file `seenMessages` set without persisting every id.
    private mutating func isFirstSighting(_ key: String?) -> Bool {
        guard let key else { return true }
        let hash = AnalyticsHash.of(key)
        guard !recentKeys.contains(hash) else { return false }
        recentKeys.append(hash)
        if recentKeys.count > 64 { recentKeys.removeFirst(recentKeys.count - 64) }
        return true
    }

    private static func prompt(_ obj: [String: Any]) -> String? {
        if (obj["isMeta"] as? Bool) == true { return nil }
        let content = obj.object("message")?["content"]
        var text: String
        if let blocks = content as? [Any] {
            let dicts = blocks.map { $0 as? [String: Any] }
            if !dicts.isEmpty && dicts.allSatisfy({ $0?.string("type") == "tool_result" }) { return nil }
            text = dicts.compactMap { $0?.string("type") == "text" ? $0?.string("text") : nil }.joined(separator: "\n")
        } else if let string = content as? String {
            text = string
        } else {
            return nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "[Request interrupted by user]", !text.hasPrefix("<task-notification>") else { return nil }
        return text
    }

    static func sessionModel(_ value: String?) -> String? {
        guard let model = value?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty,
              !["<synthetic>", "synthetic", "<unknown>", "unknown"].contains(model.lowercased()) else { return nil }
        return model
    }

    func record(id: String) -> AnalyticsSessionRecord {
        var copy = self
        copy.closeTurn()
        return AnalyticsSessionRecord(source: .claude, id: id, bounds: bounds, turns: copy.turns, editTurns: copy.editTurns,
                                      retryTurns: retryTurns, models: models, editTurnsByModel: copy.editTurnsByModel)
    }
}

struct AnalyticsSessionRecord {
    let source: AnalyticsSource
    let id: String
    let bounds: AnalyticsSessionBounds
    let turns: Int
    let editTurns: Int
    let retryTurns: Int
    let models: [String: AnalyticsUsageDetail]
    let editTurnsByModel: [String: Int]

    var totalTokens: Int { models.values.saturatingSum { $0.counts.total } }
}

/// `summarizeSessions` (SA:2434-2604) for one local-day window.
enum AnalyticsEfficiencySummary {
    private struct ModelRow {
        let model: String
        var usage: AnalyticsUsageDetail
        var editTurns: Int
    }

    private struct ModelAggregate {
        var sessions = 0
        var editSessions = 0
        var firstPass = 0
        var editTurns = 0
        var editTokens = 0
    }

    static func summarize(_ records: [AnalyticsSessionRecord], from: Int, to: Int, day: (Double) -> Int, pricing: AnalyticsPricing) -> AnalyticsEfficiency? {
        var sessions = 0, editSessions = 0, firstPass = 0, editTurns = 0
        var editCost = 0.0
        var costIsPartial = false
        var byModel: [String: ModelAggregate] = [:]
        for record in records {
            guard let start = record.bounds.startedAt ?? record.bounds.endedAt, let end = record.bounds.endedAt ?? record.bounds.startedAt,
                  day(end) >= from, day(start) <= to else { continue }
            let productive = record.editTurns > 0
            let isFirstPass = record.editTurns == 1 && record.retryTurns == 0
            sessions += 1
            editTurns += record.editTurns
            if productive { editSessions += 1 }
            if isFirstPass { firstPass += 1 }
            for row in rows(record) {
                if productive {
                    editCost += pricing.cost(source: record.source, model: row.model, usage: row.usage)
                    if row.usage.counts.total > 0 && pricing.rates(model: row.model, source: record.source) == nil { costIsPartial = true }
                }
                var aggregate = byModel[row.model] ?? ModelAggregate()
                aggregate.sessions += 1
                if productive { aggregate.editSessions += 1 }
                if isFirstPass { aggregate.firstPass += 1 }
                aggregate.editTurns += row.editTurns
                if productive { aggregate.editTokens = aggregate.editTokens.saturatingAdd(row.usage.counts.total) }
                byModel[row.model] = aggregate
            }
        }
        guard sessions > 0 else { return nil }
        let hidden: Set<String> = ["unknown", "synthetic", "<synthetic>", "openai"]
        let models = byModel
            .filter { !hidden.contains($0.key.lowercased()) && $0.value.editTurns > 0 }
            .sorted { lhs, rhs in
                let a = lhs.value, b = rhs.value
                if a.editTurns != b.editTurns { return a.editTurns > b.editTurns }
                if a.editSessions != b.editSessions { return a.editSessions > b.editSessions }
                if a.sessions != b.sessions { return a.sessions > b.sessions }
                return lhs.key < rhs.key
            }
            .prefix(5)
            .map { entry in
                AnalyticsEfficiencyModel(
                    model: entry.key,
                    sessions: entry.value.sessions,
                    editSessions: entry.value.editSessions,
                    firstPassRate: entry.value.editSessions > 0 ? Double(entry.value.firstPass) / Double(entry.value.editSessions) : nil,
                    tokensPerEdit: entry.value.editTurns > 0 ? Int((Double(entry.value.editTokens) / Double(entry.value.editTurns)).rounded()) : nil
                )
            }
        return AnalyticsEfficiency(
            sessions: sessions,
            editSessions: editSessions,
            firstPassSessions: firstPass,
            editTurns: editTurns,
            costPerEditUSD: editTurns > 0 ? editCost / Double(editTurns) : nil,
            costIsPartial: costIsPartial,
            byModel: Array(models)
        )
    }

    /// `modelUsageForAggregation`: placeholder models fold into "unknown", empty rows drop, and edit
    /// turns without a usage row go to the busiest model.
    private static func rows(_ record: AnalyticsSessionRecord) -> [ModelRow] {
        var merged: [String: ModelRow] = [:]
        for (model, usage) in record.models {
            let name = AnalyticsClaudeSession.sessionModel(model) ?? "unknown"
            var row = merged[name] ?? ModelRow(model: name, usage: AnalyticsUsageDetail(), editTurns: 0)
            row.usage.add(usage)
            row.editTurns += record.editTurnsByModel[model] ?? 0
            merged[name] = row
        }
        var rows = merged.values.filter { !$0.usage.counts.isZero }
            .sorted { $0.usage.counts.total != $1.usage.counts.total ? $0.usage.counts.total > $1.usage.counts.total : $0.model < $1.model }
        guard !rows.isEmpty else {
            return [ModelRow(model: "unknown", usage: AnalyticsUsageDetail(), editTurns: record.editTurns)]
        }
        let residual = record.editTurns - rows.reduce(0) { $0 + $1.editTurns }
        if residual > 0 { rows[0].editTurns += residual }
        return rows
    }
}
