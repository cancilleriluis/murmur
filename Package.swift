// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Murmur",
            path: "Sources/Murmur"
        )
    ]
)
