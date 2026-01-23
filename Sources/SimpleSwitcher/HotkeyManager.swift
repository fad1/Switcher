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

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyPressedHandler: EventHandlerRef?
    private var eventTap: CFMachPort?

    // Serial queue for thread-safe state access
    private let stateQueue = DispatchQueue(label: "com.simpleswitcher.state")

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

    func start() {
        registerCmdTabHotkey()
        setupEventTap()
    }

    func stop() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handler = hotKeyPressedHandler {
            RemoveEventHandler(handler)
            hotKeyPressedHandler = nil
        }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
    }

    // MARK: - Cmd+Tab Hotkey Registration (Carbon)

    private func registerCmdTabHotkey() {
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
                // Set active immediately so event tap knows to block events
                manager.isActive = true
                DispatchQueue.main.async {
                    manager.delegate?.hotkeyTriggered()
                }
            }
            return noErr
        }

        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(eventTarget, handler, eventTypes.count, &eventTypes, userDataPtr, &hotKeyPressedHandler)

        // Register Cmd+Tab hotkey
        let hotkeyId = EventHotKeyID(signature: HotkeyManager.signature, id: 1)
        let keyCode = UInt32(kVK_Tab)
        let modifiers = UInt32(cmdKey)
        RegisterEventHotKey(keyCode, modifiers, hotkeyId, eventTarget, UInt32(kEventHotKeyNoOptions), &hotKeyRef)
    }

    // MARK: - Event Tap (for modifier release + key events while panel is shown)

    private func setupEventTap() {
        // Listen for flagsChanged, keyDown, and mouse clicks
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.keyDown.rawValue) |
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
            } else if type == .keyDown {
                // Check active state first
                let active = manager.isActive
                if active {
                    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    DispatchQueue.main.async {
                        manager.delegate?.keyPressed(keyCode)
                    }
                    // Block key event from reaching other apps
                    return nil
                }
            } else if type == .leftMouseDown || type == .rightMouseDown {
                if manager.isActive {
                    let location = event.location
                    DispatchQueue.main.async {
                        manager.delegate?.mouseClicked(at: location)
                    }
                }
            } else if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                if let eventTap = manager.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: userDataPtr
        )

        if let eventTap = eventTap {
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            print("Event tap created successfully")
        } else {
            print("ERROR: Failed to create event tap. Grant Input Monitoring permission in System Settings > Privacy & Security > Input Monitoring")
        }
    }
}
