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

    /// Minimize every window of an app that Accessibility can reach.
    ///
    /// All of them rather than just the frontmost, deliberately: the switcher
    /// drops an app only once none of its windows survive, so a partial minimize
    /// would leave it in the list and make the keystroke look broken.
    ///
    /// **`kAXWindows` only returns windows on the CURRENT Space** (measured
    /// 2026-08-09: Ghostty reported 2 AX windows against ~22 real ones parked on
    /// other Spaces; Brave reported 17, matching its 16 on-screen plus 1
    /// minimized). Windows on other Spaces therefore stay open and the app
    /// returns to the switcher on the next Cmd+Tab. AX cannot reach them without
    /// switching Spaces, so this is a limit of the API, not something to fix here.
    ///
    /// Returns immediately; the work happens on a background queue.
    /// Already-minimized windows are skipped, and fullscreen ones simply refuse
    /// (macOS does not minimize a fullscreen window) — such an app stays listed,
    /// which is honest, since it is still on screen somewhere.
    ///
    /// Issuing the calls is not the slow part: all 12 windows of a test app took
    /// 2.8ms to issue, then ~6s for macOS to animate them into the Dock one at a
    /// time. Issuing them concurrently instead changed the total by <10%, so the
    /// sequential loop stays — the animation is the WindowServer's and is not
    /// ours to parallelize.
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
