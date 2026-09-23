// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextDaddy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ContextCore", targets: ["ContextCore"]),
        .executable(name: "ContextDaddy", targets: ["ContextDaddy"]),
    ],
    targets: [
        .target(name: "ContextCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ContextDaddy", dependencies: ["ContextCore"]),
        .testTarget(name: "ContextCoreTests", dependencies: ["ContextCore"]),
        .testTarget(name: "ContextDaddyTests", dependencies: ["ContextDaddy"]),
    ]
)
