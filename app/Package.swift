// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenFlow",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "OpenFlow",
            path: "Sources/OpenFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
