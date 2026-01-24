import Cocoa

struct AppInfo {
    let app: NSRunningApplication
    let name: String
    let icon: NSImage
    let pid: pid_t
    let badge: String?  // Dock badge (notification count)
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

    /// Returns apps that should be shown in the switcher
    /// Shows apps that are:
    /// - Regular apps (activationPolicy == .regular)
    /// - Not hidden
    /// - Have visible windows OR have a dock badge (notification)
    static func getVisibleApps() -> [AppInfo] {
        // Get PIDs of apps that have at least one on-screen window
        let visiblePIDs = getVisibleWindowPIDs()

        // Get dock badges for all running apps
        let badges = getDockBadges()

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

            // Get badge for this app (if any)
            let badge = badges[app.bundleIdentifier ?? ""]

            // Include apps that have visible windows OR have a badge
            let hasVisibleWindow = visiblePIDs.contains(app.processIdentifier)
            let hasBadge = badge != nil

            guard hasVisibleWindow || hasBadge else { return nil }

            // Get app info
            let name = app.localizedName ?? "Unknown"
            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
            icon.size = NSSize(width: 64, height: 64)

            return AppInfo(app: app, name: name, icon: icon, pid: app.processIdentifier, badge: badge)
        }

        // Sort by MRU order
        return sortByMRU(apps)
    }

    /// Gets PIDs of all apps with on-screen windows across all spaces
    /// Includes fullscreen windows and windows on other spaces
    private static func getVisibleWindowPIDs() -> Set<pid_t> {
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var pids = Set<pid_t>()
        for window in windowList {
            // Get window layer - layer 0 is normal windows
            // Negative layers are below desktop, high positive layers are system UI
            let layer = window[kCGWindowLayer as String] as? Int ?? 0

            // Accept normal windows (layer 0) and some special cases
            // Layer 0: normal windows
            // Layer < 0: below desktop (skip)
            // Layer 3: screensaver/fullscreen video (some apps)
            // Layer > 20: system UI elements like menubar, dock (skip)
            if layer < 0 || layer > 20 {
                continue
            }

            // Check bounds - skip windows with no size (menus, tooltips, etc.)
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
                let width = bounds["Width"] ?? 0
                let height = bounds["Height"] ?? 0
                // Minimum size to be considered a real window
                if width < 50 || height < 50 {
                    continue
                }
            } else {
                continue
            }

            // Check if window is on screen OR if it has valid bounds (for other spaces)
            // Windows on other spaces have isOnScreen = false but still valid
            let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false

            // For windows not on current screen, check if they're just on another space
            // by verifying they have a valid owner name (real app, not system process)
            if !isOnScreen {
                // Skip if no owner name (likely system window)
                guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                      !ownerName.isEmpty else {
                    continue
                }
            }

            if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                pids.insert(pid)
            }
        }

        return pids
    }

    /// Gets dock badges (notification counts) for running apps
    /// Queries the Dock's accessibility hierarchy for AXStatusLabel
    private static func getDockBadges() -> [String: String] {
        var badges: [String: String] = [:]

        // Find the Dock process
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return badges
        }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        // Get Dock's children
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return badges
        }

        // Find the list element (contains dock items)
        for child in children {
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String,
                  role == kAXListRole else {
                continue
            }

            // Get list children (dock items)
            var listChildrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenValue) == .success,
                  let listChildren = listChildrenValue as? [AXUIElement] else {
                continue
            }

            // Check each dock item
            for dockItem in listChildren {
                // Get subrole - must be application dock item
                var subroleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, kAXSubroleAttribute as CFString, &subroleValue) == .success,
                      let subrole = subroleValue as? String,
                      subrole == "AXApplicationDockItem" else {
                    continue
                }

                // Check if app is running
                var isRunningValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, "AXIsApplicationRunning" as CFString, &isRunningValue) == .success,
                      let isRunning = isRunningValue as? Bool,
                      isRunning else {
                    continue
                }

                // Get the badge label (AXStatusLabel)
                var statusLabelValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, "AXStatusLabel" as CFString, &statusLabelValue) == .success,
                      let statusLabel = statusLabelValue as? String,
                      !statusLabel.isEmpty else {
                    continue
                }

                // Get the app URL to find bundle identifier
                var urlValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, kAXURLAttribute as CFString, &urlValue) == .success,
                      let url = urlValue as? URL ?? (urlValue as? NSURL)?.filePathURL else {
                    continue
                }

                // Get bundle identifier from the app URL
                if let bundle = Bundle(url: url),
                   let bundleId = bundle.bundleIdentifier {
                    badges[bundleId] = statusLabel
                }
            }
        }

        return badges
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
