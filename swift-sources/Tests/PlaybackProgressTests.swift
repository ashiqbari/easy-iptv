import XCTest
import AVFoundation
import CoreVideo
import Combine
#if os(macOS)
import VLC
#endif
@testable import EasyIPTV

final class PlaybackProgressTests: XCTestCase {
    @MainActor func testLiveClockTicksDoNotInvalidateLibraryAndVODClockStillUpdates() {
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        defer { manager.stop() }
        manager.currentChannel = media(url: URL(string: "https://fixture.invalid/live.m3u8")!, type: .live)
        var changes = 0
        let subscription = manager.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        for tick in 1...100 { manager.updatePlaybackClock(position: Double(tick), duration: 300) }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(manager.currentTime, 0)
        XCTAssertEqual(manager.duration, 0)
        for type in [M3UItem.ContentType.movie, .series] {
            manager.currentChannel = media(type: type)
            changes = 0
            manager.updatePlaybackClock(position: 120, duration: 300)
            XCTAssertEqual(manager.currentTime, 120)
            XCTAssertEqual(manager.duration, 300)
            changes = 0
            manager.updatePlaybackClock(position: 120, duration: 300)
            manager.updatePlaybackClock(position: .nan, duration: .infinity)
            XCTAssertEqual(changes, 0)
            manager.updatePlaybackClock(position: 121, duration: 300)
            XCTAssertEqual(changes, 1)
        }
    }

    @MainActor func testRepeatedPlaybackStateDoesNotInvalidateLibrary() {
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        defer { manager.stop() }
        manager.currentChannel = media(type: .live)
        manager.updatePlaybackState(playing: true, buffering: false)
        var changes = 0
        let subscription = manager.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        for _ in 0..<100 { manager.updatePlaybackState(playing: true, buffering: false) }
        XCTAssertEqual(changes, 0)
        manager.updatePlaybackState(playing: false, buffering: true)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertTrue(manager.isBuffering)
        XCTAssertEqual(changes, 2)
    }

    #if os(macOS)
    @MainActor func testVLCIsDefaultForEveryContentTypeAndContinueWatching() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = isolatedDefaults()
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop() }
        for type in M3UItem.ContentType.allCases {
            let item = media(url: url, type: type)
            manager.playDirectStream(item)
            XCTAssertTrue(manager.useVLCPlayback, "Default for \(type)")
            XCTAssertNotNil(manager.vlcPlayer)
            XCTAssertNil(manager.player)
            let originalVLC = manager.vlcPlayer
            manager.playDirectStreamWithAVKit(item)
            XCTAssertFalse(manager.useVLCPlayback)
            XCTAssertNotNil(manager.player, "Manual AVKit selection must still work")
            XCTAssertNil(manager.vlcPlayer)
            manager.stop()
            if type != .live {
                manager.progressStore.save(item: item, position: 120, duration: 300)
                manager.playDirectStream(item)
                let request = try XCTUnwrap(manager.resumeRequest)
                XCTAssertTrue(request.useVLC)
                manager.resolveResume(request, startOver: false)
                XCTAssertTrue(manager.useVLCPlayback)
                manager.continueWatching(item)
                XCTAssertTrue(manager.useVLCPlayback)
                XCTAssertEqual(manager.progressStore.progress(for: item)?.resumePosition, 120)
                XCTAssertNil(manager.player)
                XCTAssertTrue(manager.vlcPlayer !== originalVLC)
            }
            manager.stop()
            manager.progressStore.clear(item)
        }
    }

    @MainActor func testLiveRelativeSeekReadsEngineClockWithoutPublishedTicks() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        defer { manager.stop() }
        manager.playAVKitFixture(media(url: url, type: .live))
        let ready = await waitUntil { manager.player?.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready)
        let player = try XCTUnwrap(manager.player)
        player.pause()
        await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 120, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in continuation.resume() }
        }
        XCTAssertEqual(manager.currentTime, 0)
        manager.seekBy(seconds: 10)
        XCTAssertEqual(manager.currentTime, 130, accuracy: 1)
        manager.seekBy(seconds: 1000)
        XCTAssertEqual(manager.currentTime, 300, accuracy: 1)
    }
    #endif

    private func media(url: URL = URL(string: "https://provider.example/series/user/password/7.mp4")!,
                       type: M3UItem.ContentType = .series, season: Int = 1, episode: Int = 1) -> M3UItem {
        M3UItem(name: "Episode", streamURL: url, contentType: type,
                mediaID: "7", seriesID: "12", seasonNumber: season, episodeNumber: episode)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "EasyIPTVTests.\(UUID().uuidString)")!
    }

    @MainActor func testStableKeysSeparateEpisodesAndProviders() {
        let a = media()
        XCTAssertEqual(PlaybackProgressStore.key(for: a), PlaybackProgressStore.key(for: media()))
        XCTAssertNotEqual(PlaybackProgressStore.key(for: a), PlaybackProgressStore.key(for: media(season: 2)))
        XCTAssertNotEqual(PlaybackProgressStore.key(for: a), PlaybackProgressStore.key(for: media(episode: 2)))
        XCTAssertNotEqual(PlaybackProgressStore.key(for: a), PlaybackProgressStore.key(for: media(type: .movie)))
        XCTAssertNotEqual(PlaybackProgressStore.key(for: a), PlaybackProgressStore.key(for: media(url: URL(string: "https://other.example/7.mp4")!)))
        XCTAssertFalse(PlaybackProgressStore.key(for: a).contains("password"))
    }

    @MainActor func testPersistenceAndUnknownDuration() {
        let defaults = isolatedDefaults()
        let store = PlaybackProgressStore(defaults: defaults)
        let item = media()
        store.save(item: item, position: 123, duration: 600)
        store.save(item: item, position: 124, duration: 0)
        let restored = PlaybackProgressStore(defaults: defaults)
        XCTAssertEqual(restored.progress(for: item)?.resumePosition, 124)
        XCTAssertEqual(restored.progress(for: item)?.duration, 600)
        store.clear(item)
        XCTAssertNil(PlaybackProgressStore(defaults: defaults).progress(for: item))
    }

    func testCompletionThresholdsAndShortClips() {
        XCTAssertFalse(PlaybackProgress.isFinished(position: 540, duration: 600))
        XCTAssertTrue(PlaybackProgress.isFinished(position: 556, duration: 600))
        XCTAssertTrue(PlaybackProgress.isFinished(position: 950, duration: 1000))
        XCTAssertFalse(PlaybackProgress.isFinished(position: 0, duration: 30))
        XCTAssertFalse(PlaybackProgress.isFinished(position: 10, duration: 30))
        XCTAssertFalse(PlaybackProgress.isFinished(position: 600, duration: 0))
        XCTAssertEqual(PlaybackProgress.timestamp(83), "01:23")
        XCTAssertEqual(PlaybackProgress.timestamp(3683), "1:01:23")
    }

    @MainActor func testLiveAndInvalidPositionsAreNotSaved() {
        let store = PlaybackProgressStore(defaults: isolatedDefaults())
        store.save(item: media(type: .live), position: 120, duration: 600)
        store.save(item: media(), position: .nan, duration: 600)
        store.save(item: media(), position: -1, duration: 600)
        XCTAssertTrue(store.records.isEmpty)
    }

    @MainActor func testResumePromptDoesNotStartPlayerAndStaleChoiceIsIgnored() throws {
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let first = media()
        let second = media(episode: 2)
        manager.progressStore.save(item: first, position: 120, duration: 600)
        manager.progressStore.save(item: second, position: 240, duration: 600)
        manager.playDirectStream(first)
        let stale = try XCTUnwrap(manager.resumeRequest)
        XCTAssertNil(manager.player)
        XCTAssertFalse(manager.isPlaying)
        manager.playDirectStream(second)
        manager.resolveResume(stale, startOver: false)
        XCTAssertEqual(manager.resumeRequest?.item.episodeNumber, 2)
        XCTAssertNil(manager.player)
        manager.stop()
        XCTAssertNil(manager.resumeRequest)
    }

    @MainActor func testSeriesContinueSelectsLatestUnfinishedEpisode() {
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let first = media()
        let second = media(episode: 2)
        manager.seriesEpisodes = [first, second]
        manager.progressStore.save(item: first, position: 120, duration: 600)
        manager.progressStore.save(item: second, position: 240, duration: 600)
        XCTAssertEqual(manager.continueWatchingEpisode?.episodeNumber, 2)
        manager.progressStore.save(item: second, position: 600, duration: 600, completed: true)
        XCTAssertEqual(manager.continueWatchingEpisode?.episodeNumber, 1)
    }


    @MainActor private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @MainActor func testStopSavesActualClockAndReleasesAVPlayer() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let item = media(url: url)
        manager.playAVKitFixture(item)
        let originalItem = manager.player?.currentItem
        let ready = await waitUntil { manager.player?.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready, "AVPlayer error: \(String(describing: originalItem?.error))")
        let player = try XCTUnwrap(manager.player)
        player.pause()
        await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 120, preferredTimescale: 600), toleranceBefore: .zero,
                        toleranceAfter: .zero) { _ in continuation.resume() }
        }
        manager.stop()
        XCTAssertNil(manager.player)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.position ?? 0, 120, accuracy: 1)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.duration ?? 0, 300, accuracy: 1)
        manager.togglePlayPause()
        XCTAssertFalse(manager.isPlaying)
    }

    @MainActor func testMovieDetailsBackSavesClockAndResumeSeeksAfterMetadata() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        defer { manager.stop() }
        let item = media(url: url, type: .movie)
        manager.playChannel(item)
        XCTAssertNil(manager.player)
        manager.playMovie()
        manager.playAVKitFixture(item)
        let ready = await waitUntil { manager.player?.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready)
        let player = try XCTUnwrap(manager.player)
        player.pause()
        await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 120, preferredTimescale: 600), toleranceBefore: .zero,
                        toleranceAfter: .zero) { _ in continuation.resume() }
        }
        manager.returnToMovie()
        XCTAssertTrue(manager.isViewingMovieDetails)
        XCTAssertTrue(manager.player === player)
        XCTAssertNotNil(player.currentItem)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.position ?? 0, 120, accuracy: 1)
        manager.playMovie()
        XCTAssertTrue(manager.player === player)
        XCTAssertFalse(manager.isViewingMovieDetails)
        let resumed = await waitUntil { (manager.vlcPlayer.map { Double($0.time.intValue) / 1000 } ?? manager.player?.currentTime().seconds ?? 0) >= 119 }
        XCTAssertTrue(resumed)
        XCTAssertNil(manager.resumeRequest)
    }

    @MainActor func testResumeSeeksAfterMetadataAndStartOverClearsProgress() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let item = media(url: url, type: .movie)
        manager.progressStore.save(item: item, position: 120, duration: 300)
        manager.playDirectStream(item)
        let request = try XCTUnwrap(manager.resumeRequest)
        // SwiftUI dismisses the alert binding before running the selected action.
        manager.showingResumeChoice = false
        manager.resolveResume(request, startOver: false)
        manager.vlcPlayer?.media?.addOption(":vout=dummy")
        manager.vlcPlayer?.media?.addOption(":aout=dummy")
        manager.vlcPlayer?.play()
        let resumed = await waitUntil { (manager.vlcPlayer.map { Double($0.time.intValue) / 1000 } ?? manager.player?.currentTime().seconds ?? 0) >= 119 }
        XCTAssertTrue(resumed)
        manager.stop()
        manager.playDirectStream(item)
        manager.resolveResume(try XCTUnwrap(manager.resumeRequest), startOver: true)
        XCTAssertNil(manager.progressStore.progress(for: item))
        XCTAssertLessThan(manager.player?.currentTime().seconds ?? 0, 5)
        manager.stop()
    }

    @MainActor func testFullscreenHostReplacementDoesNotStopButFinalUnmountDoes() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let first = UUID(), replacement = UUID()
        manager.playerViewAppeared(first)
        manager.playAVKitFixture(media(url: url))
        let player = try XCTUnwrap(manager.player)
        manager.playerViewDisappeared(first)
        manager.playerViewAppeared(replacement)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(manager.player === player)
        manager.playerViewDisappeared(replacement)
        let stopped = await waitUntil { manager.player == nil }
        XCTAssertTrue(stopped)
        XCTAssertNil(player.currentItem)
    }

    @MainActor func testEpisodeSwitchAndBackgroundPauseSaveBeforeReplacement() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let first = media(url: url), second = media(url: url, episode: 2)
        manager.playAVKitFixture(first)
        let ready = await waitUntil { manager.player?.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready)
        let oldPlayer = try XCTUnwrap(manager.player)
        await withCheckedContinuation { continuation in
            oldPlayer.seek(to: CMTime(seconds: 80, preferredTimescale: 600), toleranceBefore: .zero,
                           toleranceAfter: .zero) { _ in continuation.resume() }
        }
        manager.pauseForBackground()
        XCTAssertEqual(oldPlayer.rate, 0)
        XCTAssertEqual(manager.progressStore.progress(for: first)?.position ?? 0, 80, accuracy: 1)
        manager.playAVKitFixture(second)
        XCTAssertNil(oldPlayer.currentItem)
        XCTAssertEqual(manager.currentChannel?.episodeNumber, 2)
        manager.stop()
    }

    @MainActor func testLongNetworkPauseReopensBothEnginesAtPausedPosition() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        #if os(macOS)
        let engines = [false, true]
        #else
        let engines = [false]
        #endif
        for useVLC in engines {
            let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
            defer { manager.stop() }
            manager.playAVKitFixture(media(url: url))
            #if os(macOS)
            if useVLC {
                manager.playCurrentStreamWithVLC()
                let vlc = try XCTUnwrap(manager.vlcPlayer)
                vlc.media?.addOption(":vout=dummy")
                vlc.media?.addOption(":aout=dummy")
                vlc.play()
            }
            #endif
            let ready = await waitUntil { manager.isPlaying && manager.duration > 0 }
            XCTAssertTrue(ready)
            manager.seek(to: 80)
            let sought = await waitUntil {
                #if os(macOS)
                if useVLC { return abs(Double(manager.vlcPlayer?.time.intValue ?? 0) / 1000 - 80) < 2 }
                #endif
                return abs((manager.player?.currentTime().seconds ?? 0) - 80) < 2
            }
            XCTAssertTrue(sought)
            let remote = media()
            manager.currentChannel = remote
            let originalAV = manager.player
            #if os(macOS)
            let originalVLC = manager.vlcPlayer
            #endif
            manager.pauseForBackground(now: Date().addingTimeInterval(-120))
            manager.pauseForBackground() // Repeated background notifications must keep the original pause time.
            if !useVLC {
                NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: originalAV?.currentItem)
                try await Task.sleep(nanoseconds: 20_000_000)
                XCTAssertFalse(manager.progressStore.progress(for: remote)?.completed ?? true)
                XCTAssertTrue(manager.player === originalAV)
            }
            manager.seek(to: 90)
            manager.isViewingSeriesDetails = true
            XCTAssertEqual(manager.handleRemotePlayback(.play), .success)
            XCTAssertNil(manager.resumeRequest)
            XCTAssertEqual(manager.currentChannel?.id, remote.id)
            XCTAssertTrue(manager.isViewingSeriesDetails)
            XCTAssertEqual(manager.useVLCPlayback, useVLC)
            #if os(macOS)
            if useVLC { XCTAssertTrue(manager.vlcPlayer !== originalVLC) }
            else { XCTAssertTrue(manager.player !== originalAV) }
            #else
            XCTAssertTrue(manager.player !== originalAV)
            #endif
            manager.stop()
            XCTAssertEqual(manager.progressStore.progress(for: remote)?.position ?? 0, 90, accuracy: 1)
        }
    }

    @MainActor func testShortPauseKeepsConnectionButMissingItemReopensAtBookmark() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        defer { manager.stop() }
        manager.playAVKitFixture(media(url: url))
        let ready = await waitUntil { manager.player?.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready)
        let player = try XCTUnwrap(manager.player)
        await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 80, preferredTimescale: 600), toleranceBefore: .zero,
                        toleranceAfter: .zero) { _ in continuation.resume() }
        }
        let remote = media()
        manager.currentChannel = remote
        manager.togglePlayPause()
        manager.togglePlayPause()
        XCTAssertTrue(manager.player === player)
        manager.togglePlayPause()
        player.replaceCurrentItem(with: nil)
        manager.togglePlayPause()
        XCTAssertTrue(manager.player !== player)
        manager.stop()
        XCTAssertEqual(manager.progressStore.progress(for: remote)?.position ?? 0, 80, accuracy: 2)
    }

    @MainActor func testLongLocalPauseKeepsExistingPlayer() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        defer { manager.stop() }
        manager.playAVKitFixture(media(url: url))
        let ready = await waitUntil { manager.player?.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready)
        let player = manager.player
        manager.pauseForBackground(now: Date().addingTimeInterval(-120))
        manager.togglePlayPause()
        XCTAssertTrue(manager.player === player)
    }

    @MainActor func testPeriodicSaveAndCompletionSurviveExit() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let item = media(url: url)
        manager.playAVKitFixture(item)
        let ready = await waitUntil { manager.player?.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready)
        let player = try XCTUnwrap(manager.player)
        await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 80, preferredTimescale: 600), toleranceBefore: .zero,
                        toleranceAfter: .zero) { _ in continuation.resume() }
        }
        try await Task.sleep(nanoseconds: 5_300_000_000)
        XCTAssertGreaterThan(manager.progressStore.progress(for: item)?.position ?? 0, 80)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
        let finished = await waitUntil { manager.progressStore.progress(for: item)?.completed == true }
        XCTAssertTrue(finished)
        manager.stop()
        XCTAssertTrue(manager.progressStore.progress(for: item)?.completed == true)
        manager.playAVKitFixture(item)
        XCTAssertNil(manager.resumeRequest)
        XCTAssertLessThan(manager.player?.currentTime().seconds ?? 0, 5)
        manager.stop()
    }

    @MainActor func testStopDuringPendingResumeKeepsSavedPosition() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let item = media(url: url)
        manager.progressStore.save(item: item, position: 120, duration: 300)
        manager.playDirectStream(item)
        manager.resolveResume(try XCTUnwrap(manager.resumeRequest), startOver: false)
        manager.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(manager.player)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.resumePosition, 120)
    }

    #if os(macOS)
    func testVLCResumeDoesNotRequireKnownDurationAndBoundsSeekTargets() {
        XCTAssertEqual(IPTVPlayerManager.vlcResumeTime(position: 120, seekable: true, duration: 0), 120_000)
        XCTAssertEqual(IPTVPlayerManager.vlcResumeTime(position: 120, seekable: true, duration: .nan), 120_000)
        XCTAssertEqual(IPTVPlayerManager.vlcResumeTime(position: 120, seekable: true, duration: 60), 59_000)
        XCTAssertNil(IPTVPlayerManager.vlcResumeTime(position: 120, seekable: false, duration: 300))
        XCTAssertNil(IPTVPlayerManager.vlcResumeTime(position: .infinity, seekable: true, duration: 0))
        XCTAssertNil(IPTVPlayerManager.vlcResumeTime(position: -1, seekable: true, duration: 0))
        XCTAssertEqual(IPTVPlayerManager.vlcResumeTime(position: .greatestFiniteMagnitude, seekable: true, duration: 0), .max)
    }

    @MainActor func testFailedResumeRetryPreservesBookmarkAndExplicitStartOverClearsIt() throws {
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        defer { manager.stop() }
        let item = media()
        manager.progressStore.save(item: item, position: 120, duration: 300)
        manager.playDirectStream(item)
        manager.resolveResume(try XCTUnwrap(manager.resumeRequest), startOver: false)
        manager.errorMessage = "Resume failed"
        XCTAssertTrue(manager.canStartOverAfterResumeFailure)
        manager.retryCurrentStream()
        manager.errorMessage = "Resume failed again"
        XCTAssertTrue(manager.canStartOverAfterResumeFailure)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.position, 120)
        manager.startCurrentStreamOver()
        XCTAssertFalse(manager.canStartOverAfterResumeFailure)
        XCTAssertNil(manager.progressStore.progress(for: item))
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.currentChannel?.id, item.id)
        XCTAssertNotNil(manager.vlcPlayer)
    }

    @MainActor func testVLCStopReleasesActivePlayerAndCannotRestart() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        manager.playDirectStream(media(url: url))
        manager.playCurrentStreamWithVLC()
        XCTAssertNotNil(manager.vlcPlayer)
        manager.stop()
        XCTAssertNil(manager.vlcPlayer)
        XCTAssertFalse(manager.useVLCPlayback)
        manager.playCurrentStreamWithVLC()
        manager.togglePlayPause()
        XCTAssertNil(manager.vlcPlayer)
        XCTAssertFalse(manager.isPlaying)
    }

    @MainActor func testVLCResumeAndStopSaveRealClock() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let item = media(url: url)
        manager.progressStore.save(item: item, position: 120, duration: 300)
        manager.playDirectStream(item)
        manager.resolveResume(try XCTUnwrap(manager.resumeRequest), startOver: false)
        manager.playCurrentStreamWithVLC()
        let vlc = try XCTUnwrap(manager.vlcPlayer)
        vlc.media?.addOption(":vout=dummy")
        vlc.media?.addOption(":aout=dummy")
        vlc.play()
        let resumed = await waitUntil { vlc.time.intValue >= 119_000 && vlc.audio?.volume != 0 }
        XCTAssertTrue(resumed)
        manager.stop()
        XCTAssertNil(manager.vlcPlayer)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.position ?? 0, 120, accuracy: 3)
        let stopped = await waitUntil { vlc.state == .stopped }
        XCTAssertTrue(stopped)
    }
    #endif
}
