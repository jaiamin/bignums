// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BigNums",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BigNums", path: "Sources/BigNums")
    ]
)
