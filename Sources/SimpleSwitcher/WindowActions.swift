import Cocoa

/// Actions performed ON another app's windows, via Accessibility.
///
/// AX is the only way to minimize someone else's window — there is no
/// `NSRunningApplication.minimize()`. That means calling INTO the target app, so
/// unlike the WindowServer query used for *reading* minimized state, these calls
/// can stall for as long as that app is busy. Fine here: this runs once, on
/// deliberate user input, never on the hot path — and it still runs off the main
/// thread with a bounded timeout so a beach-balling app cannot freeze Switcher.
enum WindowActions {

    /// Upper bound on how long a single AX call may block, so a hung app costs a
    /// second on a background queue instead of hanging there forever.
    private static let axTimeout: Float = 1.0

    /// Minimize EVERY window of an app.
    ///
    /// All of them, deliberately: the switcher hides an app only once none of its
    /// windows survive, so minimizing just the frontmost would leave the app in
    /// the list and make the keystroke look broken.
    ///
    /// Returns immediately; the work happens on a background queue.
    /// Already-minimized windows are skipped, and fullscreen ones simply refuse
    /// (macOS does not minimize a fullscreen window) — such an app stays listed,
    /// which is honest, since it is still on screen somewhere.
    static func minimizeAllWindows(ofPID pid: pid_t) {
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, axTimeout)

            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement] else {
                return
            }

            for window in windows {
                var minimizedValue: CFTypeRef?
                let alreadyMinimized = AXUIElementCopyAttributeValue(
                    window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success
                    && (minimizedValue as? Bool) == true
                guard !alreadyMinimized else { continue }

                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }
}
