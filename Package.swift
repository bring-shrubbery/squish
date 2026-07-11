// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Squish",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Squish", targets: ["SquishApp"])
    ],
    targets: [
        .target(name: "SquishCore"),
        .executableTarget(
            name: "SquishApp",
            dependencies: ["SquishCore"],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "SquishCoreTests",
            dependencies: ["SquishCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
