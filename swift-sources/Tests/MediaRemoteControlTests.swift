import XCTest
import AVFoundation
import MediaPlayer
#if os(macOS)
import AppKit
import VLC
#endif
@testable import EasyIPTV

@MainActor
final class MediaRemoteControlTests: XCTestCase {
    private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Playback did not reach the expected state", file: file, line: line)
    }

    func testHeadsetPlayPauseAndToggleControlBothEnginesWithoutReplacingPlayback() async throws {
        #if os(macOS)
        _ = NSApplication.shared
        let engines = [false, true]
        #else
        let engines = [false]
        #endif
        let url = try await alternateAudioMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        for useVLC in engines {
            let suite = "remote-controls-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            let manager = IPTVPlayerManager(progressDefaults: defaults)
            manager.configureRemotePlaybackControls()
            manager.configureRemotePlaybackControls()
            #if os(macOS)
            var window: NSWindow?
            #endif
            defer {
                manager.stop(); defaults.removePersistentDomain(forName: suite)
                #if os(macOS)
                window?.close()
                #endif
            }
            XCTAssertEqual(manager.handleRemotePlayback(.play), .noSuchContent)
            XCTAssertFalse(MPRemoteCommandCenter.shared().playCommand.isEnabled)
            let item = M3UItem(name: "Remote fixture", streamURL: url, contentType: .movie)
            manager.playDirectStream(item)
            #if os(macOS)
            if useVLC {
                manager.playCurrentStreamWithVLC()
                let surface = VLCVideoSurfaceNSView()
                let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                    styleMask: [.titled], backing: .buffered, defer: false)
                host.isReleasedWhenClosed = false; host.contentView = surface; host.makeKeyAndOrderFront(nil)
                surface.update(player: try XCTUnwrap(manager.vlcPlayer), shouldPlay: true, screenSize: .auto)
                window = host
            }
            #endif
            try await wait { manager.isPlaying }
            let player = manager.player
            #if os(macOS)
            let vlc = manager.vlcPlayer
            #endif
            XCTAssertTrue(MPRemoteCommandCenter.shared().playCommand.isEnabled)
            XCTAssertEqual(manager.handleRemotePlayback(.pause), .success)
            XCTAssertEqual(manager.handleRemotePlayback(.pause), .success)
            try await wait { !manager.isPlaying }
            XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
            XCTAssertEqual(manager.handleRemotePlayback(.play), .success)
            XCTAssertEqual(manager.handleRemotePlayback(.play), .success)
            try await wait { manager.isPlaying }
            XCTAssertEqual(manager.handleRemotePlayback(.toggle), .success)
            try await wait { !manager.isPlaying }
            XCTAssertEqual(manager.handleRemotePlayback(.toggle), .success)
            try await wait { manager.isPlaying }
            // Browsing another show's details must not block controls for the playing stream.
            manager.isViewingSeriesDetails = true
            XCTAssertEqual(manager.handleRemotePlayback(.pause), .success)
            XCTAssertEqual(manager.handleRemotePlayback(.play), .success)
            try await wait { manager.isPlaying }
            XCTAssertTrue(manager.isViewingSeriesDetails)
            XCTAssertTrue(manager.player === player)
            #if os(macOS)
            XCTAssertTrue(manager.vlcPlayer === vlc)
            #endif
            manager.stop()
            XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            XCTAssertFalse(MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled)
            XCTAssertEqual(manager.handleRemotePlayback(.toggle), .noSuchContent)
        }
    }

    func testNowPlayingTracksEpisodeMetadataSeekPauseAndClearWithoutExposingStreamURL() async throws {
        let suite = "remote-metadata-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url); defaults.removePersistentDomain(forName: suite) }
        var manager: IPTVPlayerManager? = IPTVPlayerManager(progressDefaults: defaults)
        weak var reference = manager
        manager!.configureRemotePlaybackControls()
        let episode = M3UItem(name: "Long show title", groupTitle: "Season 2", streamURL: url,
            contentType: .series, seasonNumber: 2, episodeNumber: 3)
        manager!.playDirectStream(episode)
        try await wait { manager?.isPlaying == true }
        manager!.updatePlaybackClock(position: 120, duration: 300)
        manager!.handleRemotePlayback(.pause)
        var info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Season 2 · Episode 3")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 300)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 120)
        XCTAssertFalse(String(describing: info).contains(url.absoluteString))
        manager!.seek(to: 60)
        info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 60)
        manager!.stop()
        let live = M3UItem(name: "Live fixture", streamURL: URL(string: "https://provider.invalid/user/secret/channel.ts")!, contentType: .live)
        manager!.playDirectStream(live)
        info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
        XCTAssertNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
        XCTAssertFalse(String(describing: info).contains("secret"))
        manager!.stop()
        manager = nil
        XCTAssertNil(reference, "System command handlers must not retain the player manager")
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertFalse(MPRemoteCommandCenter.shared().pauseCommand.isEnabled)
    }

    func testRemotePlayDoesNotBypassResumeChoiceOrRestartAStoppedEpisode() async throws {
        let suite = "remote-resume-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        let episode = M3UItem(name: "Episode", streamURL: url, contentType: .series)
        manager.progressStore.save(item: episode, position: 120, duration: 300)
        manager.playDirectStream(episode)
        XCTAssertNotNil(manager.resumeRequest)
        XCTAssertEqual(manager.handleRemotePlayback(.play), .noSuchContent)
        XCTAssertNil(manager.player)
        manager.cancelResume()
        XCTAssertEqual(manager.handleRemotePlayback(.toggle), .noSuchContent)
        XCTAssertNil(manager.player)
        manager.continueWatching(episode)
        XCTAssertEqual(manager.handleRemotePlayback(.play), .commandFailed)
        XCTAssertEqual(manager.handleRemotePlayback(.pause), .commandFailed)
    }
}
