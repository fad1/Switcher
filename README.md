# Switcher

A fast, lightweight Cmd+Tab replacement for macOS. No bloat, no lag, no memory leaks.

## Why Switcher?

**Frustrated with AltTab?** You're not alone. AltTab is powerful but comes with costs:
- 🐌 Sluggish performance over time
- 💾 Memory usage that grows unbounded
- 🔋 Background CPU drain
- 🐛 Occasional freezes and glitches
- ⚙️ Complex settings for features you don't use

**Switcher takes a different approach:** do less, but do it well.

## What Switcher Does

- ✅ Shows only apps with visible windows (no hidden/minimized clutter)
- ✅ Sorts by most recently used
- ✅ Native macOS blur effect
- ✅ Instant response (<16ms)
- ✅ ~30MB memory footprint
- ✅ Zero background CPU when idle
- ✅ Keyboard shortcuts: H to hide, Q to quit, Shift to go back
- ✅ Mouse support: hover to select, click to activate
- ✅ Multi-monitor: appears on screen where your pointer is

## What Switcher Doesn't Do

- ❌ Window thumbnails (requires Screen Recording permission)
- ❌ Per-window switching
- ❌ Preferences UI
- ❌ Themes or customization
- ❌ Anything else

**This is intentional.** Switcher does one thing and does it well.

## Installation

### Homebrew (Recommended)
```bash
brew tap fad1/tap
brew install --cask switcher
```

### Manual Download
Grab `Switcher.app` from [Releases](../../releases) and move it to `/Applications`.

### Build from Source
```bash
git clone https://github.com/fad1/Switcher.git
cd Switcher
swift build -c release
./create-icon.sh  # optional: creates app icon
./build-app.sh release
```

### First Run

**Important:** Grant Accessibility permission *before* launching Switcher for the first time.

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click the **+** button and add Switcher.app
3. Now open Switcher.app
4. Press Cmd+Tab — that's it

> **Why?** If you launch first and grant permission via the macOS prompt, the app may hang. You'd need to remove it from Accessibility, quit the app, re-add it, then relaunch.

### Removing Permissions

**Never remove Switcher from Accessibility while it's running.** Always quit the app first (use Activity Monitor if needed).

> **Why?** This is a [known macOS bug](https://developer.apple.com/forums/thread/735204): removing Accessibility permission from an app using CGEventTap while it's running can block mouse clicks system-wide, requiring a restart to fix.

### Auto-Start
System Settings → General → Login Items → add Switcher

## Usage

| Key | Action |
|-----|--------|
| Cmd+Tab | Open switcher / next app |
| Shift | Previous app |
| ←/→ | Navigate left/right |
| ↑/↓ | Navigate up/down (when multiple rows) |
| H | Hide selected app |
| Q | Quit selected app |
| Return | Activate |
| Escape | Dismiss |
| Release Cmd | Activate selected |

Mouse: hover to select (after slight movement), click to activate.

## Options

**Grayscale icons** — show app icons without color:
```bash
defaults write com.simpleswitcher.app grayscaleIcons -bool true
```
To revert:
```bash
defaults delete com.simpleswitcher.app grayscaleIcons
```
Restart the app after changing.

## Permissions

**Only Accessibility** — no Input Monitoring, no Screen Recording, no admin access.

## Technical Details

~900 lines of Swift. No dependencies. Uses:
- Carbon hotkeys (avoids Input Monitoring requirement)
- CGEvent tap for modifier detection
- Private `CGSSetSymbolicHotKeyEnabled` API to intercept native Cmd+Tab

See [CLAUDE.md](CLAUDE.md) for architecture details.

## Philosophy

> "Perfection is achieved not when there is nothing more to add, but when there is nothing left to take away." — Antoine de Saint-Exupéry

Switcher exists because sometimes you just want to switch apps. Fast. Without thinking about it. Without your computer grinding to a halt after a week of uptime.

If you need window thumbnails, per-window switching, or extensive customization, use AltTab. It's a great project with different goals.

If you want a Cmd+Tab that just works, try Switcher.

## Support

If you find Switcher useful, you can [buy me a coffee](https://ko-fi.com/cheetah9960).

## License

MIT
