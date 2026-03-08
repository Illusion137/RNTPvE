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
    ],
    targets: [
        .target(
            name: "SwiftAudioEx",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
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
