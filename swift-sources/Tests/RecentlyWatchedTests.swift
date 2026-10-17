import XCTest
#if os(macOS)
import VLC
#endif
@testable import EasyIPTV

@MainActor
final class RecentlyWatchedTests: XCTestCase {
    private func media(_ id: Int, type: M3UItem.ContentType = .movie, episode: Int? = nil,
                       host: String = "provider.example") -> M3UItem {
        M3UItem(name: "Title \(id)", streamURL: URL(string: "https://\(host)/user/password/\(id).mp4")!,
                contentType: type, mediaID: String(id), seriesID: type == .series ? "show" : nil,
                seasonNumber: episode == nil ? nil : 1, episodeNumber: episode)
    }

    func testCapacityOrderingPersistenceAndSectionIsolation() throws {
        let suite = "recent-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentlyWatchedStore(defaults: defaults)
        for type in M3UItem.ContentType.allCases {
            for id in 0..<35 { store.record(media(id, type: type)) }
            XCTAssertEqual(store.records.filter { $0.contentType == type }.count, 30)
        }
        store.record(media(10))
        XCTAssertEqual(store.records.first?.libraryKey, PlaybackProgressStore.key(for: media(10)))
        XCTAssertEqual(store.records.count, 90)
        XCTAssertFalse(store.records.contains { $0.libraryKey == PlaybackProgressStore.key(for: media(0)) })
        XCTAssertEqual(RecentlyWatchedStore(defaults: defaults).records, store.records)
        let saved = try XCTUnwrap(defaults.data(forKey: "com.iptvplayer.recentlyWatched.v1"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("password"))
        store.remove(media(10))
        XCTAssertEqual(store.records.filter { $0.contentType == .movie }.count, 29)
        store.clear(.live)
        XCTAssertFalse(store.records.contains { $0.contentType == .live })
        XCTAssertEqual(store.records.filter { $0.contentType == .series }.count, 30)
        XCTAssertEqual(RecentlyWatchedStore(defaults: defaults).records, store.records)
    }

    func testSeriesUsesOneEntryAndSeparatesProviders() {
        let suite = "recent-series-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentlyWatchedStore(defaults: defaults)
        let show = media(100, type: .series)
        store.record(media(1, type: .series, episode: 1), series: show)
        store.record(media(2, type: .series, episode: 2), series: show)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.episode, 2)
        XCTAssertEqual(store.records.first?.episodeKey, PlaybackProgressStore.key(for: media(2, type: .series, episode: 2)))
        store.record(media(2, type: .series, episode: 2, host: "other.example"),
                     series: media(100, type: .series, host: "other.example"))
        XCTAssertEqual(store.records.count, 2)
    }

    func testHistoryResolvesCurrentLibraryFiltersAndRemovesMissingTitles() async {
        let suite = "recent-library-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let first = media(1), second = media(2), live = media(3, type: .live)
        let refreshed = media(1)
        var loader = LibraryLoader()
        loader.playlist = { url in url.lastPathComponent == "refresh" ? [refreshed, live] : [first, second, live] }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); defaults.removePersistentDomain(forName: suite) }
        manager.recentlyWatchedStore.record(first)
        manager.recentlyWatchedStore.record(second)
        manager.recentlyWatchedStore.record(live)
        manager.currentChannel = live // Avoid the loader's automatic playback.
        await manager.loadPlaylist(from: "https://fixture.invalid/initial")
        manager.selectedSection = .movie
        manager.selectedCategory = "Recently Watched"
        XCTAssertEqual(manager.filteredChannels.map(\.id), [second.id, first.id])
        XCTAssertFalse(manager.filteredCategories.contains("Recently Watched"))
        manager.searchText = "Title 1"
        XCTAssertEqual(manager.filteredChannels.map(\.id), [first.id])
        manager.searchText = ""
        manager.currentChannel = live
        await manager.loadPlaylist(from: "https://fixture.invalid/refresh")
        XCTAssertEqual(manager.filteredChannels.map(\.id), [refreshed.id])
        manager.selectedSection = .live
        XCTAssertEqual(manager.selectedCategory, "Recently Watched")
        XCTAssertEqual(manager.filteredChannels.map(\.id), [live.id])
        manager.removeRecentlyWatched(live)
        XCTAssertTrue(manager.filteredChannels.isEmpty)
        manager.selectedSection = .movie
        manager.clearRecentlyWatched()
        XCTAssertTrue(manager.filteredChannels.isEmpty)
        XCTAssertFalse(manager.recentlyWatchedStore.records.contains { $0.contentType == .movie })
    }

    func testSeriesHistoryOpensDetailsWithoutStartingOrResumingAnEpisode() async throws {
        let suite = "recent-series-browse-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let show = media(100, type: .series)
        let episode = media(2, type: .series, episode: 2)
        var loader = LibraryLoader()
        loader.seriesDetails = { _ in SeriesDetails(details: nil, episodes: [episode]) }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); defaults.removePersistentDomain(forName: suite) }
        manager.progressStore.save(item: episode, position: 120, duration: 600)
        for lastWatched in [episode, media(9, type: .series, episode: 9)] {
            manager.recentlyWatchedStore.record(lastWatched, series: show)
            manager.playRecentlyWatched(show)
            for _ in 0..<100 {
                if !manager.isLoadingEpisodes { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(manager.isLoadingEpisodes)
            XCTAssertFalse(manager.showingDashboard)
            XCTAssertTrue(manager.isViewingSeriesDetails)
            XCTAssertEqual(manager.downloadSeriesItem?.id, show.id)
            XCTAssertEqual(manager.seriesEpisodes.map(\.id), [episode.id])
            XCTAssertNil(manager.currentChannel)
            XCTAssertNil(manager.player)
            XCTAssertFalse(manager.useVLCPlayback)
            XCTAssertNil(manager.resumeRequest)
            XCTAssertNil(manager.errorMessage)
            XCTAssertEqual(manager.progressStore.progress(for: episode)?.position, 120)
        }
    }

    func testContinueWatchingLoadsAndResumesLatestEpisodeOrReportsUnavailable() async throws {
        let suite = "recent-resume-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let show = media(100, type: .series)
        let first = media(1, type: .series, episode: 1)
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let last = M3UItem(name: "Episode 2", streamURL: url, contentType: .series,
                           mediaID: "2", seriesID: "show", seasonNumber: 1, episodeNumber: 2)
        var loader = LibraryLoader()
        loader.seriesDetails = { _ in SeriesDetails(details: nil, episodes: [first, last]) }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); defaults.removePersistentDomain(forName: suite) }
        manager.recentlyWatchedStore.record(last, series: show)
        manager.progressStore.save(item: last, position: 120, duration: 600)
        manager.playRecentlyWatched(show, resumeSeries: true)
        for _ in 0..<100 {
            if !manager.isLoadingEpisodes { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(manager.currentChannel?.id, last.id)
        XCTAssertFalse(manager.isViewingSeriesDetails)
        XCTAssertNil(manager.resumeRequest, "History resumes directly without an extra prompt")
        #if os(macOS)
        XCTAssertTrue(manager.useVLCPlayback)
        XCTAssertNotNil(manager.vlcPlayer)
        #else
        XCTAssertNotNil(manager.player)
        #endif
        manager.stop()
        manager.recentlyWatchedStore.record(media(9, type: .series, episode: 9), series: show)
        manager.playRecentlyWatched(show, resumeSeries: true)
        for _ in 0..<100 {
            if !manager.isLoadingEpisodes { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(manager.isViewingSeriesDetails)
        XCTAssertNil(manager.player)
        XCTAssertNotNil(manager.errorMessage)
    }

    func testHistoryOnlyRecordsActualPlaybackAndDoesNotReinsertRemovedItemOnPause() async throws {
        let suite = "recent-playback-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let item = M3UItem(name: "Movie", streamURL: url, contentType: .movie)
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer {
            manager.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        manager.playChannel(item)
        manager.recordPlaybackStarted()
        XCTAssertTrue(manager.recentlyWatchedStore.records.isEmpty)
        manager.playMovie()
        manager.playAVKitFixture(item)
        for _ in 0..<250 {
            if !manager.recentlyWatchedStore.records.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(manager.recentlyWatchedStore.records.count, 1)
        manager.removeRecentlyWatched(item)
        manager.recordPlaybackStarted()
        XCTAssertTrue(manager.recentlyWatchedStore.records.isEmpty)
        manager.stop()
        manager.playDirectStream(M3UItem(name: "Missing", streamURL: URL(fileURLWithPath: "/private/tmp/missing-recent-\(UUID()).mp4"), contentType: .movie))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(manager.recentlyWatchedStore.records.isEmpty)
    }

    #if os(macOS)
    func testVLCRecordsLivePlaybackAfterItStarts() async throws {
        let suite = "recent-vlc-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let item = M3UItem(name: "Live fixture", streamURL: url, contentType: .live)
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer {
            manager.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        manager.playDirectStream(item)
        let player = try XCTUnwrap(manager.vlcPlayer)
        player.media?.addOption(":vout=dummy")
        player.media?.addOption(":aout=dummy")
        player.play()
        for _ in 0..<250 {
            if !manager.recentlyWatchedStore.records.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(manager.recentlyWatchedStore.records.first?.libraryKey, PlaybackProgressStore.key(for: item))
        XCTAssertEqual(manager.recentlyWatchedStore.records.first?.contentType, .live)
        XCTAssertNil(manager.progressStore.progress(for: item))
    }
    #endif
}
