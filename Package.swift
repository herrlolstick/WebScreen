// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WebScreen",
    platforms: [.macOS(.v14)],
    targets: [
        // Headers for the private CoreGraphics API CGVirtualDisplay
        .target(
            name: "CGVirtualDisplayBridge",
            path: "Sources/CGVirtualDisplayBridge",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "WebScreen",
            dependencies: ["CGVirtualDisplayBridge"],
            path: "Sources/WebScreen",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
