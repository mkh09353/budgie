// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Budgie",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Budgie",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Budgie"
        ),
        .testTarget(
            name: "BudgieTests",
            dependencies: ["Budgie"],
            path: "Tests/BudgieTests"
        )
    ]
)
