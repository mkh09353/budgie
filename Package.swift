// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Budgie",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.7"),
    ],
    targets: [
        .executableTarget(
            name: "Budgie",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Budgie"
        )
    ]
)
