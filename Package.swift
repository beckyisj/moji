// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Moji",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MojiCore"),
        .executableTarget(name: "MojiApp", dependencies: ["MojiCore"]),
        .executableTarget(name: "moji-search", dependencies: ["MojiCore"]),
    ]
)
