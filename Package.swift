// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Squish",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Squish", targets: ["SquishApp"]),
        .executable(name: "squish-hook", targets: ["SquishHook"])
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(name: "SquishCore"),
        .executableTarget(
            name: "SquishHook",
            dependencies: ["SquishCore"]
        ),
        .executableTarget(
            name: "SquishApp",
            dependencies: [
                "SquishCore",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "SquishCoreTests",
            dependencies: ["SquishCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
