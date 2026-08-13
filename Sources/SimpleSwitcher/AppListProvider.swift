import Cocoa
import SwitcherKernels

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

        seedMRU()

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

    /// Seed the MRU order at launch from window z-order.
    ///
    /// Only activations that happen while Switcher is running feed `mruOrder`, so
    /// without a seed exactly one app has a rank and every other ties at `Int.max`
    /// in `sortByMRU` — an arbitrary tail. Invisible while the switcher lists
    /// everything; under `limitRecentApps` it decides which apps are reachable at
    /// all, and it would reset on every relaunch.
    ///
    /// ponytail: CGWindowList's front-to-back order is a *proxy* for recency, not
    /// a record of it — accurate for the current Space, weaker across Spaces, and
    /// blind to anything used before the last window raise. macOS keeps no
    /// queryable activation history, so this is the best available signal; the
    /// ceiling is one launch, since real activations replace it from the first
    /// Cmd+Tab onward. Upgrade path: persist `mruOrder` across launches.
    private static func seedMRU() {
        let owners = classifyWindows().windows
            .filter { $0.onScreen && $0.keepsAppListed }
            .map { $0.pid }
        mruOrder = RecentApps.orderedUnique(pids: owners,
                                            frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier)
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
    ///
    /// The accept/reject rule itself lives in `WindowFilter`; this does the query
    /// and the collection. Windows accepted by the OFF-SCREEN branch get a second
    /// pass: CGWindowList cannot tell an other-Space window from a minimized one
    /// (`WindowFilterSpecs.md`), so their minimized state is read from the
    /// WindowServer in one batched query (`MinimizedStateSpecs.md`). On-screen
    /// windows are never touched by that pass, which is also what makes the
    /// restore race benign.
    private static func getVisibleWindowPIDs() -> Set<pid_t> {
        classifyWindows().pids
    }

    /// A window that survived the CGWindowList filter, with the branch that
    /// accepted it and — for off-screen windows — the WindowServer's verdict.
    struct AcceptedWindow {
        let pid: pid_t
        let ownerName: String
        let wid: CGWindowID?
        let onScreen: Bool
        /// nil means "keeps its app listed": an on-screen window, or an
        /// off-screen one the WindowServer says is a real window elsewhere.
        var rejection: MinimizedState.Verdict?

        var keepsAppListed: Bool { rejection == nil }
    }

    /// Shared by `getVisibleWindowPIDs` and the `--list-apps` diagnostic, so the
    /// two can never drift apart.
    static func classifyWindows() -> (pids: Set<pid_t>, windows: [AcceptedWindow]) {
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return ([], [])
        }

        var accepted: [AcceptedWindow] = []
        for window in windowList {
            let raw = RawWindow(cgWindowInfo: window)
            guard case .accept(let onScreen) = WindowFilter.verdict(for: raw),
                  let pid = raw.ownerPID else { continue }
            accepted.append(AcceptedWindow(pid: pid, ownerName: raw.ownerName ?? "",
                                           wid: raw.windowID, onScreen: onScreen))
        }

        if Preferences.hideMinimizedOnlyApps {
            let candidates = accepted.filter { !$0.onScreen }.compactMap { $0.wid }
            if !candidates.isEmpty {
                let rejected = MinimizedState.rejectedWids(among: candidates,
                                                           states: queryWindowServer(candidates))
                for index in accepted.indices where !accepted[index].onScreen {
                    if let wid = accepted[index].wid {
                        accepted[index].rejection = rejected[wid]
                    }
                }
            }
        }

        // An app stays listed if ANY of its windows survived.
        let pids = Set(accepted.filter { $0.keepsAppListed }.map { $0.pid })
        return (pids, accepted)
    }

    /// One batched `SLSWindowQueryWindows` for the given wids. Impure (Mach IPC),
    /// so it has no Specs/Tests triad — the pure decode it feeds does.
    ///
    /// Returns an empty dictionary on any failure, which `MinimizedState` treats
    /// as "nothing is minimized", i.e. exactly today's behavior. Every step here
    /// must fail open: a macOS change may cost us the filtering, never an app.
    private static func queryWindowServer(_ wids: [CGWindowID]) -> [CGWindowID: WsRawWindow] {
        guard !wids.isEmpty else { return [:] }

        let result = SLSWindowQueryWindows(CGSMainConnectionID(), wids as CFArray, Int32(wids.count))
            .takeRetainedValue()
        let iterator = SLSWindowQueryResultCopyWindows(result).takeRetainedValue()

        var states: [CGWindowID: WsRawWindow] = [:]
        states.reserveCapacity(wids.count)
        while SLSWindowIteratorAdvance(iterator) {
            let wid = SLSWindowIteratorGetWindowID(iterator)
            states[wid] = WsRawWindow(wid: wid,
                                      attributes: SLSWindowIteratorGetAttributes(iterator),
                                      tags: SLSWindowIteratorGetTags(iterator))
        }
        return states
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

    /// `--list-apps`: print what the switcher would show and why, then exit.
    /// Window filtering is invisible in the UI — an app is either there or it
    /// isn't — so this is how a "why is X missing / why is X still here" report
    /// gets diagnosed without guessing.
    static func printAppListDiagnostic() {
        Preferences.registerDefaults()
        // Two snapshots a moment apart (getVisibleApps runs its own). Fine for a
        // diagnostic; a window opening between them just shows as a mismatch.
        let (_, windows) = classifyWindows()
        let apps = getVisibleApps()
        let listed = Set(apps.map { $0.pid })

        print("hideMinimizedOnlyApps: \(Preferences.hideMinimizedOnlyApps)")
        print("accepted windows: \(windows.count) (\(windows.filter { $0.onScreen }.count) on-screen, "
              + "\(windows.filter { !$0.onScreen && $0.keepsAppListed }.count) off-screen kept, "
              + "\(windows.filter { $0.rejection == .minimized }.count) minimized-rejected, "
              + "\(windows.filter { $0.rejection == .notSwitchable }.count) helper-windows)\n")

        let byPID = Dictionary(grouping: windows, by: { $0.pid })
        print("SWITCHER LIST (\(apps.count) apps, MRU order):")
        for app in apps {
            let mine = byPID[app.pid] ?? []
            let verdict: String
            if mine.contains(where: { $0.onScreen }) {
                verdict = "visible"
            } else if mine.contains(where: { $0.keepsAppListed }) {
                verdict = "other-Space"
            } else if app.badge != nil {
                verdict = "badge-rescued"
            } else {
                verdict = "listed (no surviving window?)"
            }
            let badge = app.badge.map { " badge=\($0)" } ?? ""
            print("  \(app.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(verdict)\(badge)")
        }

        // Apps that owned windows but did not make the list — the interesting half.
        let excluded = byPID.filter { !listed.contains($0.key) }
        if !excluded.isEmpty {
            print("\nEXCLUDED (owned accepted windows but not listed):")
            for (pid, mine) in excluded {
                let name = mine.first?.ownerName ?? "pid \(pid)"
                let reason: String
                if mine.contains(where: { $0.rejection == .minimized }) {
                    let helpers = mine.filter { $0.rejection == .notSwitchable }.count
                    reason = "minimized-rejected" + (helpers > 0 ? " (+\(helpers) helper-windows)" : "")
                } else if mine.allSatisfy({ $0.rejection == .notSwitchable }) {
                    reason = "only helper-windows"
                } else {
                    reason = "hidden / not a regular app / self"
                }
                print("  \(name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(reason)")
            }
        }
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
