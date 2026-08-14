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
        .executable(name: "afterray-visual-lab", targets: ["AfterRayVisualLab"]),
        .executable(name: "afterray-visual-snapshots", targets: ["AfterRayVisualSnapshots"]),
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
    ]
)
