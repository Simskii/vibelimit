import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var state: ConnectionState = .loading
    @Published private(set) var lastUpdated: Date?

    private let client: CodexAppServerClient
    private let notificationManager: LimitNotificationManager
    private var refreshTimer: Timer?
    private var refreshInFlight = false

    var notificationsEnabled: Bool {
        notificationManager.isEnabled
    }

    init(
        client: CodexAppServerClient = CodexAppServerClient(),
        notificationManager: LimitNotificationManager? = nil
    ) {
        self.client = client
        self.notificationManager = notificationManager ?? LimitNotificationManager()
        client.onRateLimitsChanged = { [weak self] in
            self?.refresh()
        }
        client.onProcessExit = { [weak self] error in
            self?.handleFailure(error)
        }
    }

    func start() {
        notificationManager.start()
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        if snapshot == nil {
            state = .loading
        }

        client.refresh { [weak self] result in
            guard let self else { return }
            self.refreshInFlight = false
            switch result {
            case let .success(payload):
                let buckets = payload.sortedBuckets
                guard !buckets.isEmpty else {
                    self.handleFailure(.invalidResponse)
                    return
                }
                let snapshot = UsageSnapshot(
                    buckets: buckets,
                    resetCredits: payload.rateLimitResetCredits
                )
                self.snapshot = snapshot
                self.notificationManager.process(snapshot: snapshot)
                self.lastUpdated = Date()
                self.state = .connected
            case let .failure(error):
                self.handleFailure(error)
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        client.stop()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationManager.setEnabled(enabled)
        objectWillChange.send()
    }

    private func handleFailure(_ error: CodexClientError) {
        refreshInFlight = false
        let message = error.localizedDescription
        if snapshot == nil {
            state = .unavailable(message)
        } else {
            state = .stale(message)
        }
    }
}
