// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoxuCore", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MoxuCore", targets: ["MoxuCore"])],
    targets: [
        .systemLibrary(name: "CZlib"), .target(name: "MoxuCore", dependencies: ["CZlib"]),
        .testTarget(name: "MoxuCoreTests", dependencies: ["MoxuCore"]),
    ])
