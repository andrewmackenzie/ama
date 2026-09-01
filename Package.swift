// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "parrot",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Tiny Obj-C shim to catch NSExceptions (e.g. AVFAudio's installTap
        // throw) that Swift's do/catch can't see. See ExceptionCatcher.h.
        .target(name: "ExceptionCatcher"),
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ExceptionCatcher",
            ]
        ),
    ]
)
