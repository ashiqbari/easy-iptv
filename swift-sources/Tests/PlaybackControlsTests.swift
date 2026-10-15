import XCTest
import AppKit
@testable import EasyIPTV

@MainActor
final class PlaybackControlsTests: XCTestCase {
    func testPlaybackBadgeDistinguishesContentAndKnownLivePosition() {
        func item(_ type: M3UItem.ContentType, _ extensionName: String = "ts") -> M3UItem {
            M3UItem(name: "Badge fixture", streamURL: URL(fileURLWithPath: "/private/tmp/badge.\(extensionName)"), contentType: type)
        }
        for type in [M3UItem.ContentType.movie, .series] {
            for paused in [false, true] {
                XCTAssertEqual(IPTVPlayerManager.playbackBadge(for: item(type), paused: paused, liveOffset: 0), type == .movie ? "Movie" : "Episode")
            }
        }
        XCTAssertEqual(IPTVPlayerManager.playbackBadge(for: item(.live, "mp4"), paused: false, liveOffset: 0), "Movie")
        for offset in [nil, Double.nan, Double.infinity, -1] {
            XCTAssertEqual(IPTVPlayerManager.playbackBadge(for: item(.live), paused: false, liveOffset: offset), "Live TV")
        }
        XCTAssertEqual(IPTVPlayerManager.playbackBadge(for: item(.live), paused: false, liveOffset: 30), "LIVE")
        XCTAssertEqual(IPTVPlayerManager.playbackBadge(for: item(.live), paused: false, liveOffset: 31), "Behind live")
        XCTAssertEqual(IPTVPlayerManager.playbackBadge(for: item(.live), paused: true, liveOffset: 0), "Live TV · Paused")
    }

    func testPlaybackBadgeFollowsPlayingItemWhileBrowsing() {
        let manager = playing()
        defer { manager.stop() }
        for type in M3UItem.ContentType.allCases {
            manager.selectedSection = type
            XCTAssertEqual(manager.playbackBadge, "Movie")
        }
        manager.currentChannel = M3UItem(name: "Live fixture", streamURL: URL(fileURLWithPath: "/private/tmp/badge.ts"), contentType: .live)
        XCTAssertEqual(manager.playbackBadge, "Live TV · Paused")
        manager.stop()
        XCTAssertNil(manager.playbackBadge)
    }

    private func playing(_ type: M3UItem.ContentType = .movie) -> IPTVPlayerManager {
        _ = NSApplication.shared
        let manager = IPTVPlayerManager(progressDefaults: UserDefaults(suiteName: "controls-\(UUID())")!)
        manager.currentChannel = M3UItem(name: "Fixture", streamURL: URL(fileURLWithPath: "/private/tmp/controls-fixture.mp4"), contentType: type)
        manager.pointerInsidePlayer = true
        manager.isPlaying = true
        manager.isFullscreen = true
        return manager
    }

    func testFullscreenDeadlineAndActivityReset() async throws {
        let manager = playing()
        defer { manager.stop() }
        try await Task.sleep(nanoseconds: 1_400_000_000)
        manager.notePlayerActivity()
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertTrue(manager.showVideoControls)
        XCTAssertFalse(manager.playbackCursorHidden)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(manager.showVideoControls)
        XCTAssertTrue(manager.playbackCursorHidden)
        manager.notePlayerActivity()
        XCTAssertTrue(manager.showVideoControls)
        XCTAssertFalse(manager.playbackCursorHidden)
    }

    func testPauseExitFullscreenAndStopRestoreCursorForEveryMediaType() {
        for type in [M3UItem.ContentType.live, .movie, .series] {
            let manager = playing(type)
            manager.hideControlsIfIdle()
            XCTAssertTrue(manager.playbackCursorHidden)
            manager.isPlaying = false
            XCTAssertTrue(manager.showVideoControls)
            XCTAssertFalse(manager.playbackCursorHidden)
            manager.hideControlsIfIdle()
            XCTAssertTrue(manager.showVideoControls)
            manager.isPlaying = true
            manager.hideControlsIfIdle()
            manager.isFullscreen = false
            XCTAssertTrue(manager.showVideoControls)
            XCTAssertFalse(manager.playbackCursorHidden)
            manager.isFullscreen = true
            manager.hideControlsIfIdle()
            manager.stop()
            XCTAssertFalse(manager.playbackCursorHidden)
            XCTAssertTrue(manager.showVideoControls)
        }
    }

    func testHoverAndNestedMenusHoldControlsUntilAllClose() {
        let manager = playing()
        defer { manager.stop() }
        for region in ["bottomBar", "menu-parent", "menu-child"] {
            manager.setControlsInteraction(region, active: true)
        }
        for region in ["bottomBar", "menu-parent"] {
            manager.setControlsInteraction(region, active: false)
            manager.hideControlsIfIdle()
            XCTAssertTrue(manager.showVideoControls)
            XCTAssertFalse(manager.playbackCursorHidden)
        }
        manager.setControlsInteraction("menu-child", active: false)
        manager.hideControlsIfIdle()
        XCTAssertTrue(manager.playbackCursorHidden)
        // Removing an already-absent hover region must not reveal the fading HUD.
        manager.setControlsInteraction("bottomBar", active: false)
        XCTAssertFalse(manager.showVideoControls)
    }

    func testSubtitlesDrawersDialogsAndSeekingBlockAutoHide() {
        let manager = playing(.series)
        defer { manager.stop() }
        let blockers: [ReferenceWritableKeyPath<IPTVPlayerManager, Bool>] = [
            \.showingEpisodesDrawer, \.showingDownloads, \.showingEPGSheet,
            \.showingSources, \.showingOrganization, \.showingPlaylistSheet, \.showingAboutSheet, \.showingSubscriptionInfo, \.showingResumeChoice, \.isSeeking
        ]
        for key in blockers {
            manager[keyPath: key] = true
            manager.hideControlsIfIdle()
            XCTAssertTrue(manager.showVideoControls)
            XCTAssertFalse(manager.playbackCursorHidden)
            manager[keyPath: key] = false
        }
        manager.audioTracks.showingMenu = true
        manager.hideControlsIfIdle()
        XCTAssertTrue(manager.showVideoControls)
        manager.audioTracks.showingMenu = false
        manager.subtitles.showingMenu = true
        manager.hideControlsIfIdle()
        XCTAssertTrue(manager.showVideoControls)
        manager.subtitles.showingMenu = false
        manager.hideControlsIfIdle()
        XCTAssertTrue(manager.playbackCursorHidden)
    }

    func testOutsidePlayerHidesHUDWithoutHidingOtherDisplaysCursor() {
        let manager = playing()
        defer { manager.stop() }
        manager.pointerInsidePlayer = false
        manager.hideControlsIfIdle()
        XCTAssertFalse(manager.showVideoControls)
        XCTAssertFalse(manager.playbackCursorHidden)
        manager.isFullscreen = false
        manager.hideControlsIfIdle()
        XCTAssertFalse(manager.showVideoControls)
        XCTAssertFalse(manager.playbackCursorHidden)
    }

    func testPointerLeavingClearsHoverButKeepsMenusAndRestartsIdleDeadline() async throws {
        let manager = playing()
        defer { manager.stop() }
        manager.setControlsInteraction("bottomBar", active: true)
        manager.setControlsInteraction("menu-player", active: true)
        manager.pointerLeftPlayer()
        XCTAssertTrue(manager.controlsAutoHideBlocked)
        manager.setControlsInteraction("menu-player", active: false)
        XCTAssertFalse(manager.controlsAutoHideBlocked)
        try await Task.sleep(nanoseconds: 2_700_000_000)
        XCTAssertFalse(manager.showVideoControls)
        XCTAssertFalse(manager.playbackCursorHidden)
    }

    func testLosingWindowAndAppFocusStillHidesControls() async throws {
        let manager = playing()
        let view = PlaybackActivityNSView(manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { manager.stop(); window.close() }
        await Task.yield()
        manager.setControlsInteraction("topBar", active: true)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        XCTAssertFalse(manager.controlsAutoHideBlocked)
        try await Task.sleep(nanoseconds: 2_700_000_000)
        XCTAssertFalse(manager.showVideoControls)
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.allSatisfy { $0.options.contains(.activeAlways) && $0.options.contains(.mouseMoved) })
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.handle(event)
        XCTAssertTrue(manager.showVideoControls)
    }

    func testNativeControlHoverWorksWithoutKeyWindow() throws {
        let manager = playing()
        defer { manager.stop() }
        let view = PlaybackControlNSView(manager: manager, region: "centerControls")
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.allSatisfy { $0.options.contains(.activeAlways) })
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0))
        view.mouseEntered(with: event)
        manager.hideControlsIfIdle()
        XCTAssertTrue(manager.showVideoControls)
        view.mouseExited(with: event)
        manager.hideControlsIfIdle()
        XCTAssertFalse(manager.showVideoControls)
    }

    func testDiagnosticsRatesHandleStartupResetAndMeasuredInterval() {
        XCTAssertNil(PlaybackDiagnosticsView.rate(current: 100, previous: nil, elapsed: 1))
        XCTAssertNil(PlaybackDiagnosticsView.rate(current: 5, previous: 100, elapsed: 1))
        XCTAssertNil(PlaybackDiagnosticsView.rate(current: 100, previous: 50, elapsed: 0))
        XCTAssertEqual(PlaybackDiagnosticsView.rate(current: 220, previous: 100, elapsed: 2), 60)
    }

    func testNativeInputAndTrackingCleanup() async throws {
        let manager = playing()
        let view = PlaybackActivityNSView(manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = false
        window.contentView = view
        defer { manager.stop(); window.close() }
        await Task.yield()
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseDragged] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            manager.pointerInsidePlayer = true
            manager.hideControlsIfIdle()
            view.handle(event)
            XCTAssertTrue(manager.showVideoControls)
            XCTAssertFalse(manager.playbackCursorHidden)
        }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        manager.hideControlsIfIdle()
        view.handle(key)
        XCTAssertTrue(manager.showVideoControls)
        manager.hideControlsIfIdle()
        view.mouseExited(with: key)
        XCTAssertFalse(manager.pointerInsidePlayer)
        XCTAssertFalse(manager.playbackCursorHidden)
        manager.setControlsInteraction("bottomBar", active: true)
        manager.stop()
        XCTAssertFalse(manager.controlsAutoHideBlocked)
        view.stopTracking()
        await Task.yield()
        XCTAssertFalse(window.acceptsMouseMovedEvents)
        XCTAssertFalse(manager.pointerInsidePlayer)
    }
}
