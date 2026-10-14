import Foundation
import UserNotifications

@MainActor
final class LimitNotificationManager {
    private enum DefaultsKey {
        static let enabled = "limitNotificationsEnabled"
    }

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var previousStates: [SubscriptionProvider: LimitNotificationState] = [:]

    private(set) var isEnabled: Bool

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        if defaults.object(forKey: DefaultsKey.enabled) == nil {
            defaults.set(true, forKey: DefaultsKey.enabled)
        }
        isEnabled = defaults.bool(forKey: DefaultsKey.enabled)
    }

    func start() {
        guard isEnabled else { return }
        requestAuthorization()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.enabled)
        if enabled {
            requestAuthorization()
        }
    }

    func process(snapshot: UsageSnapshot, provider: SubscriptionProvider = .codex) {
        guard let currentState = LimitNotificationEvaluator.state(for: snapshot) else {
            return
        }
        defer { previousStates[provider] = currentState }

        guard isEnabled,
              let event = LimitNotificationEvaluator.event(
                previous: previousStates[provider],
                current: currentState
              ) else {
            return
        }

        deliver(event, provider: provider)
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func deliver(_ event: LimitNotificationEvent, provider: SubscriptionProvider) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        let identifier: String
        switch event {
        case let .low(remainingPercent, resetsAt):
            identifier = "\(provider.rawValue)-limit-low"
            content.title = "\(provider.displayName) is running low"
            content.body = "\(Int(remainingPercent.rounded()))% remaining\(resetSuffix(resetsAt))"
        case let .exhausted(resetsAt):
            identifier = "\(provider.rawValue)-limit-exhausted"
            content.title = "\(provider.displayName) limit reached"
            content.body = "A \(provider.displayName) usage limit is exhausted\(resetSuffix(resetsAt))"
        case let .recovered(remainingPercent):
            identifier = "\(provider.rawValue)-limit-recovered"
            content.title = "\(provider.displayName) is available again"
            content.body = "\(Int(remainingPercent.rounded()))% capacity is now available"
        }

        center.add(
            UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
        )
    }

    private func resetSuffix(_ resetsAt: TimeInterval?) -> String {
        guard let resetsAt else { return "." }
        let countdown = DurationFormatter.countdown(
            to: Date(timeIntervalSince1970: resetsAt)
        )
        return ". Resets in \(countdown)."
    }
}
