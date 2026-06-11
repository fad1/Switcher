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
- ✅ Light memory footprint (releases its UI when idle)
- ✅ Negligible background CPU (a lightweight permission check, no window polling)
- ✅ Keyboard shortcuts: H to hide, Q to quit, Shift to go back
- ✅ Mouse support: hover to select, click to activate
- ✅ Multi-monitor: appears on screen where your pointer is

## What Switcher Doesn't Do

- ❌ Window thumbnails (requires Screen Recording permission)
- ❌ Per-window switching
- ❌ Themes or extensive customization
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

1. Open **Switcher.app**
2. When prompted, grant Accessibility permission in **System Settings → Privacy & Security → Accessibility** (toggle Switcher on)
3. Switcher takes over Cmd+Tab automatically within ~1 second — no relaunch needed

Until you grant permission, Switcher **leaves your native Cmd+Tab working** and waits, so it can never get stuck. You can quit any time from its menu bar icon (⌘ → Quit).

> Switcher is ad-hoc signed, so rebuilding/replacing the app can invalidate a previous grant — just remove and re-add it under Accessibility.

### Stopping Switcher

To turn Switcher off, use **menu bar ⌘ → Quit**.

> Removing its Accessibility permission is *not* a reliable off-switch: macOS caches an app's permission for its entire running lifetime, so Switcher keeps working until you **relaunch** it (at which point it sees no permission and leaves Cmd+Tab alone). Switcher uses a *passive* event tap, so — unlike many tools — revoking its permission does **not** risk the [known macOS input-freeze](https://developer.apple.com/forums/thread/735204) that active-tap apps can trigger.

### Auto-Start
Open **Preferences** (menu bar ⌘) and tick **Start at login** (macOS 13+). Or add it manually via System Settings → General → Login Items.

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

## Preferences

Switcher runs in the background. Open **Preferences** from its menu bar icon, or by
launching Switcher again while it's already running. The window lets you:

- **Show icon in menu bar** — toggle the menu bar icon on or off
- **Grayscale icons** — show app icons without color (applies on the next Cmd+Tab)
- **Donate** — support development

The menu bar icon (⌘) also has a quick **Grayscale Icons** toggle, plus Preferences, Donate, and Quit.

Grayscale can still be set from the terminal if you prefer:
```bash
defaults write com.simpleswitcher.app grayscaleIcons -bool true   # enable
defaults delete com.simpleswitcher.app grayscaleIcons             # revert
```

## Permissions

**Only Accessibility** — no Input Monitoring, no Screen Recording, no admin access.

## Technical Details

~1,900 lines of Swift across 12 files. No dependencies. Uses:
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
