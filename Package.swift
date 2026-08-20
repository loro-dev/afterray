// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AfterRay",
    // `.v15` needs swift-tools 6.0, which also switches the default language
    // mode to Swift 6; the string form raises the deployment target without
    // dragging in that migration. The shipped app already required macOS 15 —
    // `AfterRayCaptureShim` is built for it and the site advertises it.
    platforms: [.macOS("15.0")],
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
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.5"
        ),
        .package(
            url: "https://github.com/gonzalezreal/swift-markdown-ui",
            exact: "2.4.1"
        ),
    ],
    targets: [
        .target(
            name: "AfterRayRecall",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "swift/AfterRayRecall/Sources"
        ),
        .target(
            name: "AfterRayMockData",
            dependencies: ["AfterRayRecall"],
            path: "swift/AfterRayMockData/Sources"
        ),
        .executableTarget(
            name: "AfterRayApp",
            dependencies: [
                "AfterRayRecall",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "apps/AfterRay/Sources",
            linkerSettings: [
                // Sparkle.framework is copied into Contents/Frameworks by
                // scripts/build-release.sh; SwiftPM emits a bare executable and
                // does not assemble the bundle for us.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
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
            name: "AfterRayAppTests",
            dependencies: ["AfterRayApp"],
            path: "apps/AfterRay/Tests"
        ),
        .testTarget(
            name: "AfterRayMlxVlmWorkerTests",
            dependencies: ["AfterRayMlxVlmWorkerCore"],
            path: "swift/AfterRayMlxVlmWorkerTests"
        ),
    ]
)
