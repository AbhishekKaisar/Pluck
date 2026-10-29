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
        .executableTarget(name: "MacDownloader", dependencies: ["DownloaderCore"]),
        .executableTarget(name: "mdl", dependencies: ["DownloaderCore"]),
        .testTarget(name: "DownloaderCoreTests", dependencies: ["DownloaderCore"]),
    ],
    swiftLanguageModes: [.v5]
)
