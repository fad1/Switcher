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
        guard state == .idle else {
            // Already active - Tab handling is done in keyPressed()
            return
        }

        // Get visible apps
        currentApps = AppListProvider.getVisibleApps()

        guard !currentApps.isEmpty else {
            print("No visible apps to switch to")
            return
        }

        // Show panel with apps, select second app (index 1) if available
        let selectIndex = currentApps.count > 1 ? 1 : 0
        panel.showWithApps(currentApps, selectIndex: selectIndex)

        state = .active
        hotkeyManager.isActive = true
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

        // Convert CGEvent coordinates (bottom-left origin) to screen coordinates
        // and check if click is inside the panel
        let screenPoint = NSPoint(x: point.x, y: point.y)

        // Check if click is inside panel frame
        if panel.frame.contains(screenPoint) {
            // Click inside panel - let the panel handle it (hover already selects, click activates)
            if let selectedApp = panel.getSelectedApp() {
                activateApp(selectedApp)
            }
            dismissPanel()
        } else {
            // Click outside - dismiss without switching
            dismissPanel()
        }
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

    private func dismissPanel() {
        panel.hidePanel()
        state = .idle
        hotkeyManager.isActive = false
    }
}
