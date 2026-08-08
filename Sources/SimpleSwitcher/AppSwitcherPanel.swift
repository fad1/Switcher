import Cocoa

protocol AppSwitcherPanelDelegate: AnyObject {
    func panelDidSelectApp(_ app: AppInfo)
    /// A click landed on a click shield (outside the panel) — dismiss, like Escape.
    func panelDidRequestDismiss()
}

class AppSwitcherPanel: NSPanel, AppItemViewDelegate {
    weak var panelDelegate: AppSwitcherPanelDelegate?

    private var appViews: [AppItemView] = []
    private var rows: [[AppItemView]] = []  // Grid layout: rows of app views
    private var verticalStackView: NSStackView!  // Contains row stack views
    private var selectedRow: Int = 0
    private var selectedColumn: Int = 0
    private var visualEffectView: NSVisualEffectView!

    // Subtle "hide others to declutter" reminder shown at the bottom of the panel
    // only when the switcher has grown cluttered (2+ rows) and the pref is enabled.
    // Renders as plain text at rest and reveals itself as a clickable pill button
    // on hover (see DeclutterHintView). Reused across opens; kept out of the
    // `rows` array so navigation/hit-testing never treat it as an app. See updateHint.
    private var hintView: DeclutterHintView?

    // Dead zone for hover - like AltTab's CursorEvents
    private var deadZoneInitialPosition: NSPoint?
    private var isAllowedToMouseHover = false
    private var mouseMonitor: Any?

    // Mid-open resizes (remove/append) can fire spurious mouseEntered events,
    // so hover is suppressed for ~100ms around them (see
    // suppressHoverDuringResize). The token pairs each delayed restore with its
    // own suppression and the pre-suppression value is captured only by the
    // outermost call, so overlapping suppressions (H twice quickly, or a
    // live-refresh append during a removal) can't clobber each other and leave
    // hover stuck off.
    private var hoverSuppressionToken = 0
    private var hoverAllowedBeforeSuppression: Bool?

    // Invisible per-screen panels that swallow clicks outside the switcher while
    // it's open (the .listenOnly tap can't consume them). See showClickShields.
    private var clickShields: [ClickShieldPanel] = []

    // Recomputed per show based on the target screen (see iconSize(for:)).
    private var itemSize: CGFloat = 76
    // Max items per row, computed from screen width in showWithApps and reused by
    // appendApps so live-added apps pack into rows the same way.
    private var itemsPerRow: Int = 1
    private let itemSpacing: CGFloat = 0
    private let rowSpacing: CGFloat = 4
    private let panelPadding: CGFloat = 10
    private let deadZoneThreshold: CGFloat = 3
    private let screenMarginPercent: CGFloat = 0.85  // Use max 85% of screen width

    // Icon scaling: base size on a reference-height display, scaled up for
    // larger monitors so icons stay legible. Floored at the base so laptops
    // and standard displays never shrink; capped so it can't get absurd.
    private let baseItemSize: CGFloat = 76
    private let maxItemSize: CGFloat = 160
    private let referenceScreenHeight: CGFloat = 1080

    /// Item/icon size scaled to the given screen's point height.
    private func iconSize(for screen: NSScreen) -> CGFloat {
        let scaled = baseItemSize * (screen.frame.height / referenceScreenHeight)
        return min(max(scaled, baseItemSize), maxItemSize)
    }

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
        let effectView = HoverTrackingVisualEffectView()
        effectView.onMouseMovement = { [weak self] in self?.handleMouseMoved() }
        visualEffectView = effectView
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
        // Clear any leftover views (normally already cleared on hide). The panel
        // is rebuilt from scratch every open, so this is just defensive.
        clearAppViews()

        // Find screen containing mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = targetScreen.visibleFrame

        // Scale icon size to this screen (bigger monitors get bigger icons)
        itemSize = iconSize(for: targetScreen)

        // Calculate max items per row based on screen width
        let maxPanelWidth = screenFrame.width * screenMarginPercent
        let availableWidth = maxPanelWidth - panelPadding * 2
        itemsPerRow = max(1, Int(floor((availableWidth + itemSpacing) / (itemSize + itemSpacing))))

        // Create app views and organize into rows
        var currentRow: [AppItemView] = []
        var currentRowStackView = createRowStackView()

        for (index, app) in apps.enumerated() {
            let itemView = AppItemView(appInfo: app, itemSize: itemSize)
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

        // Show the "start fresh" hint when the switcher has grown cluttered (2+ rows).
        let showingHint = updateHint()

        // Calculate panel size (including the hint row if shown)
        let size = panelSize(showingHint: showingHint)

        // Center panel on target screen
        let panelX = screenFrame.midX - size.width / 2
        let panelY = screenFrame.midY - size.height / 2

        setFrame(NSRect(x: panelX, y: panelY, width: size.width, height: size.height), display: true)

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
        cancelHoverSuppression()
        startMouseMonitor()

        showClickShields()
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

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }
    }

    private func handleMouseMoved() {
        let currentPos = NSEvent.mouseLocation

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

        if frame.contains(currentPos) {
            selectAppUnderMouse()
            updateHintHover()
        } else {
            hintView?.setHovered(false)
        }
    }

    private func selectAppUnderMouse() {
        // Use mouseLocationOutsideOfEventStream for accurate position in non-activating panel
        let windowPoint = mouseLocationOutsideOfEventStream

        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, view) in row.enumerated() {
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

    /// Reveal/unreveal the hint's button styling based on the pointer position.
    /// Only called once the dead zone has been crossed (from handleMouseMoved),
    /// so the button never flashes just because the panel opened under the cursor.
    private func updateHintHover() {
        guard let hint = hintView, hint.superview != nil else { return }
        let windowPoint = mouseLocationOutsideOfEventStream
        hint.setHovered(hint.convert(hint.bounds, to: nil).contains(windowPoint))
    }

    /// True when the pointer is on the hint AND the hint is currently revealed
    /// as a button. Requiring the revealed state means a click can only trigger
    /// Hide Others after the hover styling made the consequence visible —
    /// a stray click just below the bottom icon row can't hide everything.
    func isMouseOverHintButton() -> Bool {
        guard let hint = hintView, hint.superview != nil, hint.isHovered else { return false }
        return hint.convert(hint.bounds, to: nil).contains(mouseLocationOutsideOfEventStream)
    }

    /// App under the current mouse position, independent of dead-zone hover state.
    func getAppUnderMouse() -> AppInfo? {
        return getAppAtPoint(mouseLocationOutsideOfEventStream)
    }

    func getAppAtPoint(_ windowPoint: NSPoint) -> AppInfo? {
        for row in rows {
            for view in row {
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

    // MARK: - Click Shields

    /// Cover every screen with an invisible panel one window level below the
    /// switcher while it's open. The event tap is .listenOnly and cannot consume
    /// events, so without these a click outside the panel would also land in the
    /// app under the cursor. The shields catch that click via ordinary
    /// window-server routing (no permissions involved) and request a dismiss —
    /// click-away behaves like Escape. Clicks on the switcher itself are
    /// unaffected: it floats above the shields.
    /// Recreated per open (screens can change) and released on hide so their
    /// full-screen backing stores don't stay resident between switches.
    private func showClickShields() {
        hideClickShields()
        for screen in NSScreen.screens {
            let shield = ClickShieldPanel(screenFrame: screen.frame)
            shield.onClick = { [weak self] in self?.panelDelegate?.panelDidRequestDismiss() }
            shield.orderFront(nil)
            clickShields.append(shield)
        }
    }

    private func hideClickShields() {
        clickShields.forEach { $0.orderOut(nil) }
        clickShields.removeAll()
    }

    func hidePanel() {
        stopMouseMonitor()
        hideClickShields()
        deadZoneInitialPosition = nil
        isAllowedToMouseHover = false
        cancelHoverSuppression()
        // Also restores the arrow cursor if the panel closes mid-hover.
        hintView?.setHovered(false)
        orderOut(nil)
        // Release the item views (and their icon image references) while closed,
        // so they don't sit resident between switches. The next open rebuilds
        // everything anyway, so this costs no rebuild latency.
        clearAppViews()
    }

    /// Tear down all app item views and their containing row stack views.
    private func clearAppViews() {
        appViews.forEach { $0.removeFromSuperview() }
        appViews.removeAll()
        rows.removeAll()
        for subview in verticalStackView.arrangedSubviews {
            verticalStackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
    }

    /// Next/previous walk the grid in reading order and wrap at both ends.
    /// Up/down move by row only, clamping the column because the last row is
    /// usually shorter, and are no-ops in a single-row panel.
    func selectNext() {
        guard !rows.isEmpty else { return }

        if selectedColumn < rows[selectedRow].count - 1 {
            selectedColumn += 1
        } else {
            if selectedRow < rows.count - 1 {
                selectedRow += 1
                selectedColumn = 0
            } else {
                selectedRow = 0
                selectedColumn = 0
            }
        }
        updateSelection()
    }

    func selectPrevious() {
        guard !rows.isEmpty else { return }

        if selectedColumn > 0 {
            selectedColumn -= 1
        } else {
            if selectedRow > 0 {
                selectedRow -= 1
                selectedColumn = rows[selectedRow].count - 1
            } else {
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
            selectedRow = rows.count - 1
        }
        selectedColumn = min(selectedColumn, rows[selectedRow].count - 1)
        updateSelection()
    }

    func selectDown() {
        guard rows.count > 1 else { return }

        if selectedRow < rows.count - 1 {
            selectedRow += 1
        } else {
            selectedRow = 0
        }
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

        suppressHoverDuringResize()

        if let flatIndex = appViews.firstIndex(where: { $0 === removedView }) {
            appViews.remove(at: flatIndex)
        }

        if let rowStackView = removedView.superview as? NSStackView {
            rowStackView.removeArrangedSubview(removedView)
            removedView.removeFromSuperview()
        }

        rows[selectedRow].remove(at: selectedColumn)

        if rows[selectedRow].isEmpty {
            if let rowStackView = verticalStackView.arrangedSubviews[safe: selectedRow] {
                verticalStackView.removeArrangedSubview(rowStackView)
                rowStackView.removeFromSuperview()
            }
            rows.remove(at: selectedRow)
        }

        // -1/-1 marks "no selection"; getSelectedApp and removeSelectedApp both
        // range-check, so an empty panel returns nil rather than trapping.
        if rows.isEmpty {
            selectedRow = -1
            selectedColumn = -1
        } else {
            if selectedRow >= rows.count {
                selectedRow = rows.count - 1
            }
            if selectedColumn >= rows[selectedRow].count {
                selectedColumn = rows[selectedRow].count - 1
            }
        }

        // Update panel size (hint may drop off if we fell below 2 rows)
        if !rows.isEmpty {
            resizeKeepingCenter()
            updateSelection()
        }

        return removedApp
    }

    /// Append newly-appeared apps to the end of the grid WITHOUT disturbing the
    /// existing items or the current selection (unlike showWithApps, which fully
    /// rebuilds, recenters on screen, resets the dead zone, and re-orders front).
    /// Driven by AppDelegate's live-refresh timer while the panel is open.
    func appendApps(_ apps: [AppInfo]) {
        guard !apps.isEmpty, !rows.isEmpty else { return }

        suppressHoverDuringResize()

        // Detach the hint (it's the last arranged subview) so new rows append before
        // it; updateHint() re-adds it last afterward.
        if let existing = hintView, existing.superview != nil {
            verticalStackView.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }

        // The current last row's horizontal stack view (its items share it as superview).
        var currentRowStackView = rows.last?.first?.superview as? NSStackView

        for app in apps {
            // Start a new row if the current one is full or missing.
            if currentRowStackView == nil || (rows.last?.count ?? itemsPerRow) >= itemsPerRow {
                let rowStack = createRowStackView()
                verticalStackView.addArrangedSubview(rowStack)
                rows.append([])
                currentRowStackView = rowStack
            }
            let itemView = AppItemView(appInfo: app, itemSize: itemSize)
            itemView.delegate = self
            appViews.append(itemView)
            currentRowStackView?.addArrangedSubview(itemView)
            rows[rows.count - 1].append(itemView)
        }

        resizeKeepingCenter()

        // Selection indices are unchanged (append-only), just repaint highlight.
        updateSelection()
    }

    var hasApps: Bool {
        !rows.isEmpty
    }

    // MARK: - Private Methods

    /// Panel size from the current `rows`, adding a row for the hint when shown.
    /// Single source of truth so `showWithApps` and `removeSelectedApp` stay consistent.
    private func panelSize(showingHint: Bool) -> CGSize {
        let rowCount = rows.count
        let maxRowCount = rows.map { $0.count }.max() ?? 1
        var width = CGFloat(maxRowCount) * itemSize + CGFloat(maxRowCount - 1) * itemSpacing + panelPadding * 2
        var height = CGFloat(rowCount) * itemSize + CGFloat(rowCount - 1) * rowSpacing + panelPadding * 2
        if showingHint, let hint = hintView {
            let hintSize = hint.fittingSize
            height += rowSpacing + hintSize.height        // stack spacing + hint pill
            width = max(width, hintSize.width + panelPadding * 2)  // don't clip a wide hint
        }
        return CGSize(width: width, height: height)
    }

    /// Re-attach the hint if warranted, then resize to fit the current rows,
    /// keeping the panel's center fixed (NOT recentering on screen — the panel
    /// is already placed). Shared by removeSelectedApp and appendApps.
    private func resizeKeepingCenter() {
        let showingHint = updateHint()
        let size = panelSize(showingHint: showingHint)
        var frame = self.frame
        let centerX = frame.midX
        let centerY = frame.midY
        frame.size = size
        frame.origin.x = centerX - size.width / 2
        frame.origin.y = centerY - size.height / 2
        setFrame(frame, display: true)
    }

    /// Suppress hover briefly around a mid-open resize, restoring the
    /// pre-suppression value once things settle (see the token/value members).
    private func suppressHoverDuringResize() {
        if hoverAllowedBeforeSuppression == nil {
            hoverAllowedBeforeSuppression = isAllowedToMouseHover
        }
        isAllowedToMouseHover = false
        hoverSuppressionToken += 1
        let token = hoverSuppressionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.hoverSuppressionToken == token else { return }
            if let allowed = self.hoverAllowedBeforeSuppression {
                self.isAllowedToMouseHover = allowed
                self.hoverAllowedBeforeSuppression = nil
            }
        }
    }

    /// Drop any pending hover restore. Called when the panel opens or closes,
    /// where hover state is reset wholesale — a stale restore from the previous
    /// open must not re-enable hover past the fresh dead zone.
    private func cancelHoverSuppression() {
        hoverSuppressionToken += 1
        hoverAllowedBeforeSuppression = nil
    }

    /// Attach the hint as the last arranged subview when cluttered (2+ rows), else
    /// detach it. Appended last so it never shifts a row's index in the stack (which
    /// `removeSelectedApp` relies on). Returns whether the hint is now showing.
    @discardableResult
    private func updateHint() -> Bool {
        // Always detach first: avoids a double-add and keeps hide/rebuild clean.
        // Unhovering here also drops stale button styling across rebuilds/resizes;
        // the next mouse move re-reveals it if the pointer is still on the hint.
        if let existing = hintView, existing.superview != nil {
            existing.setHovered(false)
            verticalStackView.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }
        guard Preferences.showDeclutterTip, rows.count >= 2 else { return false }
        let view = hintView ?? DeclutterHintView()
        hintView = view
        verticalStackView.addArrangedSubview(view)
        return true
    }

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

// MARK: - Declutter Hint View

/// The declutter tip at the bottom of the panel. Looks like a plain caption at
/// rest; once the pointer is over it (past the dead zone) it reveals itself as
/// a pill button — same highlight as a selected app — with a pointing-hand
/// cursor. The pill hugs the text (a few points of padding), so the clickable
/// area stays narrow. Clicks are routed by AppDelegate.mouseClicked via
/// isMouseOverHintButton(); this view draws, it doesn't handle events.
private class DeclutterHintView: NSView {
    private let label: NSTextField
    private(set) var isHovered = false

    private let horizontalPadding: CGFloat = 9
    private let verticalPadding: CGFloat = 4

    init() {
        label = NSTextField(labelWithString: "⌥⌘H · Hide others — fewer icons here")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2  // full pill
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        layer?.backgroundColor = hovered ? NSColor.white.withAlphaComponent(0.3).cgColor : nil
        label.textColor = hovered ? .labelColor : .secondaryLabelColor
        // The panel never becomes key, so cursor rects don't fire; set directly.
        if hovered {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

// MARK: - Hover Tracking Effect View

/// The panel's content view; forwards any mouse movement over the panel to the
/// hover logic. Hover normally rides a global mouseMoved monitor, but global
/// monitors never see the app's OWN events — so when Switcher itself is the
/// active app (e.g. Cmd+Tab right after using the Preferences window) the
/// monitor goes silent and hover selection dies. This tracking area fires
/// regardless of which app is active. Both paths call handleMouseMoved, which
/// is idempotent, so double delivery is harmless.
private class HoverTrackingVisualEffectView: NSVisualEffectView {
    var onMouseMovement: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { onMouseMovement?() }
    override func mouseEntered(with event: NSEvent) { onMouseMovement?() }
    override func mouseExited(with event: NSEvent) { onMouseMovement?() }
}

// MARK: - Click Shield

/// Invisible, non-activating panel covering one screen just below the switcher.
/// Swallows clicks that would otherwise fall through to the app behind the
/// panel and reports them so the switcher can dismiss.
private class ClickShieldPanel: NSPanel {
    var onClick: (() -> Void)?

    init(screenFrame: NSRect) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // One notch below the switcher panel (.popUpMenu) so it never covers it.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        // Not .clear: the window server treats fully transparent windows as
        // click-through; a hair of alpha keeps clicks landing here. Explicitly
        // setting ignoresMouseEvents=false also opts out of that automatism.
        backgroundColor = NSColor.black.withAlphaComponent(0.001)
        ignoresMouseEvents = false
        contentView = ClickShieldView(onClick: { [weak self] in self?.onClick?() })
    }
}

private class ClickShieldView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The shield is non-activating and never key, so the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }
    override func otherMouseDown(with event: NSEvent) { onClick() }
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
