// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AfterRayMlxAsrWorker",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "afterray-mlx-asr-worker", targets: ["AfterRayMlxAsrWorker"])],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "cae704f53bc32a3d0b606823828fbc5bedaaf388"
        )
    ],
    targets: [
        .executableTarget(
            name: "AfterRayMlxAsrWorker",
            dependencies: [
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ]
        )
    ]
)
