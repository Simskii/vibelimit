import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let attemptedDefaultKey = "didAttemptDefaultLaunchAtLogin"

    init() {
        refreshStatus()
    }

    func enableByDefaultIfNeeded() {
        guard !defaults.bool(forKey: attemptedDefaultKey) else { return }
        defaults.set(true, forKey: attemptedDefaultKey)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Launch at login couldn’t be updated."
        }
        refreshStatus()
    }

    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

