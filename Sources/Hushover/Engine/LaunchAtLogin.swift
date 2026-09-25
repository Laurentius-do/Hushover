import Observation
import ServiceManagement

/// Registers Hushover as a login item. The system's login item list is the source of truth,
/// so the state is read back from there rather than stored in our settings.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = false
    /// Registered, but the user still has to allow it in System Settings → Login Items.
    private(set) var needsApproval = false
    private(set) var error: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
