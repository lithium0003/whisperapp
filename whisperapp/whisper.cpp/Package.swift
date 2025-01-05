// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "whisper",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "whisper", targets: ["whisper"]),
    ],
    targets: [
        .systemLibrary(name: "whisper")
    ]
)
