import XCTest
import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
import SwiftVLC
#endif
@testable import EasyIPTV

final class VideoScreenSizeTests: XCTestCase {
    func testFixedRatiosFitAndStayCenteredInLandscapeAndPortraitAreas() {
        for bounds in [CGRect(x: 0, y: 0, width: 1000, height: 1000), CGRect(x: 10, y: 20, width: 1200, height: 600), CGRect(x: 0, y: 0, width: 400, height: 900)] {
            for mode in VideoScreenSize.allCases {
                let rect = mode.videoRect(in: bounds)
                XCTAssertEqual(rect.midX, bounds.midX, accuracy: 0.001)
                XCTAssertEqual(rect.midY, bounds.midY, accuracy: 0.001)
                XCTAssertLessThanOrEqual(rect.width, bounds.width)
                XCTAssertLessThanOrEqual(rect.height, bounds.height)
                if let ratio = mode.ratio {
                    XCTAssertEqual(rect.width / rect.height, ratio, accuracy: 0.001)
                    XCTAssertTrue(rect.width == bounds.width || abs(rect.height - bounds.height) < 0.001)
                    XCTAssertEqual(mode.gravity, .resize)
                } else { XCTAssertEqual(rect, bounds) }
            }
        }
        XCTAssertEqual(VideoScreenSize.auto.gravity, .resizeAspect)
        XCTAssertEqual(VideoScreenSize.zoom.gravity, .resizeAspectFill)
        XCTAssertEqual(VideoScreenSize.stretch.gravity, .resize)
        XCTAssertEqual(VideoScreenSize.widescreen.videoRect(in: .zero), .zero)
    }

    @MainActor func testGlobalSelectionPersistsAndResetAndInvalidPreferenceUseAuto() {
        let suite = "video-screen-size-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = IPTVPlayerManager(progressDefaults: defaults)
        XCTAssertEqual(first.screenSize, .auto)
        first.screenSize = .ultrawide
        let second = IPTVPlayerManager(progressDefaults: defaults)
        XCTAssertEqual(second.screenSize, .ultrawide)
        for type in M3UItem.ContentType.allCases {
            second.selectedSection = type
            XCTAssertEqual(second.screenSize, .ultrawide)
        }
        second.screenSize = .auto
        XCTAssertEqual(IPTVPlayerManager(progressDefaults: defaults).screenSize, .auto)
        defaults.set("unknown", forKey: VideoScreenSize.storageKey)
        XCTAssertEqual(IPTVPlayerManager(progressDefaults: defaults).screenSize, .auto)
        first.stop(); second.stop()
    }

    #if os(macOS)
    @MainActor func testAVLayerForcesRatioAndReflowsWithoutReplacingPlayer() throws {
        let player = AVPlayer()
        let view = AVPlayerLayerNSView(player: player)
        let layer = try XCTUnwrap(view.layer?.sublayers?.first as? AVPlayerLayer)
        for size in [CGSize(width: 1000, height: 1000), CGSize(width: 1200, height: 600)] {
            view.setFrameSize(size)
            for mode in VideoScreenSize.allCases {
                view.update(player: player, videoGravity: .resizeAspect, screenSize: mode)
                view.layout()
                XCTAssertTrue(layer.player === player)
                XCTAssertEqual(layer.frame, mode.videoRect(in: view.bounds))
                XCTAssertEqual(layer.videoGravity, mode.gravity)
            }
        }
    }

    @MainActor func testScreenSizeChangesKeepAVPlaybackAndSurfaceRunning() async throws {
        try await checkPlayback(useVLC: false)
    }

    @MainActor func testScreenSizeChangesKeepVLCPlaybackAndSurfaceRunning() async throws {
        try await checkPlayback(useVLC: true)
    }

    @MainActor private func checkPlayback(useVLC: Bool) async throws {
        let suite = "video-sizing-playback-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        let item = M3UItem(name: "Sizing fixture", streamURL: url, contentType: useVLC ? .live : .movie)
        manager.playDirectStream(item)
        if !useVLC, let item = manager.currentChannel { manager.playAVKitFixture(item) }
        let av = manager.player
        let avItem = av?.currentItem
        let vlc = manager.vlcPlayer
        vlc?.aspectRatio = .ratio(4, 3)
        let hosting = NSHostingView(rootView: IPTVPlaybackView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            manager.stop(); window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        func settle() async throws {
            for _ in 0..<10 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func avSurface(in view: NSView) -> AVPlayerLayerNSView? {
            if let surface = view as? AVPlayerLayerNSView { return surface }
            return view.subviews.lazy.compactMap { avSurface(in: $0) }.first
        }
        try await settle()
        for _ in 0..<100 {
            if manager.isPlaying && (useVLC ? (vlc?.currentTime.secondsValue ?? 0) > 0 : (av?.currentTime().seconds ?? 0) > 0) { break }
            try await settle()
        }
        let original: NSView = try XCTUnwrap(useVLC ? vlcSurface(in: hosting) : avSurface(in: hosting))
        let media = vlc?.currentMedia
        let start = useVLC ? vlc!.currentTime.secondsValue : av!.currentTime().seconds
        for mode in VideoScreenSize.allCases {
            manager.screenSize = mode
            try await settle()
            XCTAssertTrue(manager.isPlaying)
            XCTAssertTrue(manager.player === av)
            XCTAssertTrue(manager.vlcPlayer === vlc)
            XCTAssertTrue(av?.currentItem === avItem)
            XCTAssertTrue(vlc?.currentMedia === media)
            XCTAssertEqual(manager.currentChannel?.id, item.id)
            XCTAssertTrue((useVLC ? vlcSurface(in: hosting) : avSurface(in: hosting)) === original)
            if let vlc {
                let aspect = vlc.aspectRatio
                if mode.ratio != nil { XCTAssertEqual(aspect.description, mode.title) }
                if mode == .auto { XCTAssertEqual(aspect, .default) }
                if mode == .stretch { XCTAssertEqual(aspect, .ratio(700, 500)) }
                if mode == .zoom { XCTAssertEqual(aspect, .fill) }
            }
        }
        window.setContentSize(CGSize(width: 500, height: 700))
        try await settle()
        if let vlc { XCTAssertEqual(vlc.aspectRatio, .fill) }
        manager.screenSize = .auto
        try await settle()
        if let vlc {
            XCTAssertEqual(vlc.aspectRatio, .default)
        }
        XCTAssertTrue((useVLC ? vlcSurface(in: hosting) : avSurface(in: hosting)) === original)
        let end = useVLC ? vlc!.currentTime.secondsValue : av!.currentTime().seconds
        XCTAssertGreaterThan(end, start)
    }
    #endif
}
