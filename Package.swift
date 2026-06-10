// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DreamVault",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DreamEngine", targets: ["DreamEngine"]),
    ],
    targets: [
        .target(name: "DreamEngine"),
        .testTarget(name: "DreamEngineTests", dependencies: ["DreamEngine"]),
    ]
)
