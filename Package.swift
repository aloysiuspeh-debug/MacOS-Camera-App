// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CameraApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CameraApp", targets: ["CameraApp"])
    ],
    targets: [
        .executableTarget(
            name: "CameraApp",
            path: "Sources/CameraApp"
        )
    ]
)
