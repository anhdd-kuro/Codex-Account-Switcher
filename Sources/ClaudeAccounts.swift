import Foundation

struct ClaudeAccountSummary: Equatable {
    let id: String
    let title: String
    let email: String
    let plan: String
    let fiveHourRemaining: Int?
    let weeklyRemaining: Int?
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let isActive: Bool
    let needsLogin: Bool
    let usageError: String?
}

struct ClaudeProfile {
    let id: String
    let email: String
    let organizationID: String
    let organizationName: String
    let keychainAccount: String
    let keychainService: String
    let oauthAccount: [String: Any]

    static func identity(email: String, organizationID: String) -> String {
        organizationID.isEmpty ? email : "\(email):\(organizationID)"
    }

    var title: String {
        if organizationName.isEmpty || organizationName.hasSuffix("'s Organization") {
            return "Personal"
        }
        return organizationName
    }

    func dictionary() -> [String: Any] {
        [
            "id": id,
            "email": email,
            "organizationID": organizationID,
            "organizationName": organizationName,
            "keychainAccount": keychainAccount,
            "keychainService": keychainService,
            "oauthAccount": oauthAccount
        ]
    }

    init(id: String, email: String, organizationID: String, organizationName: String, keychainAccount: String, keychainService: String, oauthAccount: [String: Any]) {
        self.id = id
        self.email = email
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.keychainAccount = keychainAccount
        self.keychainService = keychainService
        self.oauthAccount = oauthAccount
    }

    init?(dictionary: [String: Any]) {
        guard let email = dictionary["email"] as? String, !email.isEmpty,
              let service = dictionary["keychainService"] as? String, service.hasPrefix(ClaudeAccountStore.backupServicePrefix) else {
            return nil
        }
        let organizationID = dictionary["organizationID"] as? String ?? ""
        self.init(
            id: ClaudeProfile.identity(email: email, organizationID: organizationID),
            email: email,
            organizationID: organizationID,
            organizationName: dictionary["organizationName"] as? String ?? "",
            keychainAccount: dictionary["keychainAccount"] as? String ?? NSUserName(),
            keychainService: service,
            oauthAccount: dictionary["oauthAccount"] as? [String: Any] ?? [:]
        )
    }

    func with(oauthAccount: [String: Any]) -> ClaudeProfile {
        ClaudeProfile(
            id: id,
            email: email,
            organizationID: organizationID,
            organizationName: oauthAccount["organizationName"] as? String ?? organizationName,
            keychainAccount: keychainAccount,
            keychainService: keychainService,
            oauthAccount: oauthAccount
        )
    }
}

enum ClaudeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Keychain access goes through /usr/bin/security so Claude Code, which reads its
/// credentials the same way, keeps access without prompts. Secrets travel over
/// stdin as hex, never as process arguments.
enum ClaudeKeychain {
    private static let security = "/usr/bin/security"

    static func read(_ service: String) -> String? {
        let result = ProcessRunner.run(security, ["find-generic-password", "-s", service, "-w"], environment: [:], timeout: 5)
        guard result.status == 0 else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Like `read`, but only a missing item yields nil; any other failure throws.
    static func readStrict(_ service: String) throws -> String? {
        let result = ProcessRunner.run(security, ["find-generic-password", "-s", service, "-w"], environment: [:], timeout: 5)
        if result.status == 44 { return nil }
        guard result.status == 0 else { throw ClaudeError.message("Keychain read failed for \(service); nothing was changed.") }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func accountAttribute(_ service: String) -> String? {
        let result = ProcessRunner.run(security, ["find-generic-password", "-s", service], environment: [:], timeout: 5)
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") where line.contains("\"acct\"<blob>=\"") {
            let parts = line.components(separatedBy: "\"acct\"<blob>=\"")
            if parts.count == 2, let end = parts[1].lastIndex(of: "\"") {
                return String(parts[1][..<end])
            }
        }
        return nil
    }

    @discardableResult
    static func delete(_ service: String) -> Bool {
        ProcessRunner.run(security, ["delete-generic-password", "-s", service], environment: [:], timeout: 5).status == 0
    }

    static func write(_ service: String, account: String, secret: String) throws {
        guard !service.contains("\""), !account.contains("\"") else {
            throw ClaudeError.message("Invalid Keychain item name")
        }
        if let existing = accountAttribute(service), existing != account {
            var deletions = 0
            while delete(service), deletions < 10 { deletions += 1 }
        }
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        // Same approach as Claude Code: stdin keeps the secret out of the process list,
        // but `security -i` truncates long lines, so large payloads go through argv.
        let result = command.utf8.count <= 4000
            ? ProcessRunner.run(security, ["-i"], environment: [:], input: Data(command.utf8), timeout: 5)
            : ProcessRunner.run(security, ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex], environment: [:], timeout: 5)
        guard result.status == 0, read(service) == secret else {
            throw ClaudeError.message("Keychain write failed. Check Keychain access for this app.")
        }
    }
}

enum ClaudeAccountStore {
    static let liveService = "Claude Code-credentials"
    static let backupServicePrefix = "claude-switcher:"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let lock = NSRecursiveLock()

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeStateURL: URL { home.appendingPathComponent(".claude.json") }
    private static var storeURL: URL {
        home.appendingPathComponent("Library/Application Support/CodexAccountSwitcher/claude-profiles.json")
    }
    private static var legacyStoreURL: URL { home.appendingPathComponent(".config/claude-switcher/accounts.json") }

    // MARK: - Profiles

    static func loadProfiles() -> [ClaudeProfile] {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: storeURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = object["profiles"] as? [[String: Any]] {
            return raw.compactMap(ClaudeProfile.init(dictionary:))
        }
        let migrated = legacyProfiles()
        if !migrated.isEmpty {
            try? saveProfiles(migrated)
        }
        return migrated
    }

    static func saveProfiles(_ profiles: [ClaudeProfile]) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "profiles": profiles.map { $0.dictionary() }], options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeAtomically(data, to: storeURL)
    }

    /// One-time import of profiles saved by the earlier Python claude-switcher, whose
    /// Keychain backups use the same service names.
    private static func legacyProfiles() -> [ClaudeProfile] {
        guard let data = try? Data(contentsOf: legacyStoreURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else {
            return []
        }
        return accounts.compactMap { account in
            guard (account["provider"] as? String ?? "claude") == "claude",
                  let email = account["email"] as? String else { return nil }
            let oauth = account["oauth_account"] as? [String: Any] ?? [:]
            let organizationID = account["organization_id"] as? String ?? oauth["organizationUuid"] as? String ?? ""
            let id = ClaudeProfile.identity(email: email, organizationID: organizationID)
            let service = (account["keychain_service"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(backupServicePrefix)\(email)"
            guard ClaudeKeychain.read(service) != nil else { return nil }
            return ClaudeProfile(
                id: id,
                email: email,
                organizationID: organizationID,
                organizationName: account["org_name"] as? String ?? oauth["organizationName"] as? String ?? "",
                keychainAccount: account["keychain_account"] as? String ?? NSUserName(),
                keychainService: service,
                oauthAccount: oauth
            )
        }
    }

    // MARK: - Live login

    static func readOAuthAccount() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeStateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["oauthAccount"] as? [String: Any]
    }

    private static func writeOAuthAccount(_ account: [String: Any]?) throws {
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: claudeStateURL.path) {
            let data = try Data(contentsOf: claudeStateURL)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClaudeError.message("Cannot read ~/.claude.json")
            }
            object = parsed
        }
        object["oauthAccount"] = account
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try writeAtomically(data, to: claudeStateURL)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static func parseCredentials(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func serialize(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw ClaudeError.message("Cannot encode credentials") }
        return text
    }

    private static func oauth(_ credentials: [String: Any]?) -> [String: Any]? {
        credentials?["claudeAiOauth"] as? [String: Any]
    }

    private static func liveIdentity() -> String? {
        guard let account = readOAuthAccount(), let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
        return ClaudeProfile.identity(email: email, organizationID: account["organizationUuid"] as? String ?? "")
    }

    /// Mirrors the live login into its profile backup (Claude Code rotates tokens) and
    /// saves a login that no profile knows yet. `activeID` is nil when the live owner
    /// is unconfirmed; `preserved` is false when the live login is not safely saved.
    static func synchronize() -> (profiles: [ClaudeProfile], activeID: String?, preserved: Bool) {
        lock.lock(); defer { lock.unlock() }
        var profiles = loadProfiles()
        let liveText: String?
        do { liveText = try ClaudeKeychain.readStrict(liveService) } catch { return (profiles, nil, false) }
        guard let liveText else { return (profiles, nil, true) }
        guard let liveOAuth = oauth(parseCredentials(liveText)),
              let oauthAccount = readOAuthAccount(),
              let email = oauthAccount["emailAddress"] as? String, !email.isEmpty else {
            return (profiles, nil, false)
        }
        let organizationID = oauthAccount["organizationUuid"] as? String ?? ""
        let id = ClaudeProfile.identity(email: email, organizationID: organizationID)
        func backupMatchesLive(_ profile: ClaudeProfile) -> Bool {
            let backup = oauth(parseCredentials(ClaudeKeychain.read(profile.keychainService)))
            return backup?["refreshToken"] as? String == liveOAuth["refreshToken"] as? String
                && backup?["accessToken"] as? String == liveOAuth["accessToken"] as? String
        }
        let known = profiles.first(where: { $0.id == id })
        if let known, backupMatchesLive(known) {
            return (profiles, id, true)
        }
        // New tokens: a running Claude Code session can leave ~/.claude.json naming a
        // different account, so confirm whose token this is before saving it anywhere.
        guard let token = liveOAuth["accessToken"] as? String, let ownerID = tokenOwner(token) else {
            return (profiles, nil, false)
        }
        if ownerID != id {
            guard let owner = profiles.first(where: { $0.id == ownerID }),
                  let text = try? serialize(["claudeAiOauth": liveOAuth]),
                  (try? ClaudeKeychain.write(owner.keychainService, account: owner.keychainAccount, secret: text)) != nil else {
                return (profiles, nil, false)
            }
            return (profiles, ownerID, true)
        }
        var profile: ClaudeProfile
        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profile = profiles[index].with(oauthAccount: oauthAccount)
            profiles[index] = profile
        } else {
            profile = ClaudeProfile(
                id: id,
                email: email,
                organizationID: organizationID,
                organizationName: oauthAccount["organizationName"] as? String ?? "",
                keychainAccount: ClaudeKeychain.accountAttribute(liveService) ?? NSUserName(),
                keychainService: "\(backupServicePrefix)\(id)",
                oauthAccount: oauthAccount
            )
            profiles.append(profile)
        }
        guard let text = try? serialize(["claudeAiOauth": liveOAuth]),
              (try? ClaudeKeychain.write(profile.keychainService, account: profile.keychainAccount, secret: text)) != nil,
              (try? saveProfiles(profiles)) != nil else {
            return (profiles, id, false)
        }
        return (profiles, id, true)
    }

    /// The account and organization an access token belongs to, from Anthropic.
    private static func tokenOwner(_ token: String) -> String? {
        var request = URLRequest(url: profileURL)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let email = (object["account"] as? [String: Any])?["email"] as? String else { return }
            let organization = (object["organization"] as? [String: Any])?["uuid"] as? String ?? ""
            box.value = ClaudeProfile.identity(email: email, organizationID: organization)
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: String?
    }

    // MARK: - Switching

    static func switchTo(profileID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let (profiles, activeID, preserved) = synchronize()
        guard preserved else {
            throw ClaudeError.message("The current Claude login could not be saved first, so nothing was changed. Try again shortly.")
        }
        guard let target = profiles.first(where: { $0.id == profileID }) else {
            throw ClaudeError.message("Claude profile not found")
        }
        guard activeID != profileID else { return }
        guard let targetOAuth = oauth(parseCredentials(ClaudeKeychain.read(target.keychainService))),
              !(targetOAuth["accessToken"] as? String ?? "").isEmpty,
              !(targetOAuth["refreshToken"] as? String ?? "").isEmpty else {
            throw ClaudeError.message("Saved credentials for \(target.title) are missing. Sign in to it again.")
        }
        guard !target.oauthAccount.isEmpty else {
            throw ClaudeError.message("Saved account details for \(target.title) are missing. Sign in to it again.")
        }

        let liveText = try ClaudeKeychain.readStrict(liveService)
        var credentials: [String: Any] = [:]
        if let liveText {
            guard let parsed = parseCredentials(liveText) else {
                throw ClaudeError.message("The current Claude credentials are unreadable, so nothing was changed.")
            }
            credentials = parsed
        }
        let liveAccount = ClaudeKeychain.accountAttribute(liveService) ?? target.keychainAccount
        let liveOAuthAccount = readOAuthAccount()
        credentials["claudeAiOauth"] = targetOAuth
        do {
            try ClaudeKeychain.write(liveService, account: liveAccount, secret: try serialize(credentials))
            try writeOAuthAccount(target.oauthAccount)
            guard (oauth(parseCredentials(ClaudeKeychain.read(liveService))) as NSDictionary?)?.isEqual(to: targetOAuth) == true,
                  liveIdentity() == target.id else {
                throw ClaudeError.message("Claude login did not change.")
            }
        } catch {
            var restored = true
            if let liveText {
                restored = (try? ClaudeKeychain.write(liveService, account: liveAccount, secret: liveText)) != nil
            } else {
                ClaudeKeychain.delete(liveService)
                do { restored = try ClaudeKeychain.readStrict(liveService) == nil } catch { restored = false }
            }
            restored = (try? writeOAuthAccount(liveOAuthAccount)) != nil && restored
            throw ClaudeError.message(restored
                ? "\(error.localizedDescription) The previous login was restored."
                : "\(error.localizedDescription) The previous login could not be fully restored; run `claude auth login` to recover.")
        }
    }

    static func remove(profileID: String) throws {
        lock.lock(); defer { lock.unlock() }
        var profiles = loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard liveIdentity() != profileID else {
            throw ClaudeError.message("Switch to another Claude account before removing this one.")
        }
        if !profiles.contains(where: { $0.id != profileID && $0.keychainService == profile.keychainService }) {
            ClaudeKeychain.delete(profile.keychainService)
        }
        profiles.removeAll { $0.id == profileID }
        try saveProfiles(profiles)
    }

    // MARK: - Usage

    static func summaries(_ profiles: [ClaudeProfile], activeID: String?) async -> [ClaudeAccountSummary] {
        // Claude Code owns the live token: never refresh it, and refresh nothing while
        // the live owner is unconfirmed.
        let liveRefreshToken = oauth(parseCredentials(ClaudeKeychain.read(liveService)))?["refreshToken"] as? String
        return await withTaskGroup(of: (Int, ClaudeAccountSummary).self) { group in
            for (index, profile) in profiles.enumerated() {
                group.addTask { (index, await summary(for: profile, isActive: profile.id == activeID, mayRefresh: activeID != nil, liveRefreshToken: liveRefreshToken)) }
            }
            var results: [(Int, ClaudeAccountSummary)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func summary(for profile: ClaudeProfile, isActive: Bool, mayRefresh: Bool, liveRefreshToken: String?) async -> ClaudeAccountSummary {
        let service = isActive ? liveService : profile.keychainService
        var credentials = oauth(parseCredentials(ClaudeKeychain.read(service)))
        let canRefresh = !isActive && mayRefresh && credentials?["refreshToken"] as? String != liveRefreshToken
        var needsLogin = credentials == nil
        var usage: [String: Any]?
        var error: String? = credentials == nil ? "No saved login" : nil

        if canRefresh, let current = credentials, isExpired(current) {
            switch await refreshed(current, profile: profile) {
            case .success(let updated): credentials = updated
            case .failure(let failure):
                needsLogin = failure.isInvalidGrant
                error = failure.message
            }
        }
        if let token = credentials?["accessToken"] as? String, !needsLogin {
            var result = await fetchUsage(token: token)
            if case .failure(let failure) = result, failure.status == 401, canRefresh, let current = credentials {
                switch await refreshed(current, profile: profile) {
                case .success(let updated):
                    if let newToken = updated["accessToken"] as? String { result = await fetchUsage(token: newToken) }
                case .failure(let refreshFailure):
                    needsLogin = refreshFailure.isInvalidGrant
                }
            }
            switch result {
            case .success(let object):
                usage = object
                error = nil
            case .failure(let failure):
                if failure.status == 401 { needsLogin = true }
                error = failure.message
            }
        }

        func window(_ key: String) -> (Int?, Date?) {
            guard let window = usage?[key] as? [String: Any],
                  let utilization = (window["utilization"] as? NSNumber)?.doubleValue,
                  utilization.isFinite else {
                return (nil, nil)
            }
            let remaining = max(0, min(100, Int((100 - utilization).rounded())))
            return (remaining, (window["resets_at"] as? String).flatMap(parseDate))
        }
        let five = window("five_hour")
        let weekly = window("seven_day")
        return ClaudeAccountSummary(
            id: profile.id,
            title: profile.title,
            email: profile.email,
            plan: planText(credentials ?? [:], profile: profile),
            fiveHourRemaining: five.0,
            weeklyRemaining: weekly.0,
            fiveHourResetAt: five.1,
            weeklyResetAt: weekly.1,
            isActive: isActive,
            needsLogin: needsLogin,
            usageError: error
        )
    }

    private static func planText(_ credentials: [String: Any], profile: ClaudeProfile) -> String {
        let subscription = (credentials["subscriptionType"] as? String) ?? (profile.oauthAccount["billingType"] as? String) ?? ""
        var plan = subscription.isEmpty ? "Claude" : "Claude \(subscription.prefix(1).uppercased())\(subscription.dropFirst())"
        let tier = credentials["rateLimitTier"] as? String ?? ""
        if let range = tier.range(of: #"\d+x$"#, options: .regularExpression) {
            plan += " \(tier[range])"
        }
        return plan
    }

    private static func isExpired(_ credentials: [String: Any]) -> Bool {
        guard let expiresAt = (credentials["expiresAt"] as? NSNumber)?.doubleValue else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1000) < Date().addingTimeInterval(120)
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    private struct Failure: Error {
        let status: Int?
        let message: String
        var isInvalidGrant: Bool { status == 400 || status == 401 }
    }

    private static func fetchUsage(token: String) async -> Result<[String: Any], Failure> {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        do {
            let payload = try await CodexHTTPClient.send(request, retries: 1)
            guard payload.statusCode == 200 else {
                let message = payload.statusCode == 429 ? "Usage is rate limited; retrying later" : "Usage returned \(payload.statusCode)"
                return .failure(Failure(status: payload.statusCode, message: message))
            }
            guard let object = try JSONSerialization.jsonObject(with: payload.data) as? [String: Any] else {
                return .failure(Failure(status: nil, message: "Usage response was unreadable"))
            }
            return .success(object)
        } catch {
            return .failure(Failure(status: nil, message: error.localizedDescription))
        }
    }

    /// Refreshes an inactive profile's token. The refresh token rotates, so the new
    /// credentials are saved before anything else can use the old ones.
    private static func refreshed(_ credentials: [String: Any], profile: ClaudeProfile) async -> Result<[String: Any], Failure> {
        guard let refreshToken = credentials["refreshToken"] as? String else {
            return .failure(Failure(status: 400, message: "Session expired"))
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
        if let scopes = credentials["scopes"] as? [String], !scopes.isEmpty {
            body["scope"] = scopes.joined(separator: " ")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let payload: HTTPPayload
        do {
            payload = try await CodexHTTPClient.send(request, retries: 0)
        } catch {
            return .failure(Failure(status: nil, message: error.localizedDescription))
        }
        guard payload.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: payload.data)) as? [String: Any],
              let accessToken = object["access_token"] as? String else {
            let expired = payload.statusCode == 400 || payload.statusCode == 401
            return .failure(Failure(status: payload.statusCode, message: expired ? "Session expired" : "Token refresh returned \(payload.statusCode)"))
        }
        var updated = credentials
        updated["accessToken"] = accessToken
        if let newRefresh = object["refresh_token"] as? String { updated["refreshToken"] = newRefresh }
        if let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue {
            updated["expiresAt"] = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
        }
        if let scope = object["scope"] as? String { updated["scopes"] = scope.split(separator: " ").map(String.init) }

        guard saveRefreshed(updated, profile: profile) else {
            return .failure(Failure(status: nil, message: "Refreshed login could not be saved"))
        }
        return .success(updated)
    }

    private static func saveRefreshed(_ credentials: [String: Any], profile: ClaudeProfile) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard liveIdentity() != profile.id else { return true }
        guard let text = try? serialize(["claudeAiOauth": credentials]) else { return false }
        return (try? ClaudeKeychain.write(profile.keychainService, account: profile.keychainAccount, secret: text)) != nil
    }

    // MARK: - Sign in

    static func claudeExecutable() -> String? {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Opens Terminal with `claude auth login`; the next refresh saves the new login.
    static func openLoginTerminal(email: String?) throws {
        guard synchronize().preserved else {
            throw ClaudeError.message("The current Claude login could not be saved first. Try again shortly.")
        }
        guard let claude = claudeExecutable() else {
            throw ClaudeError.message("Claude Code CLI was not found. Install it from claude.com/claude-code.")
        }
        func quoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }
        var command = "\(quoted(claude)) auth login"
        if let email, email.contains("@") { command += " --email \(quoted(email))" }
        let script = "#!/bin/zsh\nclear\necho 'Sign in to Claude. The switcher saves this login automatically.'\n\(command)\nexit\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-login-\(UUID().uuidString).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let result = ProcessRunner.run("/usr/bin/open", ["-a", "Terminal", url.path], environment: [:], timeout: 10)
        guard result.status == 0 else { throw ClaudeError.message("Could not open Terminal: \(result.output)") }
    }
}

struct ClaudePanelModel {
    let accounts: [ClaudeAccountSummary]
    let lastError: String?
    let updatedText: String
    let isSwitching: Bool
    let switchAccount: (String) -> Void
    let signIn: (String?) -> Void
    let remove: (String) -> Void

    static let empty = ClaudePanelModel(accounts: [], lastError: nil, updatedText: "never", isSwitching: false, switchAccount: { _ in }, signIn: { _ in }, remove: { _ in })

    var active: ClaudeAccountSummary? { accounts.first(where: \.isActive) }
}

final class ClaudeController {
    private(set) var accounts: [ClaudeAccountSummary] = []
    private(set) var lastError: String?
    private(set) var lastUpdatedAt: Date?
    private(set) var isSwitching = false
    private var isRefreshing = false
    private var pendingRefresh = false
    private var lastRefreshStartedAt: Date?
    private var pendingSwitch: (id: String, completion: (String?) -> Void)?
    private let refreshInterval: TimeInterval = 90
    var onChange: (() -> Void)?
    var isEnabled = true

    var active: ClaudeAccountSummary? { accounts.first(where: \.isActive) }

    var updatedText: String {
        if isRefreshing && lastUpdatedAt == nil { return "refreshing..." }
        guard let lastUpdatedAt else { return "never" }
        let seconds = Int(Date().timeIntervalSince(lastUpdatedAt))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    func refreshIfNeeded(maximumAge: TimeInterval? = nil) {
        if let lastRefreshStartedAt, Date().timeIntervalSince(lastRefreshStartedAt) < (maximumAge ?? refreshInterval) { return }
        refresh()
    }

    func refresh() {
        guard isEnabled, !isSwitching else { return }
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        lastRefreshStartedAt = Date()
        Task.detached(priority: .utility) {
            let (profiles, activeID, _) = ClaudeAccountStore.synchronize()
            let summaries = await ClaudeAccountStore.summaries(profiles, activeID: activeID)
            await MainActor.run { self.apply(summaries) }
        }
    }

    private func apply(_ summaries: [ClaudeAccountSummary]) {
        let previous = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        accounts = summaries.map { summary in
            guard summary.usageError != nil, !summary.needsLogin, let old = previous[summary.id], old.fiveHourRemaining != nil else {
                return summary
            }
            return ClaudeAccountSummary(
                id: summary.id, title: summary.title, email: summary.email, plan: summary.plan,
                fiveHourRemaining: old.fiveHourRemaining, weeklyRemaining: old.weeklyRemaining,
                fiveHourResetAt: old.fiveHourResetAt, weeklyResetAt: old.weeklyResetAt,
                isActive: summary.isActive, needsLogin: false, usageError: summary.usageError
            )
        }
        lastError = ClaudeAccountStore.claudeExecutable() == nil && accounts.isEmpty ? "Claude Code CLI not found" : nil
        if summaries.contains(where: { $0.usageError == nil && !$0.needsLogin }) {
            lastUpdatedAt = Date()
        }
        isRefreshing = false
        // Start a queued switch before onChange, which may run auto-switch.
        if let pendingSwitch {
            self.pendingSwitch = nil
            pendingRefresh = false
            switchTo(pendingSwitch.id, completion: pendingSwitch.completion)
            return
        }
        onChange?()
        if pendingRefresh {
            pendingRefresh = false
            refresh()
        }
    }

    /// Waits for an in-flight refresh: it may be rotating the target's token.
    func switchTo(_ id: String, completion: @escaping (String?) -> Void) {
        guard isEnabled else { return completion("Claude switching is disabled in demo mode.") }
        guard !isSwitching, pendingSwitch == nil else { return completion("Another Claude switch is already in progress.") }
        guard !isRefreshing else {
            pendingSwitch = (id, completion)
            return
        }
        isSwitching = true
        onChange?()
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try ClaudeAccountStore.switchTo(profileID: id)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.isSwitching = false
                self.lastError = failure
                if failure == nil {
                    self.accounts = self.accounts.map { account in
                        ClaudeAccountSummary(
                            id: account.id, title: account.title, email: account.email, plan: account.plan,
                            fiveHourRemaining: account.fiveHourRemaining, weeklyRemaining: account.weeklyRemaining,
                            fiveHourResetAt: account.fiveHourResetAt, weeklyResetAt: account.weeklyResetAt,
                            isActive: account.id == id, needsLogin: account.needsLogin, usageError: account.usageError
                        )
                    }
                }
                self.onChange?()
                completion(failure)
                self.refresh()
            }
        }
    }

    func remove(_ id: String) throws {
        try ClaudeAccountStore.remove(profileID: id)
        accounts.removeAll { $0.id == id }
        onChange?()
    }

    func signIn(email: String?, completion: @escaping (String?) -> Void) {
        guard isEnabled else {
            completion("Claude sign-in is disabled in demo mode.")
            return
        }
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try ClaudeAccountStore.openLoginTerminal(email: email)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { completion(failure) }
        }
    }
}
