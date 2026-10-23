import Foundation

// Read-side model for the Analytics tab. Ported from TokenTracker (MIT, github.com/xiufengsun/TokenTracker);
// definitions follow tmp/analytics-spec.md §4–§6. Codex and Claude Code sources only.

enum AnalyticsSource: String, CaseIterable, Codable {
    case codex
    case claude
}

enum AnalyticsPeriod: String, CaseIterable {
    case day
    case week
    case month
    case total
}

struct AnalyticsTotals: Equatable, Codable {
    var input = 0            // non-cached input
    var cached = 0           // cache reads
    var cacheCreation = 0    // part of total, not shown as a column
    var output = 0
    var reasoning = 0        // subset of output for Codex, separate for Claude
    var total = 0            // = input + cached + cacheCreation + output (+ reasoning for Claude)
    var conversations = 0
    var costUSD = 0.0
}

struct AnalyticsDay: Equatable {
    let day: Date                 // local midnight
    let totals: AnalyticsTotals
    let modelTokens: [String: Int]
}

struct AnalyticsSourceShare: Equatable {
    let source: AnalyticsSource
    let tokens: Int
    let share: Double             // 0...100
    let modelCount: Int
}

struct AnalyticsModelShare: Equatable {
    let name: String
    let tokens: Int
    let share: Double             // 0...100
}

struct AnalyticsHeatCell: Equatable {
    let day: Date
    let tokens: Int
    let level: Int                // 0...4, quantile levels over non-zero days (§4.2)
}

struct AnalyticsTrendBar: Equatable {
    let start: Date               // hour (day period), day (week/month), or month (total)
    let segments: [AnalyticsModelShare] // per model, tokens descending
    let isFuture: Bool
}

struct AnalyticsProject: Equatable {
    let name: String              // owner/repo from the git origin remote
    let totals: AnalyticsTotals
}

struct AnalyticsEfficiencyModel: Equatable {
    let model: String
    let sessions: Int
    let editSessions: Int
    let firstPassRate: Double?    // 0...1
    let tokensPerEdit: Int?
}

struct AnalyticsEfficiency: Equatable {
    let sessions: Int
    let editSessions: Int
    let firstPassSessions: Int
    let editTurns: Int
    let costPerEditUSD: Double?
    let costIsPartial: Bool       // an edit session used a model with no price; cost is a lower bound
    let byModel: [AnalyticsEfficiencyModel] // top 5
}

struct AnalyticsSnapshot: Equatable {
    let period: AnalyticsPeriod
    let from: Date                // local midnight, inclusive
    let to: Date                  // local midnight, inclusive
    let totals: AnalyticsTotals   // selected period
    let costIsPartial: Bool       // some model had no price
    let sources: [AnalyticsSourceShare]
    let topModels: [AnalyticsModelShare] // top 3 for the selected period
    let last7dTokens: Int
    let last30dTokens: Int
    let averageDailyTokens: Int   // 30d / active days in 30d
    let started: Date?
    let activeDays: Int           // 52-week heatmap window
    let heatmap: [AnalyticsHeatCell] // week-aligned, Sunday start, 52 columns, oldest first
    let trend: [AnalyticsTrendBar]
    let daily: [AnalyticsDay]     // last 30 days, newest first
    let projects: [AnalyticsProject] // selected period, tokens descending
    let efficiency: AnalyticsEfficiency?
    let scannedAt: Date
}

/// Scan progress shown while the first (multi-GB) index build runs.
struct AnalyticsScanStatus: Equatable {
    let isScanning: Bool
    let processedBytes: Int64
    let totalBytes: Int64
    let lastError: String?
}

/// Implemented by the engine (`AnalyticsController`); the panel only talks to this.
/// `onChange` fires on the main queue.
protocol AnalyticsProviding: AnyObject {
    var snapshot: AnalyticsSnapshot? { get }
    var status: AnalyticsScanStatus { get }
    var period: AnalyticsPeriod { get }
    var onChange: (() -> Void)? { get set }
    /// Scans new log bytes incrementally, then recomputes the snapshot. Coalesces overlapping calls.
    func refresh()
    /// Recomputes the snapshot for `period` from the stored buckets (no rescan).
    func select(_ period: AnalyticsPeriod)
}
