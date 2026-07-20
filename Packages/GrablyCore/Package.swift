// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrablyCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GrablyCore",
            targets: ["GrablyCore"]
        )
    ],
    targets: [
        .target(
            name: "GrablyCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "GrablyCoreTests",
            dependencies: ["GrablyCore"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
