import AppKit
import SwiftUI

struct PanelContentView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginManager

    private let panelBackground = Color(red: 0.025, green: 0.028, blue: 0.032)
    private let secondaryText = Color.white.opacity(0.42)

    var body: some View {
        VStack(spacing: 0) {
            header

            content

            Divider()
                .overlay(Color.white.opacity(0.06))
                .padding(.horizontal, 18)
            footer
        }
        .frame(width: 344)
        .fixedSize(horizontal: false, vertical: true)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(usageStore.snapshot?.displayBuckets.first?.displayName ?? "Codex")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))

                if let lastUpdated = usageStore.lastUpdated {
                    Text("Updated \(lastUpdated, style: .relative)")
                } else if usageStore.state == .loading {
                    Text("Updating…")
                } else {
                    Text("Limits unavailable")
                }
            }

            Spacer()

            if let snapshot = usageStore.snapshot {
                if let remaining = snapshot.displayBuckets.first?.primaryRemainingPercent {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            CapacityLevel(remainingPercent: remaining).color
                        )
                }
            }

            if usageStore.state == .loading {
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
        if let snapshot = usageStore.snapshot {
            VStack(spacing: 13) {
                if let bucket = snapshot.displayBuckets.first {
                    ForEach(bucket.windows) { namedWindow in
                        LimitWindowSection(namedWindow: namedWindow)
                    }
                }

                if case let .stale(message) = usageStore.state {
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
            if usageStore.state == .loading {
                Text("Connecting to Codex…")
                    .foregroundStyle(Color.white.opacity(0.76))
            } else {
                Text("Limits unavailable")
                    .foregroundStyle(Color.white.opacity(0.82))

                if case let .unavailable(message) = usageStore.state {
                    Text(message)
                        .foregroundStyle(secondaryText)
                        .multilineTextAlignment(.center)
                }

                Button("Retry") {
                    usageStore.refresh()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.24, green: 0.90, blue: 0.48))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 24)
    }

    private func staleNotice(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Cached data · \(message)")
                .lineLimit(1)
            Spacer()
            Button("Retry") { usageStore.refresh() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Color(red: 1.00, green: 0.72, blue: 0.22).opacity(0.84))
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let count = usageStore.snapshot?.resetCredits?.availableCount {
                Label(
                    "\(count) reset credit\(count == 1 ? "" : "s")",
                    systemImage: "arrow.counterclockwise.circle"
                )
            } else {
                Label("read only", systemImage: "lock.fill")
            }

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
                usageStore.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
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
                Text("Resets in \(namedWindow.window.resetLabel())")
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
