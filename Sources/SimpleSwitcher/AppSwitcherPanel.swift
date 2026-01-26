import Cocoa

protocol AppSwitcherPanelDelegate: AnyObject {
    func panelDidSelectApp(_ app: AppInfo)
}

class AppSwitcherPanel: NSPanel, AppItemViewDelegate {
    weak var panelDelegate: AppSwitcherPanelDelegate?

    private var appViews: [AppItemView] = []
    private var rows: [[AppItemView]] = []  // Grid layout: rows of app views
    private var verticalStackView: NSStackView!  // Contains row stack views
    private var selectedRow: Int = 0
    private var selectedColumn: Int = 0
    private var visualEffectView: NSVisualEffectView!

    // Dead zone for hover - like AltTab's CursorEvents
    private var deadZoneInitialPosition: NSPoint?
    private var isAllowedToMouseHover = false
    private var mouseMonitor: Any?

    private let itemSize: CGFloat = 76
    private let itemSpacing: CGFloat = 0
    private let rowSpacing: CGFloat = 4
    private let panelPadding: CGFloat = 10
    private let deadZoneThreshold: CGFloat = 3
    private let screenMarginPercent: CGFloat = 0.85  // Use max 85% of screen width

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

        // Add darkening overlay for light mode (transparent in dark mode)
        let darkeningView = AppearanceAdaptiveView()
        darkeningView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(darkeningView)
        NSLayoutConstraint.activate([
            darkeningView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            darkeningView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            darkeningView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            darkeningView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

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
        verticalStackView = NSStackView()
        verticalStackView.orientation = .vertical
        verticalStackView.spacing = rowSpacing
        verticalStackView.alignment = .centerX
        verticalStackView.translatesAutoresizingMaskIntoConstraints = false

        visualEffectView.addSubview(verticalStackView)

        NSLayoutConstraint.activate([
            verticalStackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: panelPadding),
            verticalStackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -panelPadding),
            verticalStackView.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: panelPadding),
            verticalStackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -panelPadding)
        ])
    }

    // MARK: - Public Methods

    func showWithApps(_ apps: [AppInfo], selectIndex: Int = 1) {
        // Clear existing views
        appViews.forEach { $0.removeFromSuperview() }
        appViews.removeAll()
        rows.removeAll()

        // Clear existing row stack views
        for subview in verticalStackView.arrangedSubviews {
            verticalStackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        // Find screen containing mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = targetScreen.visibleFrame

        // Calculate max items per row based on screen width
        let maxPanelWidth = screenFrame.width * screenMarginPercent
        let availableWidth = maxPanelWidth - panelPadding * 2
        let itemsPerRow = max(1, Int(floor((availableWidth + itemSpacing) / (itemSize + itemSpacing))))

        // Create app views and organize into rows
        var currentRow: [AppItemView] = []
        var currentRowStackView = createRowStackView()

        for (index, app) in apps.enumerated() {
            let itemView = AppItemView(appInfo: app)
            itemView.delegate = self
            appViews.append(itemView)
            currentRow.append(itemView)
            currentRowStackView.addArrangedSubview(itemView)

            // Start new row if current row is full
            if currentRow.count >= itemsPerRow && index < apps.count - 1 {
                rows.append(currentRow)
                verticalStackView.addArrangedSubview(currentRowStackView)
                currentRow = []
                currentRowStackView = createRowStackView()
            }
        }

        // Add final row if it has items
        if !currentRow.isEmpty {
            rows.append(currentRow)
            verticalStackView.addArrangedSubview(currentRowStackView)
        }

        // Calculate panel size
        let rowCount = rows.count
        let maxRowCount = rows.map { $0.count }.max() ?? 1
        let panelWidth = CGFloat(maxRowCount) * itemSize + CGFloat(maxRowCount - 1) * itemSpacing + panelPadding * 2
        let panelHeight = CGFloat(rowCount) * itemSize + CGFloat(rowCount - 1) * rowSpacing + panelPadding * 2

        // Center panel on target screen
        let panelX = screenFrame.midX - panelWidth / 2
        let panelY = screenFrame.midY - panelHeight / 2

        setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight), display: true)

        // Select initial app (convert flat index to row/column)
        let adjustedIndex = min(selectIndex, apps.count - 1)
        if adjustedIndex >= 0 {
            selectedRow = adjustedIndex / itemsPerRow
            selectedColumn = adjustedIndex % itemsPerRow
            // Clamp to valid range for last row
            if selectedRow >= rows.count {
                selectedRow = rows.count - 1
                selectedColumn = rows[selectedRow].count - 1
            } else if selectedColumn >= rows[selectedRow].count {
                selectedColumn = rows[selectedRow].count - 1
            }
            updateSelection()
        }

        // Reset dead zone - hover will be enabled after mouse moves 3+ pixels
        deadZoneInitialPosition = nil
        isAllowedToMouseHover = false
        startMouseMonitor()

        orderFront(nil)
    }

    private func createRowStackView() -> NSStackView {
        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.spacing = itemSpacing
        rowStack.alignment = .centerY
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        return rowStack
    }

    private func startMouseMonitor() {
        stopMouseMonitor()

        // Single global monitor for mouse movement
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }
    }

    private func handleMouseMoved() {
        let currentPos = NSEvent.mouseLocation

        // Dead zone logic (like AltTab's CursorEvents)
        if !isAllowedToMouseHover {
            if deadZoneInitialPosition == nil {
                deadZoneInitialPosition = currentPos
                return
            }
            let dx = currentPos.x - deadZoneInitialPosition!.x
            let dy = currentPos.y - deadZoneInitialPosition!.y
            let distance = hypot(dx, dy)
            if distance > deadZoneThreshold {
                isAllowedToMouseHover = true
            } else {
                return
            }
        }

        // Hover enabled - update selection if mouse is over panel
        if frame.contains(currentPos) {
            selectAppUnderMouse()
        }
    }

    private func selectAppUnderMouse() {
        // Use mouseLocationOutsideOfEventStream for accurate position in non-activating panel
        let windowPoint = mouseLocationOutsideOfEventStream

        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, view) in row.enumerated() {
                // Convert view bounds to window coordinates
                let viewFrame = view.convert(view.bounds, to: nil)
                if viewFrame.contains(windowPoint) {
                    if selectedRow != rowIndex || selectedColumn != colIndex {
                        selectedRow = rowIndex
                        selectedColumn = colIndex
                        updateSelection()
                    }
                    return
                }
            }
        }
    }

    func getAppAtPoint(_ windowPoint: NSPoint) -> AppInfo? {
        for row in rows {
            for view in row {
                // Convert view bounds to window coordinates
                let viewFrame = view.convert(view.bounds, to: nil)
                if viewFrame.contains(windowPoint) {
                    return view.appInfo
                }
            }
        }
        return nil
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    func hidePanel() {
        stopMouseMonitor()
        deadZoneInitialPosition = nil
        isAllowedToMouseHover = false
        orderOut(nil)
    }

    func selectNext() {
        guard !rows.isEmpty else { return }

        // Move right in current row
        if selectedColumn < rows[selectedRow].count - 1 {
            selectedColumn += 1
        } else {
            // Move to next row, first column
            if selectedRow < rows.count - 1 {
                selectedRow += 1
                selectedColumn = 0
            } else {
                // Wrap to first row, first column
                selectedRow = 0
                selectedColumn = 0
            }
        }
        updateSelection()
    }

    func selectPrevious() {
        guard !rows.isEmpty else { return }

        // Move left in current row
        if selectedColumn > 0 {
            selectedColumn -= 1
        } else {
            // Move to previous row, last column
            if selectedRow > 0 {
                selectedRow -= 1
                selectedColumn = rows[selectedRow].count - 1
            } else {
                // Wrap to last row, last column
                selectedRow = rows.count - 1
                selectedColumn = rows[selectedRow].count - 1
            }
        }
        updateSelection()
    }

    func selectUp() {
        guard rows.count > 1 else { return }

        if selectedRow > 0 {
            selectedRow -= 1
        } else {
            // Wrap to last row
            selectedRow = rows.count - 1
        }
        // Clamp column to row length
        selectedColumn = min(selectedColumn, rows[selectedRow].count - 1)
        updateSelection()
    }

    func selectDown() {
        guard rows.count > 1 else { return }

        if selectedRow < rows.count - 1 {
            selectedRow += 1
        } else {
            // Wrap to first row
            selectedRow = 0
        }
        // Clamp column to row length
        selectedColumn = min(selectedColumn, rows[selectedRow].count - 1)
        updateSelection()
    }

    func getSelectedApp() -> AppInfo? {
        guard selectedRow >= 0 && selectedRow < rows.count else { return nil }
        guard selectedColumn >= 0 && selectedColumn < rows[selectedRow].count else { return nil }
        return rows[selectedRow][selectedColumn].appInfo
    }

    func removeSelectedApp() -> AppInfo? {
        guard selectedRow >= 0 && selectedRow < rows.count else { return nil }
        guard selectedColumn >= 0 && selectedColumn < rows[selectedRow].count else { return nil }

        let removedView = rows[selectedRow][selectedColumn]
        let removedApp = removedView.appInfo

        // Temporarily disable hover during removal (panel resize can trigger mouseEntered)
        let wasAllowed = isAllowedToMouseHover
        isAllowedToMouseHover = false

        // Remove from flat list
        if let flatIndex = appViews.firstIndex(where: { $0 === removedView }) {
            appViews.remove(at: flatIndex)
        }

        // Remove from current row's stack view
        if let rowStackView = removedView.superview as? NSStackView {
            rowStackView.removeArrangedSubview(removedView)
            removedView.removeFromSuperview()
        }

        // Remove from rows array
        rows[selectedRow].remove(at: selectedColumn)

        // Remove empty rows
        if rows[selectedRow].isEmpty {
            if let rowStackView = verticalStackView.arrangedSubviews[safe: selectedRow] {
                verticalStackView.removeArrangedSubview(rowStackView)
                rowStackView.removeFromSuperview()
            }
            rows.remove(at: selectedRow)
        }

        // Adjust selection
        if rows.isEmpty {
            selectedRow = -1
            selectedColumn = -1
        } else {
            // Clamp row
            if selectedRow >= rows.count {
                selectedRow = rows.count - 1
            }
            // Clamp column
            if selectedColumn >= rows[selectedRow].count {
                selectedColumn = rows[selectedRow].count - 1
            }
        }

        // Update panel size
        if !rows.isEmpty {
            let rowCount = rows.count
            let maxRowCount = rows.map { $0.count }.max() ?? 1
            let panelWidth = CGFloat(maxRowCount) * itemSize + CGFloat(maxRowCount - 1) * itemSpacing + panelPadding * 2
            let panelHeight = CGFloat(rowCount) * itemSize + CGFloat(rowCount - 1) * rowSpacing + panelPadding * 2

            var frame = self.frame
            let centerX = frame.midX
            let centerY = frame.midY
            frame.size.width = panelWidth
            frame.size.height = panelHeight
            frame.origin.x = centerX - panelWidth / 2
            frame.origin.y = centerY - panelHeight / 2
            setFrame(frame, display: true)

            updateSelection()
        }

        // Restore hover state after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isAllowedToMouseHover = wasAllowed
        }

        return removedApp
    }

    var hasApps: Bool {
        !rows.isEmpty
    }

    // MARK: - Private Methods

    private func updateSelection() {
        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, view) in row.enumerated() {
                view.setSelected(rowIndex == selectedRow && colIndex == selectedColumn)
            }
        }
    }

    // MARK: - AppItemViewDelegate

    func appItemHovered(_ view: AppItemView) {
        guard isAllowedToMouseHover else { return }
        for (rowIndex, row) in rows.enumerated() {
            if let colIndex = row.firstIndex(where: { $0 === view }) {
                selectedRow = rowIndex
                selectedColumn = colIndex
                updateSelection()
                return
            }
        }
    }
}

// MARK: - Array Safe Subscript Extension

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Appearance Adaptive View

/// A view that darkens the background in light mode only
private class AppearanceAdaptiveView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = isDark ? nil : NSColor.black.withAlphaComponent(0.35).cgColor
    }
}
