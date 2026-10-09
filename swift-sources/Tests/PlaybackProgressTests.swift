import XCTest
import AVFoundation
import CoreVideo
#if os(macOS)
import VLC
#endif
@testable import EasyIPTV

final class PlaybackProgressTests: XCTestCase {
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

    /// A native-written silent movie exercises real metadata/clock without a provider account.
    private func silentMedia() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resume-test-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        for time in 0..<300 {
            while !input.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(frame, withPresentationTime: CMTime(seconds: Double(time), preferredTimescale: 600)) else {
                throw writer.error ?? NSError(domain: "Fixture", code: 1)
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 300, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @MainActor func testExitSavesActualClockAndReleasesAVPlayer() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let item = media(url: url)
        manager.playDirectStream(item)
        let originalItem = manager.player?.currentItem
        let ready = await waitUntil { manager.player?.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready, "AVPlayer error: \(String(describing: originalItem?.error))")
        let player = try XCTUnwrap(manager.player)
        player.pause()
        await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 120, preferredTimescale: 600), toleranceBefore: .zero,
                        toleranceAfter: .zero) { _ in continuation.resume() }
        }
        manager.returnToSeries()
        XCTAssertNil(manager.player)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.position ?? 0, 120, accuracy: 1)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.duration ?? 0, 300, accuracy: 1)
        manager.togglePlayPause()
        XCTAssertFalse(manager.isPlaying)
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
        let resumed = await waitUntil { (manager.player?.currentTime().seconds ?? 0) >= 119 }
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
        manager.playDirectStream(media(url: url))
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
        manager.playDirectStream(first)
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
        manager.playDirectStream(second)
        XCTAssertNil(oldPlayer.currentItem)
        XCTAssertEqual(manager.currentChannel?.episodeNumber, 2)
        manager.stop()
    }

    @MainActor func testPeriodicSaveAndCompletionSurviveExit() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let item = media(url: url)
        manager.playDirectStream(item)
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
        manager.playDirectStream(item)
        XCTAssertNil(manager.resumeRequest)
        XCTAssertLessThan(manager.player?.currentTime().seconds ?? 0, 5)
        manager.stop()
    }

    @MainActor func testExitDuringPendingResumeKeepsSavedPosition() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        let item = media(url: url)
        manager.progressStore.save(item: item, position: 120, duration: 300)
        manager.playDirectStream(item)
        manager.resolveResume(try XCTUnwrap(manager.resumeRequest), startOver: false)
        manager.returnToSeries()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(manager.player)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.resumePosition, 120)
    }

    #if os(macOS)
    @MainActor func testVLCExitReleasesActivePlayerAndCannotRestartFromSeries() async throws {
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = IPTVPlayerManager(progressDefaults: isolatedDefaults())
        manager.playDirectStream(media(url: url))
        manager.playCurrentStreamWithVLC()
        XCTAssertNotNil(manager.vlcPlayer)
        manager.returnToSeries()
        XCTAssertNil(manager.vlcPlayer)
        XCTAssertFalse(manager.useVLCPlayback)
        manager.playCurrentStreamWithVLC()
        manager.togglePlayPause()
        XCTAssertNil(manager.vlcPlayer)
        XCTAssertFalse(manager.isPlaying)
    }

    @MainActor func testVLCResumeAndExitSaveRealClock() async throws {
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
        manager.returnToSeries()
        XCTAssertNil(manager.vlcPlayer)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.position ?? 0, 120, accuracy: 3)
        let stopped = await waitUntil { vlc.state == .stopped }
        XCTAssertTrue(stopped)
    }
    #endif
}
