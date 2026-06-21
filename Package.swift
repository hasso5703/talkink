// swift-tools-version: 6.0
import PackageDescription

// Dev/QA tooling (recording studio + --vadtest/--dictatetest harnesses) compiles
// ONLY when this is true. scripts/build_app.sh flips it to true for
// SOYLE_DEVTOOLS=1 builds and restores it afterwards; shipped release builds keep
// it false, so end users never get the studio.
let soyleDevTools = false

let package = Package(
    name: "Soyle",
    platforms: [.macOS(.v14)],
    products: [
        // Menu-bar push-to-talk app (assembled into Söyle.app via scripts/build_app.sh).
        .executable(name: "Soyle", targets: ["Soyle"]),
        // CLI for de-risking, benchmarking and headless transcription.
        .executable(name: "soyle-cli", targets: ["SoyleCLI"]),
        // Reusable engine, shared by app + CLI.
        .library(name: "SoyleKit", targets: ["SoyleKit"]),
    ],
    dependencies: [
        // Native Swift Nemotron 3.5 ASR (MLX). Pinned to a specific commit for reproducibility
        // (the package tracks `main` with no release tag).
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "417df212f54b8b4214a9815c1cd2eabb05fd4fdf"
        ),
        // Auto-updates (appcast + EdDSA-signed deltas). Pinned exact.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3"),
    ],
    targets: [
        .target(
            name: "SoyleKit",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ],
            path: "Sources/SoyleKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Soyle",
            dependencies: [
                "SoyleKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Soyle",
            swiftSettings: [.swiftLanguageMode(.v5)] + (soyleDevTools ? [.define("SOYLE_DEVTOOLS")] : [])
        ),
        .executableTarget(
            name: "SoyleCLI",
            dependencies: ["SoyleKit"],
            path: "Sources/SoyleCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure-logic tests (catalog, language mapping, VAD, memory verdicts,
        // stores, hotkey interpretation) — no Metal, no models, no network,
        // so `swift test` runs them anywhere.
        .testTarget(
            name: "SoyleTests",
            dependencies: ["Soyle", "SoyleKit"],
            path: "Tests/SoyleTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
