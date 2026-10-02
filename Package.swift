// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Bravune",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Bravune", path: "Sources/Bravune"),
        .testTarget(name: "BravuneTests", dependencies: ["Bravune"], path: "Tests/BravuneTests", exclude: ["Fixtures"])
    ]
)
