import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import EasyIPTV

final class SeriesDetailsTests: XCTestCase {
    func testPlaybackTitlesKeepEpisodeNumbersVisible() {
        let url = URL(string: "https://fixture.invalid/episode.mp4")!
        let title = "S2 • A very long provider title with the episode number hidden at the end S02E03"
        let episode = M3UItem(name: title, groupTitle: "Season 2", streamURL: url,
                              contentType: .series, seasonNumber: 2, episodeNumber: 3)
        XCTAssertEqual(episode.playbackTitle, "Season 2 · Episode 3")
        XCTAssertEqual(episode.name, title)
        let grouped = M3UItem(name: title, groupTitle: "Specials", streamURL: url, contentType: .series, episodeNumber: 4)
        XCTAssertEqual(grouped.playbackTitle, "Specials · Episode 4")
        let missing = M3UItem(name: title, streamURL: url, contentType: .series)
        XCTAssertEqual(missing.playbackTitle, title, "Missing episode numbers must not be guessed")
        let movie = M3UItem(name: "Movie title", streamURL: url, contentType: .movie, episodeNumber: 3)
        XCTAssertEqual(movie.playbackTitle, "Movie title")
    }

    @MainActor func testPlaybackSeasonFollowsEpisodeAndRestoresAfterBrowsingAnotherShow() {
        let suite = "playback-season-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites(); defaults.removePersistentDomain(forName: suite) }
        let episodes: [M3UItem] = (1...2).flatMap { (season: Int) in
            (1...2).map { (episode: Int) in
                M3UItem(name: "Episode \(episode)", groupTitle: "Season \(season)",
                        streamURL: URL(fileURLWithPath: "/private/tmp/season-\(season)-episode-\(episode).mp4"),
                        contentType: .series, seasonNumber: season, episodeNumber: episode)
            }
        }
        manager.seriesEpisodes = episodes
        manager.selectSeason("Season 2")
        manager.playDirectStream(episodes[2])
        XCTAssertEqual(manager.selectedSeason, "Season 2")
        XCTAssertEqual(manager.filteredEpisodesForSelectedSeason.map(\.id), Array(episodes.suffix(2)).map(\.id))
        manager.fetchAndShowSeries(show("other"))
        manager.selectSeason("Season 9")
        manager.dismissDetails()
        XCTAssertEqual(manager.selectedSeason, "Season 2")
        XCTAssertEqual(manager.filteredEpisodesForSelectedSeason.count, 2)
        manager.playDirectStream(episodes[0])
        XCTAssertEqual(manager.selectedSeason, "Season 1")
        XCTAssertEqual(manager.filteredEpisodesForSelectedSeason.map(\.id), Array(episodes.prefix(2)).map(\.id))
    }

    @MainActor func testBrowsingAnotherShowKeepsPlayingEpisodeContextAndHighlight() async throws {
        let suite = "series-browsing-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let media = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: media) }
        let firstShow = show("1"), secondShow = show("2")
        let firstEpisode = M3UItem(name: "First episode", streamURL: media, contentType: .series)
        let secondEpisode = M3UItem(name: "Second episode", streamURL: media, contentType: .series)
        var loader = LibraryLoader()
        loader.seriesDetails = { item in SeriesDetails(details: nil, episodes: [item.id == firstShow.id ? firstEpisode : secondEpisode]) }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop() }
        manager.fetchAndShowSeries(firstShow)
        try await waitUntil { !manager.isLoadingEpisodes }
        manager.playAVKitFixture(firstEpisode)
        let player = try XCTUnwrap(manager.player)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(manager.isCurrentPlayback(firstShow))
        manager.fetchAndShowSeries(secondShow)
        try await waitUntil { !manager.isLoadingEpisodes }
        XCTAssertTrue(manager.player === player)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(manager.currentChannel?.id, firstEpisode.id)
        XCTAssertEqual(manager.seriesDetailsItem?.id, secondShow.id)
        XCTAssertTrue(manager.isCurrentPlayback(firstShow))
        XCTAssertFalse(manager.isCurrentPlayback(secondShow))
        #if os(macOS)
        manager.playCurrentStreamWithVLC()
        XCTAssertTrue(manager.isViewingSeriesDetails)
        XCTAssertEqual(manager.seriesDetailsItem?.id, secondShow.id)
        XCTAssertTrue(manager.isCurrentPlayback(firstShow))
        #endif
        manager.dismissDetails()
        XCTAssertEqual(manager.seriesEpisodes.map(\.id), [firstEpisode.id])
        XCTAssertEqual(manager.downloadSeriesItem?.id, firstShow.id)
        manager.fetchAndShowSeries(secondShow)
        try await waitUntil { !manager.isLoadingEpisodes }
        manager.playDirectStream(secondEpisode)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(manager.currentChannel?.id, secondEpisode.id)
        XCTAssertTrue(manager.isCurrentPlayback(secondShow))
        XCTAssertFalse(manager.isCurrentPlayback(firstShow))
    }

    @MainActor func testEpisodeArrowsUseVisiblePositionInBothLayoutsAndClampAtBounds() {
        let defaults = UserDefaults(suiteName: "episode-navigation-\(UUID())")!
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop() }
        manager.seriesEpisodes = (0..<8).map {
            M3UItem(name: "Episode \($0)", groupTitle: "Season 1", streamURL: URL(string: "https://fixture.invalid/\($0).mp4")!, contentType: .series)
        }
        for grid in [true, false] {
            manager.isSeriesGridView = grid
            manager.selectSeason("Season 1")
            manager.scrollEpisodesNext()
            XCTAssertEqual(manager.episodeScrollIndex, 3)
            manager.scrollEpisodesPrev(from: 6) // The user scrolled manually past the saved target.
            XCTAssertEqual(manager.episodeScrollIndex, 3)
            let request = manager.episodeScrollRequest
            manager.scrollEpisodesPrev(from: 6)
            XCTAssertNotEqual(manager.episodeScrollRequest, request, "A repeated target must still scroll")
            manager.scrollEpisodesNext(from: 6)
            XCTAssertEqual(manager.episodeScrollIndex, 7)
            manager.scrollEpisodesNext()
            XCTAssertEqual(manager.episodeScrollIndex, 7)
            manager.scrollEpisodesPrev(from: 0)
            XCTAssertEqual(manager.episodeScrollIndex, 0)
            manager.selectSeason("Season 1")
            XCTAssertEqual(manager.episodeScrollIndex, 0)
        }
        manager.seriesEpisodes = []
        manager.scrollEpisodesNext()
        manager.scrollEpisodesPrev()
        XCTAssertEqual(manager.episodeScrollIndex, 0)
    }

    #if os(macOS)
    @MainActor func testCarouselCanScrollBackAfterNextAndManualScrolling() async throws {
        try await checkEpisodeScrolling(grid: false)
    }

    @MainActor func testGridCanScrollBackToOffscreenEpisodes() async throws {
        try await checkEpisodeScrolling(grid: true)
    }

    @MainActor private func checkEpisodeScrolling(grid: Bool) async throws {
        let manager = IPTVPlayerManager(progressDefaults: UserDefaults(suiteName: "episode-scroll-view-\(UUID())")!)
        manager.currentChannel = show("1")
        manager.isViewingSeriesDetails = true
        manager.isSeriesGridView = grid
        manager.seriesEpisodes = (0..<24).map {
            M3UItem(name: "Episode \($0)", groupTitle: "Season 1", streamURL: URL(fileURLWithPath: "/private/tmp/episode-\($0).mp4"), contentType: .series)
        }
        let hosting = NSHostingView(rootView: IPTVPlaybackView(manager: manager).transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 850, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { manager.stop(); window.close() }
        func settle() async throws {
            for _ in 0..<15 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        func carousel(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView,
               grid ? (scroll.hasVerticalScroller && !scroll.hasHorizontalScroller) : scroll.hasHorizontalScroller { return scroll }
            return view.subviews.lazy.compactMap { carousel(in: $0) }.first
        }
        try await settle()
        let scroll = try XCTUnwrap(carousel(in: hosting))
        func offset() -> CGFloat { grid ? scroll.contentView.bounds.minY : scroll.contentView.bounds.minX }
        // Set up a scrolled viewport before ScrollViewReader establishes an animated target.
        scroll.contentView.setBoundsOrigin(grid ? CGPoint(x: 0, y: 1400) : CGPoint(x: 1400, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertGreaterThan(manager.visibleEpisodeIndex, 3)
        let manual = offset()
        manager.scrollEpisodesPrev(from: manager.visibleEpisodeIndex)
        try await settle()
        XCTAssertLessThan(offset(), manual - 100)
        let previous = offset()
        manager.scrollEpisodesNext(from: manager.visibleEpisodeIndex)
        try await settle()
        XCTAssertGreaterThan(offset(), previous + 100)
        XCTAssertGreaterThan(manager.visibleEpisodeIndex, 0, "Left must enable when the row has moved")
        let next = offset()
        manager.scrollEpisodesPrev(from: manager.visibleEpisodeIndex)
        try await settle()
        XCTAssertLessThan(offset(), next - 100)
    }

    @MainActor func testSeasonPillsWrapRatherThanOverflowNarrowScreens() {
        let manager = IPTVPlayerManager(progressDefaults: UserDefaults(suiteName: "season-layout-\(UUID())")!)
        defer { manager.stop() }
        manager.seriesEpisodes = (1...12).map {
            M3UItem(name: "Episode", groupTitle: "Season \($0)", streamURL: URL(string: "https://fixture.invalid/\($0).mp4")!, contentType: .series)
        }
        let hosting = NSHostingController(rootView: IPTVPlaybackView(manager: manager).seasonSelector)
        let narrow = hosting.sizeThatFits(in: CGSize(width: 320, height: 2000))
        let wide = hosting.sizeThatFits(in: CGSize(width: 1200, height: 2000))
        XCTAssertLessThanOrEqual(narrow.width, 320)
        XCTAssertGreaterThan(narrow.height, wide.height)
        manager.selectSeason("Season 12")
        XCTAssertEqual(manager.filteredEpisodesForSelectedSeason.first?.groupTitle, "Season 12")
    }
    #endif

    private func show(_ id: String) -> M3UItem {
        M3UItem(name: "Show \(id)", streamURL: URL(string: "https://fixture.invalid/provider/series/user/pass/\(id).mp4")!,
                contentType: .series, seriesID: id)
    }

    func testSeriesMetadataAndEpisodeParsingShareProviderResponse() throws {
        let data = Data("""
        {"info":{"name":"Provider Show","cover":"https://fixture.invalid/poster.jpg",
        "releaseDate":"2021-02-03","episode_run_time":"52","rating":"7.8",
        "genre":"Drama","plot":"Provider synopsis","cast":"Provider cast","director":"Provider director"},
        "episodes":{"2":[{"id":"42","episode_num":3,"title":"Episode title","container_extension":"mkv",
        "info":{"subtitles":[{"url":"subtitles/en.srt","language":"English"}]}}],
        "1":[{"id":41,"episode_num":1,"title":"First"},{"id":"../bad","title":"Invalid"}]}}
        """.utf8)
        let details = try MediaDetails.parse(data)
        XCTAssertEqual(details.title, "Provider Show")
        XCTAssertEqual(details.year, "2021")
        XCTAssertEqual(details.runtime, "52 min/ep")
        XCTAssertEqual(details.rating, "7.8")
        XCTAssertEqual(details.plot, "Provider synopsis")
        XCTAssertEqual(details.cast, "Provider cast")
        XCTAssertEqual(details.director, "Provider director")
        let episodes = try XtreamCodesManager.parseSeriesEpisodes(data,
            streamBase: URL(string: "https://fixture.invalid/provider/series/user/pass/")!, seriesID: "99")
        XCTAssertEqual(episodes.map(\.mediaID), ["41", "42"])
        XCTAssertEqual(episodes.last?.seasonNumber, 2)
        XCTAssertEqual(episodes.last?.episodeNumber, 3)
        XCTAssertEqual(episodes.last?.seriesID, "99")
        XCTAssertEqual(episodes.last?.streamURL.absoluteString, "https://fixture.invalid/provider/series/user/pass/42.mkv")
        XCTAssertEqual(episodes.last?.subtitleSources?.first?.url.absoluteString, "https://fixture.invalid/provider/subtitles/en.srt")
        XCTAssertThrowsError(try XtreamCodesManager.parseSeriesEpisodes(Data("{}".utf8), streamBase: show("99").streamURL.deletingLastPathComponent(), seriesID: "99"))
    }

    func testSeriesRequestUsesSelectedAccountAndSeriesIdentifier() async throws {
        let service = XtreamCodesManager()
        let requestedURL = await service.infoRequest(for: show("99"))
        let request = try XCTUnwrap(requestedURL)
        XCTAssertEqual(request.path, "/provider/player_api.php")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["action"], "get_series_info")
        XCTAssertEqual(query["series_id"], "99")
        XCTAssertEqual(query["username"], "user")
        XCTAssertEqual(query["password"], "pass")
        let subtitleRequest = await service.subtitleRequest(for: show("99"))
        XCTAssertNil(subtitleRequest, "Episode subtitles must not request movie metadata")
    }

    @MainActor func testLateResponseCannotReplaceNewSeriesAndStopClearsMetadata() async throws {
        let first = SeriesResponseGate(), second = SeriesResponseGate()
        defer { first.finish("Old"); second.finish("New") }
        var loader = LibraryLoader()
        loader.seriesDetails = { item in try await (item.seriesID == "1" ? first : second).wait() }
        let suite = "series-details-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop() }
        manager.fetchAndShowSeries(show("1"))
        try await waitUntil { first.started }
        manager.fetchAndShowSeries(show("2"))
        try await waitUntil { second.started }
        XCTAssertNil(manager.seriesDetails)
        second.finish("New")
        try await waitUntil { !manager.isLoadingEpisodes }
        XCTAssertEqual(manager.seriesDetails?.title, "New")
        first.finish("Old")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(manager.seriesDetails?.title, "New")
        manager.stop()
        XCTAssertNil(manager.seriesDetails)
    }

    @MainActor func testFailedRequestShowsErrorWithoutInventingMetadataOrEpisodes() async throws {
        var loader = LibraryLoader()
        loader.seriesDetails = { _ in throw XtreamCodesError.invalidResponse }
        let suite = "series-details-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop() }
        manager.fetchAndShowSeries(show("1"))
        try await waitUntil { !manager.isLoadingEpisodes }
        XCTAssertTrue(manager.seriesDetailsFailed)
        XCTAssertNil(manager.seriesDetails)
        XCTAssertTrue(manager.seriesEpisodes.isEmpty)
        XCTAssertNil(manager.player)
    }

    func testM3UHasNoInventedMetadataAndKeepsActualStreamPlayable() async throws {
        let item = M3UItem(name: "M3U Episode", streamURL: URL(string: "https://fixture.invalid/episode.mp4")!, contentType: .series)
        let result = try await XtreamCodesManager().fetchSeriesDetails(for: item)
        XCTAssertNil(result.details)
        XCTAssertEqual(result.episodes, [item])
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Series response did not settle")
    }
}

@MainActor private final class SeriesResponseGate {
    var started = false
    private var continuation: CheckedContinuation<SeriesDetails, Error>?
    func wait() async throws -> SeriesDetails {
        try await withCheckedThrowingContinuation { continuation = $0; started = true }
    }
    func finish(_ title: String) {
        var details = MediaDetails()
        details.title = title
        continuation?.resume(returning: SeriesDetails(details: details, episodes: []))
        continuation = nil
    }
}
