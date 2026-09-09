// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MountMate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MountMateCore", targets: ["MountMateCore"]),
    ],
    targets: [
        .target(name: "MountMateCore"),
        .testTarget(name: "MountMateCoreTests", dependencies: ["MountMateCore"]),
    ]
)
