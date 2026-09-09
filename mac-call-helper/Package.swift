// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CallBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "call-bridge", targets: ["CallBridge"]),
    ],
    targets: [
        .executableTarget(
            name: "CallBridge",
            path: "Sources/CallBridge"
        ),
    ]
)
