import Foundation

@main
struct InfrastructureTests {
    private static var failures: [String] = []
    private static var assertionCount = 0

    static func main() throws {
        testResetRefreshPolicy()
        testUsageRefreshPolicy()
        testLastKnownGoodSnapshotPolicy()
        try testComputerUsePluginDiscovery()
        try testBackupPruning()
        testProcessRunner()
        testLimitResetWatcher()
        testCursorUsageExport()

        if failures.isEmpty {
            print("Infrastructure tests passed (\(assertionCount) assertions).")
            return
        }

        for failure in failures {
            FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
        }
        exit(1)
    }

    private static func testCursorUsageExport() {
        let csv = """
        Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-10-23T05:46:06.987Z","","","Included","claude-sonnet-5-5-medium","No","24029","4","0","2080","26113","Included"
        "2026-10-23T05:50:00.000Z","","","Included","claude-sonnet-5-5-medium","No","100","100","50","10","160","Included"
        "not a date","","","Included","x","No","1","1","1","1","4","Included"
        "2026-10-23T06:10:00.000Z","","","Included","","No","0","0","0","0","0","Included"
        """
        let records = AnalyticsCursorCSV.parse(csv)
        expect(records.count == 2, "rows with a bad date or no tokens are skipped")
        expect(records.first?.cacheWrite == 24025 && records.first?.input == 4, "cache write is input with write minus input without")
        expect(records.first?.counts.total == 26109, "total is input, cache write, cache read and output")
        expect(AnalyticsCursorCSV.parse("Date,Model\n1,2").isEmpty, "a missing column yields no records")

        let awkward = "\u{FEFF}Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens\r\n\"2026-10-23T05:46:06Z\",\"a,\"\"b\"\"\nc\",\"1e100\",\"NaN\",\"inf\",\"7\"\r\n"
        let parsed = AnalyticsCursorCSV.parse(awkward)
        expect(parsed.count == 1 && parsed[0].model == "a,\"b\"\nc" && parsed[0].output == 7, "BOM, CRLF and quoted commas, quotes and newlines parse")
        expect(parsed.first.map { $0.cacheRead == 0 && $0.input == 0 } == true, "NaN and inf cells count as zero without trapping")

        var store = AnalyticsStore()
        expect(store.replaceCursorUsage(records), "first import changes the store")
        expect(store.buckets.values.reduce(0) { $0 + $1.counts.total } == 26109 + 160, "buckets hold every record")
        expect(!store.replaceCursorUsage(records), "re-importing the same export changes nothing")
        let later = AnalyticsCursorRecord(seconds: records[0].seconds + 3600, model: "m2", input: 50, cacheWrite: 0, cacheRead: 0, output: 50)
        store.replaceCursorUsage(records + [later])
        let corrected = AnalyticsCursorRecord(seconds: later.seconds, model: "m2", input: 1, cacheWrite: 0, cacheRead: 0, output: 1)
        expect(store.replaceCursorUsage(records + [corrected]), "a corrected export replaces the old rows")
        expect(store.buckets.values.reduce(0) { $0 + $1.counts.total } == 26109 + 160 + 2, "corrected rows after the earliest event are rebuilt")
        store = AnalyticsStore()
        store.replaceCursorUsage(records)
        let older = AnalyticsCursorRecord(seconds: records[0].seconds - 86_400 * 3, model: "m", input: 5, cacheWrite: 0, cacheRead: 0, output: 5)
        store.replaceCursorUsage([older])
        expect(store.buckets.keys.contains { $0.model == "m" } && store.buckets.values.reduce(0) { $0 + $1.counts.total } == 10, "a windowed export wipes only from its earliest event")
        var partial = AnalyticsStore()
        partial.buckets[AnalyticsBucketKey(source: .cursor, model: "m", halfHour: AnalyticsTime.halfHour(Double(records[0].seconds)))] = {
            var bucket = AnalyticsBucket(); bucket.add(AnalyticsCursorRecord(seconds: 0, model: "m", input: 900, cacheWrite: 0, cacheRead: 0, output: 0).counts, conversations: 1, tier: nil); return bucket
        }()
        partial.replaceCursorUsage([AnalyticsCursorRecord(seconds: records[0].seconds, model: "m", input: 10, cacheWrite: 0, cacheRead: 0, output: 0)])
        expect(partial.buckets.values.reduce(0) { $0 + $1.counts.total } == 900, "the earliest half hour of a windowed export never shrinks")
        var other = AnalyticsStore()
        other.buckets[AnalyticsBucketKey(source: .codex, model: "gpt", halfHour: 1)] = AnalyticsBucket()
        other.replaceCursorUsage(records)
        expect(other.buckets.keys.contains { $0.source == .codex }, "other sources are never touched")
    }

    private static func testLimitResetWatcher() {
        func limit(_ remaining: Int, key: String = "a") -> WatchedLimit { WatchedLimit(key: key, title: key, remaining: remaining) }
        var watcher = LimitResetWatcher()
        expect(watcher.observe([limit(10)]).isEmpty, "first observation never celebrates")
        expect(watcher.observe([limit(100)]).count == 1, "refill after being near the limit celebrates")
        expect(watcher.observe([limit(100)]).isEmpty, "a steady full window does not celebrate again")
        var relaxed = LimitResetWatcher()
        _ = relaxed.observe([limit(80)])
        expect(relaxed.observe([limit(100)]).isEmpty, "refill from a comfortable level does not celebrate")
        var drifting = LimitResetWatcher()
        _ = drifting.observe([limit(60)])
        _ = drifting.observe([limit(15)])
        expect(drifting.observe([limit(95)]).count == 1, "the lowest value since the last reset counts")
        var independent = LimitResetWatcher()
        _ = independent.observe([limit(10, key: "a"), limit(10, key: "b")])
        expect(independent.observe([limit(100, key: "a"), limit(10, key: "b")]).map(\.key) == ["a"], "windows are tracked independently")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        if !condition() { failures.append(message) }
    }

    private static func testResetRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 1_000)
        expect(ResetRefreshPolicy.shouldRefresh(lastRefresh: nil, now: now, ttl: 300, force: false), "missing reset snapshot should refresh")
        expect(!ResetRefreshPolicy.shouldRefresh(lastRefresh: now.addingTimeInterval(-299), now: now, ttl: 300, force: false), "fresh reset snapshot should stay cached")
        expect(ResetRefreshPolicy.shouldRefresh(lastRefresh: now.addingTimeInterval(-300), now: now, ttl: 300, force: false), "expired reset snapshot should refresh")
        expect(ResetRefreshPolicy.shouldRefresh(lastRefresh: now, now: now, ttl: 300, force: true), "forced reset refresh should bypass cache")
    }

    private static func testUsageRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 2_000)
        expect(UsageRefreshPolicy.shouldRefresh(lastRefresh: nil, now: now, ttl: 30, force: false), "missing usage snapshot should refresh")
        expect(!UsageRefreshPolicy.shouldRefresh(lastRefresh: now.addingTimeInterval(-29), now: now, ttl: 30, force: false), "fresh usage snapshot should stay cached")
        expect(UsageRefreshPolicy.shouldRefresh(lastRefresh: now.addingTimeInterval(-30), now: now, ttl: 30, force: false), "expired usage snapshot should refresh")
        expect(UsageRefreshPolicy.shouldRefresh(lastRefresh: now, now: now, ttl: 30, force: true), "forced usage refresh should bypass cache")
    }

    private static func testLastKnownGoodSnapshotPolicy() {
        let current = ["one": 100, "two": 100, "removed": 42]
        let merged = LastKnownGoodSnapshotPolicy.merged(
            current: current,
            successful: ["one": 99],
            validKeys: Set(["one", "two", "three"])
        )
        expect(merged["one"] == 99, "new successful usage should replace the previous reading")
        expect(merged["two"] == 100, "a failed or missing refresh should retain the last known good reading")
        expect(merged["three"] == nil, "an account without a successful reading should not invent usage")
        expect(merged["removed"] == nil, "removed accounts should be pruned from retained usage")

        let unchanged = LastKnownGoodSnapshotPolicy.merged(
            current: ["one": 100, "two": 100],
            successful: [:],
            validKeys: Set(["one", "two"])
        )
        expect(unchanged == ["one": 100, "two": 100], "a wholly failed refresh should not roll usage back")
    }

    private static func testComputerUsePluginDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["1.0.799", "1.0.1000366", "1.2.1"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(version).appendingPathComponent("Codex Computer Use.app"),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("9.9.9"), withIntermediateDirectories: true)
        let found = ComputerUsePluginLocator.latestApp(in: root)
        expect(found?.deletingLastPathComponent().lastPathComponent == "1.2.1", "plugin discovery should use the newest valid numeric version")
        expect(found?.lastPathComponent == "Codex Computer Use.app", "plugin discovery should return the app bundle")
    }

    private static func testBackupPruning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for stamp in 1...5 {
            let url = root.appendingPathComponent("account.auth.json.bak.\(stamp)")
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        FileManager.default.createFile(atPath: root.appendingPathComponent("account.auth.json").path, contents: Data())
        let removed = AuthBackupPruner.prune(in: root, keepingPerAccount: 2)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        expect(removed == 3, "backup pruning should report removed files")
        expect(remaining.contains("account.auth.json.bak.5"), "backup pruning should keep newest backup")
        expect(remaining.contains("account.auth.json.bak.4"), "backup pruning should keep requested backup count")
        expect(remaining.contains("account.auth.json"), "backup pruning should preserve active auth snapshot")
    }

    private static func testProcessRunner() {
        let environment = ProcessInfo.processInfo.environment
        let success = ProcessRunner.run("/bin/echo", ["healthy"], environment: environment, timeout: 2)
        expect(success.status == 0 && success.output.contains("healthy"), "process runner should capture successful output")
        let timeout = ProcessRunner.run("/bin/sleep", ["2"], environment: environment, timeout: 0.1)
        expect(timeout.status == 124 && timeout.output.contains("timed out"), "process runner should terminate stalled commands")
    }
}
