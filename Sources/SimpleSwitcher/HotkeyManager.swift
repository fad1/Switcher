import Cocoa
import Carbon
import SwitcherKernels

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyTriggered()
    /// Cmd+Shift+Tab: open the switcher in reverse (from idle) or step backward
    /// (while active) — mirrors the native reverse-cycling gesture.
    func hotkeyTriggeredReverse()
    func modifierKeyReleased()
    func keyPressed(_ keyCode: UInt16)
    /// Shift pressed and released while Cmd is held, with no Shift+Tab in
    /// between — the legacy "tap Shift to go back" gesture. Fires on release so
    /// it can't double up with hotkeyTriggeredReverse.
    func shiftTapped()
    func hideOthersRequested()
    func mouseClicked()
}

class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private static let signature: OSType = {
        "smpl".utf16.reduce(0) { ($0 << 8) + OSType($1) }
    }()

    private var hotKeyPressedHandler: EventHandlerRef?
    private var tabHotKeyRef: EventHotKeyRef?
    private var shiftTabHotKeyRef: EventHotKeyRef?
    private var activeHotKeyRefs: [EventHotKeyRef?] = []
    private var eventTap: CFMachPort?

    // Dedicated thread + run loop that services the event tap, so its callback is
    // never starved by main-thread UI work (see tryCreateEventTap for rationale).
    private var eventTapThread: Thread?
    // Written by the tap thread, read by stop() — access only under stateQueue.
    // The flag covers the startup race: if stop() runs before the thread has
    // stored its run loop, the thread sees it and exits instead of running
    // unstoppable forever.
    private var _eventTapRunLoop: CFRunLoop?
    private var _tapStopRequested = false

    private let stateQueue = DispatchQueue(label: "com.simpleswitcher.state")

    // Backstop watchdog (see startCmdWatchdog) — polls live modifier state while
    // the panel is active in case the .listenOnly tap drops the Cmd-up event.
    private var cmdWatchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.simpleswitcher.cmdwatchdog")

    // State protected by stateQueue
    private var _isActive = false
    // Shift-tap vs Shift+Tab, decided in SwitcherKernels. Touched from both the
    // tap thread (flagsChanged) and the main thread (the Carbon handler), so
    // every transition runs as one critical section rather than as separate
    // reads and writes.
    private var _shiftTap = ShiftTapResolver()

    /// Set this synchronously in an event handler BEFORE any async delegate call:
    /// release-build optimizations otherwise let the tap thread observe the old
    /// value and drop the matching Cmd-up.
    var isActive: Bool {
        get { stateQueue.sync { _isActive } }
        set { stateQueue.sync { _isActive = newValue } }
    }

    private func noteShiftTabHotkey() {
        stateQueue.sync { _shiftTap.shiftTabHotkeyFired() }
    }

    private func resolveShiftTap(cmdDown: Bool, shiftDown: Bool) -> ShiftTapResolver.Action {
        stateQueue.sync { _shiftTap.flagsChanged(cmdDown: cmdDown, shiftDown: shiftDown) }
    }

    // Hotkey IDs — sequential, NOT key codes; hotkeyToKeyCode maps them back to
    // key codes for the delegate. The comments name the modifier each one is
    // registered with, which the raw values don't show.
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
        case hideOthers = 10 // Cmd+Opt+H - hide all apps except the frontmost
        case shiftTab = 11  // Cmd+Shift+Tab - activate in reverse/previous
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

    // Ordinary Cmd+<key> combos that have no switcher action. Registered as no-op
    // Carbon hotkeys while the panel is open so they're swallowed instead of leaking
    // to the app behind the panel (e.g. Cmd+W closing a tab). Excludes the action
    // keys (Tab/H/Q/arrows/Escape/Return), which are registered separately.
    private static let swallowKeyCodes: [Int] = [
        kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_Z,
        kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_W, kVK_ANSI_E,
        kVK_ANSI_R, kVK_ANSI_Y, kVK_ANSI_T, kVK_ANSI_O, kVK_ANSI_U, kVK_ANSI_I,
        kVK_ANSI_P, kVK_ANSI_L, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_N, kVK_ANSI_M,
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
        kVK_ANSI_Backslash, kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Comma,
        kVK_ANSI_Period, kVK_ANSI_Slash, kVK_ANSI_Grave,
        kVK_Space, kVK_Delete, kVK_ForwardDelete,
    ]

    func stop() {
        if let ref = tabHotKeyRef {
            UnregisterEventHotKey(ref)
            tabHotKeyRef = nil
        }
        if let ref = shiftTabHotKeyRef {
            UnregisterEventHotKey(ref)
            shiftTabHotKeyRef = nil
        }

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
        stateQueue.sync {
            _tapStopRequested = true
            if let runLoop = _eventTapRunLoop {
                CFRunLoopStop(runLoop)
                _eventTapRunLoop = nil
            }
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

        // Cmd+Opt+H — hide all apps except the frontmost (macOS "Hide Others"), to
        // declutter the switcher. Registered separately because it needs the option
        // modifier, and distinct from Cmd+H (hide selected). Only registered while the
        // panel is open, so native Hide-Others works normally elsewhere. Unlike Shift,
        // Option isn't watched by the tap, so there's no select-previous side effect.
        var hideOthersRef: EventHotKeyRef?
        let hideOthersId = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.hideOthers.rawValue)
        RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(cmdKey | optionKey), hideOthersId, eventTarget, UInt32(kEventHotKeyNoOptions), &hideOthersRef)
        activeHotKeyRefs.append(hideOthersRef)

        // These ids are absent from `hotkeyToKeyCode`, so the Carbon handler no-ops
        // them — registration alone consumes the keystroke. The 0x1000 offset keeps
        // them clear of the action ids (1–11).
        for keyCode in HotkeyManager.swallowKeyCodes {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(0x1000 + keyCode))
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
                    manager.isActive = true
                    DispatchQueue.main.async {
                        manager.delegate?.hotkeyTriggered()
                    }
                } else if id.id == HotkeyID.shiftTab.rawValue {
                    // Marks the Shift hold so its release isn't also treated as a
                    // bare Shift tap, which would double-step.
                    manager.isActive = true
                    manager.noteShiftTabHotkey()
                    DispatchQueue.main.async {
                        manager.delegate?.hotkeyTriggeredReverse()
                    }
                } else if id.id == HotkeyID.hideOthers.rawValue {
                    // Cmd+Opt+H - hide others. Its own path so it isn't misrouted to
                    // keyPressed(H), which hides only the selected app.
                    DispatchQueue.main.async {
                        manager.delegate?.hideOthersRequested()
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

        // Only register Cmd+Tab / Cmd+Shift+Tab at startup - other hotkeys
        // registered when panel is active. Carbon hotkeys need an exact modifier
        // match, so the Shift variant must be its own registration — without it,
        // Cmd+Shift+Tab (whose native handler we disable) would do nothing.
        let id = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.tab.rawValue)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey), id, eventTarget, UInt32(kEventHotKeyNoOptions), &tabHotKeyRef)
        let shiftId = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.shiftTab.rawValue)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey | shiftKey), shiftId, eventTarget, UInt32(kEventHotKeyNoOptions), &shiftTabHotKeyRef)
    }

    // MARK: - Event Tap (for modifier release and mouse clicks only)

    /// Creates the CGEvent tap. Returns true on success (or if already created).
    /// Returns false when `CGEvent.tapCreate` fails — which happens when
    /// Accessibility permission is not granted. The caller uses this as the gate:
    /// native Cmd+Tab is only disabled once this succeeds.
    @discardableResult
    func tryCreateEventTap() -> Bool {
        // Idempotent: never create a second tap / run-loop source.
        if eventTap != nil { return true }

        // No keyDown: that would require Input Monitoring permission on top of
        // Accessibility, so keys come from Carbon hotkeys instead.
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

                let shiftIsDown = flags.contains(.maskShift)
                let cmdIsDown = flags.contains(.maskCommand)

                if manager.resolveShiftTap(cmdDown: cmdIsDown, shiftDown: shiftIsDown) == .selectPrevious {
                    DispatchQueue.main.async {
                        manager.delegate?.shiftTapped()
                    }
                }

                if !cmdIsDown {
                    manager.isActive = false
                    DispatchQueue.main.async {
                        manager.delegate?.modifierKeyReleased()
                    }
                }
            } else if type == .leftMouseDown || type == .rightMouseDown {
                if manager.isActive {
                    DispatchQueue.main.async {
                        manager.delegate?.mouseClicked()
                    }
                    // NOTE: the tap is .listenOnly (so revoking Accessibility can
                    // never freeze input), which means we CANNOT consume the click.
                    // Clicks outside the panel are swallowed by AppSwitcherPanel's
                    // per-screen click shields instead; this callback stays the
                    // primary dismiss/activate path.
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
        // On the main run loop the callback competes with UI work (loading icons,
        // building the panel); when that work runs long, macOS disables the tap by
        // timeout and the in-flight Cmd-up is lost, leaving the panel stuck open.
        stateQueue.sync { _tapStopRequested = false }
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            // Store the run loop and check for an early stop() in one critical
            // section, so a stop can never fall between the two.
            let shouldRun: Bool = self.stateQueue.sync {
                self._eventTapRunLoop = CFRunLoopGetCurrent()
                return !self._tapStopRequested
            }
            guard shouldRun else { return }
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
