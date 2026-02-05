// swift-tools-version: 6.0
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
        .package(url: "https://github.com/apple/swift-collections.git", branch: "main"),
        .package(url: "https://github.com/nicklockwood/LRUCache.git", from: "1.1.2"),
//        .package(url: "https://github.com/lake-of-fire/bookmark-storage.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "SwiftUIWebView",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "LRUCache", package: "LRUCache"),
//                .product(name: "BookmarkStorage", package: "bookmark-storage"),
            ],
            resources: [
//                .process("Resources"),
            ]),
    ]
)
