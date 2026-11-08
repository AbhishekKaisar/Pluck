// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pluck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pluck", targets: ["Pluck"]),
        .executable(name: "mdl", targets: ["mdl"]),
    ],
    targets: [
        .target(name: "DownloaderCore"),
        .target(name: "PluckUI", dependencies: ["DownloaderCore"]),
        .executableTarget(name: "Pluck", dependencies: ["DownloaderCore", "PluckUI"]),
        // Renders the real views with sample data into build/snapshots/*.png (no screen recording needed).
        .executableTarget(name: "snapshot", dependencies: ["DownloaderCore", "PluckUI"]),
        .executableTarget(name: "mdl", dependencies: ["DownloaderCore"]),
        .testTarget(name: "DownloaderCoreTests", dependencies: ["DownloaderCore", "PluckUI"]),
    ],
    swiftLanguageModes: [.v5]
)
