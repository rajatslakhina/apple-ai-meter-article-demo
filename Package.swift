// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeteredInference",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeteredInference", targets: ["MeteredInference"])
    ],
    targets: [
        .target(name: "MeteredInference"),
        .testTarget(name: "MeteredInferenceTests", dependencies: ["MeteredInference"])
    ]
)
