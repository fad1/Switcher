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
- ✅ ~3MB memory footprint
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

**This is intentional.** Switcher is finished software. It does one thing and does it correctly. No feature creep, no updates that break things, no growing complexity.

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
1. Open Switcher.app
2. Grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility)
3. Press Cmd+Tab — that's it

### Auto-Start
System Settings → General → Login Items → add Switcher

## Usage

| Key | Action |
|-----|--------|
| Cmd+Tab | Open switcher / next app |
| Shift | Previous app |
| ←/→ | Navigate |
| H | Hide selected app |
| Q | Quit selected app |
| Return | Activate |
| Escape | Dismiss |
| Release Cmd | Activate selected |

Mouse: hover to select (after slight movement), click to activate.

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

## License

MIT
