import Foundation

// Cursor plan usage (Plan / Auto / API), read with the login Cursor already keeps on disk.
// Approach and endpoint follow TokenTracker (MIT): cursor.com/api/usage-summary with the WorkOS session cookie.

struct CursorUsageSnapshot: Equatable {
    let membership: String?
    let planUsed: Int?
    let autoUsed: Int?
    let apiUsed: Int?
    let resetAt: Date?
}

enum CursorMenuBarLane: String {
    case off, on
}

struct CursorUsageState: Equatable {
    var isInstalled = false
    var snapshot: CursorUsageSnapshot?
    var error: String?
    var updatedAt: Date?
}

enum CursorUsageError: LocalizedError {
    case notSignedIn
    case sessionExpired
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to Cursor"
        case .sessionExpired: return "Cursor session expired — reopen Cursor"
        case .http(let code): return "Cursor API returned \(code)"
        case .malformed: return "Unexpected Cursor response"
        }
    }
}

enum CursorUsageClient {
    static let appDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
    static var stateDatabase: URL { appDirectory.appendingPathComponent("User/globalStorage/state.vscdb") }
    static var cliConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/cli-config.json")
    }

    static var isInstalled: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: appDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The `cursorAuth/accessToken` JWT, read read-only through the system sqlite3.
    static func accessToken() -> String? {
        guard FileManager.default.fileExists(atPath: stateDatabase.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", stateDatabase.path, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              token.count >= 10 else { return nil }
        return token
    }

    private static let oauthSubject = try! NSRegularExpression(pattern: #"^(google-oauth2|github|oidc|auth0)\|[^|]+$"#)
    private static let nativeSubject = try! NSRegularExpression(pattern: #"\|(user_[A-Za-z0-9_]+)$"#)

    /// `auth0|user_X` → `user_X`; WorkOS OAuth subjects stay as `provider|id`.
    static func normalizedSubject(_ subject: String) -> String? {
        let range = NSRange(subject.startIndex..., in: subject)
        if let match = nativeSubject.firstMatch(in: subject, range: range), let id = Range(match.range(at: 1), in: subject) {
            return String(subject[id])
        }
        return oauthSubject.firstMatch(in: subject, range: range) != nil ? subject : nil
    }

    static func userID(jwt: String) -> String? {
        if let data = try? Data(contentsOf: cliConfig),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let auth = object["authInfo"] as? [String: Any],
           let id = auth["authId"] as? String,
           let normalized = normalizedSubject(id) {
            return normalized
        }
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String else { return nil }
        return normalizedSubject(subject)
    }

    static func sessionCookie() -> String? {
        guard let jwt = accessToken(), let userID = userID(jwt: jwt) else { return nil }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(jwt)"
    }

    static func clampPercent(_ value: Any?) -> Int? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
        return Int(min(100, max(0, number)).rounded())
    }

    private static func centsPercent(_ used: Any?, _ limit: Any?) -> Int? {
        guard let used = (used as? NSNumber)?.doubleValue, let limit = (limit as? NSNumber)?.doubleValue,
              used.isFinite, limit.isFinite, limit > 0 else { return nil }
        return clampPercent(NSNumber(value: used / limit * 100))
    }

    /// Port of TokenTracker `normalizeCursorUsageSummary`.
    static func parse(_ body: [String: Any]) -> CursorUsageSnapshot {
        let individual = body["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let individualOnDemand = individual?["onDemand"] as? [String: Any]
        let teamOnDemand = (body["teamUsage"] as? [String: Any])?["onDemand"] as? [String: Any]
        let auto = clampPercent(plan?["autoPercentUsed"])
        let api = clampPercent(plan?["apiPercentUsed"])
        let fromIndividual = centsPercent(individualOnDemand?["used"], individualOnDemand?["limit"])
        let fromTeam = centsPercent(teamOnDemand?["used"], teamOnDemand?["limit"])

        var total = clampPercent(plan?["totalPercentUsed"])
        if total == nil {
            if let auto, let api { total = Int((Double(auto + api) / 2).rounded()) }
            else { total = api ?? auto ?? centsPercent(plan?["used"], plan?["limit"]) }
        }
        total = total ?? fromIndividual ?? fromTeam
        if total == 0 { total = fromIndividual.flatMap { $0 > 0 ? $0 : nil } ?? fromTeam.flatMap { $0 > 0 ? $0 : nil } ?? total }
        let membership = body["membershipType"] as? String
        if body["limitType"] as? String == "team" || membership == "enterprise" || membership == "team",
           let fromTeam, total == nil || total == 0 {
            total = fromTeam
        }
        let resetAt = (body["billingCycleEnd"] as? String).flatMap { Self.parseDate($0) }
        return CursorUsageSnapshot(membership: membership, planUsed: total, autoUsed: auto, apiUsed: api, resetAt: resetAt)
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Refuses redirects off cursor.com so the session cookie never leaves it.
    private final class Guard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let host = request.url?.host ?? ""
            completionHandler(request.url?.scheme == "https" && (host == "cursor.com" || host == "www.cursor.com") ? request : nil)
        }
    }

    static func fetch() throws -> CursorUsageSnapshot {
        guard let cookie = sessionCookie() else { throw CursorUsageError.notSignedIn }
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.cursor.com/settings", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: Guard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<CursorUsageSnapshot, Error> = .failure(CursorUsageError.malformed)
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { result = .failure(CursorUsageError.sessionExpired); return }
            guard (200..<300).contains(status) else { result = .failure(CursorUsageError.http(status)); return }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(CursorUsageError.malformed); return
            }
            result = .success(parse(object))
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}

final class CursorUsageController {
    private(set) var state = CursorUsageState()
    var onChange: (() -> Void)?
    private var isRefreshing = false
    private let queue = DispatchQueue(label: "cursor-usage", qos: .utility)

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        queue.async { [weak self] in
            let installed = CursorUsageClient.isInstalled
            var next = CursorUsageState(isInstalled: installed)
            if installed {
                do { next.snapshot = try CursorUsageClient.fetch() } catch { next.error = error.localizedDescription }
                next.updatedAt = Date()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                var merged = next
                if merged.snapshot == nil, merged.error != nil { merged.snapshot = self.state.snapshot }
                if merged != self.state {
                    self.state = merged
                    self.onChange?()
                }
            }
        }
    }
}
