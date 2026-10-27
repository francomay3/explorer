// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExplorerCore", targets: ["ExplorerCore"]),
        .executable(name: "Explorer", targets: ["Explorer"]),
    ],
    targets: [
        .target(
            name: "ExplorerCore",
            path: "Sources/ExplorerCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Explorer",
            dependencies: ["ExplorerCore"],
            path: "Sources/Explorer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ExplorerCoreTests",
            dependencies: ["ExplorerCore"],
            path: "Tests/ExplorerCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
