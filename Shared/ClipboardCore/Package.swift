// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClipboardCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ClipboardCore",
            targets: ["ClipboardCore"]
        )
    ],
    targets: [
        .target(name: "ClipboardCore")
    ]
)
