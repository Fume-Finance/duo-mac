// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DuoMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "NanoHelper",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/NanoHelper"
        ),
    ]
)
