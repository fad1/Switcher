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
    // Apps the user removed with H / Q / M during THIS panel session. The live
    // refresh must never re-add them: those actions all complete asynchronously,
    // so getVisibleApps() keeps reporting the app for a while afterwards — and
    // since it is no longer in currentApps, the refresh would mistake it for a
    // newly launched app and append it at the end of the grid. Minimize makes
    // this obvious (one AX call per window, into the target app), but hide and
    // quit race it too; they usually just win.
    private var actedOnPIDs = Set<pid_t>()
    private var activityToken: NSObjectProtocol?
    private var isHandlingRevocation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Settings: register in-process fallbacks before any read, then count this
        // launch. Must precede startObserving, whose MRU seed queries the window
        // list and would otherwise read hideMinimizedOnlyApps as an unregistered
        // false, seeding from windows the switcher will never show.
        Preferences.registerDefaults()
        Preferences.launchCount += 1

        AppListProvider.startObserving()

        // Setup hotkey manager (does NOT take over Cmd+Tab yet — see enableSwitching)
        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self

        // Create panel (hidden initially)
        panel = AppSwitcherPanel()
        panel.panelDelegate = self

        // Set app to accessory (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Menu bar icon (optional, controlled by preferences). Provides a Quit
        // escape hatch even while we're waiting for Accessibility permission.
        statusBarController = StatusBarController()
        statusBarController.onOpenPreferences = { [weak self] in self?.showPreferences() }
        statusBarController.onHideOtherApps = { [weak self] in self?.hideOtherApps() }
        refreshStatusItem()

        // Preferences window (reusable single instance, hidden until requested)
        prefsWindowController = PreferencesWindowController()
        prefsWindowController.onToggleMenuBar = { [weak self] _ in self?.refreshStatusItem() }

        // Only take over Cmd+Tab once Accessibility permission is confirmed. Until
        // then, native Cmd+Tab is left working — so a first launch without
        // permission can never leave the system broken.
        if AccessibilityPermission.isGranted {
            enableSwitching()
        } else {
            AccessibilityPermission.prompt()
        }
        // Reconcile continuously, so a grant takes effect without a relaunch.
        startPermissionMonitor()

        // Nag AFTER switching is live, and deferred: runModal() blocks this
        // method, and anything sequenced behind it, until the user answers.
        DispatchQueue.main.async { [weak self] in
            self?.maybeShowDonationNag()
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
        openPanel(reverse: false)
    }

    func hotkeyTriggeredReverse() {
        // Cmd+Shift+Tab: same as hotkeyTriggered but cycling backward.
        guard state == .idle else {
            panel.selectPrevious()
            return
        }
        openPanel(reverse: true)
    }

    /// Snapshot the visible apps and show the panel. Forward opens on the
    /// second app (quick Alt-Tab back-and-forth); reverse opens on the last
    /// (least recently used), matching the native switcher's wrap-around.
    private func openPanel(reverse: Bool) {
        currentApps = AppListProvider.getVisibleApps()
        actedOnPIDs.removeAll()  // each open starts a fresh session

        guard !currentApps.isEmpty else {
            print("No visible apps to switch to")
            // Reset since we're not actually activating
            hotkeyManager.isActive = false
            return
        }

        let selectIndex = reverse
            ? currentApps.count - 1
            : (currentApps.count > 1 ? 1 : 0)
        panel.showWithApps(currentApps, selectIndex: selectIndex)

        state = .active
        // Register active-only hotkeys (H, Q, arrows, etc.)
        hotkeyManager.registerActiveHotkeys()
        // Mirror apps opened while the panel is up (they're missing from the initial
        // snapshot until their windows render).
        startAppListRefresh()
    }

    func modifierKeyReleased() {
        guard state == .active else { return }

        if let selectedApp = panel.getSelectedApp() {
            activateApp(selectedApp)
        }

        dismissPanel()
    }

    func shiftTapped() {
        guard state == .active else { return }
        panel.selectPrevious()
    }

    func mouseClicked() {
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

        switch Int(keyCode) {
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

        case kVK_ANSI_H:
            hideSelectedApp()

        case kVK_ANSI_M:
            minimizeSelectedApp()

        case kVK_ANSI_Q:
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

    /// A click was swallowed by a click shield (outside the panel). The tap's
    /// mouseClicked usually dismisses first; this is the shield-side path so the
    /// panel still closes if the tap misses the event. Both are state-guarded.
    func panelDidRequestDismiss() {
        guard state == .active else { return }
        dismissPanel()
    }

    // MARK: - Private Methods

    private func activateApp(_ appInfo: AppInfo) {
        appInfo.app.activate(options: [.activateIgnoringOtherApps])
    }

    private func hideSelectedApp() {
        guard let appToHide = panel.removeSelectedApp() else { return }

        appToHide.app.hide()
        actedOnPIDs.insert(appToHide.pid)
        currentApps.removeAll { $0.pid == appToHide.pid }

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

    /// M: minimize every window of the selected app and drop it from the panel.
    ///
    /// The panel updates immediately while the AX calls run in the background, so
    /// the keystroke stays responsive even against a busy app. With
    /// `hideMinimizedOnlyApps` on (the default) the app is then gone from the
    /// next Cmd+Tab too; with it off, minimizing still works but the app comes
    /// back in the list, which is the honest result of that setting.
    private func minimizeSelectedApp() {
        guard let appToMinimize = panel.removeSelectedApp() else { return }

        WindowActions.minimizeAllWindows(ofPID: appToMinimize.pid)
        actedOnPIDs.insert(appToMinimize.pid)
        currentApps.removeAll { $0.pid == appToMinimize.pid }

        if !panel.hasApps {
            dismissPanel()
        }
    }

    private func quitSelectedApp() {
        guard let appToQuit = panel.removeSelectedApp() else { return }

        appToQuit.app.terminate()
        actedOnPIDs.insert(appToQuit.pid)
        currentApps.removeAll { $0.pid == appToQuit.pid }

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
            var additions = fresh.filter { !known.contains($0.pid) && !self.actedOnPIDs.contains($0.pid) }
            additions = Array(additions.prefix(self.remainingSlots()))
            guard !additions.isEmpty else { return }  // no change → no reflow
            self.currentApps.append(contentsOf: additions)
            self.panel.appendApps(additions)
        }
        appListRefreshTimer = timer
        timer.resume()
    }

    /// How many apps the refresh may still append this session. Unbounded unless
    /// the recent-apps cap is on, since the panel has no way to *remove* an app to
    /// make room — `appendApps` only ever grows the grid — so without this the
    /// panel walks past the limit as apps launch.
    ///
    /// Apps removed with H/Q/M count against the allowance (via `actedOnPIDs`)
    /// rather than freeing a slot. Otherwise culling app #3 would promote the old
    /// #6 into range and the refresh would pop it in ~300ms later, refilling the
    /// panel as fast as the user empties it. Removals stay monotonic within a
    /// session; the next Cmd+Tab is a fresh snapshot and shows a full N again.
    private func remainingSlots() -> Int {
        guard Preferences.limitRecentApps else { return .max }
        let limit = max(1, Preferences.recentAppsLimit)
        return max(0, limit - (currentApps.count + actedOnPIDs.count))
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

    /// Best-effort cleanup when Accessibility is revoked while we hold the tap:
    /// restore native Cmd+Tab, then quit. Rarely reached in practice, because
    /// `AXIsProcessTrusted()` caches per process (see AccessibilityPermission).
    /// Not load-bearing either way — the tap is `.listenOnly`, so a live tap
    /// cannot freeze input; freeze safety lives in the tap type, not here.
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
