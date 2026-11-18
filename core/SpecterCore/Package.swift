// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpecterCore",
    platforms: [
        .iOS(.v16), .macOS(.v13)
    ],
    products: [
        .library(name: "SpecterCore", targets: ["SpecterCore"]),
    ],
    targets: [
        .target(
            name: "SpecterCore",
            dependencies: []
        ),
        .testTarget(
            name: "SpecterCoreTests",
            dependencies: ["SpecterCore"]
        ),
    ]
)
