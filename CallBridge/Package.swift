// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CallBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CallBridge", targets: ["CallBridge"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "CallBridge",
            path: "CallBridge"
        )
    ]
)
