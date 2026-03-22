// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tsmd",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "tsmd",
            path: "Sources/tsmd"
        ),
        .testTarget(
            name: "tsmdTests",
            dependencies: ["tsmd"],
            path: "Tests/tsmdTests"
        ),
    ]
)
