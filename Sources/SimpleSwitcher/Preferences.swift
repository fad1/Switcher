import Cocoa

/// Single source of truth for persisted settings, wrapping `UserDefaults.standard`.
/// All keys live here so nothing is referenced as a stray string literal.
enum Preferences {

    // MARK: - Keys

    private enum Key {
        // NOTE: must stay "grayscaleIcons" for backward compatibility with the
        // existing `defaults write com.simpleswitcher.app grayscaleIcons` workflow.
        static let grayscaleIcons = "grayscaleIcons"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDeclutterTip = "showDeclutterTip"
        static let hideMinimizedOnlyApps = "hideMinimizedOnlyApps"
        static let limitRecentApps = "limitRecentApps"
        static let recentAppsLimit = "recentAppsLimit"
        static let launchCount = "launchCount"
        static let hasDonated = "hasDonated"
    }

    private static let defaults = UserDefaults.standard

    /// Registers in-process fallbacks. Does NOT persist, so this must run before
    /// any read, on every launch (see AppDelegate.applicationDidFinishLaunching).
    static func registerDefaults() {
        defaults.register(defaults: [
            Key.showMenuBarIcon: true,
            Key.showDeclutterTip: true,
            Key.hideMinimizedOnlyApps: true,
            // The count is registered but the switch is not: the cap ships off,
            // and this is the number it takes when first turned on.
            Key.recentAppsLimit: 5,
        ])
    }

    // MARK: - Accessors

    static var grayscaleIcons: Bool {
        get { defaults.bool(forKey: Key.grayscaleIcons) }
        set { defaults.set(newValue, forKey: Key.grayscaleIcons) }
    }

    static var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.showMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.showMenuBarIcon) }
    }

    /// Whether to show the "⌥⌘H · Hide others" declutter tip at the bottom of the
    /// switcher when it's cluttered (2+ rows). Defaults to true (see registerDefaults).
    static var showDeclutterTip: Bool {
        get { defaults.bool(forKey: Key.showDeclutterTip) }
        set { defaults.set(newValue, forKey: Key.showDeclutterTip) }
    }

    /// Whether an app whose windows are ALL minimized is left out of the switcher.
    /// Defaults to true (see registerDefaults). Read live on every open, so
    /// toggling it needs no restart. An app with a Dock badge stays listed either
    /// way — the badge rule is independent of window filtering.
    static var hideMinimizedOnlyApps: Bool {
        get { defaults.bool(forKey: Key.hideMinimizedOnlyApps) }
        set { defaults.set(newValue, forKey: Key.hideMinimizedOnlyApps) }
    }

    /// Whether the switcher is capped to the `recentAppsLimit` most recently used
    /// apps. Defaults to false — with it on, apps outside that window are not
    /// reachable from the switcher at all, which is the point but is not something
    /// to turn on for someone. Read live on every list build, so no restart.
    ///
    /// Kept separate from the count rather than overloading "0 means off", so
    /// switching it off and on again doesn't discard a tuned number.
    static var limitRecentApps: Bool {
        get { defaults.bool(forKey: Key.limitRecentApps) }
        set { defaults.set(newValue, forKey: Key.limitRecentApps) }
    }

    /// How many apps the switcher shows when `limitRecentApps` is on, counting the
    /// app you are currently in (so 5 means 5 icons and 4 switch targets).
    /// Defaults to 5 (see registerDefaults).
    static var recentAppsLimit: Int {
        get { defaults.integer(forKey: Key.recentAppsLimit) }
        set { defaults.set(newValue, forKey: Key.recentAppsLimit) }
    }

    static var launchCount: Int {
        get { defaults.integer(forKey: Key.launchCount) }
        set { defaults.set(newValue, forKey: Key.launchCount) }
    }

    static var hasDonated: Bool {
        get { defaults.bool(forKey: Key.hasDonated) }
        set { defaults.set(newValue, forKey: Key.hasDonated) }
    }

    // MARK: - Donations

    static let donateURL = URL(string: "https://ko-fi.com/cheetah9960")!

    /// The single choke point for donating: records that the user donated (so the
    /// nag never shows again) and opens the donation page.
    static func openDonatePage() {
        hasDonated = true
        NSWorkspace.shared.open(donateURL)
    }
}
