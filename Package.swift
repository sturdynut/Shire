// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shire",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "shire", targets: ["shire"]),
        .executable(name: "ShireApp", targets: ["ShireApp"]),
        .library(name: "ShireCore", targets: ["ShireCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "ShireCore", dependencies: ["Yams"]),
        .executableTarget(
            name: "shire",
            dependencies: [
                "ShireCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The menu bar app. `make app` wraps this executable in Shire.app.
        .executableTarget(name: "ShireApp", dependencies: ["ShireCore"]),
        .testTarget(name: "ShireCoreTests", dependencies: ["ShireCore"]),
    ]
)
