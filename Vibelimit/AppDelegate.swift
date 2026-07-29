import AppKit
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let usageStore = UsageStore()
    private let launchAtLogin = LaunchAtLoginManager()
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Vibelimit must remain available in the menu bar."
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp])
            button.toolTip = "Vibelimit"
        }

        panelController = PanelController(
            usageStore: usageStore,
            launchAtLogin: launchAtLogin,
            statusButton: statusItem.button
        )

        usageStore.$snapshot
            .combineLatest(usageStore.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, state in
                self?.updateStatusItem(snapshot: snapshot, state: state)
            }
            .store(in: &cancellables)

        usageStore.start()
        if isInstalledApplication {
            launchAtLogin.enableByDefaultIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageStore.stop()
        panelController.close()
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if panelController.isVisible {
            panelController.close()
        } else {
            usageStore.refresh()
            panelController.show(relativeTo: button)
        }
    }

    private func updateStatusItem(snapshot: UsageSnapshot?, state: ConnectionState) {
        guard let button = statusItem.button else { return }

        let remaining = snapshot?.menuRemainingPercent
        let value: String
        if let remaining {
            value = "\(Int(remaining.rounded()))%"
        } else if state == .loading {
            value = "···"
        } else {
            value = "—"
        }

        let symbol = state.isStale ? "sparkles.square.filled.on.square" : "sparkles"
        button.image = makeStatusImage(symbolName: symbol, value: value)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.toolTip = state.isStale ? "Vibelimit — showing cached limits" : "Vibelimit — \(value) remaining"
    }

    private func makeStatusImage(symbolName: String, value: String) -> NSImage? {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Vibelimit"
        )?.withSymbolConfiguration(symbolConfig) else {
            return nil
        }

        symbol.isTemplate = false
        let text = " \(value)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let symbolSize = NSSize(width: 12, height: 12)
        let imageSize = NSSize(
            width: ceil(symbolSize.width + textSize.width),
            height: 18
        )
        let image = NSImage(size: imageSize, flipped: false) { rect in
            symbol.draw(
                in: NSRect(
                    x: 0,
                    y: floor((rect.height - symbolSize.height) / 2),
                    width: symbolSize.width,
                    height: symbolSize.height
                )
            )
            text.draw(
                at: NSPoint(
                    x: symbolSize.width,
                    y: floor((rect.height - textSize.height) / 2)
                ),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Vibelimit \(value) remaining"
        return image
    }

    private var isInstalledApplication: Bool {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let systemApplication = URL(fileURLWithPath: "/Applications/Vibelimit.app")
            .standardizedFileURL
        let userApplication = FileManager.default.urls(
            for: .applicationDirectory,
            in: .userDomainMask
        )
        .first?
        .appendingPathComponent("Vibelimit.app")
        .standardizedFileURL

        return bundleURL == systemApplication || bundleURL == userApplication
    }
}
