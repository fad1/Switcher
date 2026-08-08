import Foundation

// Runs every kernel suite and exits non-zero if any check failed:
//     swift run --disable-sandbox SwitcherKernelsTests
// See TestHarness.swift for why this is an executable rather than `swift test`.

WindowFilterTests.runAll()
MinimizedStateTests.runAll()
ShiftTapResolverTests.runAll()
GridNavigationTests.runAll()

exit(Check.summarize())
