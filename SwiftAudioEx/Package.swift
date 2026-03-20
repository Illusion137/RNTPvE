// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "SwiftAudioEx",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(
            name: "SwiftAudioEx",
            targets: ["SwiftAudioEx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.27.0"),
        .package(url: "https://github.com/alta/swift-opus.git", from: "0.0.1"),
    ],
    targets: [
        .target(
            name: "SwiftAudioEx",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Opus", package: "swift-opus"),
            ]),
        .testTarget(
            name: "SwiftAudioExTests",
            dependencies: ["SwiftAudioEx"],
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
