import Cocoa
import Carbon

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyTriggered()
    func modifierKeyReleased()
    func keyPressed(_ keyCode: UInt16)
    func shiftPressed()
    func mouseClicked(at point: CGPoint)
}

class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private static let signature: OSType = {
        "smpl".utf16.reduce(0) { ($0 << 8) + OSType($1) }
    }()

    private var hotKeyPressedHandler: EventHandlerRef?
    private var tabHotKeyRef: EventHotKeyRef?
    private var activeHotKeyRefs: [EventHotKeyRef?] = []
    private var eventTap: CFMachPort?

    // Dedicated thread + run loop that services the event tap, so its callback is
    // never starved by main-thread UI work (see setupEventTap for rationale).
    private var eventTapThread: Thread?
    private var eventTapRunLoop: CFRunLoop?

    // Serial queue for thread-safe state access
    private let stateQueue = DispatchQueue(label: "com.simpleswitcher.state")

    // Backstop watchdog (see startCmdWatchdog) — polls live modifier state while
    // the panel is active in case the .listenOnly tap drops the Cmd-up event.
    private var cmdWatchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.simpleswitcher.cmdwatchdog")

    // State protected by stateQueue
    private var _isActive = false
    private var _shiftWasDown = false

    var isActive: Bool {
        get { stateQueue.sync { _isActive } }
        set { stateQueue.sync { _isActive = newValue } }
    }

    private var shiftWasDown: Bool {
        get { stateQueue.sync { _shiftWasDown } }
        set { stateQueue.sync { _shiftWasDown = newValue } }
    }

    // Hotkey IDs - using actual key codes for easy mapping
    private enum HotkeyID: UInt32 {
        case tab = 1        // Cmd+Tab - activate/next
        case h = 2          // Cmd+H - hide
        case q = 3          // Cmd+Q - quit
        case leftArrow = 4  // Cmd+Left - previous
        case rightArrow = 5 // Cmd+Right - next
        case escape = 6     // Cmd+Escape - dismiss
        case returnKey = 7  // Cmd+Return - activate
        case upArrow = 8    // Cmd+Up - previous row
        case downArrow = 9  // Cmd+Down - next row
    }

    // Map hotkey IDs to key codes for delegate
    private static let hotkeyToKeyCode: [UInt32: UInt16] = [
        HotkeyID.tab.rawValue: UInt16(kVK_Tab),
        HotkeyID.h.rawValue: UInt16(kVK_ANSI_H),
        HotkeyID.q.rawValue: UInt16(kVK_ANSI_Q),
        HotkeyID.leftArrow.rawValue: UInt16(kVK_LeftArrow),
        HotkeyID.rightArrow.rawValue: UInt16(kVK_RightArrow),
        HotkeyID.upArrow.rawValue: UInt16(kVK_UpArrow),
        HotkeyID.downArrow.rawValue: UInt16(kVK_DownArrow),
        HotkeyID.escape.rawValue: UInt16(kVK_Escape),
        HotkeyID.returnKey.rawValue: UInt16(kVK_Return),
    ]

    func stop() {
        // Unregister tab hotkey
        if let ref = tabHotKeyRef {
            UnregisterEventHotKey(ref)
            tabHotKeyRef = nil
        }

        // Unregister active hotkeys
        unregisterActiveHotkeys()

        if let handler = hotKeyPressedHandler {
            RemoveEventHandler(handler)
            hotKeyPressedHandler = nil
        }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        // Stop the dedicated event-tap thread's run loop so the thread can exit
        if let runLoop = eventTapRunLoop {
            CFRunLoopStop(runLoop)
            eventTapRunLoop = nil
        }
        eventTapThread = nil
    }

    /// Register hotkeys that only work when panel is active (Cmd+H, Cmd+Q, etc.)
    func registerActiveHotkeys() {
        guard activeHotKeyRefs.isEmpty else { return }

        let eventTarget = GetEventDispatcherTarget()

        let hotkeys: [(HotkeyID, Int)] = [
            (.h, kVK_ANSI_H),
            (.q, kVK_ANSI_Q),
            (.leftArrow, kVK_LeftArrow),
            (.rightArrow, kVK_RightArrow),
            (.upArrow, kVK_UpArrow),
            (.downArrow, kVK_DownArrow),
            (.escape, kVK_Escape),
            (.returnKey, kVK_Return),
        ]

        for (hotkeyID, keyCode) in hotkeys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: hotkeyID.rawValue)
            RegisterEventHotKey(UInt32(keyCode), UInt32(cmdKey), id, eventTarget, UInt32(kEventHotKeyNoOptions), &ref)
            activeHotKeyRefs.append(ref)
        }

        // Second layer of the sticky-panel defense (the dedicated tap thread is
        // the first): a poll that dismisses even if the Cmd-up event is dropped.
        startCmdWatchdog()
    }

    /// Unregister active-only hotkeys so they work normally in other apps
    func unregisterActiveHotkeys() {
        stopCmdWatchdog()
        for ref in activeHotKeyRefs {
            if let ref = ref {
                UnregisterEventHotKey(ref)
            }
        }
        activeHotKeyRefs.removeAll()
    }

    // MARK: - Cmd-release Watchdog

    /// Backstop for a dropped Cmd-up event. Dismissal normally rides the
    /// `.listenOnly` tap's flagsChanged callback, but that single event can be
    /// lost — e.g. macOS disables the tap by timeout exactly as Cmd is released
    /// (re-enabled only afterward) — which leaves the panel stuck open. While the
    /// panel is active, poll the *live* modifier state and dismiss the moment Cmd
    /// is no longer physically held, independent of event delivery. The tap stays
    /// the instant primary path; this only catches the miss (worst case ~100ms).
    private func startCmdWatchdog() {
        guard cmdWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }
            let cmdDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
            if !cmdDown {
                self.isActive = false  // mirror the tap's immediate-set
                DispatchQueue.main.async {
                    self.delegate?.modifierKeyReleased()
                }
            }
        }
        cmdWatchdog = timer
        timer.resume()
    }

    private func stopCmdWatchdog() {
        cmdWatchdog?.cancel()
        cmdWatchdog = nil
    }

    // MARK: - Carbon Hotkey Registration

    /// Installs the Carbon event handler and registers the global Cmd+Tab hotkey.
    /// Paired with `stop()`, which removes both — so this can be called again to
    /// re-enable switching after a permission revoke.
    func registerHotkeys() {
        let eventTarget = GetEventDispatcherTarget()

        var eventTypes = [EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )]

        let handler: EventHandlerUPP = { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )

            if let userData = userData {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                if id.id == HotkeyID.tab.rawValue {
                    // Cmd+Tab - activate switcher or select next
                    manager.isActive = true
                    DispatchQueue.main.async {
                        manager.delegate?.hotkeyTriggered()
                    }
                } else {
                    // Other hotkeys (H, Q, arrows, etc.) - only registered when active
                    if let keyCode = HotkeyManager.hotkeyToKeyCode[id.id] {
                        DispatchQueue.main.async {
                            manager.delegate?.keyPressed(keyCode)
                        }
                    }
                }
            }
            return noErr
        }

        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(eventTarget, handler, eventTypes.count, &eventTypes, userDataPtr, &hotKeyPressedHandler)

        // Only register Cmd+Tab at startup - other hotkeys registered when panel is active
        let id = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.tab.rawValue)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey), id, eventTarget, UInt32(kEventHotKeyNoOptions), &tabHotKeyRef)
    }

    // MARK: - Event Tap (for modifier release and mouse clicks only)
    // Note: keyDown removed - using Carbon hotkeys instead (only requires Accessibility permission)

    /// Creates the CGEvent tap. Returns true on success (or if already created).
    /// Returns false when `CGEvent.tapCreate` fails — which happens when
    /// Accessibility permission is not granted. The caller uses this as the gate:
    /// native Cmd+Tab is only disabled once this succeeds.
    @discardableResult
    func tryCreateEventTap() -> Bool {
        // Idempotent: never create a second tap / run-loop source.
        if eventTap != nil { return true }

        // Only listen for flagsChanged and mouse clicks
        // keyDown events require Input Monitoring permission, so we use Carbon hotkeys instead
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo = userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .flagsChanged {
                let flags = event.flags

                // Detect shift key tap (press then release while Cmd is held)
                let shiftIsDown = flags.contains(.maskShift)
                let cmdIsDown = flags.contains(.maskCommand)

                if cmdIsDown {
                    if shiftIsDown && !manager.shiftWasDown {
                        // Shift was just pressed while Cmd is held
                        DispatchQueue.main.async {
                            manager.delegate?.shiftPressed()
                        }
                    }
                    manager.shiftWasDown = shiftIsDown
                }

                // Check if Command key was released
                if !cmdIsDown {
                    manager.shiftWasDown = false
                    // Set inactive immediately
                    manager.isActive = false
                    DispatchQueue.main.async {
                        manager.delegate?.modifierKeyReleased()
                    }
                }
            } else if type == .leftMouseDown || type == .rightMouseDown {
                if manager.isActive {
                    let location = event.location
                    DispatchQueue.main.async {
                        manager.delegate?.mouseClicked(at: location)
                    }
                    // NOTE: the tap is .listenOnly (so revoking Accessibility can
                    // never freeze input), which means we CANNOT consume the click
                    // — it also reaches whatever is under the cursor. Keyboard use
                    // is unaffected; this only matters for click-to-dismiss.
                }
            } else if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                // Benign: macOS disables the tap after heavy input or a timeout —
                // just re-enable it. (Revocation is handled by AppDelegate's
                // permission poll, because macOS does NOT reliably deliver this
                // event when Accessibility permission is revoked.)
                if let eventTap = manager.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()

        // .listenOnly (passive): the window server never waits on this tap, so
        // revoking Accessibility while it's alive cannot freeze input. The cost is
        // we can't consume events (see the mouseDown branch above).
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: userDataPtr
        )

        guard let eventTap = eventTap else {
            print("Event tap not created — Accessibility permission not yet granted. Waiting…")
            return false
        }

        // Service the tap on a dedicated, high-priority thread with its own run loop.
        // Previously the source was added to the main run loop, so the Cmd-release
        // callback competed with main-thread UI work (loading icons, building the
        // panel). When that work ran long, macOS disabled the tap by timeout and the
        // Cmd-up event was lost — leaving the switcher panel stuck open. A dedicated
        // thread keeps the callback responsive regardless of what the UI is doing.
        let thread = Thread { [weak self] in
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self?.eventTapRunLoop = CFRunLoopGetCurrent()
            CGEvent.tapEnable(tap: eventTap, enable: true)
            print("Event tap created successfully")
            CFRunLoopRun()
        }
        thread.name = "com.simpleswitcher.eventtap"
        thread.qualityOfService = .userInteractive
        eventTapThread = thread
        thread.start()
        return true
    }
}
