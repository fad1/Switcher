import Foundation
import ServiceManagement

/// "Start at login" via `SMAppService` (macOS 13+). The system is the source of
/// truth for the on/off state — there is no UserDefaults key. On older macOS the
/// feature is unsupported and the Preferences checkbox is hidden.
enum LoginItem {

    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// Whether Switcher is currently registered to launch at login.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Registers/unregisters the app as a login item. Returns true on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            NSLog("Switcher: failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
            return false
        }
    }
}
