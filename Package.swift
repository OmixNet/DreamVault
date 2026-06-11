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
        .executableTarget(
            name: "dream",
            dependencies: ["DreamEngine"],
            linkerSettings: [
                // 把 Info.plist 嵌进 binary 的 __TEXT,__info_plist section
                // 让 NSApplication 在没 .app bundle 时也能读到正确的 plist metadata。
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "DreamEngineTests", dependencies: ["DreamEngine"]),
        .testTarget(name: "DreamTests", dependencies: ["dream", "DreamEngine"],
                    path: "Tests/DreamTests"),
    ]
)