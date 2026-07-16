// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SnipshotImageOutput",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ImageOutputCore",
            path: "Sources/ImageOutputCore"
        ),
        .target(
            name: "SecureInputCore",
            path: "Sources/SecureInputCore"
        ),
        .testTarget(
            name: "ImageOutputCoreTests",
            dependencies: ["ImageOutputCore"],
            path: "Tests/ImageOutputCoreTests"
        ),
    ]
)
