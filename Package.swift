// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "Apixa",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Apixa",
            path: "Sources/Apixa"
        )
    ]
)
