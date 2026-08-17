// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QLaunchpad",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QLaunchpad", targets: ["QLaunchpad"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "QLaunchpadCore",
            path: "Sources/QLaunchpadCore"
        ),
        .executableTarget(
            name: "QLaunchpad",
            dependencies: [
                "QLaunchpadCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
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
