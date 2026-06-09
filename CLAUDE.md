# Switcher

A minimal Cmd+Tab replacement for macOS. Shows only apps with visible windows, ordered by most recently used.

## Project Overview

Switcher intercepts the native Cmd+Tab hotkey and displays a custom switcher panel. It filters out:
- Hidden apps
- Apps with only minimized windows
- Background-only apps

**Total codebase: ~1100 lines across 10 Swift files**

## Architecture

```
Sources/SimpleSwitcher/
├── main.swift           # Entry point, signal handlers for clean shutdown
├── AppDelegate.swift    # App lifecycle, state machine, coordinates components
├── HotkeyManager.swift  # Carbon hotkey registration, CGEvent tap for modifiers
├── AppListProvider.swift# Queries visible apps, maintains MRU order
├── AppSwitcherPanel.swift# NSPanel subclass with visual effect blur
├── AppItemView.swift    # Individual app item (icon + name)
├── Preferences.swift    # UserDefaults wrapper (settings keys + donate helper)
├── StatusBarController.swift     # Optional menu bar icon (NSStatusItem) + menu
├── PreferencesWindowController.swift # Programmatic Preferences window
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
- Handles mouse clicks (inside panel = activate clicked app, outside = dismiss)

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
- **Multi-row layout**: Uses max 85% of screen width; wraps to additional rows when many apps are open
- Manages selection state with row/column tracking for grid navigation
- **Dead zone hover**: Ignores mouse position when panel appears; hover only enabled after 3px mouse movement (prevents accidental selection)
- Uses `mouseLocationOutsideOfEventStream` for accurate mouse position in non-activating panel

**AppItemView.swift**
- Displays app icon (76x76, no label)
- Selection highlight (white 30% alpha background)

**Preferences.swift**
- `enum Preferences`: single source of truth for persisted settings over `UserDefaults.standard`
- Keys: `grayscaleIcons`, `showMenuBarIcon` (defaults to true), `launchCount`, `hasDonated`
- `registerDefaults()` must run before any read on every launch (`register(defaults:)` does not persist)
- `openDonatePage()`: the one choke point for donating — sets `hasDonated = true`, then opens the Ko-fi URL

**StatusBarController.swift**
- Owns the optional menu bar icon (`NSStatusItem`), held by a strong reference (system does not retain it)
- `show()` / `hide()` toggle the icon live (driven by `showMenuBarIcon`)
- Menu: Preferences… / Donate / Quit; `onOpenPreferences` closure opens the window

**PreferencesWindowController.swift**
- Reusable programmatic Preferences window (`isReleasedWhenClosed = false`)
- Checkboxes: "Show icon in menu bar", "Grayscale icons"; plus a Donate button and version label
- `show()` calls `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront` so controls are clickable while staying `.accessory` (no Dock icon)
- `onToggleMenuBar` callback lets AppDelegate show/hide the status item immediately

**Preferences / menu bar / donation flow (AppDelegate)**
- App starts silently — the Preferences window does NOT auto-open on every launch
- On startup it auto-surfaces (with a Donate / Maybe Later prompt) only when `!hasDonated && launchCount % 5 == 0`
- On demand: the menu bar Preferences… item, or relaunching the app (`applicationShouldHandleReopen` surfaces the window)
- `applicationShouldTerminateAfterLastWindowClosed` returns false so closing Preferences keeps the agent running

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

> **Use `--disable-sandbox` flag** when building from Claude Code or Sandvault. SPM internally uses `sandbox-exec` which conflicts with the environment sandbox. This is safe — the environment already provides OS-level sandboxing.

### Development
```bash
cd /Users/fahd/Claude/SimpleSwitcher
swift build --disable-sandbox
.build/debug/SimpleSwitcher
```

### Release Build
```bash
swift build -c release --disable-sandbox
.build/release/SimpleSwitcher
```

### Create App Bundle
```bash
# Create icon (optional, uses ⌘ emoji by default)
./create-icon.sh
# Or with custom emoji:
./create-icon.sh "🔀"

# Build app bundle
swift build -c release
./build-app.sh release
```
This creates `Switcher.app` which can be moved to `/Applications`.

### Auto-Start at Login
1. Move `Switcher.app` to `/Applications`
2. Open System Settings > General > Login Items
3. Click + and add Switcher

## Keyboard Shortcuts (while panel is open)

| Key | Action |
|-----|--------|
| Tab | Select next app |
| Shift | Select previous app |
| Left Arrow | Select previous app |
| Right Arrow | Select next app |
| Up Arrow | Select app in row above (multi-row only) |
| Down Arrow | Select app in row below (multi-row only) |
| H | Hide selected app |
| Q | Quit selected app |
| Return | Activate selected app |
| Escape | Dismiss without switching |
| Release Cmd | Activate selected app |

## Mouse Behavior

- **Hover**: Disabled until mouse moves 3+ pixels from initial position (prevents accidental selection when panel appears under cursor)
- **Click inside panel**: Activates the clicked app
- **Click outside panel**: Dismisses without switching

## Known Limitations

1. **No window thumbnails** - Would require Screen Recording permission
2. **No per-window switching** - Shows apps, not individual windows
3. **Ad-hoc signed only** - Not notarized, may trigger Gatekeeper warning on first run
4. **Private API usage** - CGSSetSymbolicHotKeyEnabled may break in future macOS

## Threading Notes

The CGEvent tap callback runs on a separate thread from the main UI thread. In release builds (with compiler optimizations), race conditions can cause the event tap to miss state changes. The fix:

1. `isActive` state is protected by a serial `DispatchQueue`
2. State is set **synchronously** in event handlers, before any async delegate calls
3. This ensures the event tap sees the correct state even with aggressive compiler optimizations

## Releasing a New Version

When creating a new release:

1. **Build and create release zip:**
```bash
swift build -c release
./create-icon.sh
./build-app.sh release
zip -r Switcher.zip Switcher.app
```

2. **Create GitHub release:**
```bash
gh release create v1.x.x Switcher.zip --title "Switcher v1.x.x" --notes "Release notes here"
```

3. **Update Homebrew tap:**
```bash
# Get SHA256 of new release
curl -sL https://github.com/fad1/Switcher/releases/download/v1.x.x/Switcher.zip | shasum -a 256

# Update tap repo at /Users/fahd/Claude/homebrew-tap
# Edit Casks/switcher.rb: update version and sha256
cd /Users/fahd/Claude/homebrew-tap
# Update version and sha256 in Casks/switcher.rb
git add . && git commit -m "Update Switcher to v1.x.x" && git push
```

4. **Clean up:**
```bash
rm Switcher.zip
```

**Homebrew tap repo:** https://github.com/fad1/homebrew-tap

## Potential Improvements

- [ ] Number keys (1-9) for quick selection
- [ ] Window thumbnails (requires Screen Recording permission)
- [x] Preferences window (menu bar icon toggle, grayscale toggle, donate) — basic; shortcuts still code-only
- [x] App icon (via create-icon.sh)
- [ ] Full code signing and notarization (currently ad-hoc signed)
- [ ] Handle fullscreen apps better

## References

The [AltTab](https://github.com/lwouis/alt-tab-macos) codebase (located at `/Users/fahd/Claude/_reference/alt-tab-macos`) is an excellent reference for:
- CGEvent tap patterns and threading
- Private API usage (`CGSSetSymbolicHotKeyEnabled`, etc.)
- Window listing and filtering
- macOS accessibility APIs
- Dead zone hover pattern (`CursorEvents.swift`)

Since Apple's documentation for these low-level APIs is sparse or nonexistent, AltTab's production code serves as practical documentation.

## Troubleshooting

### "Failed to create event tap"
Grant Accessibility permission in System Settings > Privacy & Security > Accessibility. May need to remove and re-add the app if permissions changed or app was rebuilt.

### Native Cmd+Tab still works
The app may have crashed without restoring the hotkey. Run the app again and quit cleanly, or log out/restart.

### Panel doesn't appear
Check Console.app for errors. Ensure app has proper permissions.
