// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimpleSwitcher",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "SimpleSwitcher",
            path: "Sources/SimpleSwitcher",
            linkerSettings: [
                .unsafeFlags(["-framework", "Carbon"])
            ]
        )
    ]
)
