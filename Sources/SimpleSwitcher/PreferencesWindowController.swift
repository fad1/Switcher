import Cocoa

/// A small, reusable Preferences window built programmatically.
/// One instance is held by AppDelegate and reused on every show/reopen.
class PreferencesWindowController: NSWindowController {

    /// Invoked when the "Show icon in menu bar" checkbox changes, so the caller
    /// can show/hide the status item live. Carries the new value.
    var onToggleMenuBar: ((Bool) -> Void)?

    private var menuBarCheckbox: NSButton!
    private var grayscaleCheckbox: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
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

        let donateButton = NSButton(title: "❤️ Donate", target: self, action: #selector(donate))
        donateButton.bezelStyle = .rounded

        let versionLabel = NSTextField(labelWithString: versionString())
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            menuBarCheckbox,
            grayscaleCheckbox,
            donateButton,
            versionLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
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

    /// Refresh checkbox states from persisted values (they may have changed via
    /// the menu bar Donate item or the terminal between shows).
    private func syncFromPreferences() {
        menuBarCheckbox.state = Preferences.showMenuBarIcon ? .on : .off
        grayscaleCheckbox.state = Preferences.grayscaleIcons ? .on : .off
    }

    private func versionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version.map { "Version \($0)" } ?? ""
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

    @objc private func donate() {
        Preferences.openDonatePage()
    }
}
