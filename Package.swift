// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TranscriberCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"])
    ],
    targets: [
        .target(name: "TranscriberCore", path: "Sources/TranscriberCore"),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"],
            path: "Tests/TranscriberCoreTests",
            resources: [.copy("Engines/Fixtures")]
        )
    ]
)
