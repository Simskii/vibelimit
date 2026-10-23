import XCTest
import SQLite3
@testable import Vibelimit

final class SubscriptionConnectorTests: XCTestCase {
    func testClaudeWindowsAndFractionalReset() throws {
        let result = try decode(#"{"five_hour":{"utilization":23.5,"resets_at":"2026-10-13T12:00:00.000Z"},"seven_day":{"utilization":80,"resets_at":null}}"#, .claude)
        XCTAssertEqual(result.menuRemainingPercent, 76.5)
        XCTAssertEqual(result.buckets.first?.windows.count, 2)
        XCTAssertNotNil(result.buckets.first?.primary?.resetsAt)
        XCTAssertNil(result.buckets.first?.secondary?.resetsAt)
    }

    func testClaudeMissingSessionUsesMeasuredWeeklyWindow() throws {
        let result = try decode(#"{"five_hour":{"utilization":null},"seven_day":{"utilization":30}}"#, .claude)
        XCTAssertEqual(result.menuRemainingPercent, 70)
        XCTAssertEqual(result.buckets.first?.primary?.name, "Weekly")
    }

    func testMissingUsageNeverBecomesFullCapacity() {
        for provider in [SubscriptionProvider.claude, .copilot, .cursor] {
            XCTAssertThrowsError(try decode("{}", provider))
        }
        XCTAssertThrowsError(try decode(#"{"five_hour":{"utilization":-2}}"#, .claude))
        XCTAssertThrowsError(try decode(#"{"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":100}}}"#, .copilot))
    }

    func testCopilotNumericStringsDerivedQuotaAndUnlimited() throws {
        let result = try decode(#"{"quota_reset_date":"2026-11-01","quota_snapshots":{"premium_interactions":{"percent_remaining":"75.5"},"chat":{"entitlement":"200","remaining":"50"},"completions":{"unlimited":true}}}"#, .copilot)
        XCTAssertEqual(result.menuRemainingPercent, 75.5)
        XCTAssertEqual(result.buckets.first?.secondary?.remainingPercent, 25)
        XCTAssertNotNil(result.buckets.first?.primary?.resetsAt)
        XCTAssertEqual(result.buckets.first?.usageNote, "Completions: unlimited")
    }

    func testUnlimitedOnlyHasNoPercentageOrNotificationState() throws {
        let result = try decode(#"{"quota_snapshots":{"premium_interactions":{"unlimited":true}}}"#, .copilot)
        XCTAssertNil(result.menuRemainingPercent)
        XCTAssertNil(LimitNotificationEvaluator.state(for: result))
        XCTAssertEqual(result.buckets.first?.usageNote, "Premium requests: unlimited")
    }

    func testCopilotPreservesAllThreeQuotaLabels() throws {
        let result = try decode(#"{"quota_snapshots":{"premium_interactions":{"percent_remaining":10},"chat":{"percent_remaining":20},"completions":{"percent_remaining":30}}}"#, .copilot)
        XCTAssertEqual(result.buckets.first?.windows.map(\.window.name), ["Premium requests", "Chat", "Completions"])
        XCTAssertNil(result.buckets.first?.primary?.resetsAt)
    }

    func testCredentialParsingRejectsExpiredAndWrongScope() throws {
        let valid = Data(#"{"claudeAiOauth":{"accessToken":"test-only","expiresAt":2000000,"scopes":["user:profile"]}}"#.utf8)
        XCTAssertEqual(try SubscriptionCredentials.claudeToken(from: valid, now: Date(timeIntervalSince1970: 1000)), "test-only")
        XCTAssertThrowsError(try SubscriptionCredentials.claudeToken(from: valid, now: Date(timeIntervalSince1970: 3000)))
        let inferenceOnly = Data(#"{"claudeAiOauth":{"accessToken":"test-only","scopes":["user:inference"]}}"#.utf8)
        XCTAssertThrowsError(try SubscriptionCredentials.claudeToken(from: inferenceOnly))
    }

    func testCopilotCredentialsRejectAmbiguousAccountsAndEnterpriseHosts() throws {
        XCTAssertEqual(try SubscriptionCredentials.copilotToken(from: Data(#"{"github.com:Iv1.test":{"oauth_token":"fixture"}}"#.utf8)), "fixture")
        XCTAssertNil(try SubscriptionCredentials.copilotToken(from: Data(#"{"company.ghe.com":{"oauth_token":"fixture"}}"#.utf8)))
        XCTAssertThrowsError(try SubscriptionCredentials.copilotToken(from: Data(#"{"github.com:a":{"oauth_token":"fixture-a"},"github.com:b":{"oauth_token":"fixture-b"}}"#.utf8)))
    }

    func testLegacyCopilotAppNameIsAcceptedOnlyForAppsFile() throws {
        let data = Data(#"{"Visual Studio Code":{"oauth_token":"fixture"}}"#.utf8)
        XCTAssertNil(try SubscriptionCredentials.copilotToken(from: data))
        XCTAssertEqual(try SubscriptionCredentials.copilotToken(from: data, allowLegacyAppName: true), "fixture")
    }

    func testRequestsUseOnlyProviderEndpointsAndRequiredHeaders() throws {
        let claude = try SubscriptionUsageClient.request(for: .claude, token: "fixture")
        XCTAssertEqual(claude.url?.host, "api.anthropic.com")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        let copilot = try SubscriptionUsageClient.request(for: .copilot, token: "fixture")
        XCTAssertEqual(copilot.url?.host, "api.github.com")
        XCTAssertEqual(copilot.value(forHTTPHeaderField: "Authorization"), "token fixture")
        XCTAssertEqual(copilot.value(forHTTPHeaderField: "X-Github-Api-Version"), "2025-04-01")
        XCTAssertEqual(copilot.httpMethod, "GET")
    }

    func testCursorIncludedAndOnDemandUseSeparateCapsAndBillingReset() throws {
        let result = try decode(#"{"billingCycleEnd":"2026-11-01T00:00:00Z","individualUsage":{"plan":{"used":500,"limit":2000,"breakdown":{"total":500}},"onDemand":{"enabled":true,"used":1000,"limit":5000}}}"#, .cursor)
        XCTAssertEqual(result.menuRemainingPercent, 75)
        XCTAssertEqual(result.buckets.first?.secondary?.remainingPercent, 80)
        XCTAssertEqual(result.buckets.first?.windows.map(\.window.name), ["Included plan", "On-demand spending"])
        XCTAssertNotNil(result.buckets.first?.primary?.resetsAt)
    }

    func testCursorFractionalPercentageIsAlreadyPercent() throws {
        let result = try decode(#"{"individualUsage":{"plan":{"totalPercentUsed":0.36,"used":100,"limit":200}}}"#, .cursor)
        XCTAssertEqual(try XCTUnwrap(result.menuRemainingPercent), 99.64, accuracy: 0.0001)
    }

    func testCursorUnknownAndDisabledBudgetsDoNotInventCapacity() throws {
        for json in [#"{"individualUsage":{"plan":{"limit":2000}}}"#,
                     #"{"individualUsage":{"plan":{"used":0,"limit":0}}}"#,
                     #"{"individualUsage":{"plan":{"enabled":false,"totalPercentUsed":0}}}"#] {
            XCTAssertThrowsError(try decode(json, .cursor))
        }
        let spendingOnly = try decode(#"{"individualUsage":{"onDemand":{"enabled":true,"used":1234}}}"#, .cursor)
        XCTAssertNil(spendingOnly.menuRemainingPercent)
        XCTAssertNil(LimitNotificationEvaluator.state(for: spendingOnly))
        XCTAssertEqual(spendingOnly.buckets.first?.usageNote, "On-demand spent: US$12.34 · limit unavailable")
    }

    func testCursorPersonalCapAndOverage() throws {
        let result = try decode(#"{"individualUsage":{"overall":{"used":2500,"limit":2000}}}"#, .cursor)
        XCTAssertEqual(result.buckets.first?.primary?.name, "Personal spending limit")
        XCTAssertEqual(result.menuRemainingPercent, 0)
        XCTAssertEqual(LimitNotificationEvaluator.state(for: result)?.isExhausted, true)
        XCTAssertNil(result.buckets.first?.primary?.resetsAt)
    }

    func testCursorCookieIsBoundToEndpointAndRejectsExpiredOrMalformedTokens() throws {
        let token = cursorToken()
        let request = try SubscriptionUsageClient.request(for: .cursor, token: token)
        XCTAssertEqual(request.url?.absoluteString, "https://cursor.com/api/usage-summary")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=user_fixture%3A%3A\(token)")
        XCTAssertThrowsError(try CursorCredentials.cookieHeader(token: cursorToken(expiry: 1)))
        XCTAssertThrowsError(try CursorCredentials.cookieHeader(token: "invalid"))
        XCTAssertThrowsError(try CursorCredentials.cookieHeader(token: cursorToken(subject: "bad;cookie")))
        XCTAssertThrowsError(try CursorCredentials.cookieHeader(token: token + "\r\nInjected: value"))
    }

    func testCursorDatabaseReadDoesNotCreateOrChangeFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.vscdb")
        XCTAssertThrowsError(try CursorCredentials.readToken(databaseURL: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let token = cursorToken()
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; CREATE TABLE ItemTable (key TEXT, value BLOB); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');", nil, nil, nil), SQLITE_OK)
        // An open connection exercises live WAL reads before checkpointing.
        XCTAssertEqual(try CursorCredentials.readToken(databaseURL: url), token)
        sqlite3_close(database)
        let before = try Data(contentsOf: url)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(try CursorCredentials.readToken(databaseURL: url), token)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), filesBefore)
    }

    private func cursorToken(expiry: Double = 4102444800, subject: String = "auth0|user_fixture") -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": subject, "exp": expiry])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "fixture.\(encoded).signature"
    }

    private func decode(_ json: String, _ provider: SubscriptionProvider) throws -> UsageSnapshot {
        try SubscriptionUsageClient.decode(Data(json.utf8), provider: provider)
    }
}

@MainActor
final class SubscriptionStoreTests: XCTestCase {
    func testAutomaticChecksWaitFiveMinutesAfterFailureAndManualRefreshBypassesWait() async {
        let defaults = UserDefaults(suiteName: "VibelimitTests.\(UUID().uuidString)")!
        defaults.set("claude", forKey: "selectedProvider")
        defaults.set(false, forKey: "limitNotificationsEnabled")
        var date = Date(timeIntervalSince1970: 1_000)
        var promptPermissions: [Bool] = []
        let store = UsageStore(notificationManager: LimitNotificationManager(defaults: defaults),
            defaults: defaults, now: { date }, fetchSubscription: { _, allowPrompt in
                promptPermissions.append(allowPrompt)
                throw SubscriptionError.network
            })
        defer { store.stop() }

        store.refresh(force: false)
        await waitFor { if case .unavailable = store.state { return true }; return false }
        XCTAssertEqual(promptPermissions, [false])

        date.addTimeInterval(299)
        store.refresh(force: false)
        await Task.yield()
        XCTAssertEqual(promptPermissions.count, 1)

        date.addTimeInterval(1)
        store.refresh(force: false)
        await waitFor { if case .unavailable = store.state { return true }; return false }
        XCTAssertEqual(promptPermissions, [false, false])

        store.refresh(allowKeychainPrompt: true)
        await waitFor { if case .unavailable = store.state { return true }; return false }
        XCTAssertEqual(promptPermissions, [false, false, true])
    }

    func testLateProviderResultDoesNotReplaceSelectedProviderAndCachesStaySeparate() async throws {
        let defaults = UserDefaults(suiteName: "VibelimitTests.\(UUID().uuidString)")!
        defaults.set("claude", forKey: "selectedProvider")
        let notifications = UserDefaults(suiteName: "VibelimitNotificationsTests.\(UUID().uuidString)")!
        notifications.set(false, forKey: "limitNotificationsEnabled")
        let pending = PendingSubscriptionFetch()
        let store = UsageStore(notificationManager: LimitNotificationManager(defaults: notifications),
                               defaults: defaults, fetchSubscription: { provider, _ in
            try await pending.fetch(provider)
        })
        store.refresh()
        await pending.waitForRequest(.claude)
        store.selectProvider(.copilot)
        await pending.waitForRequest(.copilot)
        pending.resolve(.copilot, result: .success(fixture(.copilot, remaining: 60)))
        await waitFor { store.snapshot?.menuRemainingPercent == 60 }
        pending.resolve(.claude, result: .success(fixture(.claude, remaining: 20)))
        await Task.yield()
        XCTAssertEqual(store.selectedProvider, .copilot)
        XCTAssertEqual(store.snapshot?.menuRemainingPercent, 60)
        store.selectProvider(.claude)
        await waitFor { store.snapshot?.menuRemainingPercent == 20 }
        store.refresh()
        await pending.waitForRequest(.claude)
        XCTAssertEqual(store.snapshot?.menuRemainingPercent, 20)
        pending.resolve(.claude, result: .failure(SubscriptionError.network))
        await waitFor { store.state.isStale }
        XCTAssertEqual(store.snapshot?.menuRemainingPercent, 20)
        XCTAssertTrue(store.visibleProviders.contains(.claude))
        XCTAssertNotNil(store.lastUpdated)
        store.stop()
    }

    func testNoCachedDataFromOtherProviderOnFailure() async throws {
        let defaults = UserDefaults(suiteName: "VibelimitTests.\(UUID().uuidString)")!
        defaults.set("claude", forKey: "selectedProvider")
        let notifications = UserDefaults(suiteName: "VibelimitNotificationsTests.\(UUID().uuidString)")!
        notifications.set(false, forKey: "limitNotificationsEnabled")
        let store = UsageStore(notificationManager: LimitNotificationManager(defaults: notifications), defaults: defaults,
                               fetchSubscription: { provider, _ in
            if provider == .claude { return self.fixture(provider, remaining: 80) }
            throw SubscriptionError.http(401)
        })
        store.refresh()
        await waitFor { store.state == .connected }
        store.selectProvider(.copilot)
        await waitFor { if case .unavailable = store.state { return true }; return false }
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.lastUpdated)
        XCTAssertEqual(defaults.string(forKey: "selectedProvider"), "copilot")
        store.stop()
    }

    func testRefreshAllPublishesIndependentProviderSections() async {
        let defaults = UserDefaults(suiteName: "VibelimitTests.\(UUID().uuidString)")!
        defaults.set("codex", forKey: "selectedProvider")
        defaults.set(false, forKey: "limitNotificationsEnabled")
        let store = UsageStore(client: CodexAppServerClient(executableURL: nil),
            notificationManager: LimitNotificationManager(defaults: defaults), defaults: defaults,
            fetchSubscription: { provider, allowPrompt in
                XCTAssertFalse(allowPrompt)
                if provider == .copilot { throw SubscriptionError.network }
                return self.fixture(provider, remaining: provider == .claude ? 80 : 40)
            })
        XCTAssertTrue(store.visibleProviders.isEmpty)
        XCTAssertTrue(store.isDiscoveringProviders)
        store.refreshAll()
        await waitFor {
            SubscriptionProvider.allCases.allSatisfy { store.status(for: $0).state != .loading }
        }
        XCTAssertEqual(store.visibleProviders, [.claude, .cursor])
        XCTAssertFalse(store.isDiscoveringProviders)
        XCTAssertEqual(store.status(for: .claude).snapshot?.menuRemainingPercent, 80)
        XCTAssertEqual(store.status(for: .cursor).snapshot?.menuRemainingPercent, 40)
        XCTAssertNil(store.status(for: .copilot).snapshot)
        XCTAssertEqual(store.status(for: .claude).state, .connected)
        XCTAssertEqual(store.status(for: .cursor).state, .connected)
        XCTAssertEqual(store.selectedProvider, .codex)
        XCTAssertNil(store.snapshot)
        store.stop()
    }

    private func fixture(_ provider: SubscriptionProvider, remaining: Double) -> UsageSnapshot {
        UsageSnapshot(buckets: [RateLimitBucket(limitId: provider.rawValue,
            limitName: provider.displayName,
            primary: RateLimitWindow(usedPercent: 100 - remaining, windowDurationMins: 300, resetsAt: nil),
            secondary: nil, credits: nil, planType: nil, rateLimitReachedType: nil)], resetCredits: nil)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for subscription state")
    }
}

@MainActor
private final class PendingSubscriptionFetch {
    private var requests: [SubscriptionProvider: CheckedContinuation<UsageSnapshot, Error>] = [:]

    func fetch(_ provider: SubscriptionProvider) async throws -> UsageSnapshot {
        try await withCheckedThrowingContinuation { requests[provider] = $0 }
    }
    func resolve(_ provider: SubscriptionProvider, result: Result<UsageSnapshot, Error>) {
        requests.removeValue(forKey: provider)?.resume(with: result)
    }
    func waitForRequest(_ provider: SubscriptionProvider) async {
        for _ in 0..<100 {
            if requests[provider] != nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for subscription request")
    }
}
