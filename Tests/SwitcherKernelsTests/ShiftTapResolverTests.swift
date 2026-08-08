import SwitcherKernels

/// Pins the Shift-tap gesture against the regression that shaped it: firing the
/// back-step on Shift *press* instead of release double-steps every
/// Cmd+Shift+Tab, because the Carbon hotkey has already stepped once.
enum ShiftTapResolverTests {

    static func runAll() {
        // A. The bare Shift tap
        Check.run("testBareShiftTapFiresOnReleaseNotOnPress", testBareShiftTapFiresOnReleaseNotOnPress)
        Check.run("testRepeatedTapsEachFire", testRepeatedTapsEachFire)
        Check.run("testShiftHeldWithoutReleaseDoesNotFire", testShiftHeldWithoutReleaseDoesNotFire)
        // B. Cmd+Shift+Tab must not double-step
        Check.run("testShiftTabHotkeySuppressesTheTapOnRelease", testShiftTabHotkeySuppressesTheTapOnRelease)
        Check.run("testRepeatedShiftTabsInOneHoldStaySuppressed", testRepeatedShiftTabsInOneHoldStaySuppressed)
        Check.run("testAFreshShiftHoldClearsTheSuppression", testAFreshShiftHoldClearsTheSuppression)
        // C. Cmd release
        Check.run("testShiftReleaseWithoutCmdDoesNotFire", testShiftReleaseWithoutCmdDoesNotFire)
        Check.run("testCmdReleaseClearsTheShiftEdge", testCmdReleaseClearsTheShiftEdge)
        Check.run("testSuppressionFromAPreviousGestureCannotLeakIntoABareTap",
                  testSuppressionFromAPreviousGestureCannotLeakIntoABareTap)
    }

    // MARK: - A. The bare Shift tap

    static func testBareShiftTapFiresOnReleaseNotOnPress() {
        var r = ShiftTapResolver()

        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: false), .none)  // Cmd held
        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: true), .none)   // Shift pressed
        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: false), .selectPrevious)
    }

    static func testRepeatedTapsEachFire() {
        var r = ShiftTapResolver()
        _ = r.flagsChanged(cmdDown: true, shiftDown: false)

        for _ in 0..<3 {
            Check.equal(r.flagsChanged(cmdDown: true, shiftDown: true), .none)
            Check.equal(r.flagsChanged(cmdDown: true, shiftDown: false), .selectPrevious)
        }
    }

    static func testShiftHeldWithoutReleaseDoesNotFire() {
        var r = ShiftTapResolver()
        _ = r.flagsChanged(cmdDown: true, shiftDown: false)

        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: true), .none)
        // A repeated flagsChanged while Shift stays down is not a release edge.
        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: true), .none)
    }

    // MARK: - B. Cmd+Shift+Tab must not double-step (the pinned regression)

    static func testShiftTabHotkeySuppressesTheTapOnRelease() {
        var r = ShiftTapResolver()
        _ = r.flagsChanged(cmdDown: true, shiftDown: false)
        _ = r.flagsChanged(cmdDown: true, shiftDown: true)   // Shift pressed

        r.shiftTabHotkeyFired()                              // Cmd+Shift+Tab

        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: false), .none,
                    "the hotkey already stepped; firing here would double-step")
    }

    static func testRepeatedShiftTabsInOneHoldStaySuppressed() {
        var r = ShiftTapResolver()
        _ = r.flagsChanged(cmdDown: true, shiftDown: false)
        _ = r.flagsChanged(cmdDown: true, shiftDown: true)

        r.shiftTabHotkeyFired()
        r.shiftTabHotkeyFired()
        r.shiftTabHotkeyFired()

        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: false), .none)
    }

    static func testAFreshShiftHoldClearsTheSuppression() {
        var r = ShiftTapResolver()
        _ = r.flagsChanged(cmdDown: true, shiftDown: false)

        // First hold: Shift+Tab, so its release is silent.
        _ = r.flagsChanged(cmdDown: true, shiftDown: true)
        r.shiftTabHotkeyFired()
        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: false), .none)

        // Second hold in the same Cmd press: a bare tap, which must fire.
        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: true), .none)
        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: false), .selectPrevious)
    }

    // MARK: - C. Cmd release

    static func testShiftReleaseWithoutCmdDoesNotFire() {
        var r = ShiftTapResolver()
        _ = r.flagsChanged(cmdDown: true, shiftDown: true)

        Check.equal(r.flagsChanged(cmdDown: false, shiftDown: false), .none,
                    "Cmd is gone — this is the dismiss path, not a back-step")
    }

    static func testCmdReleaseClearsTheShiftEdge() {
        var r = ShiftTapResolver()
        _ = r.flagsChanged(cmdDown: true, shiftDown: true)
        _ = r.flagsChanged(cmdDown: false, shiftDown: false)

        // A new gesture starts clean: no phantom release edge carried over.
        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: false), .none)
    }

    static func testSuppressionFromAPreviousGestureCannotLeakIntoABareTap() {
        var r = ShiftTapResolver()
        _ = r.flagsChanged(cmdDown: true, shiftDown: true)
        r.shiftTabHotkeyFired()
        _ = r.flagsChanged(cmdDown: false, shiftDown: false)  // Cmd released mid-hold

        // Next gesture: a fresh Shift hold clears the stale flag, so the tap fires.
        _ = r.flagsChanged(cmdDown: true, shiftDown: false)
        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: true), .none)
        Check.equal(r.flagsChanged(cmdDown: true, shiftDown: false), .selectPrevious)
    }
}
