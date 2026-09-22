// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Uplift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "uplift", targets: ["uplift"]),
        .library(name: "UpliftCore", targets: ["UpliftCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "UpliftCore", dependencies: ["Yams"]),
        .executableTarget(
            name: "uplift",
            dependencies: [
                "UpliftCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "UpliftCoreTests", dependencies: ["UpliftCore"]),
    ]
)
