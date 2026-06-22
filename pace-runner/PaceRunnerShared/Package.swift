// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PaceRunnerShared",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "PaceRunnerShared",
            targets: ["PaceRunnerShared"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PaceRunnerShared",
            dependencies: [],
            path: "Sources/PaceRunnerShared",
            linkerSettings: [.linkedFramework("StoreKit")]
        ),
        .testTarget(
            name: "PaceRunnerSharedTests",
            dependencies: ["PaceRunnerShared"]
        ),
    ]
)
