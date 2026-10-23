import Foundation

/// cwd → `owner/repo` from the git origin remote (spec §3). Thread-safe; results are cached in memory
/// and persisted through `AnalyticsStore.projects`, re-checked after `ttl`.
final class AnalyticsProjectResolver {
    static let observerSegment = "--claude-mem-observer-sessions"
    private let ttl: Double = 24 * 3600
    private var cache: [String: AnalyticsProjectCacheEntry]
    private let lock = NSLock()
    private let fileManager = FileManager()

    init(cache: [String: AnalyticsProjectCacheEntry]) {
        self.cache = cache
    }

    var snapshot: [String: AnalyticsProjectCacheEntry] {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    func projectKey(forCwd cwd: String) -> String? {
        let now = Date().timeIntervalSince1970
        lock.lock()
        if let entry = cache[cwd], now - entry.checkedAt < ttl {
            lock.unlock()
            return entry.key
        }
        lock.unlock()
        let key = cwd.contains(Self.observerSegment) ? nil : resolve(cwd)
        lock.lock()
        cache[cwd] = AnalyticsProjectCacheEntry(key: key, checkedAt: now)
        lock.unlock()
        return key
    }

    private func resolve(_ cwd: String) -> String? {
        var current = URL(fileURLWithPath: cwd).standardizedFileURL.path
        while true {
            if let config = gitConfigPath(in: current) {
                return Self.projectKey(fromRef: Self.canonicalRef(remoteURL(config)))
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    private func gitConfigPath(in directory: String) -> String? {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            let config = (gitPath as NSString).appendingPathComponent("config")
            return isFile(config) ? config : nil
        }
        guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8),
              let line = content.split(whereSeparator: \.isNewline).first(where: { $0.lowercased().hasPrefix("gitdir:") }) else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let gitDir = raw.hasPrefix("/") ? raw : (directory as NSString).appendingPathComponent(raw)
        let config = (gitDir as NSString).appendingPathComponent("config")
        if isFile(config) { return config }
        guard let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty else { return nil }
        let commonDir = common.hasPrefix("/") ? common : (gitDir as NSString).appendingPathComponent(common)
        let commonConfig = ((commonDir as NSString).appendingPathComponent("config") as NSString).standardizingPath
        return isFile(commonConfig) ? commonConfig : nil
    }

    private func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// `[remote "origin"] url`, else the first remote's url.
    private func remoteURL(_ configPath: String) -> String? {
        guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        var remotes: [(String, String)] = []
        var current: String?
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                current = nil
                let inner = trimmed.dropFirst().dropLast()
                if inner.lowercased().hasPrefix("remote "), let open = inner.firstIndex(of: "\""), let close = inner.lastIndex(of: "\""), open < close {
                    current = String(inner[inner.index(after: open)..<close])
                }
                continue
            }
            guard let name = current, let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            let url = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            remotes.removeAll { $0.0 == name }
            remotes.append((name, url))
        }
        return remotes.first { $0.0 == "origin" }?.1 ?? remotes.first?.1
    }

    static func canonicalRef(_ remote: String?) -> String? {
        guard var ref = remote?.trimmingCharacters(in: .whitespaces), !ref.isEmpty,
              !ref.hasPrefix("file://"), !ref.hasPrefix("/") else { return nil }
        if ref.hasPrefix("git@"), let colon = ref.firstIndex(of: ":") {
            let host = ref[ref.index(ref.startIndex, offsetBy: 4)..<colon]
            ref = "https://\(host)/\(ref[ref.index(after: colon)...])"
        } else if ref.hasPrefix("ssh://") {
            guard let parsed = URLComponents(string: ref), let host = parsed.host else { return nil }
            ref = "https://\(host)\(parsed.path)"
        } else if ref.hasPrefix("git://") {
            ref = "https://" + ref.dropFirst("git://".count)
        } else if ref.hasPrefix("http://") {
            ref = "https://" + ref.dropFirst("http://".count)
        } else if !ref.hasPrefix("https://") {
            return nil
        }
        guard let parsed = URLComponents(string: ref), let host = parsed.host, !host.isEmpty else { return nil }
        ref = "https://\(host.lowercased())\(parsed.path)"
        if ref.lowercased().hasSuffix(".git") { ref.removeLast(4) }
        while ref.hasSuffix("/") { ref.removeLast() }
        return ref
    }

    static func projectKey(fromRef ref: String?) -> String? {
        guard let ref, let path = URLComponents(string: ref)?.path else { return nil }
        let segments = path.split(separator: "/").map(String.init)
        return segments.count >= 2 ? segments.joined(separator: "/") : nil
    }
}
