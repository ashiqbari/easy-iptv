// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EasyIPTV",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .executable(name: "EasyIPTV", targets: ["EasyIPTV"])
    ],
    targets: [
        .executableTarget(
            name: "EasyIPTV",
            path: ".",
            exclude: [
                "Info.plist",
                "build_dmg.sh",
                "run_app.command",
                "AppIcon.png",
                "README.md"
            ],
            sources: [
                "M3UItem.swift",
                "M3UParser.swift",
                "XtreamCodesManager.swift",
                "IPTVPlayerManager.swift",
                "IPTVPlaybackView.swift",
                "ChannelListView.swift",
                "ContentView.swift",
                "IPTVPlayerApp.swift"
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
            ]
        )
    ]
)
