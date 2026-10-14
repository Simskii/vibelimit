import Foundation
import SQLite3

// Protocol reference: github.com/steipete/CodexBar, Providers/Cursor.
// Only the signed-in Cursor app is consulted; no browser cookies are imported.
enum CursorCredentials {
    static func readToken(databaseURL: URL) throws -> String {
        let message = "Open Cursor and sign in, then retry. Vibelimit needs access to Cursor's local sign-in database."
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw SubscriptionError.credentials(message)
        }
        let hasWAL = FileManager.default.fileExists(atPath: databaseURL.path + "-wal")
        let hasSHM = FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
        // Immutable mode avoids creating sidecars for an idle WAL database. Never
        // use it with an active WAL, where the newest sign-in may not be checkpointed.
        guard hasWAL == hasSHM else { throw SubscriptionError.credentials("Cursor's sign-in database is busy. Try again shortly.") }
        let location = hasWAL ? databaseURL.path : databaseURL.absoluteString + "?immutable=1"
        var database: OpaquePointer?
        let status = sqlite3_open_v2(location, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { if let database { sqlite3_close(database) } }
        guard status == SQLITE_OK else { throw SubscriptionError.credentials(message) }
        sqlite3_busy_timeout(database, 250)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1",
            -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else {
            throw SubscriptionError.credentials(message)
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        // A UTF-16LE BLOB can also decode as UTF-8 containing NULs. Reject that
        // interpretation and try UTF-16LE before validating the JWT.
        let token = [String(data: data, encoding: .utf8), String(data: data, encoding: .utf16LittleEndian)]
            .compactMap { $0 }.first { !$0.contains("\0") && !$0.isEmpty }
        guard let token else { throw SubscriptionError.credentials(message) }
        return token
    }

    static func cookieHeader(token: String, now: Date = Date()) throws -> String {
        let message = "Cursor's sign-in is invalid or expired. Open Cursor to sign in again, then retry."
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty }),
              token.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SubscriptionError.credentials(message)
        }
        var encoded = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        struct Claims: Decodable { let sub: String; let exp: Double }
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONDecoder().decode(Claims.self, from: data),
              claims.exp.isFinite, claims.exp > now.timeIntervalSince1970 + 60,
              let user = claims.sub.split(separator: "|").last,
              !user.isEmpty, user.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SubscriptionError.credentials(message)
        }
        return "WorkosCursorSessionToken=\(user)%3A%3A\(token)"
    }
}

struct CursorUsage: Decodable {
    struct Budget: Decodable {
        let enabled: Bool?
        let used: Double?
        let limit: Double?
        let totalPercentUsed: Double?

        var percentUsed: Double? {
            guard enabled != false else { return nil }
            if let totalPercentUsed, totalPercentUsed.isFinite, totalPercentUsed >= 0 {
                return totalPercentUsed
            }
            guard let used, used.isFinite, used >= 0,
                  let limit, limit.isFinite, limit > 0 else { return nil }
            let percent = 100 * (used / limit)
            return percent.isFinite ? percent : nil
        }
    }
    struct Individual: Decodable {
        let plan: Budget?
        let overall: Budget?
        let onDemand: Budget?
    }
    let billingCycleEnd: String?
    let individualUsage: Individual?

    static func snapshot(from data: Data) throws -> UsageSnapshot {
        let usage = try JSONDecoder().decode(Self.self, from: data)
        let reset = SubscriptionUsageClient.parseDate(usage.billingCycleEnd)
        var windows: [RateLimitWindow] = []
        let budgets = [
            ("Included plan", usage.individualUsage?.plan),
            ("Personal spending limit", usage.individualUsage?.overall),
            ("On-demand spending", usage.individualUsage?.onDemand)
        ]
        var notes: [String] = []
        for (name, budget) in budgets {
            guard let budget, budget.enabled != false else { continue }
            if let percent = budget.percentUsed {
                windows.append(RateLimitWindow(usedPercent: percent, windowDurationMins: 0, resetsAt: reset, name: name))
            } else if name == "On-demand spending", let used = budget.used, used.isFinite, used >= 0 {
                // Spending without a cap is a monetary counter, not remaining capacity.
                notes.append(String(format: "On-demand spent: US$%.2f · limit unavailable", used / 100))
            }
        }
        guard !windows.isEmpty || !notes.isEmpty else { throw SubscriptionError.invalidResponse }
        return UsageSnapshot(buckets: [RateLimitBucket(
            limitId: "cursor", limitName: "Cursor", primary: windows.first,
            secondary: windows.dropFirst().first, credits: nil, planType: nil,
            rateLimitReachedType: nil, additional: windows.dropFirst(2).first,
            usageNote: notes.isEmpty ? nil : notes.joined(separator: "\n")
        )], resetCredits: nil)
    }
}
