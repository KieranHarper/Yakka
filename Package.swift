// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "Yakka",
    products: [
        .library(name: "Yakka", targets: ["Yakka"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Quick/Quick.git", from: "1.2.0"),
        .package(url: "https://github.com/Quick/Nimble.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "Yakka", path: "Sources"),
        .testTarget(name: "YakkaTests", dependencies: ["Yakka", "Quick", "Nimble"]),
    ]
)