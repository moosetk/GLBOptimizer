// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GLBCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GLBCore", targets: ["GLBCore"]),
    ],
    targets: [
        .target(name: "GLBCore"),
        .testTarget(name: "GLBCoreTests", dependencies: ["GLBCore"]),
    ]
)
