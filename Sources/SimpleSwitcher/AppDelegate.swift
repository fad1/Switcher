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
    // Polls for the Accessibility grant while switching is disabled.
    private var permissionTimer: Timer?

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
        refreshStatusItem()

        // Preferences window (reusable single instance, hidden until requested)
        prefsWindowController = PreferencesWindowController()
        prefsWindowController.onToggleMenuBar = { [weak self] _ in self?.refreshStatusItem() }

        // Start silently; only surface the window when it's time to nag.
        maybeShowDonationNag()

        // Only take over Cmd+Tab once Accessibility permission is confirmed. Until
        // then, native Cmd+Tab is left working and we poll for the grant — so a
        // first launch without permission can never leave the system broken.
        if AccessibilityPermission.isGranted {
            enableSwitching()
        } else {
            AccessibilityPermission.prompt()
            startPermissionPolling()
        }

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
            // Click inside panel - activate selected app
            if let selectedApp = panel.getSelectedApp() {
                activateApp(selectedApp)
            }
        }
        // Click outside just dismisses without activating
        dismissPanel()
    }

    func accessibilityRevoked() {
        // Permission was turned off while running — give the user back a working
        // Cmd+Tab and wait for it to be re-granted.
        disableSwitching()
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
        panel.hidePanel()
        state = .idle
        hotkeyManager.isActive = false
        // Unregister active-only hotkeys so Cmd+H/Q work in other apps
        hotkeyManager.unregisterActiveHotkeys()
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

    /// Hand Cmd+Tab back to macOS and wait for permission to return. Called when
    /// Accessibility is revoked while running.
    private func disableSwitching() {
        guard switchingEnabled else { return }
        setNativeCommandTabEnabled(true)
        hotkeyManager.stop()
        switchingEnabled = false
        print("Switching disabled (Accessibility permission lost). Waiting for re-grant…")
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        // .common mode so the donation NSAlert.runModal() can't pause the poll.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard AccessibilityPermission.isGranted else { return }
            t.invalidate()
            self?.permissionTimer = nil
            self?.enableSwitching()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
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
