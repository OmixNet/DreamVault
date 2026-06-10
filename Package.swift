// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DreamVault",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DreamEngine", targets: ["DreamEngine"]),
        .executable(name: "dream", targets: ["dream"]),
    ],
    targets: [
        .target(name: "DreamEngine"),
        .executableTarget(name: "dream", dependencies: ["DreamEngine"]),
        .testTarget(name: "DreamEngineTests", dependencies: ["DreamEngine"]),
    ]
)
