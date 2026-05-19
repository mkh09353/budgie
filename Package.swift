// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Budgie",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Budgie",
            path: "Sources/Budgie"
        )
    ]
)
