import Foundation

/// Disambiguates the legacy "tap Shift to go back" gesture from Shift held as
/// part of Cmd+Shift+Tab, while Cmd is down.
///
/// Both gestures involve the same Shift press and release, so the only thing
/// separating them is whether a Cmd+Shift+Tab hotkey fired during that hold.
/// Two consequences the tests pin:
///
/// - The back-step fires on Shift **release**, never on press. Firing on press
///   would double-step every Cmd+Shift+Tab: once from the hotkey, once here.
/// - A fresh Shift hold clears the flag, so a Shift+Tab followed by a bare Shift
///   tap in the same Cmd hold still produces a back-step for the tap.
///
/// Pure state machine: feed it the flag transitions, act on what it returns.
public struct ShiftTapResolver: Equatable {

    public enum Action: Equatable {
        case none
        /// A bare Shift tap completed — select the previous app.
        case selectPrevious
    }

    /// Shift's state as of the last `flagsChanged`, used to spot the release edge.
    public private(set) var shiftWasDown = false
    /// Whether Cmd+Shift+Tab fired during the current Shift hold.
    public private(set) var tabSeenDuringShift = false

    public init() {}

    /// The Cmd+Shift+Tab hotkey fired. Marks the hold so the coming Shift release
    /// is not also read as a bare tap.
    public mutating func shiftTabHotkeyFired() {
        tabSeenDuringShift = true
    }

    /// Feed every modifier change here while the tap is alive.
    public mutating func flagsChanged(cmdDown: Bool, shiftDown: Bool) -> Action {
        guard cmdDown else {
            // Cmd released: the gesture is over and the panel is closing. Only the
            // Shift edge is reset — tabSeenDuringShift is cleared by the next fresh
            // Shift hold, so a stale true cannot survive into a new gesture.
            shiftWasDown = false
            return .none
        }

        var action = Action.none
        if shiftDown && !shiftWasDown {
            // Fresh hold: don't act yet, the release decides which gesture it was.
            tabSeenDuringShift = false
        } else if !shiftDown && shiftWasDown && !tabSeenDuringShift {
            action = .selectPrevious
        }
        shiftWasDown = shiftDown
        return action
    }
}
