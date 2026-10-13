// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Wallpy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wallpy",
            path: "Sources/Wallpy"
        )
    ]
)
