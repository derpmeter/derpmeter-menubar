// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DerpMeterCompanion",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DerpMeterCompanion", targets: ["DerpMeterCompanion"]),
        .library(name: "DerpCore", targets: ["DerpCore"]),
    ],
    targets: [
        // Pure, testable logic shared by the app: models, API client, queue, mascot.
        .target(name: "DerpCore"),
        .executableTarget(name: "DerpMeterCompanion", dependencies: ["DerpCore"]),
        .testTarget(name: "DerpCoreTests", dependencies: ["DerpCore"]),
    ]
)
