// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyIPTV",
    platforms: [
        .macOS(.v15),
        .iOS(.v16)
    ],
    products: [
        .executable(name: "EasyIPTV", targets: ["EasyIPTV"])
    ],
    dependencies: [
        .package(url: "https://github.com/dooop/swift-vlc", exact: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "EasyIPTV",
            dependencies: [
                .product(name: "VLC", package: "swift-vlc", condition: .when(platforms: [.macOS]))
            ],
            path: ".",
            exclude: [
                "Info.plist",
                "LICENSE-LGPL-2.1",
                "build_dmg.sh",
                "run_app.command",
                "AppIcon.png",
                "Tests",
            ],
            sources: [
                "M3UItem.swift",
                "M3UParser.swift",
                "XtreamCodesManager.swift",
                "IPTVPlayerManager.swift",
                "PlaybackProgress.swift",
                "LibraryLifecycle.swift",
                "VLCPlaybackRetirement.swift",
                "IPTVPlaybackView.swift",
                "Subtitles.swift",
                "SubtitleController.swift",
                "SubtitleControls.swift",
                "TVGuide.swift",
                "ChannelListView.swift",
                "MovieDetails.swift",
                "ContentView.swift",
                "IPTVPlayerApp.swift"
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(name: "SubtitleTests", dependencies: ["EasyIPTV"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
