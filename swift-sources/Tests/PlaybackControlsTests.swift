import XCTest
import AppKit
@testable import EasyIPTV

@MainActor
final class PlaybackControlsTests: XCTestCase {
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
            \.showingPlaylistSheet, \.showingAboutSheet, \.showingResumeChoice, \.isSeeking
        ]
        for key in blockers {
            manager[keyPath: key] = true
            manager.hideControlsIfIdle()
            XCTAssertTrue(manager.showVideoControls)
            XCTAssertFalse(manager.playbackCursorHidden)
            manager[keyPath: key] = false
        }
        manager.subtitles.showingMenu = true
        manager.hideControlsIfIdle()
        XCTAssertTrue(manager.showVideoControls)
        manager.subtitles.showingMenu = false
        manager.hideControlsIfIdle()
        XCTAssertTrue(manager.playbackCursorHidden)
    }

    func testWindowedPlaybackNeverHidesCursorAndOutsidePlayerNeverHidesHUD() {
        let manager = playing()
        defer { manager.stop() }
        manager.pointerInsidePlayer = false
        manager.hideControlsIfIdle()
        XCTAssertTrue(manager.showVideoControls)
        manager.isFullscreen = false
        manager.hideControlsIfIdle()
        XCTAssertFalse(manager.showVideoControls)
        XCTAssertFalse(manager.playbackCursorHidden)
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
