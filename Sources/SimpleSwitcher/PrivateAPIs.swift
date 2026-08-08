import CoreGraphics
import Foundation

// Private API for disabling native Cmd+Tab
// Location: SkyLight.framework (private framework)

enum CGSSymbolicHotKey: Int, CaseIterable {
    case commandTab = 1
    case commandShiftTab = 2
    case commandKeyAboveTab = 6
}

/// Enables/disables system symbolic hotkeys (like Cmd+Tab)
/// Note: The effect persists after the app quits, so we must restore on exit
@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: CGSSymbolicHotKey.RawValue, _ isEnabled: Bool) -> Int32

func setNativeCommandTabEnabled(_ isEnabled: Bool) {
    for hotkey in CGSSymbolicHotKey.allCases {
        CGSSetSymbolicHotKeyEnabled(hotkey.rawValue, isEnabled)
    }
}

// MARK: - WindowServer window query (batched snapshot)

// `SLSWindowQueryWindows` is ONE IPC returning a snapshot of the requested
// windows; the iterator getters then read that local snapshot, so reading a
// field costs no further IPC. Unlike an AX read it never calls into the target
// app, so it cannot be blocked by an app that is busy or beach-balling.
//
// Measured on this machine (Darwin 24, 2026-08-08): ~50µs fixed + ~2.7µs per
// window — 286µs for the ~123 off-screen candidates, but 1128µs if handed the
// whole window list. Hence one batch of candidates only, per invocation.

typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("SLSWindowQueryWindows")
func SLSWindowQueryWindows(_ cid: CGSConnectionID, _ windows: CFArray, _ count: Int32) -> Unmanaged<CFTypeRef>

@_silgen_name("SLSWindowQueryResultCopyWindows")
func SLSWindowQueryResultCopyWindows(_ query: CFTypeRef) -> Unmanaged<CFTypeRef>

/// Returns true while positioned on a window.
@_silgen_name("SLSWindowIteratorAdvance")
func SLSWindowIteratorAdvance(_ iterator: CFTypeRef) -> Bool

@_silgen_name("SLSWindowIteratorGetWindowID")
func SLSWindowIteratorGetWindowID(_ iterator: CFTypeRef) -> CGWindowID

@_silgen_name("SLSWindowIteratorGetAttributes")
func SLSWindowIteratorGetAttributes(_ iterator: CFTypeRef) -> UInt64

/// A SECOND bitfield alongside `GetAttributes`, and the one carrying minimized.
/// Decoded by `MinimizedState`; see `MinimizedStateSpecs.md` for the measured
/// bit positions and the state matrix behind them.
@_silgen_name("SLSWindowIteratorGetTags")
func SLSWindowIteratorGetTags(_ iterator: CFTypeRef) -> UInt64
