import XCTest
import AVKit
import SwiftUI
#if os(macOS)
import VLC
import AppKit
#endif
@testable import EasyIPTV

final class PictureInPictureTests: XCTestCase {
    @MainActor func testPreferenceDefaultsOnAndPersists() {
        let suite = "pip-preference-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        XCTAssertTrue(manager.autoPictureInPicture)
        manager.autoPictureInPicture = false
        XCTAssertFalse(IPTVPlayerManager(progressDefaults: defaults).autoPictureInPicture)
    }

    @MainActor func testPlayerVisibilityTracksCoveringScreensRatherThanClicks() {
        let defaults = UserDefaults(suiteName: "pip-visibility-\(UUID())")!
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        manager.showingDashboard = false
        XCTAssertTrue(manager.isPlayerDestinationVisible)
        manager.isViewingSeriesDetails = true
        XCTAssertFalse(manager.isPlayerDestinationVisible)
        manager.isViewingSeriesDetails = false
        XCTAssertTrue(manager.isPlayerDestinationVisible)
        manager.showingDashboard = true
        XCTAssertFalse(manager.isPlayerDestinationVisible)
        manager.isFullscreen = true
        XCTAssertTrue(manager.isPlayerDestinationVisible, "Fullscreen keeps playback above Home")
        manager.isFullscreen = false
        XCTAssertFalse(manager.isPlayerDestinationVisible)
    }

    #if os(macOS)
    @MainActor func testUtilityScreensDoNotStartPiPOrInterruptPlayback() async throws {
        for contentType in [M3UItem.ContentType.live, .movie] {
            let fixture = try await PiPFixture(contentType: contentType)
            defer { fixture.cleanUp() }
            let manager = fixture.manager
            let player = manager.player
            let vlcPlayer = manager.vlcPlayer
            let pip = manager.pictureInPicture
            for screen in [\IPTVPlayerManager.showingSources, \.showingPlaylistSheet, \.showingOrganization, \.showingGuideSearch,
                           \.showingDownloads, \.showingEPGSheet, \.showingAboutSheet, \.showingSubscriptionInfo] {
                manager[keyPath: screen] = true
                for _ in 0..<5 { try await Task.sleep(nanoseconds: 10_000_000) }
                pip.reconcile()
                XCTAssertTrue(manager.isPlayerDestinationVisible)
                XCTAssertFalse(pip.isActive, "Utility screens must not start PiP")
                XCTAssertTrue(manager.isPlaying)
                XCTAssertTrue(manager.player === player)
                XCTAssertTrue(manager.vlcPlayer === vlcPlayer)
                manager[keyPath: screen] = false
            }
            manager.catchupChannel = manager.currentChannel
            for _ in 0..<5 { try await Task.sleep(nanoseconds: 10_000_000) }
            pip.reconcile()
            XCTAssertTrue(manager.isPlayerDestinationVisible)
            XCTAssertFalse(pip.isActive, "Catch-up must not start PiP")
            XCTAssertTrue(manager.isPlaying)
            XCTAssertTrue(manager.player === player)
            XCTAssertTrue(manager.vlcPlayer === vlcPlayer)
            manager.catchupChannel = nil
            pip.toggle()
            XCTAssertTrue(pip.isActive, "Manual PiP must still work")
            for screen in [\IPTVPlayerManager.showingSources, \.showingPlaylistSheet, \.showingOrganization, \.showingGuideSearch,
                           \.showingDownloads, \.showingEPGSheet, \.showingAboutSheet, \.showingSubscriptionInfo] {
                manager[keyPath: screen] = true
                pip.reconcile()
                XCTAssertTrue(pip.isActive, "Utility screens must preserve existing PiP")
                manager[keyPath: screen] = false
            }
            manager.catchupChannel = manager.currentChannel
            pip.reconcile()
            XCTAssertTrue(pip.isActive, "Catch-up must preserve existing PiP")
            manager.catchupChannel = nil
        }
    }

    @MainActor func testVLCNavigationMovesSameDrawableAndReturnKeepsClock() async throws {
        let fixture = try await PiPFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let original = try XCTUnwrap(manager.vlcPlayer)
        let drawable = try XCTUnwrap(original.drawable as? NSView)
        let time = original.time.intValue
        manager.browse(.movie)
        manager.selectedCategory = "Favorites"
        manager.pictureInPicture.reconcile()
        XCTAssertTrue(manager.isPlayerDestinationVisible)
        XCTAssertFalse(manager.pictureInPicture.isActive)
        manager.showMovieDetails(M3UItem(name: "Other", streamURL: fixture.url, contentType: .movie))
        try await fixture.wait { manager.pictureInPicture.isActive }
        XCTAssertTrue(manager.vlcPlayer === original)
        XCTAssertTrue(original.drawable as? NSView === drawable)
        XCTAssertTrue(drawable.window === manager.pictureInPicture.floatingWindow)
        manager.showMovieDetails(M3UItem(name: "Other", streamURL: fixture.url, contentType: .movie))
        manager.pictureInPicture.reconcile()
        XCTAssertTrue(manager.pictureInPicture.isActive)
        manager.dismissDetails()
        manager.browse(.series)
        manager.selectedCategory = "Favorites"
        manager.pictureInPicture.reconcile()
        XCTAssertTrue(manager.pictureInPicture.isActive, "Section/category browsing must keep PiP active")
        XCTAssertTrue(drawable.window === manager.pictureInPicture.floatingWindow)
        XCTAssertTrue(manager.vlcPlayer === original)
        XCTAssertTrue(original.drawable as? NSView === drawable)
        XCTAssertGreaterThanOrEqual(original.time.intValue, time)
        XCTAssertTrue(manager.isPlaying)
        manager.pictureInPicture.restorePlayer()
        XCTAssertFalse(manager.pictureInPicture.isActive)
        XCTAssertTrue(drawable.window === fixture.window)
        XCTAssertTrue(manager.isPlayerDestinationVisible)
        XCTAssertEqual(manager.selectedSection, .live)
    }

    @MainActor func testPiPChromeFitsCompactWindowAndUpdatesPlayback() async throws {
        let fixture = try await PiPFixture(contentType: .movie)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.pictureInPicture.toggle()
        let panel = try XCTUnwrap(manager.pictureInPicture.floatingWindow)
        let content = try XCTUnwrap(panel.contentView)
        func controls(_ view: NSView) -> NSHostingView<PictureInPictureControls>? {
            (view as? NSHostingView<PictureInPictureControls>) ?? view.subviews.lazy.compactMap { controls($0) }.first
        }
        let footer = try XCTUnwrap(controls(content))
        XCTAssertTrue(panel.titlebarAppearsTransparent)
        XCTAssertEqual(panel.titleVisibility, .hidden)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        let close = try XCTUnwrap(content.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first)
        let windowFrame = try XCTUnwrap(content.superview)
        let closeCenter = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: windowFrame.superview)
        XCTAssertTrue(windowFrame.hitTest(closeCenter) === close, "The close button must not sit behind the native titlebar")
        XCTAssertTrue(footer.rootView.isPlaying)
        XCTAssertEqual(footer.rootView.title, manager.currentChannel?.playbackTitle)
        for width in [320.0, 432, 600] {
            let controller = NSHostingController(rootView: footer.rootView)
            let size = controller.sizeThatFits(in: NSSize(width: width, height: 60))
            XCTAssertLessThanOrEqual(size.width, width)
            XCTAssertLessThanOrEqual(size.height, 60)
        }
        footer.rootView.onToggle()
        try await fixture.wait { !manager.isPlaying }
        manager.pictureInPicture.reconcile()
        XCTAssertFalse(footer.rootView.isPlaying)
        footer.rootView.onToggle()
        try await fixture.wait { manager.isPlaying }
        manager.pictureInPicture.reconcile()
        XCTAssertTrue(footer.rootView.isPlaying)
        content.layoutSubtreeIfNeeded()
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/easy-iptv-pip-redesign.png"))
        }
        footer.rootView.onRestore()
        XCTAssertFalse(manager.pictureInPicture.isActive)
        XCTAssertTrue(manager.isPlaying)
    }

    @MainActor func testPausedAndDisabledNavigationDoesNotStartPiPButManualStillWorks() async throws {
        let fixture = try await PiPFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.togglePlayPause()
        manager.showMovieDetails(M3UItem(name: "Details", streamURL: fixture.url, contentType: .movie))
        manager.pictureInPicture.reconcile()
        XCTAssertFalse(manager.pictureInPicture.isActive)
        manager.autoPictureInPicture = false
        manager.togglePlayPause()
        try await fixture.wait { manager.isPlaying }
        manager.pictureInPicture.reconcile()
        XCTAssertFalse(manager.pictureInPicture.isActive)
        manager.pictureInPicture.toggle()
        XCTAssertTrue(manager.pictureInPicture.isActive)
        manager.pictureInPicture.toggle()
        XCTAssertFalse(manager.pictureInPicture.isActive)
        XCTAssertTrue(manager.isPlaying)
    }

    @MainActor func testOutsideFocusAndWindowChangesDoNotStartPiP() async throws {
        let fixture = try await PiPFixture()
        defer { fixture.cleanUp() }
        let pip = fixture.manager.pictureInPicture
        for (name, object) in [
            (NSApplication.willResignActiveNotification, NSApplication.shared as Any),
            (NSWindow.didResignKeyNotification, fixture.window as Any),
            (NSWindow.didMiniaturizeNotification, fixture.window as Any),
            (NSWindow.didChangeOcclusionStateNotification, fixture.window as Any),
            (NSApplication.didBecomeActiveNotification, NSApplication.shared as Any)
        ] {
            NotificationCenter.default.post(name: name, object: object)
            for _ in 0..<5 { try await Task.sleep(nanoseconds: 10_000_000) }
            pip.reconcile()
            XCTAssertFalse(pip.isActive, "External focus/window changes must not trigger PiP")
        }
        XCTAssertTrue(fixture.manager.isPlaying)
        fixture.manager.showingDashboard = true
        pip.reconcile()
        XCTAssertTrue(pip.isActive)
        fixture.manager.showingDashboard = false
        pip.reconcile()
        XCTAssertTrue(pip.isActive, "Closing a covering screen must not leave PiP")
        fixture.manager.showingDashboard = true
        pip.reconcile()
        XCTAssertTrue(pip.isActive)
        fixture.manager.autoPictureInPicture = false
        pip.reconcile()
        XCTAssertFalse(pip.isActive)
        XCTAssertTrue(fixture.manager.isPlaying)
    }

    @MainActor func testPiPCloseStopsAndReplacementRetiresOldStream() async throws {
        let fixture = try await PiPFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.showMovieDetails(M3UItem(name: "Details", streamURL: fixture.url, contentType: .movie))
        try await fixture.wait { manager.pictureInPicture.isActive }
        let old = try XCTUnwrap(manager.vlcPlayer)
        let oldWindow = try XCTUnwrap(manager.pictureInPicture.floatingWindow)
        manager.playDirectStream(M3UItem(name: "Replacement", streamURL: fixture.url, contentType: .live))
        try await fixture.wait { manager.isPlaying && manager.vlcPlayer !== old }
        XCTAssertFalse(oldWindow.isVisible)
        XCTAssertFalse(manager.pictureInPicture.isActive)
        XCTAssertEqual(manager.currentChannel?.name, "Replacement")
        try await fixture.wait { !old.isPlaying }
        manager.showingDashboard = true
        try await fixture.wait { manager.pictureInPicture.isActive }
        let pipWindow = try XCTUnwrap(manager.pictureInPicture.floatingWindow)
        pipWindow.performClose(nil)
        XCTAssertNil(manager.currentChannel)
        XCTAssertNil(manager.vlcPlayer)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertFalse(manager.pictureInPicture.isActive)
        XCTAssertFalse(pipWindow.isVisible)
        manager.pictureInPicture.reconcile()
        XCTAssertFalse(manager.pictureInPicture.isActive)
    }

    @MainActor func testMoviesAndEpisodesKeepSameAVPlayerAndSurfaceInPiP() async throws {
        for type in [M3UItem.ContentType.movie, .series] {
            let fixture = try await PiPFixture(contentType: type)
            defer { fixture.cleanUp() }
            let manager = fixture.manager
            let player = try XCTUnwrap(manager.player)
            let item = try XCTUnwrap(player.currentItem)
            func findSurface(_ view: NSView) -> AVPlayerLayerNSView? {
                (view as? AVPlayerLayerNSView) ?? view.subviews.lazy.compactMap { findSurface($0) }.first
            }
            let surface = try XCTUnwrap(findSurface(fixture.hosting))
            let clock = player.currentTime().seconds
            let subtitles = FileManager.default.temporaryDirectory.appendingPathComponent("pip-subtitles-\(UUID()).srt")
            try Data("1\n00:00:00,000 --> 00:05:00,000\nPiP subtitle".utf8).write(to: subtitles)
            defer { try? FileManager.default.removeItem(at: subtitles) }
            manager.subtitles.importFile(subtitles)
            try await fixture.wait { manager.subtitles.text == "PiP subtitle" }
            manager.showMovieDetails(M3UItem(name: "Other movie", streamURL: fixture.url, contentType: .movie))
            try await fixture.wait { manager.pictureInPicture.isActive }
            XCTAssertTrue(surface.window === manager.pictureInPicture.floatingWindow)
            func subtitleOverlay(_ view: NSView) -> NSHostingView<SubtitleOverlay>? {
                (view as? NSHostingView<SubtitleOverlay>) ?? view.subviews.lazy.compactMap { subtitleOverlay($0) }.first
            }
            let floating = try XCTUnwrap(manager.pictureInPicture.floatingWindow?.contentView)
            let overlay = try XCTUnwrap(subtitleOverlay(floating))
            XCTAssertTrue(overlay.rootView.controller === manager.subtitles)
            XCTAssertEqual(overlay.rootView.controller.text, "PiP subtitle")
            manager.browse(.series)
            manager.selectedCategory = "Favorites"
            manager.pictureInPicture.reconcile()
            XCTAssertTrue(manager.pictureInPicture.isActive)
            XCTAssertTrue(surface.window === manager.pictureInPicture.floatingWindow)
            XCTAssertTrue(manager.player === player)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertGreaterThanOrEqual(player.currentTime().seconds, clock)
            manager.pictureInPicture.restorePlayer()
            XCTAssertFalse(manager.pictureInPicture.isActive)
            XCTAssertTrue(surface.window === fixture.window)
            XCTAssertTrue(manager.player === player)
            XCTAssertTrue(player.currentItem === item)
        }
    }

    @MainActor func testSeriesOverviewKeepsEpisodeAndStopStillReleasesIt() async throws {
        let suite = "series-pip-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        let episode = M3UItem(name: "Episode", streamURL: url, contentType: .series, seasonNumber: 1, episodeNumber: 2)
        manager.playDirectStream(episode)
        let player = try XCTUnwrap(manager.player)
        let item = try XCTUnwrap(player.currentItem)
        manager.returnToSeries()
        XCTAssertTrue(manager.isViewingSeriesDetails)
        XCTAssertFalse(manager.isPlayerDestinationVisible)
        XCTAssertTrue(manager.player === player)
        XCTAssertTrue(player.currentItem === item)
        manager.dismissDetails()
        XCTAssertTrue(manager.isPlayerDestinationVisible)
        XCTAssertTrue(manager.player === player)
        manager.stop()
        XCTAssertNil(player.currentItem)
        XCTAssertNil(manager.player)
    }

    @MainActor func testNativeCloseRestoreAndStaleCallbacksDoNotReplacePlayer() async throws {
        let suite = "native-pip-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        manager.playDirectStream(M3UItem(name: "Movie", streamURL: url, contentType: .movie))
        let player = try XCTUnwrap(manager.player)
        let item = try XCTUnwrap(player.currentItem)
        let layer = AVPlayerLayer(player: player)
        let pip = manager.pictureInPicture
        pip.attach(layer)
        guard let controller = pip.controller else { throw XCTSkip("Native PiP is unavailable on this machine") }
        let captions = try XCTUnwrap(item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.first)
        XCTAssertTrue(captions.suppressesPlayerRendering)
        pip.pictureInPictureControllerWillStartPictureInPicture(controller)
        XCTAssertFalse(captions.suppressesPlayerRendering)
        pip.pictureInPictureControllerDidStartPictureInPicture(controller)
        manager.showMovieDetails(M3UItem(name: "Details", streamURL: url, contentType: .movie))
        var restored = false
        pip.pictureInPictureController(controller, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored = $0 })
        pip.pictureInPictureControllerDidStopPictureInPicture(controller)
        XCTAssertTrue(restored)
        XCTAssertTrue(captions.suppressesPlayerRendering)
        XCTAssertFalse(manager.isViewingMovieDetails)
        XCTAssertTrue(manager.player === player)
        XCTAssertTrue(player.currentItem === item)
        pip.resetPlayback()
        pip.pictureInPictureControllerDidStopPictureInPicture(controller)
        XCTAssertTrue(manager.player === player, "Old callbacks must not stop a replacement session")
        pip.attach(layer)
        let next = try XCTUnwrap(pip.controller)
        pip.pictureInPictureControllerDidStartPictureInPicture(next)
        pip.pictureInPictureControllerWillStopPictureInPicture(next)
        pip.reconcile()
        pip.pictureInPictureControllerDidStopPictureInPicture(next)
        XCTAssertNil(manager.player, "Closing native PiP must use the normal Stop path")
    }
    #endif
}

#if os(macOS)
@MainActor private final class PiPFixture {
    let suite = "vlc-pip-\(UUID())"
    let url: URL
    let defaults: UserDefaults
    let manager: IPTVPlayerManager
    let hosting: NSHostingView<ContentView>
    let window: NSWindow

    init(contentType: M3UItem.ContentType = .live) async throws {
        url = try await silentMedia()
        defaults = UserDefaults(suiteName: suite)!
        manager = IPTVPlayerManager(progressDefaults: defaults)
        manager.playDirectStream(M3UItem(name: "Playback fixture", streamURL: url, contentType: contentType))
        hosting = NSHostingView(rootView: ContentView(manager: manager))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        try await wait {
            let clock = self.manager.vlcPlayer.map { Double($0.time.intValue) / 1000 } ?? self.manager.player?.currentTime().seconds ?? 0
            return self.manager.isPlaying && clock > 0 && self.manager.pictureInPicture.isPossible
        }
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            hosting.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("PiP transition timed out")
        throw NSError(domain: "PiPTests", code: 1)
    }

    func cleanUp() {
        manager.stop()
        manager.libraryPersistence.invalidatePendingWrites()
        window.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
