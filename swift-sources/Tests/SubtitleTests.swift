import XCTest
import AVFoundation
#if os(macOS)
import VLC
#endif
@testable import EasyIPTV

final class SubtitleTests: XCTestCase {
    private let srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\nHello <i>world</i> &amp; friends\r\nSecond line\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nGoodbye"

    func testSRTTimingBoundariesAndSeekBackwards() throws {
        let document = try SubtitleDocument(data: Data(srt.utf8))
        XCTAssertEqual(document.text(at: 0.99), "")
        XCTAssertEqual(document.text(at: 1), "Hello world & friends\nSecond line")
        XCTAssertEqual(document.text(at: 3.5), "")
        XCTAssertEqual(document.text(at: 4.5), "Goodbye")
        XCTAssertEqual(document.text(at: 1.2), "Hello world & friends\nSecond line")
        XCTAssertEqual(document.text(at: .nan), "")
    }

    func testWebVTTBOMIdentifiersSettingsCommentsAndOverlaps() throws {
        let vtt = """
        \u{FEFF}WEBVTT

        NOTE This is a comment
        Not a cue

        first-cue
        00:01.000 --> 00:04.000 align:start position:20%
        <v Speaker>Hello</v>

        00:02.000 --> 00:03.000
        Overlapping

        """
        let document = try SubtitleDocument(data: Data(vtt.utf8))
        XCTAssertEqual(document.text(at: 2.5), "Hello\nOverlapping")
        XCTAssertEqual(document.text(at: 3.5), "Hello")
        XCTAssertEqual(document.text(at: 4), "")
    }

    func testUnsortedCuesAndLongOverlappingCue() throws {
        let srt = "1\n00:00:03,000 --> 00:00:04,000\nShort\n\n2\n00:00:01,000 --> 00:00:09,000\nLong\n\n3\n00:00:02,000 --> 00:00:02,500\nEnded"
        let document = try SubtitleDocument(data: Data(srt.utf8))
        XCTAssertEqual(document.text(at: 5), "Long")
        XCTAssertEqual(document.text(at: 3.5), "Long\nShort")
    }

    func testMalformedFilesFailWithoutPartialSubtitleDisplay() {
        for file in ["<html>Error</html>", "WEBVTT\n\n", "1\n00:00:05,000 --> 00:00:04,000\nReversed",
                     "1\n00:61:01,000 --> 00:62:01,000\nInvalid", srt + "\n\nBroken block"] {
            XCTAssertThrowsError(try SubtitleDocument(data: Data(file.utf8)))
        }
    }

    func testUTF16FileAndSizeLimit() throws {
        let data = try XCTUnwrap(srt.data(using: .utf16))
        XCTAssertEqual(try SubtitleDocument(data: data).text(at: 4.5), "Goodbye")
        XCTAssertThrowsError(try SubtitleDocument(data: Data(repeating: 65, count: 5 * 1024 * 1024 + 1)))
    }

    func testFileCacheDeduplicatesConcurrentRequestsAndTrackSwitches() async throws {
        let probe = FetchProbe(data: Data(srt.utf8))
        let cache = SubtitleFileCache { try await probe.fetch($0) }
        let first = URL(string: "https://example.com/english.srt")!
        let second = URL(string: "https://example.com/french.srt")!
        async let a = cache.document(for: first)
        async let b = cache.document(for: first)
        let (one, two) = try await (a, b)
        XCTAssertEqual(one.cues, two.cues)
        _ = try await cache.document(for: second)
        _ = try await cache.document(for: first)
        let count = await probe.count
        XCTAssertEqual(count, 2)
    }

    func testFailedDownloadIsRetried() async throws {
        let probe = FetchProbe(data: Data(srt.utf8), failOnce: true)
        let cache = SubtitleFileCache { try await probe.fetch($0) }
        let url = URL(string: "https://example.com/subtitles.srt")!
        do {
            _ = try await cache.document(for: url)
            XCTFail("Expected initial failure")
        } catch { }
        _ = try await cache.document(for: url)
        _ = try await cache.document(for: url)
        let count = await probe.count
        XCTAssertEqual(count, 2)
    }

    func testMalformedDownloadIsNotCached() async {
        let probe = FetchProbe(data: Data("Not subtitles".utf8))
        let cache = SubtitleFileCache { try await probe.fetch($0) }
        for _ in 0..<2 {
            do { _ = try await cache.document(for: URL(string: "https://example.com/bad.srt")!); XCTFail("Expected parse failure") }
            catch { }
        }
        let count = await probe.count
        XCTAssertEqual(count, 2)
    }

    func testMediaCacheKeysIncludeProviderSeasonAndEpisode() {
        let url = URL(string: "https://example.com/series/user/password/12.mp4")!
        func episode(_ season: Int, _ number: Int) -> M3UItem {
            M3UItem(name: "Episode", streamURL: url, contentType: .series,
                    mediaID: "12", seriesID: "5", seasonNumber: season, episodeNumber: number)
        }
        XCTAssertNotEqual(episode(1, 1).subtitleCacheKey, episode(1, 2).subtitleCacheKey)
        XCTAssertNotEqual(episode(1, 1).subtitleCacheKey, episode(2, 1).subtitleCacheKey)
        XCTAssertEqual(episode(1, 1).subtitleCacheKey, episode(1, 1).subtitleCacheKey)
        let movie = M3UItem(name: "Movie", streamURL: url, contentType: .movie, mediaID: "12")
        XCTAssertNotEqual(movie.subtitleCacheKey, episode(1, 1).subtitleCacheKey)
    }

    func testSavedPlaylistsWithoutSubtitleFieldsStillDecode() throws {
        let item = M3UItem(name: "Existing movie", streamURL: URL(string: "https://example.com/12.mp4")!)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(M3UItem.self, from: data)
        XCTAssertNil(decoded.seriesID)
        XCTAssertNil(decoded.subtitleSources)
        XCTAssertEqual(decoded.streamURL, item.streamURL)
    }

    func testProviderMetadataOnlyUsesActualSidecarURLs() {
        let metadata: [String: Any] = ["subtitles": [
            ["url": "subs/english.vtt", "language": "en"],
            ["codec": "subrip", "index": 2, "language": "fr"],
            ["url": "javascript:bad", "language": "de"]
        ]]
        let sources = SubtitleSource.fromMetadata(metadata, relativeTo: URL(string: "https://example.com/"))
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.url.absoluteString, "https://example.com/subs/english.vtt")
        XCTAssertFalse(sources.first?.label.isEmpty ?? true)
    }

    func testM3UPlaylistSubtitleMetadata() async throws {
        let playlist = """
        #EXTM3U
        #EXTINF:-1 group-title="Movies" subtitle-url="english.vtt" subtitle-language="English",Movie
        https://example.com/movie/12.mp4
        """
        let items = try await M3UParser().parse(string: playlist)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.subtitleSources?.first?.url.absoluteString, "https://example.com/movie/english.vtt")
        XCTAssertEqual(item.subtitleSources?.first?.label, "English")
    }

    func testMovieSubtitleRequestUsesTheStreamsProviderAccountAndID() async throws {
        let service = XtreamCodesManager()
        let movie = M3UItem(name: "Movie", streamURL: URL(string: "https://provider.example:8443/iptv/movie/account/p%26ss/42.mkv")!,
                            contentType: .movie, mediaID: "42")
        let request = await service.subtitleRequest(for: movie)
        let components = try XCTUnwrap(request.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: true) })
        XCTAssertEqual(components.host, "provider.example")
        XCTAssertEqual(components.port, 8443)
        XCTAssertEqual(components.path, "/iptv/player_api.php")
        XCTAssertEqual(components.queryItems?.first { $0.name == "username" }?.value, "account")
        XCTAssertEqual(components.queryItems?.first { $0.name == "password" }?.value, "p&ss")
        XCTAssertEqual(components.queryItems?.first { $0.name == "vod_id" }?.value, "42")
        let plainMovie = M3UItem(name: "Other", streamURL: URL(string: "https://example.com/movie.mp4")!)
        let noRequest = await service.subtitleRequest(for: plainMovie)
        XCTAssertNil(noRequest)
    }

    #if os(macOS)
    @MainActor
    func testBundledVLCSupportsLiveSubtitleFontChanges() {
        let player = VLCMediaPlayer()
        XCTAssertTrue(player.responds(to: NSSelectorFromString("setTextRendererFontSize:")))
    }
    #endif

    @MainActor
    func testTrackDiscoveryCachesEmptyResultsAndBlocksDuplicateRequests() async throws {
        let controller = SubtitleController()
        let movie = M3UItem(name: "Movie", streamURL: URL(string: "https://example.com/movie.mp4")!)
        controller.reset(for: movie)
        let item = AVPlayerItem(asset: AVMutableComposition())
        var requests = 0
        controller.configure(item: item) {
            requests += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            return []
        }
        // Configuration starts discovery without opening the CC menu.
        XCTAssertTrue(controller.isLoadingTracks)
        controller.loadTracksIfNeeded()
        try await waitUntil { !controller.isLoadingTracks }
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.tracks.isEmpty)
        controller.loadTracksIfNeeded()
        XCTAssertFalse(controller.isLoadingTracks)
        XCTAssertEqual(requests, 1)
        withExtendedLifetime(item) { }
    }

    #if os(macOS)
    @MainActor
    func testProviderTracksAppearWhileVLCIsStillOpening() async throws {
        let controller = SubtitleController()
        let movie = M3UItem(name: "Movie", streamURL: URL(string: "https://example.com/movie.mkv")!, contentType: .movie)
        controller.reset(for: movie)
        let player = VLCMediaPlayer()
        let url = URL(string: "https://example.com/english.srt")!
        var requests = 0
        controller.configure(player: player) {
            requests += 1
            return [SubtitleSource(url: url, label: "English")]
        }
        try await waitUntil { controller.tracks.contains { $0.id == url.absoluteString } }
        XCTAssertTrue(controller.isLoadingTracks, "Embedded discovery should still be waiting for VLC")
        controller.loadTracksIfNeeded()
        XCTAssertEqual(requests, 1, "Reopening CC must not refetch successful provider metadata")
        controller.reset(for: nil)
        XCTAssertFalse(controller.isLoadingTracks)
        withExtendedLifetime(player) { }
    }
    #endif

    @MainActor
    func testOldBackgroundDiscoveryCannotUpdateNewEpisode() async throws {
        let controller = SubtitleController()
        let first = M3UItem(name: "Episode 1", streamURL: URL(string: "https://example.com/series/1.mp4")!, contentType: .series)
        let second = M3UItem(name: "Episode 2", streamURL: URL(string: "https://example.com/series/2.mp4")!, contentType: .series)
        let firstItem = AVPlayerItem(asset: AVMutableComposition())
        let secondItem = AVPlayerItem(asset: AVMutableComposition())
        var response: CheckedContinuation<[SubtitleSource], Never>?
        controller.reset(for: first)
        controller.configure(item: firstItem) {
            await withCheckedContinuation { response = $0 }
        }
        try await waitUntil { response != nil }
        controller.reset(for: second)
        controller.configure(item: secondItem) { [] }
        response?.resume(returning: [SubtitleSource(url: URL(string: "https://example.com/old-episode.srt")!, label: "Old episode")])
        try await waitUntil { !controller.isLoadingTracks }
        XCTAssertTrue(controller.tracks.isEmpty)
        XCTAssertNil(controller.errorMessage)
        withExtendedLifetime((firstItem, secondItem)) { }
    }

    @MainActor
    func testDiscoveryRetriesFailuresAndRekeysForNewEpisode() async throws {
        let controller = SubtitleController()
        let first = M3UItem(name: "Episode 1", streamURL: URL(string: "https://example.com/series/1.mp4")!,
                            contentType: .series, seriesID: "10", seasonNumber: 1, episodeNumber: 1)
        let second = M3UItem(name: "Episode 2", streamURL: URL(string: "https://example.com/series/2.mp4")!,
                             contentType: .series, seriesID: "10", seasonNumber: 1, episodeNumber: 2)
        controller.reset(for: first)
        let avItem = AVPlayerItem(asset: AVMutableComposition())
        var requests = 0
        controller.configure(item: avItem) {
            requests += 1
            if requests == 1 { throw SubtitleError.http(503) }
            return [SubtitleSource(url: URL(string: "https://example.com/episode1.srt")!, label: "English")]
        }
        controller.loadTracksIfNeeded()
        try await waitUntil { !controller.isLoadingTracks }
        XCTAssertNotNil(controller.errorMessage)
        controller.retry()
        try await waitUntil { !controller.isLoadingTracks }
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(controller.tracks.count, 1)
        controller.reset(for: second)
        XCTAssertTrue(controller.tracks.isEmpty)
        let nextItem = AVPlayerItem(asset: AVMutableComposition())
        controller.configure(item: nextItem) { requests += 1; return [] }
        controller.loadTracksIfNeeded()
        try await waitUntil { !controller.isLoadingTracks }
        XCTAssertEqual(requests, 3)
        withExtendedLifetime((avItem, nextItem)) { }
    }

    @MainActor
    func testImportedFileTimingOffCachedReselectionAndMediaReset() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-test-\(UUID()).srt")
        try Data(srt.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = SubtitleController()
        controller.reset(for: M3UItem(name: "Movie", streamURL: URL(string: "https://example.com/movie.mp4")!))
        controller.updateTime(1.5)
        controller.importFile(file)
        try await waitUntil { !controller.isLoadingFile }
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.text, "Hello world & friends\nSecond line")
        controller.updateTime(4.5)
        XCTAssertEqual(controller.text, "Goodbye")
        controller.select(nil)
        XCTAssertEqual(controller.text, "")
        // Removing the fixture proves re-selection uses cached content, not disk.
        try FileManager.default.removeItem(at: file)
        controller.select(file.absoluteString)
        try await waitUntil { !controller.isLoadingFile }
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.text, "Goodbye")
        controller.reset(for: M3UItem(name: "Other", streamURL: URL(string: "https://example.com/other.mp4")!))
        XCTAssertNil(controller.selectedID)
        XCTAssertEqual(controller.text, "")
        XCTAssertTrue(controller.tracks.isEmpty)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Subtitle operation did not finish within two seconds")
    }

    @MainActor
    func testFontSizeBoundsAndPersistence() {
        let key = "com.iptvplayer.subtitleFontSize"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let controller = SubtitleController()
        controller.fontSize = 100
        XCTAssertEqual(controller.fontSize, 48)
        XCTAssertEqual(SubtitleController().fontSize, 48)
        controller.fontSize = 2
        XCTAssertEqual(controller.fontSize, 16)
        controller.fontSize = .nan
        XCTAssertEqual(controller.fontSize, 24)
    }
}

private actor FetchProbe {
    private let data: Data
    private var failOnce: Bool
    private(set) var count = 0

    init(data: Data, failOnce: Bool = false) { self.data = data; self.failOnce = failOnce }

    func fetch(_ url: URL) async throws -> Data {
        count += 1
        if failOnce { failOnce = false; throw SubtitleError.http(503) }
        try await Task.sleep(nanoseconds: 20_000_000)
        return data
    }
}
