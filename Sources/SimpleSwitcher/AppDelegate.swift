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

    // Key codes
    private let kVK_Tab: UInt16 = 0x30
    private let kVK_Escape: UInt16 = 0x35
    private let kVK_Return: UInt16 = 0x24
    private let kVK_LeftArrow: UInt16 = 0x7B
    private let kVK_RightArrow: UInt16 = 0x7C
    private let kVK_H: UInt16 = 0x04
    private let kVK_Q: UInt16 = 0x0C

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start tracking app activation order
        AppListProvider.startObserving()

        // Disable native Cmd+Tab
        setNativeCommandTabEnabled(false)

        // Setup hotkey manager
        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self
        hotkeyManager.start()

        // Create panel (hidden initially)
        panel = AppSwitcherPanel()
        panel.panelDelegate = self

        // Set app to accessory (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        print("SimpleSwitcher started. Press Cmd+Tab to activate.")
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
}
