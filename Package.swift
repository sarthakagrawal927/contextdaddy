// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "StorageDaddy", platforms: [.macOS(.v14)], products: [
    .library(name: "DiskCore", targets: ["DiskCore"]),
    .executable(name: "StorageDaddy", targets: ["StorageDaddy"]),
    .executable(name: "StorageBench", targets: ["StorageBench"])
], dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")], targets: [
    .target(name: "DiskCore"),
    .executableTarget(name: "StorageDaddy", dependencies: ["DiskCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .executableTarget(name: "StorageBench", dependencies: ["DiskCore"]),
    .testTarget(name: "DiskCoreTests", dependencies: ["DiskCore"])
])
