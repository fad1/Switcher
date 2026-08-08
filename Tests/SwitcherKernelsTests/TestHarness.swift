import Foundation

/// Minimal assertion harness, because `swift test` cannot run here.
///
/// This machine has only the Command Line Tools, which ship **no XCTest** and no
/// runner for swift-testing bundles. Both were tried: XCTest fails to import, and
/// a swift-testing target links but SwiftPM then builds an `.xctest` *bundle* it
/// has no way to execute — `swift test` prints "Build complete" and exits 0
/// without running a single test. A green that means nothing is worse than no
/// tests at all, so the kernel tests are an ordinary executable instead:
///
///     swift run --disable-sandbox SwitcherKernelsTests
///
/// It prints every failure with its test name and line, and exits non-zero if any
/// failed. If Xcode is installed later, these convert to XCTest or swift-testing
/// almost mechanically — each `Check` call maps to one assertion.
enum Check {
    private(set) static var failures: [String] = []
    private(set) static var checks = 0
    private(set) static var currentTest = "<none>"

    static func run(_ name: String, _ body: () -> Void) {
        currentTest = name
        body()
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String = "",
                       line: Int = #line) {
        checks += 1
        guard !condition else { return }
        let detail = message()
        failures.append("  \(currentTest):\(line) — \(detail.isEmpty ? "expectation failed" : detail)")
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
                                    line: Int = #line) {
        checks += 1
        guard actual != expected else { return }
        let detail = message()
        let suffix = detail.isEmpty ? "" : " — \(detail)"
        failures.append("  \(currentTest):\(line) — expected \(expected), got \(actual)\(suffix)")
    }

    static func isNil<T>(_ value: T?, _ message: @autoclosure () -> String = "", line: Int = #line) {
        checks += 1
        guard value != nil else { return }
        let detail = message()
        failures.append("  \(currentTest):\(line) — expected nil, got \(value!)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    /// Prints the summary and returns the process exit code.
    static func summarize() -> Int32 {
        if failures.isEmpty {
            print("✓ \(checks) checks passed")
            return 0
        }
        print("✗ \(failures.count) of \(checks) checks FAILED\n")
        failures.forEach { print($0) }
        return 1
    }
}
