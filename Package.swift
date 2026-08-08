// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimpleSwitcher",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // Pure logic: Foundation/CoreGraphics types only, no AppKit, no IPC, no
        // state. Everything here is directly testable; the app target holds the
        // parts that talk to macOS.
        .target(
            name: "SwitcherKernels",
            path: "Sources/SwitcherKernels",
            exclude: ["WindowFilterSpecs.md"]
        ),
        .executableTarget(
            name: "SimpleSwitcher",
            dependencies: ["SwitcherKernels"],
            path: "Sources/SimpleSwitcher",
            linkerSettings: [
                .linkedFramework("Carbon"),
                // SkyLight is a private framework, so it needs both an explicit
                // link and its search path. Only the SLSWindowQuery* / iterator
                // symbols require it; CGSSetSymbolicHotKeyEnabled and
                // CGSMainConnectionID already resolve through CoreGraphics.
                .linkedFramework("SkyLight"),
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks"])
            ]
        ),
        // An executable, not a .testTarget: this machine has only the Command
        // Line Tools, which ship no XCTest and no runner for swift-testing
        // bundles — `swift test` there builds a bundle it cannot execute and
        // exits 0 without running anything. Run it with
        //     swift run --disable-sandbox SwitcherKernelsTests
        // See Tests/SwitcherKernelsTests/TestHarness.swift.
        .executableTarget(
            name: "SwitcherKernelsTests",
            dependencies: ["SwitcherKernels"],
            path: "Tests/SwitcherKernelsTests"
        )
    ]
)
