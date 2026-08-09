# MinimizedState — Specs

## Summary

`MinimizedState` is the pure decode of a window's WindowServer fields — `attributes` and
`tags`, read in one batched `SLSWindowQueryWindows` snapshot — into "is this window
minimized". It is what lets `WindowFilter`'s off-screen branch finally tell a **minimized**
window from a window **on another Space**, which CGWindowList alone cannot do (see
`WindowFilterSpecs.md`).

The bit positions are undocumented and were **measured on this machine**, not inherited
from AltTab. The tests pin the exact observed values so a future macOS that shifts them
fails loudly here instead of silently mis-filtering apps out of the switcher.

## The constants

- **`tags & (1 << 60)` = minimized.** `tags` is a second bitfield returned by
  `SLSWindowIteratorGetTags`, separate from `attributes`. Bit 60 was the *only* bit that
  was set while minimized and clear in normal, restored **and** `orderOut()` states.
- **`attributes & 0x2` = ordered in / on screen.** Cleared by minimize, app-hide, moving to
  another Space, and by a closing window mid-teardown. An ordered-in signal, **not** a
  minimized one — conflating the two is the mistake this whole triad exists to prevent.
- **`tags & 0x0300000000000000` (bits 56|57) = a window a user can switch to.** Clear on
  the invisible helper windows apps keep around. Without it, detecting minimized is not
  enough to hide an app — see "Helper windows" below, which is the bug that shipped in the
  first cut of 1.2.0.

## State matrix (2026-08-08, macOS 15.7.9 build 24G830, Darwin 24, arm64)

An own-process `NSWindow` walked through every state, diffing `tags`. Own-process because
it needs no permissions and lets states be driven on demand, which is not possible in
another app. Baseline for a plain windowed window is `0x0000200100482001`.

| state | attributes | tags | vs baseline |
|---|---|---|---|
| normal (ordered in) | `0x0000000000000002` | `0x0000200100482001` | — |
| **minimized** | `0x0000000000000000` | `0x1000200100480001` | **+60**, −13 |
| restored | `0x0000000000000002` | `0x0000200100480001` | −13 |
| `orderOut()` (off-screen, NOT minimized) | `0x0000000000000000` | `0x0000200100480001` | −13 |
| minimized again | `0x0000000000000000` | `0x1000200100480001` | **+60**, −13 |
| restored again | `0x0000000000000002` | `0x0000200100480001` | −13 |

**Bit 60 is specific, not merely correlated.** `orderOut()` produces a window that is
off-screen, ordered out, and otherwise indistinguishable from a minimized one — and it
leaves bit 60 clear. The bit is also not sticky: a second minimize sets it again after a
restore cleared it.

**Bit 13 is noise.** It is cleared by minimize *and* by `orderOut()`, and it does not
return after a restore. Nothing may be built on it; `attributes & 0x2` is the ordered-in
signal. (AltTab reached the same conclusion on macOS 26.)

**Differences from AltTab's macOS 26 measurement.** The baseline `tags` value differs
(`0x0000200100482001` here vs `0x0300000100482001` there) — expected across OS versions.
The bit 60 semantics are identical on both.

**Not measured here:** the app-hidden bit (AltTab observed bit 39 on macOS 26). Switcher
never needs it — `getVisibleApps()` already drops hidden apps via `NSRunningApplication`
`isHidden`, before any of this runs.

## Helper windows — why detecting minimized is not enough (2026-08-09)

The first cut of this feature detected minimized correctly and still failed in the field:
minimizing Chrome, Signal or Crypto Pro left them in the switcher. The minimized window
*was* being rejected. What kept the app listed was a **second, invisible window**.

Nearly every app owns an off-screen 500×500 window at (0,400) that is never displayed —
observed on Signal, KeePassXC, Crypto Pro, Emacs, Activity Monitor, Claude Usage, and
others. Chromium apps add more: 54×54 stubs and off-screen bubbles. To CGWindowList these
are indistinguishable from a window on another Space: off-screen, layer 0, ≥50×50, valid
owner name. And they are genuinely *not* minimized, so bit 60 does not reject them.

Measured on the failing apps (all minimized at the time):

| app | real window | helper window(s) |
|---|---|---|
| Crypto Pro | `0x1300000100480001` min, spaces=1:3 | `0x0000000100080001` 500×500, spaces=NONE |
| Signal | `0x1300000100080401` min, spaces=1:3 | `0x0000000100080001` 500×500, spaces=NONE |
| KeePassXC | `0x1300002100480001` min, spaces=1:3 | `0x0000000100080001` 500×500, spaces=NONE |
| Google Chrome | `0x1300000100080401` min, spaces=1:130 | `0x0000000100080001` 54×54 + `0x0000000100080402` + `0x00000001400C0402` bubble, spaces=1:130 |

**Space membership is NOT the discriminator, despite appearances.** Three of the four
helpers report `spaces=NONE`, which looks decisive until you check a real window on another
desktop: Ghostty's and Finder's other-Space windows *also* report `spaces=NONE`
(`0x0300000100480001`). Filtering on Space membership would have hidden every app on
another desktop — the exact catastrophic failure this filter must never cause. Chrome's
bubble independently disproves it from the other side: it *does* belong to a Space.

**Bits 56|57 are the discriminator.** Verified across 18 regular apps and ~160 windows:

- Set on every window a user can switch to — on-screen, on another Space, and minimized
  alike (`0x03` in the top byte; minimized reads `0x13` because bit 60 joins it).
- Clear on every helper window observed, including Chrome's Space-bearing bubble.
- The check is **either bit, not both**: ordinary windows read `0x03` but Activity
  Monitor's on-screen window reads `0x02`.
- Sweep result: the rule newly hid exactly the four apps that were minimized, and **no app
  holding an on-screen window**. The only on-screen window lacking the marker belonged to a
  non-regular app, which can never reach the switcher anyway.
- An `.accessory` app's window also reads `0x00`. Harmless — `getVisibleApps()` already
  requires `activationPolicy == .regular`.

The semantics of these two bits are not known, only their behavior. They are treated as an
opaque measured marker, pinned by tests, exactly like bit 60.

## Cross-process behavior and cost (same session)

Measured against every window on a busy machine, submitted as one batch:

- 154 candidate wids submitted, **154 returned, 0 missing**.
- Exactly 2 windows reported minimized (Brave Browser, KeePassXC); both genuinely were.
- **0 on-screen windows reported minimized** — the false-positive check that matters most,
  since a false positive would hide an app the user is looking at.
- No new permissions. Accessibility only, unchanged; no Screen Recording, because window
  titles are never read.

Cost, median of 25 warm runs: roughly **50µs fixed + ~2.7µs per wid**.

| wids | median |
|---|---|
| 25 | 85 µs |
| 100 | 253 µs |
| 123 (off-screen candidates only) | **286 µs** |
| 398 (every window on the system) | 1128 µs |

This is why the caller submits **only the off-screen candidates, in one batch per
invocation** — never the whole window list, and never one query per window.

## The restore race, and why it is benign here

AltTab measured that on a Dock restore the minimized bit clears **late** (~644ms, after the
animation ends), later even than AX. That would matter if the bit were the only signal.

It is not, because the filter only ever runs on the **off-screen branch**. A restored
window is back on-screen — `kCGWindowIsOnscreen` true — well before the bit clears, so it
is accepted by the on-screen branch and never reaches this decode. The stale `true` is
therefore unobservable.

**Re-diff on a new major macOS.** These are undocumented bit positions. The probe that
produced the matrix above is described in `.claude/plans/alttab-port.md`; re-run its
equivalent and compare before trusting the constants on a new OS.

## Test scenarios

Mirrors `MinimizedStateTests.swift` 1:1.

### A. The minimized bit (observed values)
- **testMinimizedWhenTagBitSet** — `tags = 0x1000200100480001` (observed minimized) → minimized.
- **testNotMinimizedWhenTagBitClear** — `tags = 0x0000200100482001` (observed normal) → not minimized.
- **testOrderedOutWindowIsNotMinimized** — `tags = 0x0000200100480001`, the observed
  `orderOut()` value: ordered out, but NOT minimized. The discrimination everything rests on.
- **testRestoredWindowIsNotMinimized** — the observed restored value → not minimized, i.e.
  the bit is not sticky.
- **testBitThirteenIsNotUsedAsASignal** — the minimized and `orderOut()` values differ from
  baseline in bit 13 alike, so bit 13 cannot separate them; only bit 60 does.

### B. Ordered-in (`attributes & 0x2`)
- **testOrderedInWhenAttributeBitSet** — `attributes = 0x2` (observed normal) → ordered in.
- **testNotOrderedInWhenMinimizedOrOrderedOut** — `attributes = 0x0` (observed for both) → not ordered in.
- **testOrderedInIsNotAMinimizedSignal** — an ordered-out window that is NOT minimized:
  the two decodes disagree, which is the whole point of having both.

### C. Helper windows
- **testRealWindowsCarryTheSwitchableMarker** — normal, minimized, restored, other-Space and
  Activity Monitor's `0x02` variant all carry it.
- **testHelperWindowsLackTheMarker** — the observed 500×500 helper: not switchable, and
  genuinely *not* minimized, so the marker is the only thing that rejects it.
- **testChromiumBubbleIsNotSwitchable** — the helper that belongs to a Space.
- **testOtherSpaceWindowIsKept** — the regression this must never cause.
- **testVerdictSeparatesAllThreeCases** — keep / minimized / notSwitchable.

### D. Fail-open policy
- **testIdentifiesMinimizedCandidates** — the ordinary case, a mixed batch.
- **testWidMissingFromTheResultIsTreatedAsNotMinimized** — a submitted wid the query did not
  return must survive.
- **testEmptyResultRejectsNothing** — a failed or empty query degrades to today's behavior.
- **testNoCandidatesRejectsNothing** — trivially empty.
- **testUnrelatedWidsInTheResultAreIgnored** — a minimized window that was not a candidate
  does not leak into the rejection set.
