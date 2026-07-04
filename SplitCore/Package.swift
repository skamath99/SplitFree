// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SplitCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SplitCore", targets: ["SplitCore"])
    ],
    targets: [
        .target(name: "SplitCore"),
        .testTarget(name: "SplitCoreTests", dependencies: ["SplitCore"])
    ]
)
