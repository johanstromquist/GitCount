// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitCount",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "GitCount",
            path: "Sources"
        )
    ]
)
