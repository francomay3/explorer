// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExplorerCore", targets: ["ExplorerCore"]),
        .executable(name: "Explorer", targets: ["Explorer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1"),
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
            dependencies: [
                "ExplorerCore",
                .product(name: "Highlightr", package: "Highlightr"),
            ],
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
