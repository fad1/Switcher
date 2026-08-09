import CoreGraphics
import SwitcherKernels

/// Pins the WindowServer decode against the exact values observed on this
/// machine (macOS 15.7.9 / Darwin 24). If a future macOS shifts these bits, this
/// fails loudly instead of silently filtering apps out of the switcher.
/// Mirrors `MinimizedStateSpecs.md` 1:1.
enum MinimizedStateTests {

    // The measured values, straight from the probe matrix. These come from a
    // .regular app's window (the shape that can actually reach the switcher).
    private static let tagsNormal: UInt64 = 0x0300000100482001
    private static let tagsMinimized: UInt64 = 0x1300000100480001
    private static let tagsRestored: UInt64 = 0x0300000100480001
    private static let tagsOrderedOut: UInt64 = 0x0300000100480001
    private static let attrsOrderedIn: UInt64 = 0x0000000000000002
    private static let attrsOrderedOut: UInt64 = 0x0000000000000000

    // A window on another Space, observed on Ghostty and Finder: off-screen and
    // not minimized, but a real window — this MUST keep its app listed.
    private static let tagsOtherSpace: UInt64 = 0x0300000100480001
    // The invisible 500x500 helper window nearly every app owns (observed on
    // Signal, KeePassXC, Crypto Pro, Emacs, Activity Monitor, Claude Usage).
    private static let tagsHelperWindow: UInt64 = 0x0000000100080001
    // Chromium's off-screen bubble — the one helper that DOES belong to a Space,
    // which is why Space membership cannot be used as the discriminator.
    private static let tagsChromiumBubble: UInt64 = 0x00000001400C0402
    // Activity Monitor's on-screen window: only the LOW marker bit, hence the
    // mask test is "either bit", not "both".
    private static let tagsActivityMonitor: UInt64 = 0x0200000100482001

    private static func w(_ wid: CGWindowID = 1, attributes: UInt64 = attrsOrderedIn,
                          tags: UInt64 = tagsNormal) -> WsRawWindow {
        WsRawWindow(wid: wid, attributes: attributes, tags: tags)
    }

    static func runAll() {
        // A. The minimized bit
        Check.run("testMinimizedWhenTagBitSet", testMinimizedWhenTagBitSet)
        Check.run("testNotMinimizedWhenTagBitClear", testNotMinimizedWhenTagBitClear)
        Check.run("testOrderedOutWindowIsNotMinimized", testOrderedOutWindowIsNotMinimized)
        Check.run("testRestoredWindowIsNotMinimized", testRestoredWindowIsNotMinimized)
        Check.run("testBitThirteenIsNotUsedAsASignal", testBitThirteenIsNotUsedAsASignal)
        // B. Ordered-in
        Check.run("testOrderedInWhenAttributeBitSet", testOrderedInWhenAttributeBitSet)
        Check.run("testNotOrderedInWhenMinimizedOrOrderedOut", testNotOrderedInWhenMinimizedOrOrderedOut)
        Check.run("testOrderedInIsNotAMinimizedSignal", testOrderedInIsNotAMinimizedSignal)
        // C. Helper windows (the 1.2.0 follow-up fix)
        Check.run("testRealWindowsCarryTheSwitchableMarker", testRealWindowsCarryTheSwitchableMarker)
        Check.run("testHelperWindowsLackTheMarker", testHelperWindowsLackTheMarker)
        Check.run("testChromiumBubbleIsNotSwitchable", testChromiumBubbleIsNotSwitchable)
        Check.run("testOtherSpaceWindowIsKept", testOtherSpaceWindowIsKept)
        Check.run("testVerdictSeparatesAllThreeCases", testVerdictSeparatesAllThreeCases)
        // D. Fail-open policy
        Check.run("testIdentifiesMinimizedCandidates", testIdentifiesMinimizedCandidates)
        Check.run("testWidMissingFromTheResultIsTreatedAsNotMinimized",
                  testWidMissingFromTheResultIsTreatedAsNotMinimized)
        Check.run("testEmptyResultRejectsNothing", testEmptyResultRejectsNothing)
        Check.run("testNoCandidatesRejectsNothing", testNoCandidatesRejectsNothing)
        Check.run("testUnrelatedWidsInTheResultAreIgnored", testUnrelatedWidsInTheResultAreIgnored)
    }

    // MARK: - A. The minimized bit (observed values)

    static func testMinimizedWhenTagBitSet() {
        Check.expect(MinimizedState.isMinimized(w(tags: tagsMinimized)))
        Check.equal(MinimizedState.minimizedTag, 1 << 60, "the measured bit position")
    }

    static func testNotMinimizedWhenTagBitClear() {
        Check.expect(!MinimizedState.isMinimized(w(tags: tagsNormal)))
    }

    /// The discrimination the whole feature rests on: an orderOut() window is
    /// off-screen and ordered out, exactly like a minimized one, but bit 60 is
    /// clear. A window on another Space reads the same way.
    static func testOrderedOutWindowIsNotMinimized() {
        Check.expect(!MinimizedState.isMinimized(w(attributes: attrsOrderedOut, tags: tagsOrderedOut)))
    }

    static func testRestoredWindowIsNotMinimized() {
        // Not sticky: the bit clears once the window comes back.
        Check.expect(!MinimizedState.isMinimized(w(tags: tagsRestored)))
    }

    /// Bit 13 is cleared by minimize AND by orderOut(), so it cannot separate
    /// them — recorded here so nobody rediscovers it as a shortcut.
    static func testBitThirteenIsNotUsedAsASignal() {
        let bit13: UInt64 = 1 << 13
        Check.expect(tagsNormal & bit13 != 0, "baseline has bit 13 set")
        Check.expect(tagsMinimized & bit13 == 0, "minimize clears bit 13")
        Check.expect(tagsOrderedOut & bit13 == 0, "orderOut clears bit 13 too — hence useless")
        // Only bit 60 tells the two apart.
        Check.expect(MinimizedState.isMinimized(w(tags: tagsMinimized))
                     != MinimizedState.isMinimized(w(tags: tagsOrderedOut)))
    }

    // MARK: - B. Ordered-in (attributes & 0x2)

    static func testOrderedInWhenAttributeBitSet() {
        Check.expect(MinimizedState.isOrderedIn(w(attributes: attrsOrderedIn)))
    }

    static func testNotOrderedInWhenMinimizedOrOrderedOut() {
        // Observed 0x0 for both minimized and orderOut().
        Check.expect(!MinimizedState.isOrderedIn(w(attributes: attrsOrderedOut)))
    }

    /// Ordered-out does NOT imply minimized. Having both decodes is the point.
    static func testOrderedInIsNotAMinimizedSignal() {
        let orderedOutNotMinimized = w(attributes: attrsOrderedOut, tags: tagsOrderedOut)
        Check.expect(!MinimizedState.isOrderedIn(orderedOutNotMinimized))
        Check.expect(!MinimizedState.isMinimized(orderedOutNotMinimized))
    }

    // MARK: - C. Helper windows

    /// Every window a user can switch to carries the marker — on-screen, on
    /// another Space, or minimized alike.
    static func testRealWindowsCarryTheSwitchableMarker() {
        for tags in [tagsNormal, tagsMinimized, tagsRestored, tagsOtherSpace, tagsActivityMonitor] {
            Check.expect(MinimizedState.isSwitchable(w(tags: tags)),
                         String(format: "0x%016llX is a real window", tags))
        }
    }

    /// The invisible 500x500 window nearly every app owns. Off-screen and never
    /// minimized, so without this it looks exactly like an other-Space window and
    /// keeps its app in the switcher forever.
    static func testHelperWindowsLackTheMarker() {
        Check.expect(!MinimizedState.isSwitchable(w(tags: tagsHelperWindow)))
        Check.expect(!MinimizedState.isMinimized(w(tags: tagsHelperWindow)),
                     "it is genuinely not minimized — the marker is what rejects it")
    }

    /// Chromium's bubble belongs to a Space, unlike the other helpers, which is
    /// why Space membership is NOT usable as the discriminator.
    static func testChromiumBubbleIsNotSwitchable() {
        Check.expect(!MinimizedState.isSwitchable(w(tags: tagsChromiumBubble)))
    }

    /// The regression this must never cause: a window merely on another desktop
    /// keeps its app listed.
    static func testOtherSpaceWindowIsKept() {
        Check.equal(MinimizedState.verdict(for: w(tags: tagsOtherSpace)), .keep)
    }

    static func testVerdictSeparatesAllThreeCases() {
        Check.equal(MinimizedState.verdict(for: w(tags: tagsOtherSpace)), .keep)
        Check.equal(MinimizedState.verdict(for: w(tags: tagsMinimized)), .minimized)
        Check.equal(MinimizedState.verdict(for: w(tags: tagsHelperWindow)), .notSwitchable)
    }

    // MARK: - D. Fail-open policy

    static func testIdentifiesMinimizedCandidates() {
        let states: [CGWindowID: WsRawWindow] = [
            10: w(10, tags: tagsMinimized),
            11: w(11, tags: tagsOtherSpace),
            12: w(12, tags: tagsHelperWindow),
        ]
        let rejected = MinimizedState.rejectedWids(among: [10, 11, 12], states: states)
        Check.equal(rejected[10], .minimized)
        Check.isNil(rejected[11], "an other-Space window must not be rejected")
        Check.equal(rejected[12], .notSwitchable)
    }

    /// A submitted wid the query did not return must survive — a window we know
    /// nothing about is never hidden.
    static func testWidMissingFromTheResultIsTreatedAsNotMinimized() {
        let states: [CGWindowID: WsRawWindow] = [10: w(10, tags: tagsMinimized)]
        let rejected = MinimizedState.rejectedWids(among: [10, 99], states: states)
        Check.equal(rejected[10], .minimized)
        Check.isNil(rejected[99])
    }

    /// A failed or empty query degrades to today's behavior: nothing filtered.
    static func testEmptyResultRejectsNothing() {
        Check.expect(MinimizedState.rejectedWids(among: [10, 11], states: [:]).isEmpty)
    }

    static func testNoCandidatesRejectsNothing() {
        Check.expect(MinimizedState.rejectedWids(among: [], states: [10: w(10, tags: tagsMinimized)]).isEmpty)
    }

    /// A minimized window that was not a candidate must not leak into the
    /// rejection set — only submitted wids can be rejected.
    static func testUnrelatedWidsInTheResultAreIgnored() {
        let states: [CGWindowID: WsRawWindow] = [
            10: w(10, tags: tagsOtherSpace),
            77: w(77, tags: tagsMinimized),
        ]
        Check.expect(MinimizedState.rejectedWids(among: [10], states: states).isEmpty)
    }
}
