// swift-tools-version:5.8
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
            type: .dynamic,
            targets: ["SwiftUIWebView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", branch: "development"),
//        .package(url: "https://github.com/lake-of-fire/bookmark-storage.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "SwiftUIWebView",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZipFoundation"),
//                .product(name: "BookmarkStorage", package: "bookmark-storage"),
            ],
            resources: [
//                .process("Resources"),
            ]),
    ]
)
