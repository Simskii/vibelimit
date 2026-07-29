import AppKit
import Combine
import SwiftUI

private final class VibelimitPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    private static let panelWidth: CGFloat = 344

    private let panel: VibelimitPanel
    private let hostingView: NSHostingView<PanelContentView>
    private weak var statusButton: NSStatusBarButton?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var layoutUpdateScheduled = false
    private var cancellables = Set<AnyCancellable>()

    var isVisible: Bool { panel.isVisible }

    init(
        usageStore: UsageStore,
        launchAtLogin: LaunchAtLoginManager,
        statusButton: NSStatusBarButton?
    ) {
        self.statusButton = statusButton
        hostingView = NSHostingView(
            rootView: PanelContentView(
                usageStore: usageStore,
                launchAtLogin: launchAtLogin
            )
        )

        panel = VibelimitPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 190),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow

        usageStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.scheduleLayoutUpdate()
            }
            .store(in: &cancellables)
    }

    func show(relativeTo button: NSStatusBarButton) {
        statusButton = button
        resizeAndPosition()
        panel.orderFrontRegardless()
        panel.makeKey()
        installEventMonitors()
    }

    func close() {
        panel.orderOut(nil)
        removeEventMonitors()
    }

    private func resizeAndPosition() {
        guard let button = statusButton,
              let buttonWindow = button.window else { return }

        let measuredHeight = hostingView.fittingSize.height
        let height = min(420, max(148, measuredHeight))
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero

        var originX = buttonRectOnScreen.midX - (Self.panelWidth / 2)
        originX = min(
            max(originX, visibleFrame.minX + 8),
            visibleFrame.maxX - Self.panelWidth - 8
        )
        let originY = buttonRectOnScreen.minY - height - 7

        panel.setFrame(
            NSRect(x: originX, y: originY, width: Self.panelWidth, height: height),
            display: true,
            animate: false
        )
    }

    private func scheduleLayoutUpdate() {
        guard !layoutUpdateScheduled else { return }
        layoutUpdateScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutUpdateScheduled = false
            self.resizeAndPosition()
        }
    }

    private func installEventMonitors() {
        removeEventMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            let panelWindow = self.panel.windowNumber
            let statusWindow = self.statusButton?.window?.windowNumber
            if event.windowNumber != panelWindow, event.windowNumber != statusWindow {
                self.close()
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}
