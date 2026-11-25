// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Usage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Usage", targets: ["Usage"]),
        .library(name: "UsageCore", targets: ["UsageCore"])
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "Usage", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ],
    swiftLanguageModes: [.v5]
)
