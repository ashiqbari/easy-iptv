import XCTest
#if os(macOS)
import Darwin
#endif
@testable import EasyIPTV

@MainActor
func waitForLibraryFilter(_ manager: IPTVPlayerManager, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while manager.isFilteringLibrary && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertFalse(manager.isFilteringLibrary, "Library filtering timed out")
}

@MainActor
final class LibrarySortingTests: XCTestCase {
    private func item(_ name: String, group: String = "News", type: M3UItem.ContentType = .live,
                      addedAt: Date? = nil, rating: Double? = nil) -> M3UItem {
        M3UItem(name: name, groupTitle: group, streamURL: URL(string: "https://fixture.invalid/\(UUID()).m3u8")!, contentType: type,
                addedAt: addedAt, rating: rating)
    }

    func testNaturalStableSortingAndCombinedFiltersPreserveProviderOrder() async throws {
        let suite = "sorting-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = [item("Channel 10"), item("Café", group: "Sports"), item("Channel 2"), item("Channel 2"),
                       item("Movie", type: .movie), item("Series", type: .series)]
        var loader = LibraryLoader(); loader.playlist = { _ in catalog }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        await manager.loadPlaylist(from: "https://fixture.invalid/list")
        XCTAssertEqual(manager.filteredChannels.map(\.id), Array(catalog.prefix(4)).map(\.id))
        manager.librarySortOrder = .nameAscending
        XCTAssertEqual(manager.filteredChannels.map(\.id), [catalog[1], catalog[2], catalog[3], catalog[0]].map(\.id))
        manager.librarySortOrder = .nameDescending
        XCTAssertEqual(manager.filteredChannels.map(\.id), [catalog[0], catalog[2], catalog[3], catalog[1]].map(\.id))
        manager.toggleFavorite(catalog[0]); manager.toggleFavorite(catalog[2])
        manager.favoritesOnly = true
        manager.selectedCategory = "News"
        XCTAssertEqual(manager.filteredChannels.map(\.id), [catalog[0], catalog[2]].map(\.id))
        manager.searchText = "channel 2"
        XCTAssertEqual(manager.filteredChannels.map(\.id), [catalog[2].id])
        manager.setChannelHidden(catalog[2], hidden: true)
        XCTAssertTrue(manager.filteredChannels.isEmpty)
        manager.setChannelHidden(catalog[2], hidden: false)
        manager.searchText = ""; manager.favoritesOnly = false; manager.librarySortOrder = .provider
        manager.selectedCategory = "All"
        XCTAssertEqual(manager.filteredChannels.map(\.id), Array(catalog.prefix(4)).map(\.id))
        manager.searchText = "cafe"
        XCTAssertEqual(manager.filteredChannels.map(\.id), [catalog[1].id])
        manager.searchText = ""; manager.selectedSection = .movie
        XCTAssertEqual(manager.filteredChannels.map(\.id), [catalog[4].id])
        manager.selectedSection = .series
        XCTAssertEqual(manager.filteredChannels.map(\.id), [catalog[5].id])
    }

    func testMetadataSortingFiltersAndMissingValues() async throws {
        let suite = "metadata-sort-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        func movie(_ name: String, days: Double?, rating: Double?) -> M3UItem {
            M3UItem(name: name, streamURL: URL(string: "https://fixture.invalid/\(name).mp4")!, contentType: .movie,
                    addedAt: days.map { now.addingTimeInterval(-$0 * 86_400) }, rating: rating)
        }
        let catalog = [movie("Old", days: 50, rating: 9), movie("Missing", days: nil, rating: nil),
                       movie("New", days: 1, rating: 7.5), movie("Newest", days: 0, rating: 8),
                       movie("Tie", days: 0, rating: 8), movie("Future", days: -2, rating: nil)]
        var loader = LibraryLoader(); loader.playlist = { _ in catalog }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        manager.selectedSection = .movie
        await manager.loadPlaylist(from: "https://fixture.invalid/list")
        XCTAssertTrue(manager.hasCatalogDates); XCTAssertTrue(manager.hasRatings)
        manager.librarySortOrder = .recentlyAdded
        XCTAssertEqual(manager.filteredChannels.map(\.name), ["Future", "Newest", "Tie", "New", "Old", "Missing"])
        manager.librarySortOrder = .highestRated
        XCTAssertEqual(manager.filteredChannels.map(\.name), ["Old", "Newest", "Tie", "New", "Missing", "Future"])
        manager.recentlyAddedOnly = true; manager.minimumRating = 8
        XCTAssertEqual(manager.filteredChannels.map(\.name), ["Newest", "Tie"])
        manager.toggleFavorite(catalog[3]); manager.favoritesOnly = true
        XCTAssertEqual(manager.filteredChannels.map(\.name), ["Newest"])
        let restored = IPTVPlayerManager(progressDefaults: defaults)
        defer { restored.stop() }
        XCTAssertTrue(restored.recentlyAddedOnly); XCTAssertEqual(restored.minimumRating, 8)
        manager.resetLibraryFilters()
        XCTAssertFalse(manager.libraryFiltersActive)
        XCTAssertEqual(manager.filteredChannels.map(\.id), catalog.map(\.id))
        manager.selectedSection = .live
        XCTAssertFalse(manager.hasCatalogDates); XCTAssertFalse(manager.hasRatings)
    }

    func testProviderMetadataAcceptsNumbersAndStringsAndOldCache() throws {
        let decoder = JSONDecoder()
        let vod = try decoder.decode(XtreamVodStream.self, from: Data(#"{"stream_id":1,"name":"Movie","added":1800000000,"rating":"7.6"}"#.utf8))
        XCTAssertEqual(vod.addedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(vod.rating, 7.6)
        let series = try decoder.decode(XtreamSeriesItem.self, from: Data(#"{"series_id":1,"name":"Series","added":"1800000000","rating":"0","rating_5based":4.2}"#.utf8))
        XCTAssertEqual(series.addedAt, vod.addedAt); XCTAssertEqual(series.rating, 8.4)
        let live = try decoder.decode(XtreamLiveStream.self, from: Data(#"{"stream_id":1,"added":1800000000}"#.utf8))
        XCTAssertEqual(live.addedAt, vod.addedAt)
        let invalid = try decoder.decode(XtreamVodStream.self, from: Data(#"{"stream_id":1,"rating":"NaN","rating_5based":7,"added":"-12"}"#.utf8))
        XCTAssertNil(invalid.rating); XCTAssertNil(invalid.addedAt)
        let old = try decoder.decode(M3UItem.self, from: Data(#"{"id":"742579AF-9871-4D57-9ADB-62FF7A08DD49","name":"Old cache","groupTitle":"News","streamURL":"https://fixture.invalid/1","isFavorite":false,"contentType":"Live TV"}"#.utf8))
        XCTAssertNil(old.addedAt); XCTAssertNil(old.rating)
        let rated = M3UItem(name: "Rated", streamURL: old.streamURL, addedAt: vod.addedAt, rating: vod.rating)
        let restored = try decoder.decode(M3UItem.self, from: JSONEncoder().encode(rated))
        XCTAssertEqual(restored.addedAt, rated.addedAt); XCTAssertEqual(restored.rating, rated.rating)
    }

    func testRefreshReloadsAllCatalogsAndUsesSeriesUpdateDates() async throws {
        let suite = "refresh-metadata-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let json = try JSONSerialization.data(withJSONObject: ["series_id": 7, "name": "Updated series",
            "last_modified": Int(now.addingTimeInterval(-86_400).timeIntervalSince1970), "rating": "8.1"] as [String: Any])
        let decoded = try JSONDecoder().decode(XtreamSeriesItem.self, from: json)
        XCTAssertNil(decoded.addedAt)
        XCTAssertNotNil(decoded.updatedAt)
        let updated = M3UItem(name: decoded.name, streamURL: URL(string: "https://fixture.invalid/series/7.mp4")!, contentType: .series,
                              addedAt: decoded.addedAt, updatedAt: decoded.updatedAt, rating: decoded.rating)
        let older = M3UItem(name: "Old series", streamURL: URL(string: "https://fixture.invalid/series/8.mp4")!, contentType: .series,
                            addedAt: now.addingTimeInterval(-60 * 86_400), updatedAt: now, rating: 9)
        let calls = CatalogRefreshCalls()
        let live = item("Live"), movie = item("Movie", type: .movie)
        var loader = LibraryLoader()
        loader.live = { _, _, _ in await calls.record(.live); return [live] }
        loader.movies = { _, _, _ in await calls.record(.movie); return [movie] }
        loader.series = { _, _, _ in await calls.record(.series); return [older, updated] }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        for refresh in [false, true] {
            if refresh { await manager.refreshPlaylist() }
            else { await manager.loadXtream(serverURL: "https://fixture.invalid", username: "user", password: "password") }
            for _ in 0..<200 {
                if manager.channels.count == 4 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(manager.channels.count, 4, "Refresh must reload live, movie, and series catalogs")
            let counts = await calls.snapshot()
            for section in M3UItem.ContentType.allCases { XCTAssertEqual(counts[section], refresh ? 2 : 1) }
            manager.selectedSection = .series
            XCTAssertTrue(manager.hasCatalogDates)
            XCTAssertTrue(manager.hasRatings)
            manager.librarySortOrder = .recentlyAdded
            XCTAssertEqual(manager.filteredChannels.map(\.id), [updated.id, older.id], "A real added date must take precedence over a last update")
            manager.recentlyAddedOnly = true
            XCTAssertEqual(manager.filteredChannels.map(\.id), [updated.id])
            manager.recentlyAddedOnly = false
        }
        let restored = try JSONDecoder().decode(M3UItem.self, from: JSONEncoder().encode(updated))
        XCTAssertNil(restored.addedAt)
        XCTAssertEqual(restored.updatedAt, updated.updatedAt)
        XCTAssertEqual(restored.catalogDate, updated.updatedAt)
        XCTAssertEqual(LibrarySortOrder.recentlyAdded.title(for: .series), "Recently added / updated")
    }

    func testDefaultOrderKeepsManualFavoritesAndPreferencesPersist() async throws {
        let suite = "sort-settings-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = [item("Alpha"), item("Bravo")]
        var loader = LibraryLoader(); loader.playlist = { _ in catalog }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        await manager.loadPlaylist(from: "https://fixture.invalid/list")
        for channel in catalog { manager.toggleFavorite(channel) }
        manager.moveFavorite(catalog[1], before: catalog[0]); manager.selectedCategory = "Favorites"
        XCTAssertEqual(manager.filteredChannels.map(\.id), catalog.reversed().map(\.id))
        manager.librarySortOrder = .nameAscending
        XCTAssertEqual(manager.filteredChannels.map(\.id), catalog.reversed().map(\.id))
        manager.librarySortOrder = .provider
        XCTAssertEqual(manager.filteredChannels.map(\.id), catalog.reversed().map(\.id))
        manager.librarySortOrder = .nameDescending; manager.favoritesOnly = true
        let restored = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { restored.stop(); restored.libraryPersistence.invalidatePendingWrites() }
        XCTAssertEqual(restored.librarySortOrder, .nameDescending)
        XCTAssertTrue(restored.favoritesOnly)
        defaults.set("unknown", forKey: "com.iptvplayer.librarySort")
        let fallback = IPTVPlayerManager(progressDefaults: defaults)
        defer { fallback.stop() }
        XCTAssertEqual(fallback.librarySortOrder, .provider)
    }

    func testFavoritesIgnoreLibraryFiltersAndSortAcrossSections() async {
        let suite = "favorites-filters-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let catalog = M3UItem.ContentType.allCases.flatMap { type in
            [item("Alpha", type: type), item("Bravo", type: type), item("Not favorite", type: type)]
        }
        var loader = LibraryLoader(); loader.playlist = { _ in catalog }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer {
            manager.stop(); manager.libraryPersistence.invalidatePendingWrites()
            defaults.removePersistentDomain(forName: suite)
        }
        await manager.loadPlaylist(from: "https://fixture.invalid/list")
        for type in M3UItem.ContentType.allCases {
            let items = catalog.filter { $0.contentType == type }
            manager.toggleFavorite(items[0]); manager.toggleFavorite(items[1])
            manager.moveFavorite(items[1], before: items[0])
            manager.selectedSection = type
            manager.favoritesOnly = true
            manager.recentlyAddedOnly = true
            manager.minimumRating = 9
            for category in ["Favorites", "★ Favorites"] {
                manager.selectedCategory = category
                for order in LibrarySortOrder.allCases {
                    manager.librarySortOrder = order
                    XCTAssertEqual(manager.filteredChannels.map(\.id), [items[1].id, items[0].id])
                }
                manager.searchText = "Alpha"
                XCTAssertEqual(manager.filteredChannels.map(\.id), [items[0].id])
                manager.searchText = ""
            }
            manager.selectedCategory = "All"
            XCTAssertTrue(manager.filteredChannels.isEmpty)
            XCTAssertTrue(manager.favoritesOnly)
            XCTAssertTrue(manager.recentlyAddedOnly)
            XCTAssertEqual(manager.minimumRating, 9)
            XCTAssertEqual(manager.librarySortOrder, LibrarySortOrder.allCases.last)
        }
    }

    func testLargeLibrarySortSearchCancellationAndPlaybackStayResponsive() async throws {
        let suite = "sort-large-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let catalog = (0..<100_000).reversed().map { index in
            item("Channel \(index)", addedAt: now.addingTimeInterval(-Double(index % 90) * 86_400), rating: Double(index % 10 + 1))
        }
        var loader = LibraryLoader(); loader.playlist = { _ in catalog }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        await manager.loadPlaylist(from: "https://fixture.invalid/list")
        let media = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: media) }
        manager.playAVKitFixture(M3UItem(name: "Playback", streamURL: media, contentType: .movie))
        let player = try XCTUnwrap(manager.player)
        #if os(macOS)
        var beforeSort = rusage()
        getrusage(RUSAGE_SELF, &beforeSort)
        #endif
        let started = Date()
        manager.librarySortOrder = .nameAscending
        XCTAssertTrue(manager.isFilteringLibrary)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "Sorting must leave the main actor free for playback")
        try await waitForLibraryFilter(manager)
        XCTAssertEqual(manager.filteredChannels.first?.name, "Channel 0")
        XCTAssertEqual(manager.filteredChannels.last?.name, "Channel 99999")
        print("Library: sorting 100,000 channels took \(Date().timeIntervalSince(started))s")
        #if os(macOS)
        var afterSort = rusage()
        getrusage(RUSAGE_SELF, &afterSort)
        print("Library: additional process peak RSS during sort: \(Double(afterSort.ru_maxrss - beforeSort.ru_maxrss) / 1_048_576) MiB")
        #endif
        let metadataStarted = Date()
        manager.librarySortOrder = .highestRated
        try await waitForLibraryFilter(manager)
        XCTAssertEqual(manager.filteredChannels.first?.rating, 10)
        XCTAssertEqual(manager.filteredChannels.last?.rating, 1)
        manager.minimumRating = 8; manager.recentlyAddedOnly = true
        try await waitForLibraryFilter(manager)
        XCTAssertFalse(manager.filteredChannels.isEmpty)
        XCTAssertTrue(manager.filteredChannels.allSatisfy { ($0.rating ?? 0) >= 8 && ($0.addedAt ?? .distantPast) >= now.addingTimeInterval(-30 * 86_400) })
        print("Library: rating sort plus recent/rating filters on 100,000 channels took \(Date().timeIntervalSince(metadataStarted))s")
        manager.resetLibraryFilters()
        manager.searchText = "Channel 99999"
        manager.searchText = "Channel 12345"
        try await waitForLibraryFilter(manager)
        XCTAssertEqual(manager.filteredChannels.map(\.name), ["Channel 12345"])
        manager.searchText = "Channel 99999"
        manager.selectedSection = .movie
        XCTAssertTrue(manager.filteredChannels.isEmpty)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(manager.filteredChannels.isEmpty, "Old searches must not overwrite a different section")
        XCTAssertTrue(manager.player === player)
        manager.searchText = ""; manager.selectedSection = .live
        manager.librarySortOrder = .provider
        XCTAssertEqual(manager.filteredChannels.map(\.id), catalog.map(\.id))
        XCTAssertFalse(manager.isFilteringLibrary)
        manager.librarySortOrder = .nameDescending
        manager.clearAllData()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(manager.filteredChannels.isEmpty, "An old sort must not restore a cleared library")
        XCTAssertFalse(manager.isFilteringLibrary)
    }
}

private actor CatalogRefreshCalls {
    private var counts: [M3UItem.ContentType: Int] = [:]
    func record(_ section: M3UItem.ContentType) { counts[section, default: 0] += 1 }
    func snapshot() -> [M3UItem.ContentType: Int] { counts }
}
