// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AfterRayCaptureShim",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AfterRayCaptureShim", targets: ["AfterRayCaptureShim"]),
    ],
    targets: [
        .target(
            name: "AfterRayCapturePolicy",
            path: "Sources/AfterRayCapturePolicy"
        ),
        .executableTarget(
            name: "AfterRayCaptureShim",
            dependencies: ["AfterRayCapturePolicy"],
            path: "Sources/AfterRayCaptureShim"
        ),
        .testTarget(
            name: "AfterRayCaptureShimTests",
            dependencies: ["AfterRayCapturePolicy"]
        ),
    ]
)
