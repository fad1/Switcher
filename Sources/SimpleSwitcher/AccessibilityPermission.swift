import ApplicationServices

/// Thin wrapper around the macOS Accessibility (AX) trust APIs.
///
/// The CGEvent tap that drives Switcher requires Accessibility permission. We
/// must never disable the native Cmd+Tab until this is granted, otherwise the
/// user is left with no working switcher (see AppDelegate's gating logic).
enum AccessibilityPermission {

    /// Whether this process currently has Accessibility permission. Cheap and
    /// thread-safe; safe to call from a background timer.
    ///
    /// Caches per process: after permission is REVOKED, macOS keeps reporting a
    /// running app as trusted until it relaunches. Grant detection (the path that
    /// matters) works; revoke detection largely does not, so nothing may depend
    /// on it firing.
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Triggers the standard macOS Accessibility prompt and registers the app in
    /// the Accessibility list. The system shows the dialog at most once per
    /// process lifetime, so this is safe to call once at launch. Poll `isGranted`
    /// thereafter — do NOT call this from a timer.
    @discardableResult
    static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: kCFBooleanTrue as Any] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
