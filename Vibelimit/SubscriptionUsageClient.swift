import Foundation
import LocalAuthentication
import Security

enum SubscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, copilot, cursor

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .copilot: return "GitHub Copilot"
        case .cursor: return "Cursor"
        }
    }
    var shortName: String {
        self == .copilot ? "Copilot" : self == .claude ? "Claude" : displayName
    }
}

enum SubscriptionError: LocalizedError {
    case credentials(String)
    case invalidResponse
    case http(Int)
    case network

    var errorDescription: String? {
        switch self {
        case let .credentials(message): return message
        case .invalidResponse: return "No supported usage limits were returned."
        case .http(401), .http(403): return "Usage access was denied. Sign in again in the provider's app, then retry."
        case .http(429): return "Too many requests. Wait a few minutes before retrying."
        case let .http(status): return "Usage service returned HTTP \(status). Try again later."
        case .network: return "Could not reach the usage service. Check your connection and retry."
        }
    }
}

struct SubscriptionUsageClient {
    private static let usageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    var session: URLSession = usageSession

    func fetch(_ provider: SubscriptionProvider, allowKeychainPrompt: Bool = false) async throws -> UsageSnapshot {
        // Keychain access can block while macOS asks for permission. Keep it off the UI thread.
        let token = try await Task.detached {
            try SubscriptionCredentials.token(for: provider, allowKeychainPrompt: allowKeychainPrompt)
        }.value
        let request = try Self.request(for: provider, token: token)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubscriptionError.network
        }
        guard let response = response as? HTTPURLResponse else { throw SubscriptionError.invalidResponse }
        guard response.statusCode == 200 else { throw SubscriptionError.http(response.statusCode) }
        return try Self.decode(data, provider: provider)
    }

    static func request(for provider: SubscriptionProvider, token: String) throws -> URLRequest {
        let url: URL
        switch provider {
        case .claude: url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        case .copilot: url = URL(string: "https://api.github.com/copilot_internal/user")!
        case .cursor: url = URL(string: "https://cursor.com/api/usage-summary")!
        case .codex: throw SubscriptionError.invalidResponse
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Vibelimit", forHTTPHeaderField: "User-Agent")
        if provider == .claude {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else if provider == .cursor {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(try CursorCredentials.cookieHeader(token: token), forHTTPHeaderField: "Cookie")
        } else {
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
            request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
            request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
            request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        }
        return request
    }

    static func decode(_ data: Data, provider: SubscriptionProvider) throws -> UsageSnapshot {
        do {
            switch provider {
            case .claude:
                let payload = try JSONDecoder().decode(ClaudeUsage.self, from: data)
                let windows = [
                    payload.five_hour?.window(minutes: 300, name: "5 hour"),
                    payload.seven_day?.window(minutes: 10_080, name: "Weekly")
                ].compactMap { $0 }
                guard !windows.isEmpty else { throw SubscriptionError.invalidResponse }
                return snapshot(provider: provider, windows: windows)
            case .copilot:
                let payload = try JSONDecoder().decode(CopilotUsage.self, from: data)
                let reset = parseDate(payload.quota_reset_date)
                let quotas = [
                    ("Premium requests", payload.quota_snapshots?.premium_interactions),
                    ("Chat", payload.quota_snapshots?.chat),
                    ("Completions", payload.quota_snapshots?.completions)
                ]
                var windows: [RateLimitWindow] = []
                var notes: [String] = []
                for (name, quota) in quotas {
                    guard let quota else { continue }
                    if quota.unlimited == true {
                        notes.append("\(name): unlimited")
                    } else if let remaining = quota.remainingPercent {
                        windows.append(RateLimitWindow(
                            usedPercent: 100 - remaining, windowDurationMins: 0,
                            resetsAt: reset, name: name
                        ))
                    }
                }
                guard !windows.isEmpty || !notes.isEmpty else { throw SubscriptionError.invalidResponse }
                return snapshot(provider: provider, windows: windows, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
            case .cursor:
                return try CursorUsage.snapshot(from: data)
            case .codex: throw SubscriptionError.invalidResponse
            }
        } catch {
            throw SubscriptionError.invalidResponse
        }
    }

    private static func snapshot(provider: SubscriptionProvider, windows: [RateLimitWindow], note: String? = nil) -> UsageSnapshot {
        UsageSnapshot(buckets: [RateLimitBucket(
            limitId: provider.rawValue, limitName: provider.displayName,
            primary: windows.first, secondary: windows.dropFirst().first,
            credits: nil, planType: nil, rateLimitReachedType: nil,
            additional: windows.dropFirst(2).first, usageNote: note
        )], resetCredits: nil)
    }

    static func parseDate(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: value)?.timeIntervalSince1970
    }
}

private struct ClaudeUsage: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
        func window(minutes: Int, name: String) -> RateLimitWindow? {
            guard let utilization, utilization.isFinite, (0...100).contains(utilization) else { return nil }
            return RateLimitWindow(usedPercent: utilization, windowDurationMins: minutes,
                                   resetsAt: SubscriptionUsageClient.parseDate(resets_at), name: name)
        }
    }
    let five_hour: Window?
    let seven_day: Window?
}

private struct CopilotUsage: Decodable {
    struct Quota: Decodable {
        let percentRemaining: Double?
        let entitlement: Double?
        let remaining: Double?
        let unlimited: Bool?

        enum CodingKeys: String, CodingKey {
            case percent_remaining, entitlement, remaining, unlimited
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            func number(_ key: CodingKeys) -> Double? {
                if let value = try? values.decode(Double.self, forKey: key) { return value }
                if let value = try? values.decode(String.self, forKey: key) { return Double(value) }
                return nil
            }
            percentRemaining = number(.percent_remaining)
            entitlement = number(.entitlement)
            remaining = number(.remaining)
            unlimited = try values.decodeIfPresent(Bool.self, forKey: .unlimited)
        }
        var remainingPercent: Double? {
            guard !(entitlement == 0 && remaining == 0) else { return nil }
            let value: Double?
            if let percentRemaining { value = percentRemaining }
            else if let entitlement, entitlement > 0, let remaining {
                value = 100 * remaining / entitlement
            } else { value = nil }
            guard let value, value.isFinite else { return nil }
            return min(100, max(0, value))
        }
    }
    struct Quotas: Decodable {
        let premium_interactions: Quota?
        let chat: Quota?
        let completions: Quota?
    }
    let quota_reset_date: String?
    let quota_snapshots: Quotas?
}

// Reads only the credential locations owned by the selected provider. Never writes tokens.
enum SubscriptionCredentials {
    static func token(for provider: SubscriptionProvider, allowKeychainPrompt: Bool) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .claude:
            let directory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".claude")
            let file = directory.appendingPathComponent(".credentials.json")
            if FileManager.default.fileExists(atPath: file.path) {
                return try claudeToken(from: Data(contentsOf: file))
            }
            // A custom profile must never fall back to another account's global Keychain item.
            guard ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] == nil else {
                throw SubscriptionError.credentials("Sign in to your Claude Code profile, then retry.")
            }
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if !allowKeychainPrompt {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                throw SubscriptionError.credentials("Sign in with Claude Code, then choose Allow Claude Keychain Access in the actions menu.")
            }
            return try claudeToken(from: data)
        case .copilot:
            let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".config")
            for name in ["github-copilot/apps.json", "github-copilot/hosts.json"] {
                if let data = try? Data(contentsOf: base.appendingPathComponent(name)),
                   let token = try copilotToken(from: data, allowLegacyAppName: name.hasSuffix("apps.json")) { return token }
            }
            throw SubscriptionError.credentials("Sign in to GitHub Copilot in your editor. Vibelimit reads its local github-copilot apps.json or hosts.json credentials.")
        case .cursor:
            return try CursorCredentials.readToken(databaseURL: home.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            ))
        case .codex: throw SubscriptionError.invalidResponse
        }
    }

    static func claudeToken(from data: Data, now: Date = Date()) throws -> String {
        struct Credentials: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let expiresAt: Double?
                let scopes: [String]?
            }
            let claudeAiOauth: OAuth?
        }
        guard let oauth = try? JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth,
              !oauth.accessToken.isEmpty else {
            throw SubscriptionError.credentials("Sign in with Claude Code to make subscription usage available.")
        }
        if let expiry = oauth.expiresAt, expiry / 1_000 <= now.timeIntervalSince1970 {
            throw SubscriptionError.credentials("Claude Code's sign-in has expired. Open Claude Code to renew it, then retry.")
        }
        if let scopes = oauth.scopes, !scopes.contains("user:profile") {
            throw SubscriptionError.credentials("This Claude token cannot read usage. Sign in with Claude Code instead of using a setup token.")
        }
        return oauth.accessToken
    }

    static func copilotToken(from data: Data, allowLegacyAppName: Bool = false) throws -> String? {
        struct Entry: Decodable { let oauth_token: String? }
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return nil }
        let tokens = Set(entries.filter {
            $0.key == "github.com" || $0.key.hasPrefix("github.com:")
                || (allowLegacyAppName && $0.key == "Visual Studio Code")
        }.compactMap { $0.value.oauth_token }.filter { !$0.isEmpty })
        guard tokens.count <= 1 else {
            throw SubscriptionError.credentials("Multiple Copilot sign-ins were found. Keep one active GitHub account in your editor, then retry.")
        }
        return tokens.first
    }
}
