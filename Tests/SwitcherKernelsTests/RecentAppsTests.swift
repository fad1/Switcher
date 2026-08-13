import SwitcherKernels

/// Pins the MRU seed. These matter more than they look: under the recent-apps
/// cap, this ordering is the difference between "the 4 apps you just used" and
/// "4 arbitrary apps" on the first Cmd+Tab after a launch.
enum RecentAppsTests {

    static func runAll() {
        Check.run("testFirstOccurrenceWins", testFirstOccurrenceWins)
        Check.run("testOrderIsOtherwisePreserved", testOrderIsOtherwisePreserved)
        Check.run("testFrontmostIsHoistedFromTheMiddle", testFrontmostIsHoistedFromTheMiddle)
        Check.run("testFrontmostWithNoWindowsStillLeads", testFrontmostWithNoWindowsStillLeads)
        Check.run("testNoFrontmostKeepsZOrder", testNoFrontmostKeepsZOrder)
        Check.run("testEmptyInput", testEmptyInput)
    }

    /// An app owns several windows, so its pid repeats; the frontmost of them is
    /// the app's rank, and the rest must not push later apps down.
    private static func testFirstOccurrenceWins() {
        let seed = RecentApps.orderedUnique(pids: [10, 10, 20, 10, 30, 20], frontmost: nil)
        Check.equal(seed, [10, 20, 30])
    }

    private static func testOrderIsOtherwisePreserved() {
        let seed = RecentApps.orderedUnique(pids: [30, 20, 10], frontmost: nil)
        Check.equal(seed, [30, 20, 10])
    }

    /// z-order is a proxy; the active app is known for certain, so it wins over it.
    private static func testFrontmostIsHoistedFromTheMiddle() {
        let seed = RecentApps.orderedUnique(pids: [10, 20, 30], frontmost: 30)
        Check.equal(seed, [30, 10, 20])
    }

    /// e.g. the active app's only window is on another Space, so it is absent
    /// from the on-screen list — it is still what the user is looking at.
    private static func testFrontmostWithNoWindowsStillLeads() {
        let seed = RecentApps.orderedUnique(pids: [10, 20], frontmost: 99)
        Check.equal(seed, [99, 10, 20])
    }

    private static func testNoFrontmostKeepsZOrder() {
        let seed = RecentApps.orderedUnique(pids: [10, 20], frontmost: nil)
        Check.equal(seed, [10, 20])
    }

    private static func testEmptyInput() {
        Check.equal(RecentApps.orderedUnique(pids: [], frontmost: nil), [])
        Check.equal(RecentApps.orderedUnique(pids: [], frontmost: 7), [7])
    }
}
