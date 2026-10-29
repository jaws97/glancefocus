// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GlanceFocus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "GlanceFocus", path: "Sources/GlanceFocus")
    ]
)
