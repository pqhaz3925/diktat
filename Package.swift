// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Diktat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Diktat",
            path: "Sources/Diktat",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
