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

### C. Fail-open policy
- **testIdentifiesMinimizedCandidates** — the ordinary case, a mixed batch.
- **testWidMissingFromTheResultIsTreatedAsNotMinimized** — a submitted wid the query did not
  return must survive.
- **testEmptyResultRejectsNothing** — a failed or empty query degrades to today's behavior.
- **testNoCandidatesRejectsNothing** — trivially empty.
- **testUnrelatedWidsInTheResultAreIgnored** — a minimized window that was not a candidate
  does not leak into the rejection set.
