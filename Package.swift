// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-stt",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacSTTCore", targets: ["MacSTTCore"]),
        .executable(name: "mac-stt", targets: ["mac-stt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "e0de9e79d69c24a1277982bb3d8fafc4da5ce035"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.33.0"),
    ],
    targets: [
        .target(
            name: "MacSTTCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "mac-stt",
            dependencies: ["MacSTTCore"],
            linkerSettings: [
                // Gives the binary its own microphone-permission identity.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"])
            ]
        ),
        .testTarget(
            name: "MacSTTCoreTests",
            dependencies: [
                "MacSTTCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
