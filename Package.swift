// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftUIWebView",
    platforms: [
        .iOS(.v15), .macOS(.v12)
    ],
    products: [
        .library(
            name: "SwiftUIWebView",
            targets: ["SwiftUIWebView"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "SwiftUIWebView",
            dependencies: [],
            resources: [
//                .copy("Resources"), // CodeSign errors...
                .process("Resources"),
            ]),
    ]
)
