// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gitunia",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "GituniaCore"),
        .executableTarget(name: "Gitunia", dependencies: ["GituniaCore"]),
        .testTarget(name: "GituniaCoreTests", dependencies: ["GituniaCore"]),
        .testTarget(name: "GituniaTests", dependencies: ["Gitunia"]),
    ]
)
