# Switcher

A minimal Cmd+Tab replacement for macOS. Shows only apps with visible windows, ordered by most recently used.

## Project Overview

Switcher intercepts the native Cmd+Tab hotkey and displays a custom switcher panel. It filters out:
- Hidden apps
- Background-only apps

It also includes apps with a Dock badge (e.g. Mail with an unread count) even if they have no open window.

**Apps whose windows are all minimized are hidden** (since 1.2.0, pref `hideMinimizedOnlyApps`, default on). CGWindowList cannot tell a minimized window from one on another Space — both are off-screen — so the minimized state comes from the WindowServer's own tag bit, read in one batched private query. Two specs carry the evidence: `WindowFilterSpecs.md` (why CGWindowList alone cannot do it) and `MinimizedStateSpecs.md` (the measured bits, the cost, and the fail-open rules). An app with a Dock badge stays listed regardless — the badge rule is independent.

**Total codebase: ~3000 lines of app across 13 Swift files, plus ~410 lines of pure kernels and ~835 lines of tests**

## Architecture

```
Sources/SimpleSwitcher/
├── main.swift           # Entry point, signal handlers for clean shutdown
├── AppDelegate.swift    # App lifecycle, state machine, coordinates components
├── HotkeyManager.swift  # Carbon hotkey registration, CGEvent tap for modifiers
├── AppListProvider.swift# Queries visible apps, maintains MRU order
├── AppSwitcherPanel.swift# NSPanel subclass with visual effect blur
├── AppItemView.swift    # Individual app item (icon + badge, no name label)
├── Preferences.swift    # UserDefaults wrapper (settings keys + donate helper)
├── AccessibilityPermission.swift # AXIsProcessTrusted check + system prompt
├── LoginItem.swift      # "Start at login" via SMAppService (macOS 13+)
├── StatusBarController.swift     # Optional menu bar icon (NSStatusItem) + menu
├── PreferencesWindowController.swift # Programmatic Preferences window
├── WindowActions.swift  # AX actions on other apps' windows (minimize)
└── PrivateAPIs.swift    # CGSSetSymbolicHotKeyEnabled binding

Sources/SwitcherKernels/    # pure logic, no AppKit / no IPC / no state
├── WindowFilter.swift       # which CGWindowList entries count as switchable
├── WindowFilterSpecs.md     # its evidence, incl. the minimized-window finding
├── MinimizedState.swift     # decodes the WindowServer's minimized tag bit
├── MinimizedStateSpecs.md   # the measured bit positions + state matrix
├── ShiftTapResolver.swift   # Shift-tap vs Shift+Tab state machine
├── GridNavigation.swift     # row/column selection movement
└── RecentApps.swift         # the MRU seed's ordering rule (z-order → ranked pids)

Tests/SwitcherKernelsTests/  # executable test runner (see Kernels & tests)
```

### Kernels & tests

Logic that can be made pure lives in the **`SwitcherKernels`** library target, following
AltTab's triad convention: implementation + `*Specs.md` (evidence) + tests, with the spec's
"Test scenarios" section mirroring the test functions 1:1. The app target depends on it and
the call sites delegate; the kernels never touch AppKit, IPC or mutable global state.

Five kernels today: `WindowFilter` (the CGWindowList accept/reject predicate),
`MinimizedState` (the WindowServer tag-bit decode) — both with specs — plus
`ShiftTapResolver`, `GridNavigation` and `RecentApps`.

```bash
swift run --disable-sandbox SwitcherKernelsTests
```

**Not `swift test`, deliberately.** This machine has only the Command Line Tools, which ship
no XCTest and no runner for swift-testing bundles — `swift test` there builds an `.xctest`
bundle it cannot execute and **exits 0 without running anything**, i.e. a green that means
nothing. So the tests are an ordinary executable with a small assertion harness
(`Tests/SwitcherKernelsTests/TestHarness.swift`); it prints each failure with its test name
and line and exits non-zero. If Xcode is ever installed, converting to XCTest or
swift-testing is mechanical — one `Check` call per assertion.

### Component Responsibilities

**main.swift**
- Sets up signal handlers (SIGTERM, SIGINT, SIGTRAP) to restore native Cmd+Tab on crash
- Sets NSSetUncaughtExceptionHandler for Objective-C exceptions
- Creates NSApplication and AppDelegate

**AppDelegate.swift**
- State machine: `idle` <-> `active`
- Coordinates HotkeyManager and AppSwitcherPanel
- Handles keyboard shortcuts (Tab, Shift, Arrows, H, Q, Escape, Return)
- **Live app-list refresh** (`startAppListRefresh`, ~300ms while the panel is open): appends apps whose windows have since rendered. Strictly append-only — it never removes or reorders, so it can't fight the user's own H/Q/M. `remainingSlots()` bounds it under the recent-apps cap, because the panel has no removal-by-pid path (`appendApps` only grows the grid) and would otherwise walk past N. Apps removed with H/Q/M count against the allowance via `actedOnPIDs` rather than freeing a slot — otherwise culling app #3 promotes the old #6 and the panel refills as fast as you empty it. Removals stay monotonic within a session; the next Cmd+Tab is a fresh snapshot at full N. The append pass itself is `appendNewlyVisibleApps()`, shared with the ⌥⌘Tab expansion (`expandToFullList()`): the `expandedSession` flag — decided afresh on every open, set by expansion — switches the pass's source to `allVisibleApps()` and makes `remainingSlots()` unbounded, so an expanded session stays uncapped for the refresh too
- Handles mouse clicks (inside panel = activate clicked app, outside = dismiss)
- **Permission gating**: never disables native Cmd+Tab until the event tap is alive
  - `enableSwitching()`: creates the tap FIRST, and only then disables native Cmd+Tab + registers the Cmd+Tab hotkey (order matters)
  - On launch without Accessibility permission: leaves native Cmd+Tab working and fires the system prompt
  - `startPermissionMonitor()`: a background ~1s poll of `AXIsProcessTrusted()` (App Nap disabled via `beginActivity`) reconciles state — `enableSwitching()` when granted; on revoke `handleRevocation()` restores native Cmd+Tab and quits
  - **Freeze prevention is in the tap type, not the recovery**: the tap is **`.listenOnly`** (see HotkeyManager), so revoking permission can't freeze input regardless of detection. Quit-on-revoke is best-effort cleanup — nothing may depend on it firing.
  - **`AXIsProcessTrusted()` caches per process**: macOS keeps reporting a running app as trusted even after permission is revoked, until relaunch. So the revoke branch usually does NOT fire — the app keeps working until relaunched, which is harmless with a passive tap. Grant detection (the path that matters) works fine.

**HotkeyManager.swift**
- Registers Cmd+Tab AND Cmd+Shift+Tab globally (via `registerHotkeys()`, called by AppDelegate once permission is confirmed). Carbon hotkeys need an exact modifier match, so the Shift variant is its own registration — without it Cmd+Shift+Tab (whose native handler we disable) would do nothing. From idle it opens the panel selecting the LAST app (reverse/wrap-around); while open, Shift+Tab steps backward.
- **⌥⌘Tab (show all)**: a third global registration, made only while `limitRecentApps` is on — a Carbon hotkey steals its combo system-wide, so it isn't squatted for users who never enable the cap. `registerShowAllHotkey()`/`unregisterShowAllHotkey()` are idempotent and guarded on the Carbon handler being installed: a Preferences toggle firing before Accessibility is granted must not consume ⌥⌘Tab with nothing listening. `registerHotkeys()` does the initial registration; the Preferences window's `onToggleLimitRecent` callback flips it live (terminal-side `defaults write` takes effect at relaunch). Its id (14) is deliberately absent from `hotkeyToKeyCode` — it dispatches on its own branch to `hotkeyTriggeredShowAll()`, like `hideOthers`. Being global, one registration covers both idle and panel-open; AppDelegate branches on state
- **Shift-tap vs Shift+Tab disambiguation**: the legacy "tap Shift to go back" gesture fires on Shift *release*, and only if no Cmd+Shift+Tab fired during the hold. Firing on press would double-step every Shift+Tab. The state machine is `ShiftTapResolver` in SwitcherKernels; HotkeyManager feeds it flag transitions inside a single `stateQueue` critical section, since the tap thread and the main-thread Carbon handler both touch it
- `tryCreateEventTap() -> Bool`: creates the CGEvent tap; returns false when Accessibility permission is missing (the gate AppDelegate checks before touching native Cmd+Tab). Idempotent.
- **`.listenOnly` (passive) CGEvent tap**: the window server never waits on it, so revoking Accessibility while it's alive cannot freeze input (an active `.defaultTap` can — forums thread 735204). Trade-off: a passive tap can't consume events — outside clicks are instead swallowed by AppSwitcherPanel's invisible per-screen click-shield windows (see below), which turn click-away into a plain dismiss.
- On `tapDisabledByUserInput`/`tapDisabledByTimeout` (benign throttling) it just re-enables the tap
- **Sticky-panel defense (two layers)**: dismissal rides the tap's Cmd-up `flagsChanged`, but that single event can be dropped (e.g. tap disabled by timeout at the instant of release), leaving the panel stuck open. Layer 1: the tap runs on a dedicated high-priority thread so its callback isn't starved by main-thread UI work. Layer 2: `startCmdWatchdog()` — a ~100ms poll of `CGEventSource.flagsState(.combinedSessionState)` that runs only while the panel is active (started in `registerActiveHotkeys()`, stopped in `unregisterActiveHotkeys()`) and dismisses if Cmd is no longer physically held, independent of event delivery. Double-dismiss is safe: both paths hit the serial main queue and `modifierKeyReleased()`/`dismissPanel()` guard on state.
- Dynamically registers/unregisters other hotkeys (H, Q, arrows, Escape, Return) when panel is shown/hidden
  - `registerActiveHotkeys()` called when panel opens
  - `unregisterActiveHotkeys()` called when panel closes
  - This ensures Cmd+H/Q work normally in other apps when panel is not showing
- **Cmd+&lt;key&gt; swallowing**: while the panel is open, `swallowKeyCodes` registers every other ordinary Cmd combo (Cmd+W, Cmd+S, digits, punctuation…) as a no-op Carbon hotkey, so it can't leak to the app behind the panel. Their ids are `0x1000 + keyCode`, absent from `hotkeyToKeyCode`, so the handler ignores them — registration alone consumes the keystroke
- Tap monitors (read-only): flagsChanged (Cmd release / Shift) and mouseDown (notify delegate of clicks while active)
- **Thread safety**: Uses `DispatchQueue` for synchronized access to `isActive` state
- **Critical**: Sets `isActive` synchronously in event handlers before async delegate calls to avoid race conditions in release builds

**AppListProvider.swift**
- Maintains MRU (Most Recently Used) order via NSWorkspace notifications, seeded at launch from window z-order (see MRU Tracking below)
- `getVisibleApps()`: Returns apps with visible windows OR a Dock badge, sorted by MRU — and capped to the N most recent when `limitRecentApps` is on
- **Recent-apps cap** (`limitRecentApps` / `recentAppsLimit`, default off / 7): `allVisibleApps()` is the uncapped list and `getVisibleApps()` is `prefix(N)` of it. That one line is the whole cap, because `sortByMRU` is the codebase's only ordering point and all three consumers (panel open, the 300ms refresh, `--list-apps`) funnel through `getVisibleApps()`. N counts the app you're currently in, so 7 means 7 icons and 6 switch targets. A Dock badge does NOT exempt an app from the cap — it only rescues it past the window filter — so a badged Mail you haven't touched drops off, which is what keeps N predictable. Ships **off**: with it on, apps outside the window are reachable only through ⌥⌘Tab, the per-session escape hatch — from idle it opens the full uncapped list, while the capped panel is open it appends the apps the cap cut (one-shot: the next Cmd+Tab is capped again). That's the feature, but it's not something to turn on for someone. Side effect at small N: the grid never wraps, so the `⌥⌘H` declutter tip (2+ rows) can no longer appear and `selectUp`/`selectDown` are inert
- Uses CGWindowListCopyWindowInfo to find visible windows
- The accept/reject rule itself is `WindowFilter` in SwitcherKernels: 0 <= layer <= 20, bounds >= 50x50, off-screen windows accepted if they have an owner name (covers other Spaces — and, before the minimized pass, minimized windows too). Evidence and the missing-key defaults: `WindowFilterSpecs.md`
- **Minimized pass** (`classifyWindows()`): windows accepted by the **off-screen branch only** get their wids submitted as ONE batched `SLSWindowQueryWindows`, then get a three-way verdict — keep (a real window on another Space) / minimized / notSwitchable. The third case matters as much as the second: nearly every app owns an invisible off-screen 500×500 helper window that is never minimized, and it alone will hold an app in the switcher forever (this is what made the first cut of 1.2.0 fail on Chrome, Signal and Crypto Pro). Space membership does NOT separate them — genuine other-Space windows also report no Space. On-screen windows are never queried, which is what makes the restore race benign — a restored window is back on-screen before the bit clears (~644ms late per AltTab). An app stays listed if ANY of its windows survives, and a Dock badge rescues it regardless. Decode + evidence: `MinimizedState` / `MinimizedStateSpecs.md`
- **Fails open everywhere**: a failed query, an empty result, or a wid missing from the result all mean "not minimized". A macOS change costs the filtering, never an app the user is looking for
- `--list-apps` prints the computed list with a per-app verdict (visible / other-Space / minimized-rejected / badge-rescued) plus an EXCLUDED section, then exits without registering hotkeys. Window filtering is otherwise invisible, so this is how "why is X missing" gets diagnosed. It reports from the **uncapped** `allVisibleApps()` and draws a cut line where the recent-apps limit falls — otherwise capped-out apps would land in EXCLUDED labelled "hidden / not a regular app", which is a lie told by the exact tool you'd use to catch it
- **Dock badge scan is cached (~2s TTL)**: `getDockBadges()` walks the Dock's AX tree (several IPC round-trips per dock item, on the main thread), and `getVisibleApps()` runs on every Cmd+Tab press plus every 300ms while the panel is open — `getDockBadgesCached()` keeps that off the hot path

**AppSwitcherPanel.swift**
- NSPanel with `.nonactivatingPanel` style (doesn't steal focus)
- NSVisualEffectView with `.hudWindow` material (blur effect)
- Centers on screen containing mouse cursor (multi-monitor support)
- **Multi-row layout**: Uses max 85% of screen width; wraps to additional rows when many apps are open
- **Per-screen icon scaling**: `iconSize(for:)` scales the 76pt base by the target screen's height / 1080, floored at 76 and capped at 160, so large monitors get larger icons and laptops never shrink
- Manages selection state with row/column tracking; the movement rules (wrapping, column clamping into a short last row, the flat-index-to-cell conversion on open, and the reflow after H/Q) are `GridNavigation` in SwitcherKernels
- **Dead zone hover**: Ignores mouse position when panel appears; hover only enabled after 3px mouse movement (prevents accidental selection)
- **Hover has two event sources**: a global mouseMoved monitor AND an `.activeAlways` tracking area on the panel content (`HoverTrackingVisualEffectView`). The tracking area is required because global monitors never see the app's own events — when Switcher itself is active (e.g. Cmd+Tab right after using Preferences) the monitor is silent and hover would otherwise be dead
- **Click shields**: while the panel is open, invisible non-activating panels cover every screen one window level below it, swallowing clicks outside the panel (the `.listenOnly` tap can't consume them) and requesting a dismiss — click-away behaves like Escape and never reaches the app behind
- Uses `mouseLocationOutsideOfEventStream` for accurate mouse position in non-activating panel

**AppItemView.swift**
- Displays app icon at the panel's current item size (76pt base, scaled per screen; no label)
- Selection highlight (white 30% alpha background)
- Optional Dock-badge bubble (red, or a neutral sRGB gray when `grayscaleIcons`); counts over 99 render as "99+"
- **Grayscale is baked into the icon bitmap**, not applied as a layer filter — a CI filter on the item's layer makes CoreAnimation re-rasterize icon+badge whenever the selection highlight changes, which shows up as icons wobbling on hover. The gray is computed in an explicit sRGB colorspace so it doesn't come out bluish on wide-gamut Retina panels

**WindowActions.swift**
- `minimizeAllWindows(ofPID:)` — the M shortcut. AX is the only way to minimize another app's window (there is no `NSRunningApplication.minimize()`), so unlike the WindowServer *read* path this calls INTO the target app and can stall on a busy one. Acceptable because it runs once on deliberate input, never on the hot path — and it still runs on a background queue with `AXUIElementSetMessagingTimeout` so a hung app can't freeze Switcher
- **Reaches only the current Space.** `kAXWindows` does not return windows on other Spaces (measured 2026-08-09: Ghostty 2 AX windows vs ~22 real; Brave 17 = 16 on-screen + 1 minimized), so those stay open and the app reappears on the next Cmd+Tab. A limit of AX, not a bug to fix here
- **The wait is macOS's animation, not our loop.** Issuing minimize for 12 windows takes ~2.8ms; the Dock then animates them in one at a time over ~6s. Issuing concurrently changed the total by <10%, so the sequential loop stays. Nothing in Switcher can make this instant — **H (hide) is the instant alternative**, which is the real difference between the two keys
- Minimizes **every** window, not just the frontmost: the switcher only drops an app once none of its windows survive, so a partial minimize would leave it listed and make the key look broken
- Fullscreen windows refuse to minimize (macOS behavior), so such an app stays listed — honest, since it is still on screen somewhere

**Preferences.swift**
- `enum Preferences`: single source of truth for persisted settings over `UserDefaults.standard`
- Keys: `grayscaleIcons`, `showMenuBarIcon` (defaults to true), `showDeclutterTip` (defaults to true), `hideMinimizedOnlyApps` (defaults to true), `limitRecentApps`, `recentAppsLimit` (defaults to 7), `launchCount`, `hasDonated`
- The recent-apps cap is deliberately **two** keys rather than "0 means off": switching it off and back on must not discard a tuned count. The count is registered, the switch is not (so it ships off, like `grayscaleIcons`)
- `registerDefaults()` must run before any read on every launch (`register(defaults:)` does not persist)
- `openDonatePage()`: the one choke point for donating — sets `hasDonated = true`, then opens the Ko-fi URL

**StatusBarController.swift**
- Owns the optional menu bar icon (`NSStatusItem`), held by a strong reference (system does not retain it)
- `show()` / `hide()` toggle the icon live (driven by `showMenuBarIcon`)
- Menu: Preferences… / Grayscale Icons / Hide Other Apps / Donate / Quit Switcher. The `onOpenPreferences` and `onHideOtherApps` closures call back into AppDelegate
- "Hide Other Apps" carries no key equivalent on purpose: a status-menu accelerator only fires while that menu is open, so the real shortcut is ⌥⌘H inside the switcher panel
- `menuNeedsUpdate` re-reads `grayscaleIcons` on every open, since it can change from the Preferences window or the terminal

**PreferencesWindowController.swift**
- Reusable programmatic Preferences window (`isReleasedWhenClosed = false`)
- Checkboxes: "Start at login" (hidden on macOS < 13), "Show icon in menu bar", "Grayscale icons", "Show declutter tip in switcher", "Hide apps with only minimized windows", and "Show only the [N] most recently used apps" (a horizontal sub-stack: checkbox + `NSPopUpButton` 2…12 + label, popup disabled while the checkbox is off, with a small "⌥⌘Tab shows all apps" hint line underneath — hidden while the cap is off, when that hotkey isn't registered); plus Donate and Quit buttons and a version label. The window's `contentRect` height is fixed, so adding a row means growing it
- The count is a popup, not a text field, on purpose: no formatter, no clamping, no half-typed state to validate for a number with a handful of sensible values
- The "Start at login" checkbox reflects the live `SMAppService` state (not a stored pref); `syncFromPreferences()` refreshes all controls on show
- `show()` calls `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront` so controls are clickable while staying `.accessory` (no Dock icon)
- `onToggleMenuBar` callback lets AppDelegate show/hide the status item immediately; `onToggleLimitRecent` likewise lets it register/unregister the ⌥⌘Tab show-all hotkey live (guarded in HotkeyManager, so a pre-permission toggle is a no-op)

**Preferences / menu bar / donation flow (AppDelegate)**
- App starts silently — the Preferences window does NOT auto-open on every launch
- On startup it auto-surfaces (with a Donate / Maybe Later prompt) only when `!hasDonated && launchCount % 5 == 0`. The nag is deferred (async, after `enableSwitching`/`startPermissionMonitor`) because `runModal()` would otherwise block the Cmd+Tab takeover until answered
- On demand: the menu bar Preferences… item, or relaunching the app (`applicationShouldHandleReopen` surfaces the window)
- `applicationShouldTerminateAfterLastWindowClosed` returns false so closing Preferences keeps the agent running

**PrivateAPIs.swift**
- Declares CGSSetSymbolicHotKeyEnabled using @_silgen_name
- Disables system Cmd+Tab, Cmd+Shift+Tab, Cmd+` hotkeys
- Must be restored on app exit (done in emergencyExit and applicationWillTerminate)
- Also declares the SkyLight window-query family (`SLSWindowQueryWindows` + iterator getters) behind the minimized filter. These need SkyLight **explicitly linked** — see Package.swift, which adds `-F /System/Library/PrivateFrameworks`; `CGSSetSymbolicHotKeyEnabled` and `CGSMainConnectionID` resolve through CoreGraphics without it

## Key APIs Used

### Private/Undocumented
- `CGSSetSymbolicHotKeyEnabled` - Disables system symbolic hotkeys
  - Located in SkyLight.framework (private)
  - Effect persists after app quits; must restore on exit
- `SLSWindowQueryWindows` / `SLSWindowQueryResultCopyWindows` / `SLSWindowIteratorAdvance` / `SLSWindowIteratorGetWindowID` / `SLSWindowIteratorGetAttributes` / `SLSWindowIteratorGetTags` (+ `CGSMainConnectionID`) - batched WindowServer snapshot behind the minimized filter
  - ONE IPC per batch; the iterator getters then read a local snapshot, so extra fields are free
  - Never calls into the target app, so it cannot be blocked by a busy or beach-balling one (unlike AX `kAXMinimized`)
  - **Undocumented bit positions — re-diff on every major macOS.** `MinimizedStateSpecs.md` holds the measured matrix and points at the probe that produced it; the tests pin the raw values so a shift fails loudly instead of silently mis-filtering

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

1. On launch, `AppListProvider.startObserving()` **seeds** the MRU order, then registers for workspace notifications
2. `didActivateApplicationNotification` updates MRU list (most recent at index 0)
3. `didTerminateApplicationNotification` removes terminated apps
4. `getVisibleApps()` sorts filtered apps by MRU order
5. Cmd+Tab opens with the second app selected (index 1) for quick Alt-Tab behavior; Cmd+Shift+Tab opens on the last (least recently used) app instead

**The seed** (`seedMRU()`): only activations that happen while Switcher is running feed the
MRU list, so without a seed exactly one app has a rank and every other ties at `Int.max` in
`sortByMRU` — an arbitrary tail. That was invisible while the switcher listed everything, but
under the recent-apps cap it decides which apps are reachable at all, and it would reset on
every relaunch. So `mruOrder` is seeded from `classifyWindows().windows` in CGWindowList's
front-to-back order (use `.windows`, which is ordered — `.pids` is a `Set`), deduped to first
occurrence per app, with the frontmost app forced to the head. Ordering rule + tests:
`RecentApps`. macOS keeps no queryable activation history, so **z-order is a proxy for
recency, not a record of it** — accurate on the current Space, weaker across Spaces. The
ceiling is one launch: real activations replace it from the first Cmd+Tab onward. This is
also why `Preferences.registerDefaults()` must run *before* `startObserving()` in
`applicationDidFinishLaunching` — the seed's window query reads `hideMinimizedOnlyApps`.

## Permissions Required

**Accessibility** (System Settings > Privacy & Security > Accessibility)
- Required for CGEvent tap to detect modifier key changes (Cmd release, Shift press)
- App checks `AXIsProcessTrusted()` on launch and prompts if missing
- **Without it the app stays safe**: native Cmd+Tab is left working (never disabled), the menu bar icon's Quit is available, and the app polls — taking over automatically within ~1s of being granted. No zombie state, no Activity Monitor needed.
- **If revoked while running**: usually nothing happens until relaunch — `AXIsProcessTrusted()` caches per process, so the poll keeps seeing "granted" (see AppDelegate above). That's safe: the tap is `.listenOnly` and cannot freeze input. If the revoke *is* detected, `handleRevocation()` restores native Cmd+Tab and quits, as cleanup rather than as a fix.
- Implemented in `AccessibilityPermission.swift` + AppDelegate's `enableSwitching`/`handleRevocation`/`startPermissionMonitor`

**Note**: Input Monitoring is NOT required because keyboard shortcuts use Carbon hotkeys (RegisterEventHotKey) instead of CGEvent keyDown monitoring.

**Note**: the minimized filter (1.2.0) added **no permissions**. The SkyLight window query needs none, and Screen Recording is not involved because window titles are never read.

## Build & Run

> **Use `--disable-sandbox` flag** when building from Claude Code or Sandvault. SPM internally uses `sandbox-exec` which conflicts with the environment sandbox. This is safe — the environment already provides OS-level sandboxing.

### Development
```bash
cd /Users/fahd/Claude/_Constantinapple/SimpleSwitcher
swift build --disable-sandbox
swift run --disable-sandbox SwitcherKernelsTests   # kernel tests; see Kernels & tests
.build/debug/SimpleSwitcher
.build/debug/SimpleSwitcher --list-apps           # what the switcher would show, and why
```

Note `--list-apps` on the bare binary reads a different UserDefaults domain than the bundle
(a non-bundled executable has no bundle id), so to test a **preference** use
`Switcher.app/Contents/MacOS/SimpleSwitcher --list-apps` instead.

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
swift build -c release --disable-sandbox
./build-app.sh release
```
This creates `Switcher.app` which can be moved to `/Applications`.

### Auto-Start at Login
- **In-app**: Preferences → "Start at login" (macOS 13+, via `SMAppService.mainApp` in `LoginItem.swift`). The system tracks the state; there's no UserDefaults key. The checkbox is hidden on macOS < 13.
- **Manual**: move `Switcher.app` to `/Applications`, then System Settings > General > Login Items > + > Switcher

## Keyboard Shortcuts (while panel is open)

Cmd+Shift+Tab from **idle** opens the switcher selecting the last (least recently used) app, mirroring the native reverse gesture. When the recent-apps cap is on, ⌥⌘Tab from idle opens the switcher showing the full **uncapped** list.

| Key | Action |
|-----|--------|
| Tab | Select next app |
| Shift+Tab | Select previous app |
| Shift (tap, no Tab) | Select previous app (fires on Shift release) |
| ⌥⌘Tab | Show all apps — expand past the recent-apps cap (press again: select next) |
| Left Arrow | Select previous app |
| Right Arrow | Select next app |
| Up Arrow | Select app in row above (multi-row only) |
| Down Arrow | Select app in row below (multi-row only) |
| H | Hide selected app |
| ⌥⌘H | Hide all other apps (declutter), then dismiss |
| M | Minimize the selected app's windows **on the current Space** (see WindowActions) |
| Q | Quit selected app |
| , | Dismiss and open Preferences (the macOS-wide Cmd+, convention) |
| Return | Activate selected app |
| Escape | Dismiss without switching |
| Release Cmd | Activate selected app |

Every other ordinary Cmd+&lt;key&gt; combo is registered as a no-op while the panel is open, so it is swallowed rather than reaching the app behind (see HotkeyManager's `swallowKeyCodes`).

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
5. **Undocumented WindowServer bits** - the minimized filter reads tag bit 60, measured not documented. Re-diff on every major macOS (`MinimizedStateSpecs.md`); it fails open, so a shift means minimized-only apps reappear rather than apps going missing

## Threading Notes

The CGEvent tap callback runs on a separate thread from the main UI thread. In release builds (with compiler optimizations), race conditions can cause the event tap to miss state changes. The fix:

1. `isActive` state is protected by a serial `DispatchQueue`
2. State is set **synchronously** in event handlers, before any async delegate calls
3. This ensures the event tap sees the correct state even with aggressive compiler optimizations

## Releasing a New Version

When creating a new release:

1. **Build and create release zip:**
```bash
swift run --disable-sandbox SwitcherKernelsTests   # must pass first
swift build -c release --disable-sandbox
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

- [x] Hide apps whose windows are all minimized (1.2.0, via the WindowServer tag bit)
- [x] Cap the switcher to the N most recently used apps (`limitRecentApps`, default off — under evaluation)
- [x] ⌥⌘Tab shows the full list when the cap is on (the cap's escape hatch)
- [ ] Persist `mruOrder` across launches, so the recent-apps cap doesn't fall back to the z-order proxy after a restart
- [ ] Number keys (1-9) for quick selection
- [ ] Window thumbnails (requires Screen Recording permission)
- [x] Preferences window (menu bar icon, grayscale, declutter tip, donate) — basic; shortcuts still code-only
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
