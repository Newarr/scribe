// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TranscriberCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/Newarr/mlx-audio-swift.git", revision: "b8ec43083e4c5535594dbf9274893f9e6fe4a506")
    ],
    targets: [
        .target(
            name: "TranscriberCore",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift")
            ],
            path: "Sources/TranscriberCore"
        ),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"],
            path: "Tests/TranscriberCoreTests",
            resources: [.copy("Engines/Fixtures")]
        )
    ]
)
