import Cocoa
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate, HotkeyManagerDelegate, AppSwitcherPanelDelegate {

    enum State {
        case idle
        case active
    }

    private var state: State = .idle
    private var hotkeyManager: HotkeyManager!
    private var panel: AppSwitcherPanel!
    private var currentApps: [AppInfo] = []
    private var statusBarController: StatusBarController!
    private var prefsWindowController: PreferencesWindowController!

    // True once we've taken over Cmd+Tab (event tap live + native Cmd+Tab disabled).
    private var switchingEnabled = false
    // Background monitor that reconciles Accessibility permission state.
    private let permissionQueue = DispatchQueue(label: "com.simpleswitcher.permission")
    private var permissionTimer: DispatchSourceTimer?
    // Polls for newly-opened apps while the panel is shown, so their icons appear as
    // soon as their windows render (see startAppListRefresh).
    private var appListRefreshTimer: DispatchSourceTimer?
    private var activityToken: NSObjectProtocol?
    private var isHandlingRevocation = false

    // Key codes
    private let kVK_Tab: UInt16 = 0x30
    private let kVK_Escape: UInt16 = 0x35
    private let kVK_Return: UInt16 = 0x24
    private let kVK_LeftArrow: UInt16 = 0x7B
    private let kVK_RightArrow: UInt16 = 0x7C
    private let kVK_UpArrow: UInt16 = 0x7E
    private let kVK_DownArrow: UInt16 = 0x7D
    private let kVK_H: UInt16 = 0x04
    private let kVK_Q: UInt16 = 0x0C

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start tracking app activation order
        AppListProvider.startObserving()

        // Setup hotkey manager (does NOT take over Cmd+Tab yet — see enableSwitching)
        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self

        // Create panel (hidden initially)
        panel = AppSwitcherPanel()
        panel.panelDelegate = self

        // Set app to accessory (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Settings: register in-process fallbacks before any read, then count this launch.
        Preferences.registerDefaults()
        Preferences.launchCount += 1

        // Menu bar icon (optional, controlled by preferences). Provides a Quit
        // escape hatch even while we're waiting for Accessibility permission.
        statusBarController = StatusBarController()
        statusBarController.onOpenPreferences = { [weak self] in self?.showPreferences() }
        statusBarController.onHideOtherApps = { [weak self] in self?.hideOtherApps() }
        refreshStatusItem()

        // Preferences window (reusable single instance, hidden until requested)
        prefsWindowController = PreferencesWindowController()
        prefsWindowController.onToggleMenuBar = { [weak self] _ in self?.refreshStatusItem() }

        // Start silently; only surface the window when it's time to nag.
        maybeShowDonationNag()

        // Only take over Cmd+Tab once Accessibility permission is confirmed. Until
        // then, native Cmd+Tab is left working — so a first launch without
        // permission can never leave the system broken.
        if AccessibilityPermission.isGranted {
            enableSwitching()
        } else {
            AccessibilityPermission.prompt()
        }
        // Continuously reconcile permission: enable switching when granted, and
        // (critically) QUIT if it is revoked while running — terminating the
        // process is the only reliable way to release the event tap and clear
        // the macOS input-freeze bug.
        startPermissionMonitor()

        print("SimpleSwitcher started. Press Cmd+Tab to activate.")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Re-launching Switcher.app while it's already running surfaces Preferences.
        showPreferences()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing Preferences must not quit the background agent.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore native Cmd+Tab
        setNativeCommandTabEnabled(true)
        hotkeyManager?.stop()
    }

    // MARK: - HotkeyManagerDelegate

    func hotkeyTriggered() {
        // HotkeyManager already set isActive = true
        guard state == .idle else {
            // Already active - Cmd+Tab pressed again, select next app
            panel.selectNext()
            return
        }

        // Get visible apps
        currentApps = AppListProvider.getVisibleApps()

        guard !currentApps.isEmpty else {
            print("No visible apps to switch to")
            // Reset since we're not actually activating
            hotkeyManager.isActive = false
            return
        }

        // Show panel with apps, select second app (index 1) if available
        let selectIndex = currentApps.count > 1 ? 1 : 0
        panel.showWithApps(currentApps, selectIndex: selectIndex)

        state = .active
        // Register active-only hotkeys (H, Q, arrows, etc.)
        hotkeyManager.registerActiveHotkeys()
        // Mirror apps opened while the panel is up (they're missing from the initial
        // snapshot until their windows render).
        startAppListRefresh()
        // isActive already set by HotkeyManager
    }

    func modifierKeyReleased() {
        guard state == .active else { return }

        // Switch to selected app
        if let selectedApp = panel.getSelectedApp() {
            activateApp(selectedApp)
        }

        dismissPanel()
    }

    func shiftPressed() {
        guard state == .active else { return }
        panel.selectPrevious()
    }

    func mouseClicked(at point: CGPoint) {
        guard state == .active else { return }

        // Use NSEvent.mouseLocation for consistent coordinate system with panel.frame
        let mouseLocation = NSEvent.mouseLocation

        if panel.frame.contains(mouseLocation) {
            // The declutter hint acts as a button, but only while visibly
            // revealed by hover — so this can't fire from a stray click that
            // missed the bottom icon row.
            if panel.isMouseOverHintButton() {
                hideOtherApps()
                dismissPanel()
                return
            }
            // Activate the app under the cursor — a click is deliberate, so it
            // ignores dead-zone hover state. Fall back to the keyboard selection
            // only if the click missed all icons (gap/padding inside the panel).
            if let clickedApp = panel.getAppUnderMouse() {
                activateApp(clickedApp)
            } else if let selectedApp = panel.getSelectedApp() {
                activateApp(selectedApp)
            }
        }
        // Click outside just dismisses without activating
        dismissPanel()
    }

    func keyPressed(_ keyCode: UInt16) {
        guard state == .active else { return }

        switch keyCode {
        case kVK_Tab:
            panel.selectNext()

        case kVK_Escape:
            dismissPanel()

        case kVK_Return:
            if let selectedApp = panel.getSelectedApp() {
                activateApp(selectedApp)
            }
            dismissPanel()

        case kVK_LeftArrow:
            panel.selectPrevious()

        case kVK_RightArrow:
            panel.selectNext()

        case kVK_UpArrow:
            panel.selectUp()

        case kVK_DownArrow:
            panel.selectDown()

        case kVK_H:
            hideSelectedApp()

        case kVK_Q:
            quitSelectedApp()

        default:
            break
        }
    }

    /// Cmd+Opt+H while the panel is open: hide every app except the frontmost one
    /// (native "Hide Others"), then dismiss — leaving just the app you were in.
    /// Distinct from Cmd+H, which hides only the selected app.
    func hideOthersRequested() {
        guard state == .active else { return }
        hideOtherApps()
        dismissPanel()
    }

    // MARK: - AppSwitcherPanelDelegate

    func panelDidSelectApp(_ app: AppInfo) {
        activateApp(app)
        dismissPanel()
    }

    // MARK: - Private Methods

    private func activateApp(_ appInfo: AppInfo) {
        appInfo.app.activate(options: [.activateIgnoringOtherApps])
    }

    private func hideSelectedApp() {
        guard let appToHide = panel.removeSelectedApp() else { return }

        // Hide the app
        appToHide.app.hide()

        // Remove from our list
        currentApps.removeAll { $0.pid == appToHide.pid }

        // If no more apps, dismiss
        if !panel.hasApps {
            dismissPanel()
        }
    }

    /// Hide every regular app EXCEPT the frontmost one — macOS's "Hide Others",
    /// a lighter alternative to quitting apps to declutter the switcher. Hidden apps
    /// drop out of the switcher (AppListProvider filters `!app.isHidden`), so the
    /// next Cmd+Tab shows fewer icons. Uses the same NSRunningApplication.hide()
    /// primitive as hideSelectedApp, looped over all other regular apps. The panel
    /// is non-activating and we're `.accessory`, so `frontmostApplication` is the
    /// real app the user was in — from both the menu bar and the in-panel shortcut.
    private func hideOtherApps() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            if pid == selfPID || pid == frontPID { continue }  // keep ourselves + the front app
            app.hide()
        }
    }

    private func quitSelectedApp() {
        guard let appToQuit = panel.removeSelectedApp() else { return }

        // Terminate the app
        appToQuit.app.terminate()

        // Remove from our list
        currentApps.removeAll { $0.pid == appToQuit.pid }

        // If no more apps, dismiss
        if !panel.hasApps {
            dismissPanel()
        }
    }

    private func dismissPanel() {
        stopAppListRefresh()
        panel.hidePanel()
        state = .idle
        hotkeyManager.isActive = false
        // Unregister active-only hotkeys so Cmd+H/Q work in other apps
        hotkeyManager.unregisterActiveHotkeys()
    }

    /// While the panel is open, poll for apps that have become visible since it
    /// opened (e.g. ones the user just launched from the Dock/Finder, whose windows
    /// hadn't rendered when the initial snapshot was taken) and append them to the
    /// end — append-only, so it never fights the user's own hide/quit actions and
    /// never reorders or moves the icons already on screen. Runs on the main queue
    /// because building each app's icon (NSImage) must happen on main.
    private func startAppListRefresh() {
        guard appListRefreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.state == .active else { return }
            let fresh = AppListProvider.getVisibleApps()
            let known = Set(self.currentApps.map { $0.pid })
            let additions = fresh.filter { !known.contains($0.pid) }
            guard !additions.isEmpty else { return }  // no change → no reflow
            self.currentApps.append(contentsOf: additions)
            self.panel.appendApps(additions)
        }
        appListRefreshTimer = timer
        timer.resume()
    }

    private func stopAppListRefresh() {
        appListRefreshTimer?.cancel()
        appListRefreshTimer = nil
    }

    // MARK: - Switching & Accessibility Permission

    /// Take over Cmd+Tab. Creates the event tap FIRST and only disables native
    /// Cmd+Tab if that succeeded, so a permission failure never breaks the system.
    private func enableSwitching() {
        guard !switchingEnabled else { return }
        guard hotkeyManager.tryCreateEventTap() else { return }  // permission gate
        setNativeCommandTabEnabled(false)
        hotkeyManager.registerHotkeys()
        switchingEnabled = true
        print("Switching enabled.")
    }

    /// Polls Accessibility permission on a background timer and reconciles state.
    /// Deliberately a poll, not a CGEvent-tap callback: macOS does NOT reliably
    /// deliver a tap-disabled event when permission is revoked, so the callback
    /// cannot be trusted to detect revocation.
    private func startPermissionMonitor() {
        guard permissionTimer == nil else { return }
        // Disable App Nap so the timer keeps firing promptly while we hold the
        // tap. Allow idle system sleep — we only want to prevent napping, not keep
        // the whole Mac awake.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Monitor Accessibility permission to prevent input freeze"
        )
        let timer = DispatchSource.makeTimerSource(queue: permissionQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            let granted = AccessibilityPermission.isGranted
            DispatchQueue.main.async { self?.reconcilePermission(granted: granted) }
        }
        permissionTimer = timer
        timer.resume()
    }

    private func reconcilePermission(granted: Bool) {
        if granted {
            if !switchingEnabled { enableSwitching() }
        } else if switchingEnabled {
            handleRevocation()
        }
    }

    /// Accessibility was revoked while we held the event tap. Restore native
    /// Cmd+Tab and QUIT. Terminating the process is the only reliable way to tear
    /// the tap out of the window server and clear the macOS input-freeze bug —
    /// disabling the tap in-process while staying alive is NOT enough.
    private func handleRevocation() {
        guard !isHandlingRevocation else { return }
        isHandlingRevocation = true
        switchingEnabled = false
        setNativeCommandTabEnabled(true)
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Preferences & Menu Bar

    private func showPreferences() {
        prefsWindowController.show()
    }

    private func refreshStatusItem() {
        if Preferences.showMenuBarIcon {
            statusBarController.show()
        } else {
            statusBarController.hide()
        }
    }

    /// On startup only: every 5th launch (until the user donates) surface
    /// Preferences alongside a donation prompt. Donating silences it forever.
    private func maybeShowDonationNag() {
        guard !Preferences.hasDonated, Preferences.launchCount % 5 == 0 else { return }

        showPreferences()

        let alert = NSAlert()
        alert.messageText = "Enjoying Switcher?"
        alert.informativeText = "If it's useful, consider supporting development."
        alert.addButton(withTitle: "Donate")
        alert.addButton(withTitle: "Maybe Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Preferences.openDonatePage()
        }
    }
}
