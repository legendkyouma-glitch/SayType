// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SayType",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SayType", targets: ["SayType"])],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.3"),
        // MLX 0.32 tightened compile-closure Sendable requirements; the audio
        // SDK's 0.1.3 Parakeet source still needs the compatible 0.31 API.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.3"),
    ],
    targets: [
        .executableTarget(
            name: "SayType",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "app/Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
