// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AfterRay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AfterRayRecall", targets: ["AfterRayRecall"]),
        .library(name: "AfterRayMockData", targets: ["AfterRayMockData"]),
        .executable(name: "afterray-app", targets: ["AfterRayApp"]),
        .executable(name: "afterray-native-model-worker", targets: ["AfterRayNativeModelWorker"]),
        .executable(name: "afterray-mlx-vlm-worker", targets: ["AfterRayMlxVlmWorker"]),
        .executable(name: "afterray-visual-lab", targets: ["AfterRayVisualLab"]),
        .executable(name: "afterray-visual-snapshots", targets: ["AfterRayVisualSnapshots"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            exact: "3.31.4"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface",
            exact: "0.9.0"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            exact: "1.3.0"
        ),
    ],
    targets: [
        .target(
            name: "AfterRayRecall",
            path: "swift/AfterRayRecall/Sources"
        ),
        .target(
            name: "AfterRayMockData",
            dependencies: ["AfterRayRecall"],
            path: "swift/AfterRayMockData/Sources"
        ),
        .executableTarget(
            name: "AfterRayApp",
            dependencies: ["AfterRayRecall"],
            path: "apps/AfterRay/Sources"
        ),
        .executableTarget(
            name: "AfterRayNativeModelWorker",
            path: "apps/AfterRayNativeModelWorker/Sources"
        ),
        .target(
            name: "AfterRayMlxVlmWorkerCore",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "swift/AfterRayMlxVlmWorker/Sources"
        ),
        .executableTarget(
            name: "AfterRayMlxVlmWorker",
            dependencies: ["AfterRayMlxVlmWorkerCore"],
            path: "apps/AfterRayMlxVlmWorker/Sources"
        ),
        .executableTarget(
            name: "AfterRayVisualLab",
            dependencies: ["AfterRayRecall", "AfterRayMockData"],
            path: "apps/AfterRayVisualLab/Sources"
        ),
        .executableTarget(
            name: "AfterRayVisualSnapshots",
            dependencies: ["AfterRayRecall", "AfterRayMockData"],
            path: "apps/AfterRayVisualSnapshots/Sources"
        ),
        .testTarget(
            name: "AfterRayRecallTests",
            dependencies: ["AfterRayRecall", "AfterRayMockData"],
            path: "swift/AfterRayRecall/Tests"
        ),
        .testTarget(
            name: "AfterRayMlxVlmWorkerTests",
            dependencies: ["AfterRayMlxVlmWorkerCore"],
            path: "swift/AfterRayMlxVlmWorkerTests"
        ),
    ]
)
