import XCTest
@testable import EasyIPTV

final class SeriesDetailsTests: XCTestCase {
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
