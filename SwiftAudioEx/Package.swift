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
            name: "Copus",
            path: "Sources/Copus",
            exclude: [
                "celt/meson.build",
                "silk/meson.build",
                "src/meson.build",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .define("OPUS_BUILD"),
                .define("VAR_ARRAYS", to: "1"),
                .define("FLOATING_POINT"),
                .define("HAVE_LRINT", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
            ]
        ),
        .target(
            name: "SwiftAudioEx",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                "Copus",
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
