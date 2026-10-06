// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Squish",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Squish", targets: ["SquishApp"]),
        .executable(name: "squish-hook", targets: ["SquishHook"]),
        .executable(name: "squish-pricing", targets: ["SquishPricing"])
    ],
    dependencies: [
        .package(url: "https://github.com/bring-shrubbery/dynamic-landing", from: "0.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(name: "SquishCore"),
        .executableTarget(
            name: "SquishHook",
            dependencies: ["SquishCore"]
        ),
        .executableTarget(
            name: "SquishPricing",
            dependencies: ["SquishCore"]
        ),
        .executableTarget(
            name: "SquishApp",
            dependencies: [
                "SquishCore",
                .product(name: "DynamicLanding", package: "dynamic-landing"),
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
