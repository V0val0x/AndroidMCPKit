// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AndroidMCPKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AndroidMCPKit",
            targets: ["AndroidMCPKit"]
        ),
        .executable(
            name: "android-mcp",
            targets: ["android-mcp"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AndroidMCPKit",
            path: "Sources/AndroidMCPKit"
        ),
        .executableTarget(
            name: "android-mcp",
            dependencies: ["AndroidMCPKit"],
            path: "Sources/android-mcp"
        ),
        .testTarget(
            name: "AndroidMCPKitTests",
            dependencies: ["AndroidMCPKit"],
            path: "Tests/AndroidMCPKitTests"
        )
    ]
)
