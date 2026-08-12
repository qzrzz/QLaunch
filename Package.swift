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
        .executableTarget(
            name: "QLaunchpad",
            path: "Sources/QLaunchpad",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
