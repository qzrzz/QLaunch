// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QLaunchpad",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QLaunchpad", targets: ["QLaunchpad"])
    ],
    targets: [
        .target(
            name: "QLaunchpadCore",
            path: "Sources/QLaunchpadCore"
        ),
        .executableTarget(
            name: "QLaunchpad",
            dependencies: ["QLaunchpadCore"],
            path: "Sources/QLaunchpad",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "QLaunchpadCoreTests",
            dependencies: ["QLaunchpadCore"],
            path: "Tests/QLaunchpadCoreTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
