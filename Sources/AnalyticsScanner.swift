import Foundation

struct AnalyticsLogRoots {
    let codexSessions: URL
    let codexArchived: URL
    let claudeProjects: [URL]

    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> AnalyticsLogRoots {
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        var claude = [home.appendingPathComponent(".claude/projects")]
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            claude.append(URL(fileURLWithPath: configured).appendingPathComponent("projects"))
        }
        var seen = Set<String>()
        let unique = claude.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
        return AnalyticsLogRoots(codexSessions: codexHome.appendingPathComponent("sessions"),
                                 codexArchived: codexHome.appendingPathComponent("archived_sessions"),
                                 claudeProjects: unique)
    }
}

/// Incremental scan of Codex and Claude Code logs into an `AnalyticsStore` (spec §0–§2).
/// Files are parsed concurrently in path-ordered batches; their events are applied serially in
/// that order, so the global first-wins dedup sets behave as in a sequential scan.
struct AnalyticsScanner {
    static let compressedLimit = 256 << 20

    let roots: AnalyticsLogRoots
    let projects: AnalyticsProjectResolver
    var workerCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount - 2, 4))

    private enum Job {
        case codex(path: String, stat: AnalyticsFileStat, cursor: AnalyticsCodexCursor, compressed: Bool)
        case claude(path: String, stat: AnalyticsFileStat, cursor: AnalyticsClaudeCursor)

        var bytes: Int64 {
            switch self {
            case let .codex(_, stat, cursor, compressed): return compressed ? stat.size : stat.size - cursor.readPosition
            case let .claude(_, stat, cursor): return stat.size - cursor.readPosition
            }
        }
    }

    private enum JobResult {
        case codex(path: String, cursor: AnalyticsCodexCursor, events: [AnalyticsCodexEvent], oversized: Int)
        case claude(path: String, cursor: AnalyticsClaudeCursor, events: [AnalyticsClaudeEvent], oversized: Int)
        case failed(path: String, cursor: AnalyticsCodexCursor, message: String)
    }

    struct Outcome {
        var filesParsed = 0
        var oversizedLines = 0
        var errors: [String] = []
    }

    /// `progress(processed, total)` is called from worker threads.
    func scan(_ store: inout AnalyticsStore, progress: @escaping (Int64, Int64) -> Void) -> Outcome {
        let jobs = codexJobs(&store) + claudeJobs(&store)
        let total = jobs.reduce(Int64(0)) { $0 + $1.bytes }
        let counter = ProgressCounter(total: total, report: progress)
        progress(0, total)
        var outcome = Outcome()
        var start = 0
        while start < jobs.count {
            let batch = Array(jobs[start..<min(start + 48, jobs.count)])
            start += batch.count
            for result in run(batch, counter: counter) {
                apply(result, to: &store, outcome: &outcome)
            }
        }
        if outcome.oversizedLines > 0 {
            outcome.errors.append("Skipped \(outcome.oversizedLines) log line(s) over \(AnalyticsLines.maxRecordBytes >> 20) MiB")
        }
        Self.mergeForkedConversations(&store)
        store.projects = projects.snapshot
        store.lastScanAt = Date().timeIntervalSince1970
        return outcome
    }

    // MARK: Discovery

    private func codexJobs(_ store: inout AnalyticsStore) -> [Job] {
        let files = (Self.datedRollouts(in: roots.codexSessions) + Self.rollouts(under: roots.codexArchived)).sorted()
        var jobs: [Job] = []
        var present = Set<String>()
        for path in files {
            guard let stat = AnalyticsFileStat.of(path) else { continue }
            present.insert(path)
            let compressed = !path.hasSuffix(".jsonl")
            let previous = store.codexFiles[path]
            if compressed {
                if let previous, previous.inode == stat.inode, previous.size == stat.size, previous.mtime == stat.mtime { continue }
                jobs.append(.codex(path: path, stat: stat, cursor: AnalyticsCodexCursor(inode: stat.inode, size: stat.size, mtime: stat.mtime, offset: 0), compressed: true))
                continue
            }
            if var previous, previous.inode == stat.inode, previous.offset <= stat.size,
               Self.unchangedPrefix(path, stat: stat, size: previous.size, mtime: previous.mtime, offset: previous.offset, fingerprint: previous.fingerprint) {
                previous.size = stat.size
                previous.mtime = stat.mtime
                if previous.readPosition == stat.size {
                    store.codexFiles[path] = previous
                    continue
                }
                jobs.append(.codex(path: path, stat: stat, cursor: previous, compressed: false))
            } else {
                jobs.append(.codex(path: path, stat: stat, cursor: AnalyticsCodexCursor(inode: stat.inode, size: stat.size, mtime: stat.mtime, offset: 0), compressed: false))
            }
        }
        store.codexFiles = store.codexFiles.filter { present.contains($0.key) }
        return jobs
    }

    private func claudeJobs(_ store: inout AnalyticsStore) -> [Job] {
        let files = roots.claudeProjects.flatMap { Self.files(under: $0) { $0.hasSuffix(".jsonl") } }.sorted()
        var jobs: [Job] = []
        var present = Set<String>()
        for path in files {
            guard let stat = AnalyticsFileStat.of(path) else { continue }
            present.insert(path)
            if var previous = store.claudeFiles[path], previous.inode == stat.inode, previous.offset <= stat.size,
               Self.unchangedPrefix(path, stat: stat, size: previous.size, mtime: previous.mtime, offset: previous.offset, fingerprint: previous.fingerprint) {
                previous.size = stat.size
                previous.mtime = stat.mtime
                if previous.readPosition == stat.size && previous.cwdChecked {
                    store.claudeFiles[path] = previous
                    continue
                }
                jobs.append(.claude(path: path, stat: stat, cursor: previous))
            } else {
                jobs.append(.claude(path: path, stat: stat, cursor: AnalyticsClaudeCursor(inode: stat.inode, size: stat.size, mtime: stat.mtime, offset: 0)))
            }
        }
        store.claudeFiles = store.claudeFiles.filter { present.contains($0.key) }
        return jobs
    }

    /// Bytes already read must be unchanged before resuming (or skipping) at the cursor. Appends grow
    /// the file, so a new mtime with the same size means an in-place rewrite: rescan from zero. A file
    /// that grew is resumed only if the head/tail fingerprint of the read prefix still matches.
    private static func unchangedPrefix(_ path: String, stat: AnalyticsFileStat, size: Int64, mtime: Double, offset: Int64, fingerprint: UInt64?) -> Bool {
        guard offset > 0, stat.size != size || stat.mtime != mtime else { return true }
        guard stat.size != size else { return false }
        return AnalyticsFingerprint.of(path: path, upTo: offset) == fingerprint
    }

    static func isRollout(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") || name.hasSuffix(".jsonl.zstd"))
    }

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-*` only (spec §1.1).
    private static func datedRollouts(in root: URL) -> [String] {
        let fm = FileManager.default
        func children(_ path: String, digits: Int) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: path)) ?? [])
                .filter { $0.count == digits && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
                .map { (path as NSString).appendingPathComponent($0) }
        }
        var out: [String] = []
        for year in children(root.path, digits: 4) {
            for month in children(year, digits: 2) {
                for day in children(month, digits: 2) {
                    let names = (try? fm.contentsOfDirectory(atPath: day)) ?? []
                    out += names.filter(isRollout).map { (day as NSString).appendingPathComponent($0) }
                }
            }
        }
        return out
    }

    private static func rollouts(under root: URL) -> [String] {
        files(under: root) { isRollout(($0 as NSString).lastPathComponent) }
    }

    private static func files(under root: URL, matching: (String) -> Bool) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in enumerator where matching(url.path) {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { out.append(url.path) }
        }
        return out
    }

    // MARK: Parsing

    private func run(_ batch: [Job], counter: ProgressCounter) -> [JobResult] {
        var results = [JobResult?](repeating: nil, count: batch.count)
        let next = ProgressCounter(total: .max, report: { _, _ in })
        results.withUnsafeMutableBufferPointer { slots in
            let buffer = slots
            DispatchQueue.concurrentPerform(iterations: min(workerCount, batch.count)) { _ in
                while true {
                    let index = Int(next.add(1)) - 1
                    guard index < batch.count else { return }
                    buffer[index] = autoreleasepool { parse(batch[index], counter: counter) }
                }
            }
        }
        return results.compactMap { $0 }
    }

    private func parse(_ job: Job, counter: ProgressCounter) -> JobResult {
        switch job {
        case let .codex(path, stat, cursor, compressed):
            var parser = AnalyticsCodexParser(path: path, cursor: cursor, projects: projects)
            var oversized = 0
            if compressed {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
                    let text = try AnalyticsZstd.decompress(data, limit: Self.compressedLimit)
                    _ = text.withUnsafeBytes { buffer in
                        AnalyticsLines.forEach(in: buffer, includeTail: true, oversized: { oversized += 1 }) { parser.consume($0) }
                    }
                } catch {
                    counter.add(stat.size)
                    var skipped = cursor
                    skipped.offset = stat.size
                    return .failed(path: path, cursor: skipped, message: "Could not decompress \((path as NSString).lastPathComponent)")
                }
                counter.add(stat.size)
                parser.cursor.offset = stat.size
            } else {
                let read = AnalyticsLines.streamRecords(path: path, from: cursor.offset, discardingFrom: cursor.discardingFrom,
                                                        progress: { counter.add(Int64($0)) }, oversized: { oversized += 1 }) { parser.consume($0) }
                parser.cursor.offset = read.offset
                parser.cursor.discardingFrom = read.discardingFrom
                parser.cursor.fingerprint = AnalyticsFingerprint.of(path: path, upTo: parser.cursor.offset)
            }
            return .codex(path: path, cursor: parser.cursor, events: parser.events, oversized: oversized)
        case let .claude(path, stat, cursor):
            var parser = AnalyticsClaudeParser(path: path, cursor: cursor)
            if !parser.cursor.cwdChecked {
                let cwd = AnalyticsClaudeParser.fileCwd(path: path)
                parser.cursor.cwd = cwd
                parser.cursor.projectKey = cwd.flatMap(projects.projectKey(forCwd:))
                parser.cursor.cwdChecked = cwd != nil || stat.size >= 65_536
            }
            var oversized = 0
            let read = AnalyticsLines.streamRecords(path: path, from: cursor.offset, discardingFrom: cursor.discardingFrom,
                                                    progress: { counter.add(Int64($0)) }, oversized: { oversized += 1 }) { parser.consume($0) }
            parser.cursor.offset = read.offset
            parser.cursor.discardingFrom = read.discardingFrom
            parser.cursor.fingerprint = AnalyticsFingerprint.of(path: path, upTo: parser.cursor.offset)
            return .claude(path: path, cursor: parser.cursor, events: parser.events, oversized: oversized)
        }
    }

    // MARK: Applying events

    private func apply(_ result: JobResult, to store: inout AnalyticsStore, outcome: inout Outcome) {
        outcome.filesParsed += 1
        switch result {
        case let .failed(path, cursor, message):
            store.codexFiles[path] = cursor
            outcome.errors.append(message)
        case let .codex(path, cursor, events, oversized):
            outcome.oversizedLines += oversized
            store.codexFiles[path] = cursor
            for event in events {
                let isNew = event.isCompaction ? store.compactions.insert(event.dedupKey) : store.codexEvents.insert(event.dedupKey)
                guard isNew else { continue }
                store.buckets[AnalyticsBucketKey(source: .codex, model: event.model, halfHour: event.halfHour), default: AnalyticsBucket()]
                    .add(event.delta, conversations: 1, tier: event.tier)
                if let project = event.projectKey {
                    store.projectBuckets[AnalyticsProjectBucketKey(project: project, source: .codex, halfHour: event.halfHour), default: AnalyticsBucket()]
                        .add(event.delta, conversations: 1, tier: nil)
                }
            }
        case let .claude(path, cursor, events, oversized):
            outcome.oversizedLines += oversized
            store.claudeFiles[path] = cursor
            for event in events {
                applyClaude(event, project: cursor.projectKey, to: &store)
            }
        }
    }

    private func applyClaude(_ event: AnalyticsClaudeEvent, project: String?, to store: inout AnalyticsStore) {
        switch event {
        case let .fork(uuid, parent):
            store.claudeForkAliases[uuid] = parent
        case let .conversation(uuid, halfHour):
            if let uuid {
                let identity = Self.identity(uuid, aliases: store.claudeForkAliases)
                guard store.claudeConversations[identity] == nil else { return }
                store.claudeConversations[identity] = halfHour
            }
            store.buckets[AnalyticsBucketKey(source: .claude, model: "unknown", halfHour: halfHour), default: AnalyticsBucket()].conversations += 1
        case let .usage(key, model, halfHour, delta):
            if let key, !store.claudeMessages.insert(key) { return }
            store.buckets[AnalyticsBucketKey(source: .claude, model: model, halfHour: halfHour), default: AnalyticsBucket()]
                .add(delta, conversations: 0, tier: nil)
            if let project {
                store.projectBuckets[AnalyticsProjectBucketKey(project: project, source: .claude, halfHour: halfHour), default: AnalyticsBucket()]
                    .add(delta, conversations: 0, tier: nil)
            }
        }
    }

    /// Aliases can arrive after a fork copy was already counted (any file order, any scan), so every
    /// counted identity is re-resolved against the full alias graph; a family counted twice keeps its
    /// earliest half-hour and gives back the others (the `families` repair in R:1090-1110).
    static func mergeForkedConversations(_ store: inout AnalyticsStore) {
        var families: [String: [(key: String, halfHour: Int64)]] = [:]
        for (key, halfHour) in store.claudeConversations {
            families[identity(String(key.dropFirst(2)), aliases: store.claudeForkAliases), default: []].append((key, halfHour))
        }
        for (root, members) in families where members.count > 1 || members[0].key != root {
            let sorted = members.sorted { $0.halfHour != $1.halfHour ? $0.halfHour < $1.halfHour : $0.key < $1.key }
            for member in sorted { store.claudeConversations[member.key] = nil }
            store.claudeConversations[root] = sorted[0].halfHour
            for extra in sorted.dropFirst() {
                let key = AnalyticsBucketKey(source: .claude, model: "unknown", halfHour: extra.halfHour)
                if let count = store.buckets[key]?.conversations, count > 0 { store.buckets[key]?.conversations = count - 1 }
            }
        }
    }

    /// `claudeUserIdentity`: follow `forkedFrom` aliases to the root; cycles collapse to their smallest member.
    static func identity(_ uuid: String, aliases: [String: String]) -> String {
        var chain: [String] = []
        var current = uuid
        while !chain.contains(current) {
            chain.append(current)
            guard let parent = aliases[current], !parent.isEmpty else { return "u:\(current)" }
            current = parent
        }
        let cycle = chain[chain.firstIndex(of: current)!...]
        return "u:\(cycle.min()!)"
    }

    // MARK: Session records

    /// Codex rows are grouped by the file-name UUID (sessions/ and archived copies, §5.1), keeping
    /// the copy with the most tokens; Claude rows are one per file, observer transcripts excluded.
    static func sessionRecords(_ store: AnalyticsStore) -> [AnalyticsSessionRecord] {
        var codex: [String: AnalyticsSessionRecord] = [:]
        for (path, cursor) in store.codexFiles {
            let id = AnalyticsCodexParser.sessionId(fromName: (path as NSString).lastPathComponent) ?? path
            let record = cursor.session.record(id: id)
            if let existing = codex[id], existing.totalTokens >= record.totalTokens { continue }
            codex[id] = record
        }
        let claude = store.claudeFiles
            .filter { !$0.key.split(separator: "/").contains { $0.hasSuffix(AnalyticsProjectResolver.observerSegment) } }
            .map { $0.value.session.record(id: $0.key) }
        return Array(codex.values) + claude
    }
}

/// Thread-safe byte counter that forwards progress at most every 32 MiB.
final class ProgressCounter {
    private let lock = NSLock()
    private var value: Int64 = 0
    private var reported: Int64 = 0
    private let total: Int64
    private let report: (Int64, Int64) -> Void

    init(total: Int64, report: @escaping (Int64, Int64) -> Void) {
        self.total = total
        self.report = report
    }

    @discardableResult
    func add(_ amount: Int64) -> Int64 {
        lock.lock()
        value += amount
        let current = value
        let shouldReport = current - reported >= 32 << 20 || current >= total
        if shouldReport { reported = current }
        lock.unlock()
        if shouldReport && total > 0 { report(min(current, total), total) }
        return current
    }
}
