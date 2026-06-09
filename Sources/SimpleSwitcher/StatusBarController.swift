import Cocoa

/// Owns the optional menu bar icon (`NSStatusItem`) and its menu.
/// The status item is not retained by the system, so this controller holds a
/// strong reference for as long as the icon should be visible.
class StatusBarController {

    /// Invoked when the user picks "Preferences…" from the menu.
    var onOpenPreferences: (() -> Void)?

    private var statusItem: NSStatusItem?

    /// Shows the menu bar icon (no-op if already visible).
    func show() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Switcher")
        image?.isTemplate = true
        item.button?.image = image
        item.menu = makeMenu()
        statusItem = item
    }

    /// Removes the menu bar icon (no-op if already hidden).
    func hide() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let donate = NSMenuItem(title: "Donate", action: #selector(donate), keyEquivalent: "")
        donate.target = self
        menu.addItem(donate)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Switcher", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func openPreferences() {
        onOpenPreferences?()
    }

    @objc private func donate() {
        Preferences.openDonatePage()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
