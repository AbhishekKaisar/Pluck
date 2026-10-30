// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDownloader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDownloader", targets: ["MacDownloader"]),
        .executable(name: "mdl", targets: ["mdl"]),
    ],
    targets: [
        .target(name: "DownloaderCore"),
        .target(name: "MacDownloaderUI", dependencies: ["DownloaderCore"]),
        .executableTarget(name: "MacDownloader", dependencies: ["DownloaderCore", "MacDownloaderUI"]),
        // Renders the real views with sample data into build/snapshots/*.png (no screen recording needed).
        .executableTarget(name: "snapshot", dependencies: ["DownloaderCore", "MacDownloaderUI"]),
        .executableTarget(name: "mdl", dependencies: ["DownloaderCore"]),
        .testTarget(name: "DownloaderCoreTests", dependencies: ["DownloaderCore"]),
    ],
    swiftLanguageModes: [.v5]
)
