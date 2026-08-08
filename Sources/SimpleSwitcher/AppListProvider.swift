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

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                updateMRU(app.processIdentifier)
            }
        }

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
        mruOrder.removeAll { $0 == pid }
        mruOrder.insert(pid, at: 0)
        if mruOrder.count > 50 {
            mruOrder.removeLast()
        }
    }

    /// The switcher's app list, MRU-ordered. A badge alone qualifies an app, so
    /// e.g. Mail with an unread count is listed even with no window at all.
    static func getVisibleApps() -> [AppInfo] {
        let visiblePIDs = getVisibleWindowPIDs()
        let badges = getDockBadgesCached()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppInfo? in
            // .regular excludes background and accessory apps (which includes us).
            guard app.activationPolicy == .regular else { return nil }

            guard !app.isHidden else { return nil }

            guard app.processIdentifier != selfPID else { return nil }

            let badge = badges[app.bundleIdentifier ?? ""]

            let hasVisibleWindow = visiblePIDs.contains(app.processIdentifier)
            let hasBadge = badge != nil

            guard hasVisibleWindow || hasBadge else { return nil }

            // Get app info. The icon's logical size is left alone: AppItemView
            // sizes it via constraints (mutating app.icon would touch a shared
            // NSImage), and the reps carry the resolution regardless.
            let name = app.localizedName ?? "Unknown"
            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

            return AppInfo(app: app, name: name, icon: icon, pid: app.processIdentifier, badge: badge)
        }

        return sortByMRU(apps)
    }

    /// PIDs of apps owning at least one window that counts as switchable —
    /// including fullscreen windows and windows on other Spaces, which
    /// CGWindowList reports as off-screen.
    private static func getVisibleWindowPIDs() -> Set<pid_t> {
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var pids = Set<pid_t>()
        for window in windowList {
            // Layer semantics: 0 is an ordinary window; negatives sit below the
            // desktop; a few apps use small positives (3 = screensaver/fullscreen
            // video); anything above ~20 is system UI (menu bar, Dock).
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer < 0 || layer > 20 {
                continue
            }

            // Too small to be a real window: menus, tooltips, shadow helpers.
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
                let width = bounds["Width"] ?? 0
                let height = bounds["Height"] ?? 0
                if width < 50 || height < 50 {
                    continue
                }
            } else {
                continue
            }

            // A window on another Space reports isOnScreen = false, so off-screen
            // windows must be accepted too; a non-empty owner name is what keeps
            // system-process windows out. CGWindowList cannot tell those apart from
            // MINIMIZED windows (also off-screen), which is why an app whose only
            // window is minimized still appears in the switcher.
            let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !isOnScreen {
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

    // The badge scan walks the Dock's AX tree — several IPC round-trips per dock
    // item, on the main thread. getVisibleApps runs on every Cmd+Tab press AND
    // every 300ms while the panel is open (AppDelegate's live refresh), so cache
    // the result briefly instead of re-walking each time. Badges changing within
    // the TTL just show ~2s late on the next open — invisible in practice.
    private static var badgeCache: (badges: [String: String], at: Date)?
    private static let badgeCacheTTL: TimeInterval = 2.0

    private static func getDockBadgesCached() -> [String: String] {
        if let cache = badgeCache, Date().timeIntervalSince(cache.at) < badgeCacheTTL {
            return cache.badges
        }
        let fresh = getDockBadges()
        badgeCache = (fresh, Date())
        return fresh
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

            var listChildrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenValue) == .success,
                  let listChildren = listChildrenValue as? [AXUIElement] else {
                continue
            }

            for dockItem in listChildren {
                var subroleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, kAXSubroleAttribute as CFString, &subroleValue) == .success,
                      let subrole = subroleValue as? String,
                      subrole == "AXApplicationDockItem" else {
                    continue
                }

                var isRunningValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, "AXIsApplicationRunning" as CFString, &isRunningValue) == .success,
                      let isRunning = isRunningValue as? Bool,
                      isRunning else {
                    continue
                }

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
