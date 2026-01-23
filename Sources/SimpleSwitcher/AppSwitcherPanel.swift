import Cocoa

protocol AppSwitcherPanelDelegate: AnyObject {
    func panelDidSelectApp(_ app: AppInfo)
}

class AppSwitcherPanel: NSPanel, AppItemViewDelegate {
    weak var panelDelegate: AppSwitcherPanelDelegate?

    private var appViews: [AppItemView] = []
    private var stackView: NSStackView!
    private var selectedIndex: Int = 0
    private var visualEffectView: NSVisualEffectView!

    private let itemSpacing: CGFloat = 8
    private let panelPadding: CGFloat = 16

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 132),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        setupPanel()
        setupVisualEffectView()
        setupStackView()
    }

    private func setupPanel() {
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    private func setupVisualEffectView() {
        visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.maskImage = maskImage(cornerRadius: 16)

        contentView = visualEffectView
    }

    private func maskImage(cornerRadius: CGFloat) -> NSImage {
        let edgeLength = 2.0 * cornerRadius + 1.0
        let size = NSSize(width: edgeLength, height: edgeLength)
        let image = NSImage(size: size, flipped: false) { rect in
            let bezierPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            bezierPath.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    private func setupStackView() {
        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = itemSpacing
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        visualEffectView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: panelPadding),
            stackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -panelPadding),
            stackView.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: panelPadding),
            stackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -panelPadding)
        ])
    }

    // MARK: - Public Methods

    func showWithApps(_ apps: [AppInfo], selectIndex: Int = 1) {
        // Clear existing views
        appViews.forEach { $0.removeFromSuperview() }
        appViews.removeAll()

        // Create new views
        for app in apps {
            let itemView = AppItemView(appInfo: app)
            itemView.delegate = self
            appViews.append(itemView)
            stackView.addArrangedSubview(itemView)
        }

        // Update panel size
        let itemWidth: CGFloat = 80
        let panelWidth = CGFloat(apps.count) * itemWidth + CGFloat(apps.count - 1) * itemSpacing + panelPadding * 2
        let panelHeight: CGFloat = 132

        // Find screen containing mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first!

        // Center panel on target screen
        let screenFrame = targetScreen.visibleFrame
        let panelX = screenFrame.midX - panelWidth / 2
        let panelY = screenFrame.midY - panelHeight / 2

        setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight), display: true)

        // Select initial app
        selectedIndex = min(selectIndex, apps.count - 1)
        if selectedIndex >= 0 && selectedIndex < appViews.count {
            updateSelection()
        }

        orderFront(nil)
    }

    func hidePanel() {
        orderOut(nil)
    }

    func selectNext() {
        guard !appViews.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % appViews.count
        updateSelection()
    }

    func selectPrevious() {
        guard !appViews.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + appViews.count) % appViews.count
        updateSelection()
    }

    func getSelectedApp() -> AppInfo? {
        guard selectedIndex >= 0 && selectedIndex < appViews.count else { return nil }
        return appViews[selectedIndex].appInfo
    }

    func removeSelectedApp() -> AppInfo? {
        guard selectedIndex >= 0 && selectedIndex < appViews.count else { return nil }

        let removedApp = appViews[selectedIndex].appInfo
        let removedView = appViews[selectedIndex]

        // Remove view
        stackView.removeArrangedSubview(removedView)
        removedView.removeFromSuperview()
        appViews.remove(at: selectedIndex)

        // Adjust selection
        if appViews.isEmpty {
            selectedIndex = -1
        } else if selectedIndex >= appViews.count {
            selectedIndex = appViews.count - 1
        }

        // Update panel size
        if !appViews.isEmpty {
            let itemWidth: CGFloat = 80
            let panelWidth = CGFloat(appViews.count) * itemWidth + CGFloat(appViews.count - 1) * itemSpacing + panelPadding * 2

            var frame = self.frame
            let centerX = frame.midX
            frame.size.width = panelWidth
            frame.origin.x = centerX - panelWidth / 2
            setFrame(frame, display: true)

            updateSelection()
        }

        return removedApp
    }

    var hasApps: Bool {
        !appViews.isEmpty
    }

    // MARK: - Private Methods

    private func updateSelection() {
        for (index, view) in appViews.enumerated() {
            view.setSelected(index == selectedIndex)
        }
    }

    // MARK: - AppItemViewDelegate

    func appItemHovered(_ view: AppItemView) {
        if let index = appViews.firstIndex(where: { $0 === view }) {
            selectedIndex = index
            updateSelection()
        }
    }
}
