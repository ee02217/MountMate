// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MountMate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MountMateCore", targets: ["MountMateCore"]),
        .executable(name: "MountMate", targets: ["MountMate"]),
    ],
    targets: [
        .target(name: "MountMateCore"),
        .executableTarget(name: "MountMate", dependencies: ["MountMateCore"]),
        .testTarget(name: "MountMateCoreTests", dependencies: ["MountMateCore"]),
    ]
)
