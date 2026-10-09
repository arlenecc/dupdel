// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DupDel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DupDelCore", targets: ["DupDelCore"]),
        .executable(name: "DupDel", targets: ["DupDelApp"]),
    ],
    targets: [
        .target(
            name: "DupDelCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DupDelApp",
            dependencies: ["DupDelCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DupDelCoreTests",
            dependencies: ["DupDelCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
