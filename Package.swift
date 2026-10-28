// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneBridge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PhoneBridge", targets: ["PhoneBridge"])],
    targets: [
        .target(name: "BridgeCore"),
        .target(name: "BluetoothShim", publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOBluetooth")]),
        .executableTarget(name: "PhoneBridge", dependencies: ["BridgeCore", "BluetoothShim"],
            resources: [.copy("Resources/Web"), .copy("Resources/Audio")],
            linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreAudio")]),
        .executableTarget(name: "BridgeChecks", dependencies: ["BridgeCore"], path: "Tests/BridgeCoreTests")
    ]
)
