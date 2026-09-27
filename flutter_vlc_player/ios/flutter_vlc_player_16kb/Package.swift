// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "flutter_vlc_player_16kb",
    platforms: [
        .iOS("12.0")
    ],
    products: [
        .library(name: "flutter-vlc-player-16kb", targets: ["flutter_vlc_player_16kb"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(
            name: "MobileVLCKit",
            url: "https://github.com/showbie/MobileVLCKit-SPM/releases/download/3.7.3/MobileVLCKit.xcframework.zip",
            checksum: "0346e458e119d57d4768d4096e2f7b4f77b7a0df4e21d0e728856f309cc6e8ab"
        ),
        .target(
            name: "flutter_vlc_player_16kb",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .target(name: "MobileVLCKit")
            ],
            path: "Sources/flutter_vlc_player_16kb"
        )
    ]
)
