import Cocoa

/// A small, reusable Preferences window built programmatically.
/// One instance is held by AppDelegate and reused on every show/reopen.
class PreferencesWindowController: NSWindowController {

    /// Invoked when the "Show icon in menu bar" checkbox changes, so the caller
    /// can show/hide the status item live. Carries the new value.
    var onToggleMenuBar: ((Bool) -> Void)?

    /// Invoked when the recent-apps cap checkbox changes, so the caller can
    /// register/unregister the ⌥⌘Tab show-all hotkey live. Carries the new value.
    var onToggleLimitRecent: ((Bool) -> Void)?

    private var launchAtLoginCheckbox: NSButton!
    private var menuBarCheckbox: NSButton!
    private var grayscaleCheckbox: NSButton!
    private var declutterTipCheckbox: NSButton!
    private var hideMinimizedCheckbox: NSButton!
    private var limitRecentCheckbox: NSButton!
    private var recentLimitPopup: NSPopUpButton!
    private var limitHintLabel: NSTextField!

    convenience init() {
        let window = NSWindow(
            // Height must cover every stack row; a new checkbox needs ~32pt more
            // (the recent-apps hint sub-row accounts for 18 of the current total).
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Switcher Preferences"
        // Keep the single instance alive across closes.
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        setupContent()
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "Start at login",
            target: self,
            action: #selector(toggleLaunchAtLogin)
        )
        // Hidden (collapsed by the stack view) on macOS < 13 where it's unsupported.
        launchAtLoginCheckbox.isHidden = !LoginItem.isSupported

        menuBarCheckbox = NSButton(
            checkboxWithTitle: "Show icon in menu bar",
            target: self,
            action: #selector(toggleMenuBar)
        )
        grayscaleCheckbox = NSButton(
            checkboxWithTitle: "Grayscale icons",
            target: self,
            action: #selector(toggleGrayscale)
        )
        declutterTipCheckbox = NSButton(
            checkboxWithTitle: "Show declutter tip in switcher",
            target: self,
            action: #selector(toggleDeclutterTip)
        )

        hideMinimizedCheckbox = NSButton(
            checkboxWithTitle: "Hide apps with only minimized windows",
            target: self,
            action: #selector(toggleHideMinimized)
        )

        limitRecentCheckbox = NSButton(
            checkboxWithTitle: "Show only the",
            target: self,
            action: #selector(toggleLimitRecent)
        )
        // A popup rather than a text field: the count has a handful of sensible
        // values, and this way there is no formatter, no clamping and no
        // half-typed state to validate.
        recentLimitPopup = NSPopUpButton()
        recentLimitPopup.addItems(withTitles: (2...12).map(String.init))
        recentLimitPopup.target = self
        recentLimitPopup.action = #selector(changeRecentLimit)

        // The count reads as part of the sentence, so the row is one line:
        // "Show only the [7] most recently used apps".
        let limitRow = NSStackView(views: [
            limitRecentCheckbox,
            recentLimitPopup,
            NSTextField(labelWithString: "most recently used apps")
        ])
        limitRow.orientation = .horizontal
        limitRow.alignment = .firstBaseline
        limitRow.spacing = 6

        // The ⌥⌘Tab escape hatch is otherwise invisible; hidden (and collapsed by
        // the stack view) while the cap is off, when the hotkey isn't registered.
        limitHintLabel = NSTextField(labelWithString: "⌥⌘Tab shows all apps")
        limitHintLabel.font = .systemFont(ofSize: 11)
        limitHintLabel.textColor = .secondaryLabelColor

        let donateButton = NSButton(title: "❤️ Donate", target: self, action: #selector(donate))
        donateButton.bezelStyle = .rounded

        let quitButton = NSButton(title: "Quit Switcher", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded

        let versionLabel = NSTextField(labelWithString: versionString())
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            launchAtLoginCheckbox,
            menuBarCheckbox,
            grayscaleCheckbox,
            declutterTipCheckbox,
            hideMinimizedCheckbox,
            limitRow,
            limitHintLabel,
            donateButton,
            quitButton,
            versionLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(3, after: limitRow)  // the hint reads as part of its row
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20)
        ])
    }

    /// Brings the window to the front. Works for an `.accessory`/LSUIElement app:
    /// activating is required for controls to become clickable, and we stay
    /// `.accessory` so no Dock icon appears.
    func show() {
        syncFromPreferences()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Refresh control states from the current source of truth (they may have
    /// changed via the menu bar, the terminal, or System Settings between shows).
    private func syncFromPreferences() {
        launchAtLoginCheckbox.state = LoginItem.isEnabled ? .on : .off
        menuBarCheckbox.state = Preferences.showMenuBarIcon ? .on : .off
        grayscaleCheckbox.state = Preferences.grayscaleIcons ? .on : .off
        declutterTipCheckbox.state = Preferences.showDeclutterTip ? .on : .off
        hideMinimizedCheckbox.state = Preferences.hideMinimizedOnlyApps ? .on : .off
        limitRecentCheckbox.state = Preferences.limitRecentApps ? .on : .off
        // selectItem(withTitle:) on a value not in the list leaves nothing
        // selected, so fall back to the registered default.
        recentLimitPopup.selectItem(withTitle: String(Preferences.recentAppsLimit))
        if recentLimitPopup.indexOfSelectedItem < 0 {
            recentLimitPopup.selectItem(withTitle: "7")
        }
        recentLimitPopup.isEnabled = Preferences.limitRecentApps
        limitHintLabel.isHidden = !Preferences.limitRecentApps
    }

    private func versionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version.map { "Version \($0)" } ?? ""
    }

    @objc private func toggleLaunchAtLogin() {
        let want = launchAtLoginCheckbox.state == .on
        if !LoginItem.setEnabled(want) {
            // Toggle failed — snap the checkbox back to the real state.
            launchAtLoginCheckbox.state = LoginItem.isEnabled ? .on : .off
        }
    }

    @objc private func toggleMenuBar() {
        let enabled = menuBarCheckbox.state == .on
        Preferences.showMenuBarIcon = enabled
        onToggleMenuBar?(enabled)
    }

    @objc private func toggleGrayscale() {
        // Takes effect on the next Cmd+Tab, since the panel rebuilds its icons.
        Preferences.grayscaleIcons = grayscaleCheckbox.state == .on
    }

    @objc private func toggleDeclutterTip() {
        // Takes effect on the next Cmd+Tab — the panel re-reads the pref in updateHint().
        Preferences.showDeclutterTip = declutterTipCheckbox.state == .on
    }

    @objc private func toggleHideMinimized() {
        // Takes effect on the next Cmd+Tab — AppListProvider re-reads the pref
        // every time it builds the list.
        Preferences.hideMinimizedOnlyApps = hideMinimizedCheckbox.state == .on
    }

    @objc private func toggleLimitRecent() {
        // Takes effect on the next Cmd+Tab — AppListProvider re-reads the pref
        // every time it builds the list. The ⌥⌘Tab hotkey flips immediately,
        // via the callback.
        Preferences.limitRecentApps = limitRecentCheckbox.state == .on
        recentLimitPopup.isEnabled = Preferences.limitRecentApps
        limitHintLabel.isHidden = !Preferences.limitRecentApps
        onToggleLimitRecent?(Preferences.limitRecentApps)
    }

    @objc private func changeRecentLimit() {
        guard let title = recentLimitPopup.titleOfSelectedItem, let count = Int(title) else { return }
        Preferences.recentAppsLimit = count
    }

    @objc private func donate() {
        Preferences.openDonatePage()
    }

    @objc private func quit() {
        // Close the window first, then terminate. `applicationWillTerminate`
        // restores the native Cmd+Tab hotkey on the way out.
        window?.close()
        NSApp.terminate(nil)
    }
}
