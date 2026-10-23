import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var state: ConnectionState = .loading
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var selectedProvider: SubscriptionProvider

    struct ProviderState {
        var snapshot: UsageSnapshot?
        var state: ConnectionState = .loading
        var lastUpdated: Date?
    }
    @Published private(set) var providers: [SubscriptionProvider: ProviderState] = [:]
    private let client: CodexAppServerClient
    private let fetchSubscription: (SubscriptionProvider, Bool) async throws -> UsageSnapshot
    private let notificationManager: LimitNotificationManager
    private let defaults: UserDefaults
    private var refreshTimer: Timer?
    private var refreshing = Set<SubscriptionProvider>()
    private var tasks: [SubscriptionProvider: Task<Void, Never>] = [:]
    private var stopped = false
    private static let refreshInterval: TimeInterval = 300
    private var lastRefreshAttempt: [SubscriptionProvider: Date] = [:]
    private let now: () -> Date

    var visibleProviders: [SubscriptionProvider] {
        SubscriptionProvider.allCases.filter { providers[$0]?.snapshot != nil }
    }

    var isDiscoveringProviders: Bool {
        SubscriptionProvider.allCases.contains { status(for: $0).state == .loading }
    }

    var notificationsEnabled: Bool { notificationManager.isEnabled }

    init(
        client: CodexAppServerClient = CodexAppServerClient(),
        notificationManager: LimitNotificationManager? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetchSubscription: @escaping (SubscriptionProvider, Bool) async throws -> UsageSnapshot = {
            try await SubscriptionUsageClient().fetch($0, allowKeychainPrompt: $1)
        }
    ) {
        self.client = client
        self.defaults = defaults
        self.now = now
        self.fetchSubscription = fetchSubscription
        self.notificationManager = notificationManager ?? LimitNotificationManager()
        selectedProvider = SubscriptionProvider(rawValue: defaults.string(forKey: "selectedProvider") ?? "") ?? .codex
        client.onRateLimitsChanged = { [weak self] in
            self?.refresh(provider: .codex)
        }
        client.onProcessExit = { [weak self] error in
            self?.handleFailure(error, provider: .codex)
        }
    }

    func selectProvider(_ provider: SubscriptionProvider) {
        guard selectedProvider != provider else { return }
        selectedProvider = provider
        defaults.set(provider.rawValue, forKey: "selectedProvider")
        publishSelectedProvider()
        refresh(force: false)
    }

    func start() {
        stopped = false
        notificationManager.start()
        refreshAll(force: false)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll(force: false) }
        }
    }

    func refreshAll(force: Bool = true) {
        for provider in SubscriptionProvider.allCases { refresh(provider: provider, force: force) }
    }

    func status(for provider: SubscriptionProvider) -> ProviderState {
        providers[provider] ?? ProviderState()
    }

    func refresh(provider: SubscriptionProvider? = nil, allowKeychainPrompt: Bool = false, force: Bool = true) {
        let provider = provider ?? selectedProvider
        guard !stopped else { return }
        let attemptDate = now()
        if !force, let lastAttempt = lastRefreshAttempt[provider],
           attemptDate.timeIntervalSince(lastAttempt) < Self.refreshInterval { return }
        guard refreshing.insert(provider).inserted else { return }
        lastRefreshAttempt[provider] = attemptDate
        if providers[provider]?.snapshot == nil {
            providers[provider, default: ProviderState()].state = .loading
            publishSelectedProvider()
        }
        if provider == .codex {
            client.refresh { [weak self] result in
                guard let self, !self.stopped else { return }
                switch result {
                case let .success(payload):
                    guard !payload.sortedBuckets.isEmpty else {
                        self.handleFailure(CodexClientError.invalidResponse, provider: provider)
                        return
                    }
                    self.handleSuccess(UsageSnapshot(buckets: payload.sortedBuckets,
                        resetCredits: payload.rateLimitResetCredits), provider: provider)
                case let .failure(error): self.handleFailure(error, provider: provider)
                }
            }
        } else {
            tasks[provider] = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.fetchSubscription(provider, allowKeychainPrompt)
                    guard !Task.isCancelled, !self.stopped else { return }
                    self.handleSuccess(result, provider: provider)
                } catch {
                    guard !Task.isCancelled, !self.stopped else { return }
                    self.handleFailure(error, provider: provider)
                }
                self.tasks[provider] = nil
            }
        }
    }

    func stop() {
        stopped = true
        refreshTimer?.invalidate()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        refreshing.removeAll()
        client.stop()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationManager.setEnabled(enabled)
        objectWillChange.send()
    }

    private func handleSuccess(_ snapshot: UsageSnapshot, provider: SubscriptionProvider) {
        refreshing.remove(provider)
        providers[provider] = ProviderState(snapshot: snapshot, state: .connected, lastUpdated: Date())
        notificationManager.process(snapshot: snapshot, provider: provider)
        if selectedProvider == provider { publishSelectedProvider() }
    }

    private func handleFailure(_ error: Error, provider: SubscriptionProvider) {
        guard !stopped else { return }
        refreshing.remove(provider)
        let message = (error as? LocalizedError)?.errorDescription ?? "Usage is unavailable. Try again."
        var value = providers[provider] ?? ProviderState()
        value.state = value.snapshot == nil ? .unavailable(message) : .stale(message)
        providers[provider] = value
        if selectedProvider == provider { publishSelectedProvider() }
    }

    private func publishSelectedProvider() {
        let value = providers[selectedProvider] ?? ProviderState()
        snapshot = value.snapshot
        state = value.state
        lastUpdated = value.lastUpdated
    }
}
