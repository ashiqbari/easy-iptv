import XCTest
import AppKit
import SwiftUI
@testable import EasyIPTV

@MainActor
final class PlaybackControlsTests: XCTestCase {
    func testSpaceTogglesOnceWithFocusedSliderAndHiddenControlsForBothEngines() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        defer { NSApp.setActivationPolicy(policy) }
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        for useVLC in [false, true] {
            let suite = "keyboard-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            let manager = IPTVPlayerManager(progressDefaults: defaults)
            let item = M3UItem(name: "Keyboard fixture", streamURL: url, contentType: .movie)
            if useVLC { manager.playDirectStream(item) }
            else { manager.playAVKitFixture(item) }
            let hosting = NSHostingView(rootView: IPTVPlaybackView(manager: manager))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
            hosting.frame = content.bounds
            hosting.autoresizingMask = [.width, .height]
            content.addSubview(hosting)
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            defer {
                manager.stop(); window.close()
                manager.libraryPersistence.invalidatePendingWrites()
                defaults.removePersistentDomain(forName: suite)
            }
            func waitForPlayback(_ playing: Bool) async throws {
                for _ in 0..<300 {
                    if manager.isPlaying == playing { return }
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTFail("Space did not set playing=\(playing), VLC=\(useVLC)")
            }
            func space(modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: 49))
            }
            func send(_ event: NSEvent) {
                // Exercise the local monitor before native responder dispatch.
                NSApp.postEvent(event, atStart: true)
                if let next = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.02),
                                              inMode: .default, dequeue: true) { NSApp.sendEvent(next) }
            }
            try await waitForPlayback(true)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
            content.addSubview(slider)
            window.makeFirstResponder(slider)
            let volume = manager.playbackVolume
            for visible in [true, false] {
                manager.showVideoControls = visible
                send(try space())
                try await waitForPlayback(false)
                send(try space(repeatKey: true))
                try await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertFalse(manager.isPlaying, "Holding Space must not repeatedly toggle")
                send(try space())
                try await waitForPlayback(true)
            }
            XCTAssertEqual(manager.playbackVolume, volume)
            send(try space())
            try await waitForPlayback(false)
            let field = NSTextField(string: "Find")
            field.frame = NSRect(x: 20, y: 20, width: 200, height: 24)
            content.addSubview(field)
            window.makeFirstResponder(field)
            let editor = try XCTUnwrap(field.currentEditor())
            editor.selectedRange = NSRange(location: 4, length: 0)
            send(try space())
            XCTAssertEqual(field.stringValue, "Find ")
            XCTAssertFalse(manager.isPlaying)
            window.makeFirstResponder(slider)
            send(try space(modifiers: .shift))
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertFalse(manager.isPlaying, "Modified Space must keep its native behavior")
        }
    }

    func testMuteRestoresVolumeAndSliderUnmutes() throws {
        let suite = "mute-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer {
            manager.stop()
            defaults.removePersistentDomain(forName: suite)
        }
        manager.playAVKitFixture(M3UItem(name: "Mute fixture", streamURL: URL(fileURLWithPath: "/private/tmp/mute-fixture.mp4"), contentType: .movie))
        let player = try XCTUnwrap(manager.player)
        manager.playbackVolume = 0.35
        manager.toggleMute()
        XCTAssertEqual(manager.playbackVolume, 0)
        XCTAssertEqual(player.volume, 0)
        manager.toggleMute()
        XCTAssertEqual(manager.playbackVolume, 0.35)
        XCTAssertEqual(player.volume, 0.35)
        manager.toggleMute()
        manager.playbackVolume = 0.6
        XCTAssertEqual(player.volume, 0.6)
        manager.toggleMute()
        manager.toggleMute()
        XCTAssertEqual(manager.playbackVolume, 0.6)
        manager.playbackVolume = 0
        manager.toggleMute()
        XCTAssertEqual(manager.playbackVolume, 0.6)
    }

    func testDoubleClickVideoTogglesFullscreenWithVisibleAndHiddenControls() async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        for useVLC in [false, true] {
            let suite = "double-click-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            let manager = IPTVPlayerManager(progressDefaults: defaults)
            manager.playDirectStream(M3UItem(name: "Fixture", streamURL: url, contentType: .movie))
            if !useVLC, let item = manager.currentChannel { manager.playAVKitFixture(item) }
            let hosting = NSHostingView(rootView: IPTVPlaybackView(manager: manager))
            let window = FullscreenRequestWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            window.becomeKey()
            defer {
                manager.stop()
                manager.libraryPersistence.invalidatePendingWrites()
                window.close()
                defaults.removePersistentDomain(forName: suite)
            }
            let player = manager.player, vlcPlayer = manager.vlcPlayer
            for visible in [true, false] {
                manager.cancelControlsAutoHide()
                manager.showVideoControls = visible
                for _ in 0..<10 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000) }
                let before = window.fullscreenRequests
                // shortcut: this fixed point is empty video space; update it if the playback HUD layout changes.
                let point = hosting.convert(NSPoint(x: 250, y: 240), to: nil)
                for count in [1, 2] {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: count, pressure: 1))
                        NSApp.sendEvent(event)
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try await Task.sleep(nanoseconds: 400_000_000)
                XCTAssertEqual(window.fullscreenRequests, before + 1, "Engine VLC=\(useVLC), controls visible=\(visible)")
                XCTAssertTrue(manager.player === player)
                XCTAssertTrue(manager.vlcPlayer === vlcPlayer)
            }
        }
    }

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

private final class FullscreenRequestWindow: NSWindow {
    var fullscreenRequests = 0
    override func toggleFullScreen(_ sender: Any?) { fullscreenRequests += 1 }
}
