import Foundation
import SwiftUI

struct RateLimitWindow: Codable, Equatable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: TimeInterval?
    var name: String? = nil

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    var durationLabel: String {
        DurationFormatter.windowLabel(minutes: windowDurationMins)
    }

    func resetLabel(relativeTo now: Date = Date()) -> String {
        guard let resetsAt else { return "Unknown" }
        return DurationFormatter.countdown(to: Date(timeIntervalSince1970: resetsAt), relativeTo: now)
    }
}

struct BucketCredits: Codable, Equatable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

struct RateLimitBucket: Codable, Equatable, Identifiable, Sendable {
    let limitId: String
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: BucketCredits?
    let planType: String?
    let rateLimitReachedType: String?
    var additional: RateLimitWindow? = nil
    var usageNote: String? = nil

    var id: String { limitId }

    var displayName: String {
        if limitId == "codex" {
            return "Codex"
        }
        if let limitName, !limitName.isEmpty {
            return limitName
        }
        return limitId
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var windows: [NamedRateLimitWindow] {
        var result: [NamedRateLimitWindow] = []
        if let primary {
            result.append(.init(kind: .primary, window: primary))
        }
        if let secondary {
            result.append(.init(kind: .secondary, window: secondary))
        }
        if let additional {
            result.append(.init(kind: .additional, window: additional))
        }
        return result
    }

    var primaryRemainingPercent: Double? {
        primary?.remainingPercent ?? secondary?.remainingPercent
    }
}

struct NamedRateLimitWindow: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case primary
        case secondary
        case additional
    }

    let kind: Kind
    let window: RateLimitWindow

    var id: String { kind.rawValue }
}

struct ResetCredit: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let resetType: String?
    let status: String?
    let grantedAt: TimeInterval?
    let expiresAt: TimeInterval?
    let title: String?
    let description: String?
}

struct ResetCredits: Codable, Equatable, Sendable {
    let availableCount: Int
    let credits: [ResetCredit]?
}

struct RateLimitsPayload: Decodable, Equatable, Sendable {
    let rateLimits: RateLimitBucket?
    let rateLimitsByLimitId: [String: RateLimitBucket]?
    let rateLimitResetCredits: ResetCredits?

    var sortedBuckets: [RateLimitBucket] {
        let source: [RateLimitBucket]
        if let rateLimitsByLimitId, !rateLimitsByLimitId.isEmpty {
            source = Array(rateLimitsByLimitId.values)
        } else if let rateLimits {
            source = [rateLimits]
        } else {
            source = []
        }

        return source.sorted { lhs, rhs in
            if lhs.limitId == "codex" { return true }
            if rhs.limitId == "codex" { return false }
            let lhsRemaining = lhs.primaryRemainingPercent ?? 101
            let rhsRemaining = rhs.primaryRemainingPercent ?? 101
            if lhsRemaining != rhsRemaining {
                return lhsRemaining < rhsRemaining
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

struct UsageSnapshot: Equatable, Sendable {
    let buckets: [RateLimitBucket]
    let resetCredits: ResetCredits?

    var displayBuckets: [RateLimitBucket] {
        if let codex = buckets.first(where: { $0.limitId == "codex" }) {
            return [codex]
        }
        return buckets
    }

    var menuRemainingPercent: Double? {
        if let codex = buckets.first(where: { $0.limitId == "codex" }) {
            return codex.primaryRemainingPercent
        }
        return buckets.compactMap(\.primaryRemainingPercent).min()
    }
}

struct LimitNotificationState: Equatable, Sendable {
    let remainingPercent: Double
    let isExhausted: Bool
    let resetsAt: TimeInterval?
}

enum LimitNotificationEvent: Equatable, Sendable {
    case low(remainingPercent: Double, resetsAt: TimeInterval?)
    case exhausted(resetsAt: TimeInterval?)
    case recovered(remainingPercent: Double)
}

enum LimitNotificationEvaluator {
    static let lowThreshold = 10.0

    static func state(for snapshot: UsageSnapshot) -> LimitNotificationState? {
        let bucket = snapshot.buckets.first(where: { $0.limitId == "codex" })
            ?? snapshot.buckets.first
        guard let bucket else { return nil }

        let windows = bucket.windows.map(\.window)
        guard let mostConstrained = windows.min(
            by: { $0.remainingPercent < $1.remainingPercent }
        ) else {
            return nil
        }

        return LimitNotificationState(
            remainingPercent: mostConstrained.remainingPercent,
            isExhausted: mostConstrained.remainingPercent <= 0
                || bucket.rateLimitReachedType != nil,
            resetsAt: mostConstrained.resetsAt
        )
    }

    static func event(
        previous: LimitNotificationState?,
        current: LimitNotificationState
    ) -> LimitNotificationEvent? {
        guard let previous else { return nil }

        if current.isExhausted, !previous.isExhausted {
            return .exhausted(resetsAt: current.resetsAt)
        }
        if previous.isExhausted, !current.isExhausted {
            return .recovered(remainingPercent: current.remainingPercent)
        }
        if !current.isExhausted,
           previous.remainingPercent > lowThreshold,
           current.remainingPercent <= lowThreshold {
            return .low(
                remainingPercent: current.remainingPercent,
                resetsAt: current.resetsAt
            )
        }
        return nil
    }
}

enum ConnectionState: Equatable, Sendable {
    case loading
    case connected
    case stale(String)
    case unavailable(String)

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

enum CapacityLevel: Equatable {
    case healthy
    case warning
    case critical

    init(remainingPercent: Double) {
        if remainingPercent < 10 {
            self = .critical
        } else if remainingPercent <= 25 {
            self = .warning
        } else {
            self = .healthy
        }
    }

    var color: Color {
        switch self {
        case .healthy: return Color(red: 0.24, green: 0.90, blue: 0.48)
        case .warning: return Color(red: 1.00, green: 0.72, blue: 0.22)
        case .critical: return Color(red: 1.00, green: 0.32, blue: 0.34)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .healthy: return NSColor(red: 0.24, green: 0.90, blue: 0.48, alpha: 1)
        case .warning: return NSColor(red: 1.00, green: 0.72, blue: 0.22, alpha: 1)
        case .critical: return NSColor(red: 1.00, green: 0.32, blue: 0.34, alpha: 1)
        }
    }
}

enum DurationFormatter {
    static func windowLabel(minutes: Int) -> String {
        if minutes >= 1_440, minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440)d"
        }
        if minutes >= 60, minutes.isMultiple(of: 60) {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    static func countdown(to date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "<1m"
    }
}
