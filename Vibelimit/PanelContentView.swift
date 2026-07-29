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
            Divider()
                .overlay(Color.white.opacity(0.07))
                .padding(.horizontal, 16)

            content

            Divider()
                .overlay(Color.white.opacity(0.06))
                .padding(.horizontal, 16)
            footer
        }
        .frame(width: 380)
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
        HStack(spacing: 14) {
            if let snapshot = usageStore.snapshot {
                ForEach(Array(snapshot.displayBuckets.prefix(2))) { bucket in
                    SummaryMetric(bucket: bucket)
                }
                if snapshot.displayBuckets.count > 2 {
                    Text("+\(snapshot.displayBuckets.count - 2)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(secondaryText)
                }
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(secondaryText)
                Text("reading codex limits")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(secondaryText)
            }

            Spacer(minLength: 4)

            if usageStore.state == .loading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            actionsMenu
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = usageStore.snapshot {
            VStack(spacing: 0) {
                ForEach(snapshot.displayBuckets) { bucket in
                    LimitRow(bucket: bucket)
                    if bucket.id != snapshot.displayBuckets.last?.id {
                        Divider()
                            .overlay(Color.white.opacity(0.045))
                            .padding(.leading, 34)
                    }
                }

                if case let .stale(message) = usageStore.state {
                    staleNotice(message)
                }
            }
            .padding(.vertical, 4)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.025))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let count = usageStore.snapshot?.resetCredits?.availableCount {
                Label("\(count) reset\(count == 1 ? "" : "s")", systemImage: "arrow.counterclockwise.circle")
            } else {
                Label("read only", systemImage: "lock.fill")
            }

            Spacer()

            if let lastUpdated = usageStore.lastUpdated {
                Text("updated \(lastUpdated, style: .relative)")
            }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 34)
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
                .foregroundStyle(Color.white.opacity(0.38))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(launchAtLogin.errorMessage ?? "Vibelimit actions")
    }
}

private struct SummaryMetric: View {
    let bucket: RateLimitBucket

    var body: some View {
        if let window = bucket.primary ?? bucket.secondary {
            HStack(spacing: 5) {
                Image(systemName: bucket.limitId == "codex" ? "sparkles" : "bolt.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(level.color)

                Text(window.durationLabel)
                    .foregroundStyle(Color.white.opacity(0.66))
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .foregroundStyle(level.color)
                Text("↗ \(window.resetLabel())")
                    .foregroundStyle(Color.white.opacity(0.34))
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .lineLimit(1)
        }
    }

    private var level: CapacityLevel {
        CapacityLevel(remainingPercent: bucket.primaryRemainingPercent ?? 0)
    }
}

private struct LimitRow: View {
    let bucket: RateLimitBucket

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(level.color)
                .frame(width: 6, height: 6)
                .shadow(color: level.color.opacity(0.4), radius: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(bucket.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)

                if let window = bucket.primary ?? bucket.secondary {
                    Text(resetDescription(for: window))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.34))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                ForEach(bucket.windows) { namedWindow in
                    WindowMetric(namedWindow: namedWindow)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }

    private var level: CapacityLevel {
        CapacityLevel(remainingPercent: bucket.primaryRemainingPercent ?? 0)
    }

    private func resetDescription(for window: RateLimitWindow) -> String {
        let date = Date(timeIntervalSince1970: window.resetsAt)
        let absolute = date.formatted(
            Date.FormatStyle()
                .weekday(.abbreviated)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
        return "resets \(absolute) · in \(window.resetLabel())"
    }
}

private struct WindowMetric: View {
    let namedWindow: NamedRateLimitWindow

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Int(namedWindow.window.remainingPercent.rounded()))%")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(level.color)

            Text(namedWindow.window.durationLabel)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.34))
        }
        .frame(minWidth: 30, alignment: .trailing)
    }

    private var level: CapacityLevel {
        CapacityLevel(remainingPercent: namedWindow.window.remainingPercent)
    }
}
