// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Flow",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Flow",
            path: "Sources/Flow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
