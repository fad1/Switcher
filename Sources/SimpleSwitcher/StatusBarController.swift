import Cocoa

/// Owns the optional menu bar icon (`NSStatusItem`) and its menu.
/// The status item is not retained by the system, so this controller holds a
/// strong reference for as long as the icon should be visible.
class StatusBarController: NSObject, NSMenuDelegate {

    /// Invoked when the user picks "Preferences…" from the menu.
    var onOpenPreferences: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var grayscaleItem: NSMenuItem?

    /// Shows the menu bar icon (no-op if already visible).
    func show() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // ⌘ glyph, matching the app's command-key icon. Template image so it
        // adapts to the light/dark menu bar.
        let image = NSImage(systemSymbolName: "command", accessibilityDescription: "Switcher")
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
        grayscaleItem = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        // Quick toggle — checkmark reflects the current setting (see menuNeedsUpdate).
        let grayscale = NSMenuItem(title: "Grayscale Icons", action: #selector(toggleGrayscale), keyEquivalent: "")
        grayscale.target = self
        grayscale.state = Preferences.grayscaleIcons ? .on : .off
        menu.addItem(grayscale)
        grayscaleItem = grayscale

        menu.addItem(.separator())

        let donate = NSMenuItem(title: "Donate", action: #selector(donate), keyEquivalent: "")
        donate.target = self
        menu.addItem(donate)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Switcher", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Reflect the current grayscale setting each time the menu opens (it may
        // have changed from the Preferences window or the terminal).
        grayscaleItem?.state = Preferences.grayscaleIcons ? .on : .off
    }

    // MARK: - Actions

    @objc private func openPreferences() {
        onOpenPreferences?()
    }

    @objc private func toggleGrayscale() {
        // Takes effect on the next Cmd+Tab, since the panel rebuilds its icons.
        Preferences.grayscaleIcons.toggle()
    }

    @objc private func donate() {
        Preferences.openDonatePage()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
