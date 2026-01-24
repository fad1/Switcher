# SimpleSwitcher

A minimal Cmd+Tab replacement for macOS. Shows only apps with visible windows, ordered by most recently used.

## Project Overview

SimpleSwitcher intercepts the native Cmd+Tab hotkey and displays a custom switcher panel. It filters out:
- Hidden apps
- Apps with only minimized windows
- Background-only apps

**Total codebase: ~850 lines across 7 Swift files**

## Architecture

```
Sources/SimpleSwitcher/
├── main.swift           # Entry point, signal handlers for clean shutdown
├── AppDelegate.swift    # App lifecycle, state machine, coordinates components
├── HotkeyManager.swift  # Carbon hotkey registration, CGEvent tap for modifiers
├── AppListProvider.swift# Queries visible apps, maintains MRU order
├── AppSwitcherPanel.swift# NSPanel subclass with visual effect blur
├── AppItemView.swift    # Individual app item (icon + name)
└── PrivateAPIs.swift    # CGSSetSymbolicHotKeyEnabled binding
```

### Component Responsibilities

**main.swift**
- Sets up signal handlers (SIGTERM, SIGINT, SIGTRAP) to restore native Cmd+Tab on crash
- Sets NSSetUncaughtExceptionHandler for Objective-C exceptions
- Creates NSApplication and AppDelegate

**AppDelegate.swift**
- State machine: `idle` <-> `active`
- Coordinates HotkeyManager and AppSwitcherPanel
- Handles keyboard shortcuts (Tab, Shift, Arrows, H, Q, Escape, Return)
- Handles mouse clicks (inside panel = activate, outside = dismiss)

**HotkeyManager.swift**
- Registers Cmd+Tab globally at startup
- Dynamically registers/unregisters other hotkeys (H, Q, arrows, Escape, Return) when panel is shown/hidden
  - `registerActiveHotkeys()` called when panel opens
  - `unregisterActiveHotkeys()` called when panel closes
  - This ensures Cmd+H/Q work normally in other apps when panel is not showing
- Creates CGEvent tap to monitor:
  - flagsChanged: Detect Cmd release (dismiss), Shift press (previous)
  - mouseDown: Forward click location to delegate
- **Note**: Uses Carbon hotkeys instead of CGEvent keyDown to avoid requiring Input Monitoring permission (only Accessibility needed)
- **Thread safety**: Uses `DispatchQueue` for synchronized access to `isActive` state
- **Critical**: Sets `isActive` synchronously in event handlers before async delegate calls to avoid race conditions in release builds

**AppListProvider.swift**
- Maintains MRU (Most Recently Used) order via NSWorkspace notifications
- `getVisibleApps()`: Returns apps with on-screen windows, sorted by MRU
- Uses CGWindowListCopyWindowInfo to find visible windows
- Filters: layer == 0, isOnScreen == true, valid bounds

**AppSwitcherPanel.swift**
- NSPanel with `.nonactivatingPanel` style (doesn't steal focus)
- NSVisualEffectView with `.hudWindow` material (blur effect)
- Centers on screen containing mouse cursor (multi-monitor support)
- Manages selection state and app item views

**AppItemView.swift**
- Displays app icon (64x64) and name (truncated, 2 lines max)
- Mouse tracking for hover selection
- Selection highlight (white 30% alpha background)

**PrivateAPIs.swift**
- Declares CGSSetSymbolicHotKeyEnabled using @_silgen_name
- Disables system Cmd+Tab, Cmd+Shift+Tab, Cmd+` hotkeys
- Must be restored on app exit (done in emergencyExit and applicationWillTerminate)

## Key APIs Used

### Private/Undocumented
- `CGSSetSymbolicHotKeyEnabled` - Disables system symbolic hotkeys
  - Located in SkyLight.framework (private)
  - Effect persists after app quits; must restore on exit

### Carbon (legacy but required)
- `RegisterEventHotKey` - Register global hotkey
- `EventHotKeyID`, `EventHotKeyRef` - Hotkey identification
- `kVK_Tab` - Virtual key codes

### Core Graphics
- `CGEvent.tapCreate` - Monitor keyboard/mouse events
- `CGWindowListCopyWindowInfo` - Query window list
- `kCGWindowIsOnscreen`, `kCGWindowLayer` - Window properties

### AppKit
- `NSRunningApplication` - Query running apps
- `NSWorkspace.didActivateApplicationNotification` - Track app activations
- `NSPanel` with `.nonactivatingPanel` - Floating panel that doesn't steal focus
- `NSVisualEffectView` - macOS blur effect

## MRU (Most Recently Used) Tracking

1. On launch, `AppListProvider.startObserving()` registers for workspace notifications
2. `didActivateApplicationNotification` updates MRU list (most recent at index 0)
3. `didTerminateApplicationNotification` removes terminated apps
4. `getVisibleApps()` sorts filtered apps by MRU order
5. Switcher opens with second app selected (index 1) for quick Alt-Tab behavior

## Permissions Required

**Accessibility** (System Settings > Privacy & Security > Accessibility)
- Required for CGEvent tap to detect modifier key changes (Cmd release, Shift press)
- Without this, event tap creation fails
- App prompts user on first launch

**Note**: Input Monitoring is NOT required because keyboard shortcuts use Carbon hotkeys (RegisterEventHotKey) instead of CGEvent keyDown monitoring.

## Build & Run

### Development
```bash
cd /Users/Shared/sv-fahd/SimpleSwitcher
swift build
.build/debug/SimpleSwitcher
```

### Release Build
```bash
swift build -c release
.build/release/SimpleSwitcher
```

### Create App Bundle
```bash
# Debug build (default)
./build-app.sh

# Release build (optimized)
swift build -c release
./build-app.sh release
```
This creates `SimpleSwitcher.app` which can be moved to `/Applications`.

### Auto-Start at Login
1. Move `SimpleSwitcher.app` to `/Applications`
2. Open System Settings > General > Login Items
3. Click + and add SimpleSwitcher

## Keyboard Shortcuts (while panel is open)

| Key | Action |
|-----|--------|
| Tab | Select next app |
| Shift | Select previous app |
| Left Arrow | Select previous app |
| Right Arrow | Select next app |
| H | Hide selected app |
| Q | Quit selected app |
| Return | Activate selected app |
| Escape | Dismiss without switching |
| Release Cmd | Activate selected app |

## Known Limitations

1. **No window thumbnails** - Would require Screen Recording permission
2. **No per-window switching** - Shows apps, not individual windows
3. **No preferences UI** - Configuration requires code changes
4. **Ad-hoc signed only** - Not notarized, may trigger Gatekeeper warning on first run
5. **Private API usage** - CGSSetSymbolicHotKeyEnabled may break in future macOS

## Threading Notes

The CGEvent tap callback runs on a separate thread from the main UI thread. In release builds (with compiler optimizations), race conditions can cause the event tap to miss state changes. The fix:

1. `isActive` state is protected by a serial `DispatchQueue`
2. State is set **synchronously** in event handlers, before any async delegate calls
3. This ensures the event tap sees the correct state even with aggressive compiler optimizations

## Potential Improvements

- [ ] Number keys (1-9) for quick selection
- [ ] Window thumbnails (requires Screen Recording permission)
- [ ] Preferences pane (configurable shortcuts, appearance)
- [ ] Proper app icon
- [ ] Full code signing and notarization (currently ad-hoc signed)
- [ ] Handle fullscreen apps better

## References

The [AltTab](https://github.com/lwouis/alt-tab-macos) codebase (located at `/Users/Shared/sv-fahd/alt-tab-macos`) is an excellent reference for:
- CGEvent tap patterns and threading
- Private API usage (`CGSSetSymbolicHotKeyEnabled`, etc.)
- Window listing and filtering
- macOS accessibility APIs

Since Apple's documentation for these low-level APIs is sparse or nonexistent, AltTab's production code serves as practical documentation.

## Troubleshooting

### "Failed to create event tap"
Grant Accessibility permission in System Settings > Privacy & Security > Accessibility. May need to remove and re-add the app if permissions changed or app was rebuilt.

### Native Cmd+Tab still works
The app may have crashed without restoring the hotkey. Run the app again and quit cleanly, or log out/restart.

### Panel doesn't appear
Check Console.app for errors. Ensure app has proper permissions.
