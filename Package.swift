// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TranscriberCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "7734cd1fbbe86460083c1d24199737a24cadfcc8")
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
