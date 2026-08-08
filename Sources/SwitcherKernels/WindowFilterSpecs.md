# WindowFilter — Specs

## Summary

`WindowFilter` is the pure accept/reject decision behind "which apps have a switchable
window". `AppListProvider.getVisibleWindowPIDs()` reads every entry from
`CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionAll], kCGNullWindowID)`,
decodes each into a `RawWindow`, and collects the owner PID of every window the filter
accepts. An app is listed if it owns at least one accepted window **or** carries a Dock
badge — the badge rule lives in `getVisibleApps()` and is entirely independent of this
filter.

The verdict distinguishes *why* a window was rejected, and an accepted window reports
which branch took it (`accept(onScreen:)`). That distinction is not cosmetic: the
off-screen branch is where minimized windows enter, so it is the only place a future
minimized filter can act without touching on-screen windows.

## The constants

- **`0 ≤ layer ≤ 20`.** Ordinary application windows sit at layer 0. Negative layers are
  below the desktop. A few apps use small positives — layer 3 is screensaver/fullscreen
  video. Above ~20 is system UI: menu bar, Dock. The ceiling of 20 is deliberately loose;
  it admits the small-positive cases without admitting chrome.
- **`width ≥ 50 && height ≥ 50`.** Menus, tooltips and shadow helper windows are reported
  by CGWindowList like any other window. 50pt in either dimension is the floor for
  something a user would switch to.
- **Missing bounds → reject.** A window with no `kCGWindowBounds` entry is not something
  that can be shown; it is rejected separately from "too small" so the two are
  distinguishable when diagnosing.
- **Off-screen → require a non-empty `kCGWindowOwnerName`.** This is the only guard
  keeping system-process windows out of the off-screen branch.

## Defaults when a key is missing

Preserved exactly as the switcher has always read them, because they decide edge cases:

| key | missing → | effect |
|---|---|---|
| `kCGWindowLayer` | `0` | treated as an ordinary window (accepted by the layer test) |
| `kCGWindowIsOnscreen` | `false` | routed through the stricter off-screen branch |
| `kCGWindowBounds` | `nil` | `.rejectNoBounds` |
| `Width` / `Height` inside bounds | `0` | `.rejectTooSmall` |
| `kCGWindowOwnerName` | `nil` | rejected **only** on the off-screen branch |
| `kCGWindowOwnerPID` | `nil` | window is accepted but contributes no PID |

## Evidence: minimized windows cannot be excluded here (2026-07, macOS 15 / Darwin 24)

Verified empirically: **an app whose only window is minimized still appears in the
switcher, and this filter cannot fix that.**

A minimized window is off-screen in CGWindowList terms — `kCGWindowIsOnscreen` is false.
So is a window on another Space. Both carry a valid owner name, valid bounds and layer 0.
From the fields CGWindowList exposes, the two states are indistinguishable, and the
off-screen branch **must** accept other-Space windows: rejecting them would drop apps
that are merely on another desktop, which is a far worse failure than listing a minimized
app.

Excluding minimized windows therefore needs a source outside CGWindowList. The two known
ones:

- Per-window AX `kAXMinimized` (what AltTab used until 2026-08-04). Correct, but it is a
  synchronous call *into the target app*: ~500ms mid-animation and unbounded against an
  app that is beach-balling. Unacceptable on this filter's hot path — `getVisibleApps()`
  runs on every Cmd+Tab press and again every 300ms while the panel is open.
- The WindowServer's own minimized bit, read via a single batched `SLSWindowQueryWindows`
  (`SLSWindowIteratorGetTags`). ~100–200µs, never blocks on another app. This is the
  route the port brief's phase 3 takes, gated on a local probe of the bit positions.

Until then, "minimized-only apps still appear" is a known limitation, not a bug — and any
future fix belongs on the **off-screen branch only**, leaving on-screen windows untouched.

**Re-check on a new major macOS.** The layer numbering and the off-screen semantics are
observed behavior, not documented contract.

## Test scenarios

Mirrors `WindowFilterTests.swift` 1:1.

### A. Layer
- **testOrdinaryWindowAtLayerZeroIsAccepted** — layer 0, on-screen, ample size → accepted.
- **testNegativeLayerIsRejected** — layer −1 (below the desktop) → `.rejectLayer`.
- **testLayerAboveCeilingIsRejected** — layer 21 and layer 25 (system UI) → `.rejectLayer`.
- **testSmallPositiveLayersAreAccepted** — layers 1, 3 and 20 (fullscreen video and the
  boundary) → accepted.

### B. Size
- **testWindowBelowMinimumSizeIsRejected** — 49×200 and 200×49 → `.rejectTooSmall`.
- **testWindowAtExactlyMinimumSizeIsAccepted** — 50×50 → accepted (the bound is inclusive).
- **testMissingBoundsIsRejected** — `size` nil → `.rejectNoBounds`, distinct from too-small.

### C. Off-screen branch
- **testOffScreenWindowWithOwnerNameIsAccepted** — the other-Space case → `accept(onScreen: false)`.
- **testOffScreenWindowWithoutOwnerNameIsRejected** — nil owner name → `.rejectNoOwnerName`.
- **testOffScreenWindowWithEmptyOwnerNameIsRejected** — `""` counts as absent.
- **testOnScreenWindowNeedsNoOwnerName** — the owner-name guard applies only off-screen.
- **testAcceptedVerdictReportsWhichBranchAcceptedIt** — the on-screen flag is carried
  through to the verdict, which is what a minimized filter would key off.

### D. Minimized-only apps (the known limitation, pinned deliberately)
- **testMinimizedWindowIsIndistinguishableFromOtherSpaceWindow** — two `RawWindow`s built
  from the fields a minimized window and an other-Space window report are *equal*, and both
  are accepted. Pins the limitation so that a change claiming to fix it has to change this
  test, and records why the fix cannot live in this filter.

### E. Decoding a CGWindowList entry
- **testDecodesAFullWindowInfoDictionary** — every key present, values round-trip.
- **testMissingLayerDefaultsToZero** — absent layer reads as an ordinary window.
- **testMissingOnScreenFlagDefaultsToFalse** — absent flag routes through the off-screen branch.
- **testMissingBoundsDecodesToNilSize** — distinguishes absent bounds from zero-sized bounds.
- **testBoundsMissingWidthOrHeightDecodeToZero** — a partial bounds dict rejects as too small.
- **testWrongTypesAreTreatedAsMissing** — a string where a number belongs falls back to the
  documented defaults rather than trapping.
