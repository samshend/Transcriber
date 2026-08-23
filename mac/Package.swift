// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "Transcriber",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Transcriber"
        )
    ]
)
