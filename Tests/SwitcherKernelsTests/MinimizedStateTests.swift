import CoreGraphics
import SwitcherKernels

/// Pins the WindowServer decode against the exact values observed on this
/// machine (macOS 15.7.9 / Darwin 24). If a future macOS shifts these bits, this
/// fails loudly instead of silently filtering apps out of the switcher.
/// Mirrors `MinimizedStateSpecs.md` 1:1.
enum MinimizedStateTests {

    // The measured values, straight from the probe matrix.
    private static let tagsNormal: UInt64 = 0x0000200100482001
    private static let tagsMinimized: UInt64 = 0x1000200100480001
    private static let tagsRestored: UInt64 = 0x0000200100480001
    private static let tagsOrderedOut: UInt64 = 0x0000200100480001
    private static let attrsOrderedIn: UInt64 = 0x0000000000000002
    private static let attrsOrderedOut: UInt64 = 0x0000000000000000

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
        // C. Fail-open policy
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

    // MARK: - C. Fail-open policy

    static func testIdentifiesMinimizedCandidates() {
        let states: [CGWindowID: WsRawWindow] = [
            10: w(10, tags: tagsMinimized),
            11: w(11, tags: tagsOrderedOut),
            12: w(12, tags: tagsMinimized),
        ]
        Check.equal(MinimizedState.minimizedWids(among: [10, 11, 12], states: states), [10, 12])
    }

    /// A submitted wid the query did not return must survive — a window we know
    /// nothing about is never hidden.
    static func testWidMissingFromTheResultIsTreatedAsNotMinimized() {
        let states: [CGWindowID: WsRawWindow] = [10: w(10, tags: tagsMinimized)]
        Check.equal(MinimizedState.minimizedWids(among: [10, 99], states: states), [10])
    }

    /// A failed or empty query degrades to today's behavior: nothing filtered.
    static func testEmptyResultRejectsNothing() {
        Check.equal(MinimizedState.minimizedWids(among: [10, 11], states: [:]), [])
    }

    static func testNoCandidatesRejectsNothing() {
        Check.equal(MinimizedState.minimizedWids(among: [], states: [10: w(10, tags: tagsMinimized)]), [])
    }

    /// A minimized window that was not a candidate must not leak into the
    /// rejection set — only submitted wids can be rejected.
    static func testUnrelatedWidsInTheResultAreIgnored() {
        let states: [CGWindowID: WsRawWindow] = [
            10: w(10, tags: tagsOrderedOut),
            77: w(77, tags: tagsMinimized),
        ]
        Check.equal(MinimizedState.minimizedWids(among: [10], states: states), [])
    }
}
