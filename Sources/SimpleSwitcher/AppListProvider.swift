import Cocoa

struct AppInfo {
    let app: NSRunningApplication
    let name: String
    let icon: NSImage
    let pid: pid_t
}

class AppListProvider {
    // Track app activation order (most recent first)
    private static var mruOrder: [pid_t] = []
    private static var isObserving = false

    /// Start observing app activations to track MRU order
    static func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        // Initialize with current frontmost app
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            updateMRU(frontApp.processIdentifier)
        }

        // Observe app activation
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                updateMRU(app.processIdentifier)
            }
        }

        // Observe app termination to clean up MRU
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                mruOrder.removeAll { $0 == app.processIdentifier }
            }
        }
    }

    /// Update MRU order when an app is activated
    private static func updateMRU(_ pid: pid_t) {
        // Remove if already in list
        mruOrder.removeAll { $0 == pid }
        // Add to front
        mruOrder.insert(pid, at: 0)
        // Keep list reasonable size
        if mruOrder.count > 50 {
            mruOrder.removeLast()
        }
    }

    /// Returns apps that have visible (on-screen) windows
    /// This filters out:
    /// - Hidden apps (isHidden)
    /// - Apps with only minimized windows
    /// - Background-only apps (activationPolicy != .regular)
    static func getVisibleApps() -> [AppInfo] {
        // Get PIDs of apps that have at least one on-screen window
        let visiblePIDs = getVisibleWindowPIDs()

        // Get current app's PID to exclude self
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // Filter running applications
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppInfo? in
            // Only include regular apps (not background/accessory apps)
            guard app.activationPolicy == .regular else { return nil }

            // Exclude hidden apps
            guard !app.isHidden else { return nil }

            // Exclude self
            guard app.processIdentifier != selfPID else { return nil }

            // Only include apps with visible windows
            guard visiblePIDs.contains(app.processIdentifier) else { return nil }

            // Get app info
            let name = app.localizedName ?? "Unknown"
            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
            icon.size = NSSize(width: 64, height: 64)

            return AppInfo(app: app, name: name, icon: icon, pid: app.processIdentifier)
        }

        // Sort by MRU order
        return sortByMRU(apps)
    }

    /// Gets PIDs of all apps with on-screen (non-minimized) windows across all spaces
    private static func getVisibleWindowPIDs() -> Set<pid_t> {
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var pids = Set<pid_t>()
        for window in windowList {
            // Skip windows without a proper layer (menubar, dock, etc.)
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }

            // Require isOnScreen to be explicitly true (filters out minimized windows)
            guard let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool, isOnScreen else {
                continue
            }

            // Also check bounds - minimized windows may have zero/invalid bounds
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
                let width = bounds["Width"] ?? 0
                let height = bounds["Height"] ?? 0
                if width <= 0 || height <= 0 {
                    continue
                }
            }

            if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                pids.insert(pid)
            }
        }

        return pids
    }

    /// Sort apps by MRU order (most recently used first)
    private static func sortByMRU(_ apps: [AppInfo]) -> [AppInfo] {
        return apps.sorted { app1, app2 in
            let idx1 = mruOrder.firstIndex(of: app1.pid) ?? Int.max
            let idx2 = mruOrder.firstIndex(of: app2.pid) ?? Int.max
            return idx1 < idx2
        }
    }
}
