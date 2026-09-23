// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tender",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tender", targets: ["tender"]),
        .library(name: "TenderCore", targets: ["TenderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "TenderCore", dependencies: ["Yams"]),
        .executableTarget(
            name: "tender",
            dependencies: [
                "TenderCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "TenderCoreTests", dependencies: ["TenderCore"]),
    ]
)
