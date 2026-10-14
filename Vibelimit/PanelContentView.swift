import AppKit
import SwiftUI

struct PanelContentView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginManager

    var panelHeight: CGFloat = 620

    private let panelBackground = Color(red: 0.025, green: 0.028, blue: 0.032)
    private let secondaryText = Color.white.opacity(0.42)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Subscriptions")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { usageStore.refreshAll() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh all subscriptions")
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(18)

            ScrollView {
                VStack(spacing: 0) {
                    if usageStore.visibleProviders.isEmpty {
                        VStack(spacing: 10) {
                            if usageStore.isDiscoveringProviders {
                                ProgressView().controlSize(.small)
                                Text("Looking for subscriptions…")
                            } else {
                                Text("No connected subscriptions")
                                    .foregroundStyle(Color.white.opacity(0.86))
                                Text("Sign in to a supported app, then refresh. Claude may need Keychain access from the actions menu.")
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                    }
                    ForEach(usageStore.visibleProviders) { provider in
                        ProviderUsageSection(usageStore: usageStore, provider: provider)
                        if provider != usageStore.visibleProviders.last {
                            Divider()
                                .overlay(Color.white.opacity(0.06))
                                .padding(.horizontal, 18)
                        }
                    }
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.06))
                .padding(.horizontal, 18)
            footer
        }
        .frame(width: 344, height: panelHeight)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelBackground.opacity(0.985))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.62), radius: 24, y: 14)
        .environment(\.colorScheme, .dark)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label("read only", systemImage: "lock.fill")

            Spacer()

            actionsMenu
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(secondaryText)
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 38)
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                usageStore.refreshAll()
            } label: {
                Label("Refresh all", systemImage: "arrow.clockwise")
            }

            Menu("Menu bar subscription") {
                ForEach(SubscriptionProvider.allCases) { provider in
                    Button {
                        usageStore.selectProvider(provider)
                    } label: {
                        if usageStore.selectedProvider == provider {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
            }

            Button("Allow Claude Keychain Access") {
                usageStore.refresh(provider: .claude, allowKeychainPrompt: true)
            }

            Button {
                launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            } label: {
                Label(
                    launchAtLogin.isEnabled ? "Disable Launch at Login" : "Launch at Login",
                    systemImage: launchAtLogin.isEnabled ? "checkmark.circle.fill" : "circle"
                )
            }

            Button {
                usageStore.setNotificationsEnabled(!usageStore.notificationsEnabled)
            } label: {
                Label(
                    usageStore.notificationsEnabled ? "Disable Notifications" : "Enable Notifications",
                    systemImage: usageStore.notificationsEnabled ? "bell.fill" : "bell.slash"
                )
            }

            Divider()

            Button("Quit Vibelimit") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.48))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(launchAtLogin.errorMessage ?? "Vibelimit actions")
    }
}

private struct ProviderUsageSection: View {
    @ObservedObject var usageStore: UsageStore
    let provider: SubscriptionProvider
    private let secondaryText = Color.white.opacity(0.42)
    private var status: UsageStore.ProviderState { usageStore.status(for: provider) }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))

                if let lastUpdated = status.lastUpdated {
                    Text("Updated \(lastUpdated, style: .relative)")
                } else if status.state == .loading {
                    Text("Updating…")
                } else {
                    Text("Limits unavailable")
                }
            }

            Spacer()

            if let snapshot = status.snapshot {
                if let remaining = snapshot.displayBuckets.first?.primaryRemainingPercent {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            CapacityLevel(remainingPercent: remaining).color
                        )
                }
            }

            if status.state == .loading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
            }
        }
        .font(.system(size: 10, weight: .regular))
        .foregroundStyle(secondaryText)
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = status.snapshot {
            VStack(spacing: 13) {
                if let bucket = snapshot.displayBuckets.first {
                    ForEach(bucket.windows) { namedWindow in
                        LimitWindowSection(namedWindow: namedWindow)
                    }
                    if let count = status.snapshot?.resetCredits?.availableCount {
                        Text("\(count) reset credit\(count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryText)
                    }
                    if let note = bucket.usageNote {
                        Text(note)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if case let .stale(message) = status.state {
                    staleNotice(message)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if status.state == .loading {
                Text("Connecting to \(provider.displayName)…")
                    .foregroundStyle(Color.white.opacity(0.76))
            } else {
                Text("Limits unavailable")
                    .foregroundStyle(Color.white.opacity(0.82))

                if case let .unavailable(message) = status.state {
                    Text(message)
                        .foregroundStyle(secondaryText)
                        .multilineTextAlignment(.center)
                }

                Button("Retry") {
                    usageStore.refresh(provider: provider)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.24, green: 0.90, blue: 0.48))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 24)
    }

    private func staleNotice(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Cached data · \(message)")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry") { usageStore.refresh(provider: provider) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Color(red: 1.00, green: 0.72, blue: 0.22).opacity(0.84))
        .padding(.top, 2)
    }

}

private struct LimitWindowSection: View {
    let namedWindow: NamedRateLimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(level.color.opacity(0.82))
                        .frame(
                            width: proxy.size.width
                                * (namedWindow.window.remainingPercent / 100)
                        )
                }
            }
            .frame(height: 5)

            HStack {
                Text("\(Int(namedWindow.window.remainingPercent.rounded()))% remaining")
                    .foregroundStyle(Color.white.opacity(0.68))
                Spacer()
                Text(namedWindow.window.resetsAt == nil ? "Reset unavailable" : "Resets in \(namedWindow.window.resetLabel())")
                    .foregroundStyle(Color.white.opacity(0.42))
            }
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
        }
    }

    private var level: CapacityLevel {
        CapacityLevel(remainingPercent: namedWindow.window.remainingPercent)
    }

    private var title: String {
        if let name = namedWindow.window.name { return name }
        let minutes = namedWindow.window.windowDurationMins
        if minutes == 10_080 {
            return "Weekly"
        }
        if minutes >= 1_440, minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440) day"
        }
        if minutes >= 60, minutes.isMultiple(of: 60) {
            return "\(minutes / 60) hour"
        }
        return "\(minutes) minute"
    }
}
