# Switcher

A minimal Cmd+Tab replacement for macOS. Shows only apps with visible windows, ordered by most recently used.

## Project Overview

Switcher intercepts the native Cmd+Tab hotkey and displays a custom switcher panel. It filters out:
- Hidden apps
- Background-only apps

It also includes apps with a Dock badge (e.g. Mail with an unread count) even if they have no open window.

**Apps with only minimized windows are NOT filtered out** (verified empirically 2026-07): a minimized window is off-screen in CGWindowList terms, but so is a window on another Space, and the off-screen branch must accept those — CGWindowList alone cannot tell the two apart. True minimized filtering would need per-window AX checks (`AXMinimized`), like AltTab. See Known Limitations.

**Total codebase: ~1900 lines across 12 Swift files**

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
├── AccessibilityPermission.swift # AXIsProcessTrusted check + system prompt
├── LoginItem.swift      # "Start at login" via SMAppService (macOS 13+)
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
- **Permission gating**: never disables native Cmd+Tab until the event tap is alive
  - `enableSwitching()`: creates the tap FIRST, and only then disables native Cmd+Tab + registers the Cmd+Tab hotkey (order matters)
  - On launch without Accessibility permission: leaves native Cmd+Tab working and fires the system prompt
  - `startPermissionMonitor()`: a background ~1s poll of `AXIsProcessTrusted()` (App Nap disabled via `beginActivity`) reconciles state — `enableSwitching()` when granted; on revoke `handleRevocation()` restores native Cmd+Tab and quits
  - **Freeze prevention is in the tap type, not the recovery**: the tap is **`.listenOnly`** (see HotkeyManager), so revoking permission can't freeze input regardless of detection. The original attempt to *recover* from an active-tap freeze (quit-on-revoke) was unreliable and is now just a best-effort cleanup.
  - **`AXIsProcessTrusted()` caches per process**: macOS keeps reporting a running app as trusted even after permission is revoked, until relaunch. So the revoke branch usually does NOT fire — the app keeps working until relaunched. This is harmless now that the tap is passive. Grant detection (the path that matters) works fine.

**HotkeyManager.swift**
- Registers Cmd+Tab AND Cmd+Shift+Tab globally (via `registerHotkeys()`, called by AppDelegate once permission is confirmed). Carbon hotkeys need an exact modifier match, so the Shift variant is its own registration — without it Cmd+Shift+Tab (whose native handler we disable) would do nothing. From idle it opens the panel selecting the LAST app (reverse/wrap-around); while open, Shift+Tab steps backward.
- **Shift-tap vs Shift+Tab disambiguation**: the legacy "tap Shift to go back" gesture fires on Shift *release*, and only if no Cmd+Shift+Tab fired during the hold (`tabSeenDuringShift`). Firing on press would double-step every Shift+Tab.
- `tryCreateEventTap() -> Bool`: creates the CGEvent tap; returns false when Accessibility permission is missing (the gate AppDelegate checks before touching native Cmd+Tab). Idempotent.
- **`.listenOnly` (passive) CGEvent tap**: the window server never waits on it, so revoking Accessibility while it's alive cannot freeze input (an active `.defaultTap` can — forums thread 735204). Trade-off: a passive tap can't consume events — outside clicks are instead swallowed by AppSwitcherPanel's invisible per-screen click-shield windows (see below), which turn click-away into a plain dismiss.
- On `tapDisabledByUserInput`/`tapDisabledByTimeout` (benign throttling) it just re-enables the tap
- **Sticky-panel defense (two layers)**: dismissal rides the tap's Cmd-up `flagsChanged`, but that single event can be dropped (e.g. tap disabled by timeout at the instant of release), leaving the panel stuck open. Layer 1: the tap runs on a dedicated high-priority thread so its callback isn't starved by main-thread UI work. Layer 2: `startCmdWatchdog()` — a ~100ms poll of `CGEventSource.flagsState(.combinedSessionState)` that runs only while the panel is active (started in `registerActiveHotkeys()`, stopped in `unregisterActiveHotkeys()`) and dismisses if Cmd is no longer physically held, independent of event delivery. Double-dismiss is safe: both paths hit the serial main queue and `modifierKeyReleased()`/`dismissPanel()` guard on state.
- Dynamically registers/unregisters other hotkeys (H, Q, arrows, Escape, Return) when panel is shown/hidden
  - `registerActiveHotkeys()` called when panel opens
  - `unregisterActiveHotkeys()` called when panel closes
  - This ensures Cmd+H/Q work normally in other apps when panel is not showing
- Tap monitors (read-only): flagsChanged (Cmd release / Shift) and mouseDown (notify delegate of clicks while active)
- **Note**: Uses Carbon hotkeys instead of CGEvent keyDown to avoid requiring Input Monitoring permission (only Accessibility needed)
- **Thread safety**: Uses `DispatchQueue` for synchronized access to `isActive` state
- **Critical**: Sets `isActive` synchronously in event handlers before async delegate calls to avoid race conditions in release builds

**AppListProvider.swift**
- Maintains MRU (Most Recently Used) order via NSWorkspace notifications
- `getVisibleApps()`: Returns apps with visible windows OR a Dock badge, sorted by MRU
- Uses CGWindowListCopyWindowInfo to find visible windows
- Filters: 0 <= layer <= 20, bounds >= 50x50; off-screen windows accepted if they have an owner name (covers other Spaces — and, unavoidably, minimized windows; see Project Overview)
- **Dock badge scan is cached (~2s TTL)**: `getDockBadges()` walks the Dock's AX tree (several IPC round-trips per dock item, on the main thread), and `getVisibleApps()` runs on every Cmd+Tab press plus every 300ms while the panel is open — `getDockBadgesCached()` keeps that off the hot path

**AppSwitcherPanel.swift**
- NSPanel with `.nonactivatingPanel` style (doesn't steal focus)
- NSVisualEffectView with `.hudWindow` material (blur effect)
- Centers on screen containing mouse cursor (multi-monitor support)
- **Multi-row layout**: Uses max 85% of screen width; wraps to additional rows when many apps are open
- Manages selection state with row/column tracking for grid navigation
- **Dead zone hover**: Ignores mouse position when panel appears; hover only enabled after 3px mouse movement (prevents accidental selection)
- **Hover has two event sources**: a global mouseMoved monitor AND an `.activeAlways` tracking area on the panel content (`HoverTrackingVisualEffectView`). The tracking area is required because global monitors never see the app's own events — when Switcher itself is active (e.g. Cmd+Tab right after using Preferences) the monitor is silent and hover would otherwise be dead
- **Click shields**: while the panel is open, invisible non-activating panels cover every screen one window level below it, swallowing clicks outside the panel (the `.listenOnly` tap can't consume them) and requesting a dismiss — click-away behaves like Escape and never reaches the app behind
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
- Checkboxes: "Start at login" (hidden on macOS < 13), "Show icon in menu bar", "Grayscale icons"; plus a Donate button and version label
- The "Start at login" checkbox reflects the live `SMAppService` state (not a stored pref); `syncFromPreferences()` refreshes all controls on show
- `show()` calls `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront` so controls are clickable while staying `.accessory` (no Dock icon)
- `onToggleMenuBar` callback lets AppDelegate show/hide the status item immediately

**Preferences / menu bar / donation flow (AppDelegate)**
- App starts silently — the Preferences window does NOT auto-open on every launch
- On startup it auto-surfaces (with a Donate / Maybe Later prompt) only when `!hasDonated && launchCount % 5 == 0`. The nag is deferred (async, after `enableSwitching`/`startPermissionMonitor`) because `runModal()` would otherwise block the Cmd+Tab takeover until answered
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
- App checks `AXIsProcessTrusted()` on launch and prompts if missing
- **Without it the app stays safe**: native Cmd+Tab is left working (never disabled), the menu bar icon's Quit is available, and the app polls — taking over automatically within ~1s of being granted. No zombie state, no Activity Monitor needed.
- **If revoked while running**: the app restores native Cmd+Tab and quits itself within ~1s (terminating clears the macOS event-tap input-freeze bug). Quitting Switcher *before* revoking avoids any input hiccup.
- Implemented in `AccessibilityPermission.swift` + AppDelegate's `enableSwitching`/`handleRevocation`/`startPermissionMonitor`

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
- **In-app**: Preferences → "Start at login" (macOS 13+, via `SMAppService.mainApp` in `LoginItem.swift`). The system tracks the state; there's no UserDefaults key. The checkbox is hidden on macOS < 13.
- **Manual**: move `Switcher.app` to `/Applications`, then System Settings > General > Login Items > + > Switcher

## Keyboard Shortcuts (while panel is open)

Cmd+Shift+Tab from **idle** opens the switcher selecting the last (least recently used) app, mirroring the native reverse gesture.

| Key | Action |
|-----|--------|
| Tab | Select next app |
| Shift+Tab | Select previous app |
| Shift (tap, no Tab) | Select previous app (fires on Shift release) |
| Left Arrow | Select previous app |
| Right Arrow | Select next app |
| Up Arrow | Select app in row above (multi-row only) |
| Down Arrow | Select app in row below (multi-row only) |
| H | Hide selected app |
| ⌥⌘H | Hide all other apps (declutter), then dismiss |
| Q | Quit selected app |
| Return | Activate selected app |
| Escape | Dismiss without switching |
| Release Cmd | Activate selected app |

## Mouse Behavior

- **Hover**: Disabled until mouse moves 3+ pixels from initial position (prevents accidental selection when panel appears under cursor)
- **Click inside panel**: Activates the clicked app
- **Click outside panel**: Dismisses without switching; the click is swallowed by an invisible shield window and does NOT reach the app behind
- **Declutter tip button**: the "⌥⌘H · Hide others" tip (shown at 2+ rows, `DeclutterHintView`) reveals itself as a pill button on hover; clicking it runs Hide Others. Clicks only count while the button is visibly revealed, so stray clicks below the icon rows can't hide everything

## Known Limitations

1. **No window thumbnails** - Would require Screen Recording permission
2. **No per-window switching** - Shows apps, not individual windows
3. **Ad-hoc signed only** - Not notarized, may trigger Gatekeeper warning on first run
4. **Private API usage** - CGSSetSymbolicHotKeyEnabled may break in future macOS
5. **Minimized-only apps still appear** - CGWindowList can't distinguish a minimized window from one on another Space (both off-screen); filtering them would need per-window AX `AXMinimized` checks

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

### Switcher doesn't intercept Cmd+Tab (no Accessibility permission)
This is now handled gracefully: the app leaves native Cmd+Tab working and polls for the grant. Enable Switcher under System Settings > Privacy & Security > Accessibility and it takes over within ~1s — no relaunch needed. Because the app is ad-hoc signed, rebuilding it can invalidate a prior grant (remove + re-add the entry).

### Native Cmd+Tab still works
Either Accessibility isn't granted yet (see above — expected), or the app crashed via SIGKILL without restoring the hotkey. SIGTERM/SIGINT/crashes restore it automatically; for SIGKILL, run the app again and quit cleanly, or log out/restart.

### Panel doesn't appear
Check Console.app for errors. Ensure app has proper permissions.
