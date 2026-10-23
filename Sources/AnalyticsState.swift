import Foundation

/// Token columns of one usage row (spec §0 bucket schema). For Codex parser state the same shape
/// holds raw cumulative usage (input inclusive of cached), as TokenTracker's `canonicalUsage`.
struct AnalyticsCounts: Codable, Equatable {
    var input = 0
    var cached = 0
    var cacheCreation = 0
    var output = 0
    var reasoning = 0
    var total = 0

    var isZero: Bool { input == 0 && cached == 0 && cacheCreation == 0 && output == 0 && reasoning == 0 && total == 0 }
    var fields: [Int] { [input, cached, cacheCreation, output, reasoning, total] }

    init() {}

    init(fields: [Int]) {
        guard fields.count >= 6 else { return }
        (input, cached, cacheCreation, output, reasoning, total) = (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5])
    }

    mutating func add(_ other: AnalyticsCounts) {
        input = input.saturatingAdd(other.input)
        cached = cached.saturatingAdd(other.cached)
        cacheCreation = cacheCreation.saturatingAdd(other.cacheCreation)
        output = output.saturatingAdd(other.output)
        reasoning = reasoning.saturatingAdd(other.reasoning)
        total = total.saturatingAdd(other.total)
    }

    init(from decoder: Decoder) throws {
        self.init(fields: try decoder.singleValueContainer().decode([Int].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}

enum AnalyticsTier: String, Codable {
    case priority
    case ultrafast

    /// `thread_settings_applied.service_tier` (spec §1.4): "priority"/"fast" → Fast, "ultrafast".
    init?(serviceTier: String?) {
        switch serviceTier {
        case "priority", "fast": self = .priority
        case "ultrafast": self = .ultrafast
        default: return nil
        }
    }
}

/// One `(source, model, half-hour)` or `(project, source, half-hour)` row.
struct AnalyticsBucket: Codable, Equatable {
    var counts = AnalyticsCounts()
    var conversations = 0
    var priority = AnalyticsCounts()
    var ultrafast = AnalyticsCounts()

    mutating func add(_ delta: AnalyticsCounts, conversations: Int, tier: AnalyticsTier?) {
        counts.add(delta)
        self.conversations = self.conversations.saturatingAdd(conversations)
        switch tier {
        case .priority: priority.add(delta)
        case .ultrafast: ultrafast.add(delta)
        case nil: break
        }
    }

    mutating func add(_ other: AnalyticsBucket) {
        counts.add(other.counts)
        conversations = conversations.saturatingAdd(other.conversations)
        priority.add(other.priority)
        ultrafast.add(other.ultrafast)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer().decode([Int].self)
        guard values.count >= 7 else { return }
        counts = AnalyticsCounts(fields: Array(values[0..<6]))
        conversations = values[6]
        if values.count >= 19 {
            priority = AnalyticsCounts(fields: Array(values[7..<13]))
            ultrafast = AnalyticsCounts(fields: Array(values[13..<19]))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = counts.fields + [conversations]
        if !priority.isZero || !ultrafast.isZero { values += priority.fields + ultrafast.fields }
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

struct AnalyticsBucketKey: Hashable {
    let source: AnalyticsSource
    let model: String
    let halfHour: Int64
}

struct AnalyticsProjectBucketKey: Hashable {
    let project: String
    let source: AnalyticsSource
    let halfHour: Int64
}

/// Durable set of stable 64-bit hashes. Never evicted: a file rescanned from zero (inode change,
/// archive move) relies on these keys to avoid recounting totals that are kept forever (spec §1.5).
/// TokenTracker keeps the Codex set uncapped too; at 8 bytes per event it grows about 3 MB per 375k events.
struct AnalyticsDedupLog: Codable {
    private var members = Set<UInt64>()

    init() {}

    var count: Int { members.count }

    func contains(_ key: String) -> Bool { members.contains(AnalyticsHash.of(key)) }

    /// Returns false when the key was already present.
    @discardableResult
    mutating func insert(_ key: String) -> Bool {
        members.insert(AnalyticsHash.of(key)).inserted
    }

    init(from decoder: Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        var hashes = [UInt64](repeating: 0, count: data.count / 8)
        _ = hashes.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        members = Set(hashes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Array(members).withUnsafeBufferPointer { Data(buffer: $0) })
    }
}

struct AnalyticsProjectCacheEntry: Codable {
    let key: String?
    let checkedAt: Double
}

/// Everything the engine persists between launches (spec §0: buckets plus per-file cursors).
struct AnalyticsStore: Codable {
    static let currentVersion = 2

    var buckets: [AnalyticsBucketKey: AnalyticsBucket] = [:]
    var projectBuckets: [AnalyticsProjectBucketKey: AnalyticsBucket] = [:]
    var codexFiles: [String: AnalyticsCodexCursor] = [:]
    var claudeFiles: [String: AnalyticsClaudeCursor] = [:]
    var codexEvents = AnalyticsDedupLog()
    var compactions = AnalyticsDedupLog()
    var claudeMessages = AnalyticsDedupLog()
    /// Counted Claude conversations: canonical `u:<root uuid>` → half-hour it was counted in (spec §2.3).
    var claudeConversations: [String: Int64] = [:]
    var claudeForkAliases: [String: String] = [:]
    var projects: [String: AnalyticsProjectCacheEntry] = [:]
    var lastScanAt: Double?

    init() {}

    private struct BucketRow: Codable {
        let s: AnalyticsSource
        let m: String
        let h: Int64
        let v: AnalyticsBucket
    }

    private struct ProjectRow: Codable {
        let p: String
        let s: AnalyticsSource
        let h: Int64
        let v: AnalyticsBucket
    }

    private enum CodingKeys: String, CodingKey {
        case version, buckets, projectBuckets, codexFiles, claudeFiles, codexEvents, compactions
        case claudeMessages, claudeConversations, claudeForkAliases, projects, lastScanAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw CocoaError(.coderReadCorrupt)
        }
        for row in try c.decode([BucketRow].self, forKey: .buckets) {
            buckets[AnalyticsBucketKey(source: row.s, model: row.m, halfHour: row.h)] = row.v
        }
        for row in try c.decode([ProjectRow].self, forKey: .projectBuckets) {
            projectBuckets[AnalyticsProjectBucketKey(project: row.p, source: row.s, halfHour: row.h)] = row.v
        }
        codexFiles = try c.decode([String: AnalyticsCodexCursor].self, forKey: .codexFiles)
        claudeFiles = try c.decode([String: AnalyticsClaudeCursor].self, forKey: .claudeFiles)
        codexEvents = try c.decode(AnalyticsDedupLog.self, forKey: .codexEvents)
        compactions = try c.decode(AnalyticsDedupLog.self, forKey: .compactions)
        claudeMessages = try c.decode(AnalyticsDedupLog.self, forKey: .claudeMessages)
        claudeConversations = try c.decode([String: Int64].self, forKey: .claudeConversations)
        claudeForkAliases = try c.decode([String: String].self, forKey: .claudeForkAliases)
        projects = try c.decode([String: AnalyticsProjectCacheEntry].self, forKey: .projects)
        lastScanAt = try c.decodeIfPresent(Double.self, forKey: .lastScanAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(buckets.map { BucketRow(s: $0.key.source, m: $0.key.model, h: $0.key.halfHour, v: $0.value) }, forKey: .buckets)
        try c.encode(projectBuckets.map { ProjectRow(p: $0.key.project, s: $0.key.source, h: $0.key.halfHour, v: $0.value) }, forKey: .projectBuckets)
        try c.encode(codexFiles, forKey: .codexFiles)
        try c.encode(claudeFiles, forKey: .claudeFiles)
        try c.encode(codexEvents, forKey: .codexEvents)
        try c.encode(compactions, forKey: .compactions)
        try c.encode(claudeMessages, forKey: .claudeMessages)
        try c.encode(claudeConversations, forKey: .claudeConversations)
        try c.encode(claudeForkAliases, forKey: .claudeForkAliases)
        try c.encode(projects, forKey: .projects)
        try c.encodeIfPresent(lastScanAt, forKey: .lastScanAt)
    }
}

/// Binary-plist persistence under `~/Library/Application Support/AI Account Switcher/analytics/`.
/// A missing, corrupt or older-version file yields nil, which triggers a rebuild from scratch.
struct AnalyticsPersistence {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Account Switcher/analytics", isDirectory: true)
    }

    var stateURL: URL { directory.appendingPathComponent("state.plist") }

    func load() -> AnalyticsStore? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? PropertyListDecoder().decode(AnalyticsStore.self, from: data)
    }

    func save(_ store: AnalyticsStore) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(store).write(to: stateURL, options: .atomic)
    }
}
