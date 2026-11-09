// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-stt",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacSTTCore", targets: ["MacSTTCore"]),
        .executable(name: "mac-stt", targets: ["mac-stt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
    ],
    targets: [
        .target(
            name: "MacSTTCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
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
