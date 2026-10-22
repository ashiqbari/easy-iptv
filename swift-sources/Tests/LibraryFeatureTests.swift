import XCTest
import SwiftUI
import AVFoundation
#if os(macOS)
import VLC
#endif
@testable import EasyIPTV

@MainActor
final class LibraryFeatureTests: XCTestCase {
    private func item(_ id: String, host: String = "provider.invalid", group: String = "News") -> M3UItem {
        M3UItem(name: id, groupTitle: group, streamURL: URL(string: "https://\(host)/live/user/password/\(id).m3u8")!, contentType: .live)
    }

    func testSavedSourcesDeduplicateRenameAndKeepSecretsOutOfDefaults() throws {
        let suite = "sources-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedSourceStore(defaults: defaults, secure: false)
        let account = SourceConnection.xtream(server: "https://provider.invalid", username: "private-user", password: "private-password")
        store.save(account)
        let id = try XCTUnwrap(store.activeID)
        store.rename(id, to: "My provider")
        store.save(account)
        XCTAssertEqual(store.sources.count, 1)
        XCTAssertEqual(store.sources.first?.name, "My provider")
        XCTAssertEqual(try store.connection(id), account)
        store.save(.playlist("https://second.invalid/get.php?username=other&password=secret"))
        XCTAssertEqual(store.sources.count, 2)
        XCTAssertNotEqual(store.activeID, id)
        let saved = String(decoding: try XCTUnwrap(defaults.data(forKey: "com.iptvplayer.sources.v1")), as: UTF8.self)
        for credential in ["private-user", "private-password", "username", "password", "get.php"] { XCTAssertFalse(saved.contains(credential)) }
        let restored = SavedSourceStore(defaults: defaults, secure: false)
        XCTAssertEqual(restored.sources, store.sources)
        XCTAssertEqual(restored.activeID, store.activeID)
        store.remove(id)
        XCTAssertEqual(store.sources.count, 1)
        XCTAssertThrowsError(try store.connection(id))
        store.remove(try XCTUnwrap(store.activeID))
        XCTAssertNil(store.activeID)
        XCTAssertTrue(store.sources.isEmpty)
    }

    func testSwitchingSourcesRejectsFailuresAndPreservesOldLibrary() async throws {
        let suite = "switch-source-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = item("first"), second = item("second", host: "second.invalid")
        var loader = LibraryLoader()
        loader.playlist = { url in
            if url.host == "broken.invalid" { throw URLError(.cannotConnectToHost) }
            return url.host == "second.invalid" ? [second] : [first]
        }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        await manager.loadPlaylist(from: "https://provider.invalid/list")
        let firstID = try XCTUnwrap(manager.sources.activeID)
        await manager.loadPlaylist(from: "https://second.invalid/list")
        let secondID = try XCTUnwrap(manager.sources.activeID)
        XCTAssertNotEqual(firstID, secondID)
        await manager.switchSource(firstID)
        XCTAssertEqual(manager.channels.map(\.id), [first.id])
        XCTAssertEqual(manager.sources.activeID, firstID)
        await manager.loadPlaylist(from: "https://broken.invalid/list")
        XCTAssertEqual(manager.channels.map(\.id), [first.id])
        XCTAssertEqual(manager.sources.activeID, firstID)
        XCTAssertEqual(manager.sources.sources.count, 2)
        manager.sources.remove(firstID)
        manager.currentChannel = first
        manager.catchupChannel = first
        await manager.switchSource(secondID)
        XCTAssertNil(manager.currentChannel, "Switching must stop the old source even after its saved connection was removed")
        XCTAssertNil(manager.catchupChannel)
        XCTAssertEqual(manager.channels.map(\.id), [second.id])
    }

    func testRefreshDoesNotResaveConnectionsOrRecreateRemovedSources() async throws {
        for useXtream in [false, true] {
            let suite = "refresh-source-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let channel = item("refresh")
            var loader = LibraryLoader()
            loader.playlist = { _ in [channel] }
            loader.live = { _, _, _ in [channel] }
            loader.movies = { _, _, _ in [] }
            loader.series = { _, _, _ in [] }
            let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
            defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
            if useXtream {
                await manager.loadXtream(serverURL: "https://provider.invalid", username: "user", password: "password")
            } else {
                await manager.loadPlaylist(from: "https://provider.invalid/list")
            }
            let activeID = try XCTUnwrap(manager.sources.activeID)
            let metadata = defaults.data(forKey: "com.iptvplayer.sources.v1")
            manager.sources.error = "Existing source status"
            await manager.refreshPlaylist()
            XCTAssertNil(manager.errorMessage)
            XCTAssertEqual(manager.channels.map(\.id), [channel.id])
            XCTAssertEqual(manager.sources.activeID, activeID)
            XCTAssertEqual(defaults.data(forKey: "com.iptvplayer.sources.v1"), metadata)
            XCTAssertEqual(manager.sources.error, "Existing source status", "Refreshing must not run saved-source writes")
            manager.sources.remove(activeID)
            await manager.refreshPlaylist()
            XCTAssertNil(manager.errorMessage)
            XCTAssertEqual(manager.channels.map(\.id), [channel.id])
            XCTAssertTrue(manager.sources.sources.isEmpty, "Refresh must not recreate a saved Keychain connection")
            XCTAssertNil(manager.sources.activeID)
        }
    }

    func testOrganizationPersistsHidingAndFavoriteOrderAndIgnoresLegacyGroups() async throws {
        let suite = "organization-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = item("first"), second = item("second"), other = item("other", host: "second.invalid", group: "Sports")
        var loader = LibraryLoader(); loader.playlist = { _ in [first, second, other] }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        await manager.loadPlaylist(from: "https://fixture.invalid/list")
        manager.toggleFavorite(first); manager.toggleFavorite(second)
        manager.moveFavorite(second, before: first)
        manager.selectedCategory = "Favorites"
        XCTAssertEqual(manager.filteredChannels.map(\.id), [second.id, first.id])
        manager.setChannelHidden(first, hidden: true)
        XCTAssertEqual(manager.filteredChannels.map(\.id), [second.id])
        XCTAssertFalse(manager.dashboardFavorites.contains { $0.id == first.id })
        manager.setChannelHidden(first, hidden: false)
        manager.setCategoryHidden(first, hidden: true)
        manager.selectedCategory = "All"
        XCTAssertEqual(manager.filteredChannels.map(\.id), [other.id], "Other categories must remain visible")
        manager.setCategoryHidden(first, hidden: false)
        XCTAssertEqual(manager.filteredChannels.count, 3)
        let data = try XCTUnwrap(defaults.data(forKey: "com.iptvplayer.organization.v1"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("password")); XCTAssertFalse(text.contains("provider.invalid"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["groups"] = [["id": UUID().uuidString, "name": "Weekend", "members": [ChannelOrganization.key(first)]]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "com.iptvplayer.organization.v1")
        let restored = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        await restored.loadPlaylist(from: "https://fixture.invalid/list")
        XCTAssertFalse(restored.categories.contains("Group · Weekend"))
        XCTAssertEqual(restored.filteredChannels.count, 3)
        XCTAssertEqual(restored.organization.favoriteOrder, manager.organization.favoriteOrder)
        restored.stop(); restored.libraryPersistence.invalidatePendingWrites()
    }

    func testBulkOrganizationOnlyChangesSuppliedItemsAndCategories() async throws {
        let suite = "bulk-organization-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let first = item("first"), second = item("second", host: "second.invalid")
        let other = item("other", group: "Sports")
        let movie = M3UItem(name: "Movie", groupTitle: "News", streamURL: URL(string: "https://provider.invalid/movie/1.mp4")!, contentType: .movie)
        let catalog = [first, second, other, movie]
        var loader = LibraryLoader(); loader.playlist = { _ in catalog }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer {
            manager.stop(); manager.libraryPersistence.invalidatePendingWrites()
            defaults.removePersistentDomain(forName: suite)
        }
        await manager.loadPlaylist(from: "https://fixture.invalid/list")
        manager.toggleFavorite(first); manager.toggleFavorite(second)
        manager.moveFavorite(second, before: first)
        manager.recentlyWatchedStore.record(first)
        let favoriteOrder = manager.organization.favoriteOrder
        manager.setChannelsHidden([other, movie], hidden: true)
        manager.setChannelsHidden([first, second], hidden: true)
        XCTAssertTrue(manager.filteredChannels.isEmpty)
        manager.setChannelsHidden([first, second], hidden: false)
        XCTAssertEqual(manager.filteredChannels.map(\.id), [first.id, second.id])
        XCTAssertEqual(manager.organization.hidden, Set([other, movie].map(manager.organizationKey)))
        manager.setCategoriesHidden([other, movie], hidden: true)
        manager.setCategoriesHidden([first], hidden: true)
        XCTAssertTrue(manager.filteredChannels.isEmpty, "Both CDN hosts in News must be hidden")
        manager.setCategoriesHidden([first], hidden: false)
        XCTAssertEqual(manager.filteredChannels.map(\.id), [first.id, second.id])
        XCTAssertEqual(manager.organization.hiddenCategories, Set([other, movie].map(manager.organizationCategoryKey)))
        XCTAssertTrue(manager.isFavorite(first)); XCTAssertTrue(manager.isFavorite(second))
        XCTAssertEqual(manager.organization.favoriteOrder, favoriteOrder)
        XCTAssertEqual(manager.recentlyWatchedStore.records.count, 1)
        let data = try XCTUnwrap(defaults.data(forKey: "com.iptvplayer.organization.v1"))
        let saved = try JSONDecoder().decode(ChannelOrganization.self, from: data)
        XCTAssertEqual(saved.hidden, manager.organization.hidden)
        XCTAssertEqual(saved.hiddenCategories, manager.organization.hiddenCategories)
        manager.setChannelsHidden(catalog, hidden: false)
        manager.setCategoriesHidden(manager.organizationCategories(in: .live), hidden: false)
        XCTAssertEqual(manager.filteredChannels.map(\.id), [first.id, second.id, other.id])
        manager.selectedSection = .movie
        XCTAssertTrue(manager.filteredChannels.isEmpty, "Bulk live selection must preserve movie visibility")
    }

    func testLargeLibraryOrganizationTogglesStayResponsiveAcrossProviders() async throws {
        let suite = "organization-performance-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = (0..<20_000).map { index in
            item("channel-\(index)", host: index.isMultiple(of: 2) ? "first.invalid" : "second.invalid", group: "Category \(index / 200)")
        }
        var loader = LibraryLoader(); loader.playlist = { _ in catalog }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        await manager.loadPlaylist(from: "https://fixture.invalid/list")
        XCTAssertEqual(manager.organizationCategories(in: .live).count, 100)
        let group = catalog[0]
        let started = Date()
        for _ in 0..<5 {
            manager.setCategoryHidden(group, hidden: true)
            XCTAssertEqual(manager.filteredChannels.count, 19_800)
            XCTAssertEqual(manager.organization.hiddenCategories.count, 2, "Both CDN hosts in the category must be hidden")
            manager.setCategoryHidden(group, hidden: false)
            XCTAssertEqual(manager.filteredChannels.count, 20_000)
        }
        manager.setChannelHidden(catalog[1], hidden: true)
        XCTAssertEqual(manager.filteredChannels.count, 19_999)
        manager.setChannelHidden(catalog[1], hidden: false)
        let elapsed = Date().timeIntervalSince(started)
        print("Organization: 12 visibility toggles across 20,000 channels took \(elapsed)s")
        XCTAssertLessThan(elapsed, 2, "Checkboxes must not rehash the entire catalog on each click")
        for channel in catalog.prefix(4) { XCTAssertEqual(manager.organizationKey(channel), ChannelOrganization.key(channel)) }
        for channel in catalog.prefix(2) { XCTAssertEqual(manager.organizationCategoryKey(channel), ChannelOrganization.categoryKey(channel)) }
        var organization = ChannelOrganization()
        organization.favoriteOrder = [ChannelOrganization.key(catalog[2])]
        XCTAssertEqual(organization.orderedFavorites(Array(catalog.prefix(4))).map(\.id), [catalog[2], catalog[0], catalog[1], catalog[3]].map(\.id))
    }

    func testCatchupURLRetainsEscapedCredentialsAndValidatesArchiveWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let program = GuideProgram(title: "News", description: "", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        let channel = M3UItem(name: "News", streamURL: URL(string: "https://provider.invalid:8443/iptv/live/user%2Fname/p%40ss/42.m3u8")!, contentType: .live)
        let info = CatchupInfo(mode: "xc", days: 7, source: nil, timezone: "Europe/Helsinki")
        let url = try XCTUnwrap(info.url(for: channel, program: program, now: now))
        XCTAssertTrue(url.absoluteString.contains("/iptv/timeshift/user%2Fname/p%40ss/60/"))
        XCTAssertTrue(url.absoluteString.hasSuffix("/42.m3u8"))
        XCTAssertEqual(url.port, 8443)
        XCTAssertNil(info.url(for: channel, program: GuideProgram(title: "Future", description: "", start: now, end: now.addingTimeInterval(100)), now: now))
        XCTAssertNil(info.url(for: channel, program: GuideProgram(title: "Old", description: "", start: now.addingTimeInterval(-900000), end: now.addingTimeInterval(-899000)), now: now))
        XCTAssertNil(CatchupInfo(mode: "default", days: 7, source: "file:///tmp/{utc}", timezone: nil).url(for: channel, program: program, now: now))
        XCTAssertNil(CatchupInfo(mode: "default", days: 7, source: "https://provider.invalid/{unknown}", timezone: nil).url(for: channel, program: program, now: now))
        let append = CatchupInfo(mode: "append", days: 7, source: "?utc={utc}&duration={duration}", timezone: nil)
        XCTAssertEqual(append.url(for: channel, program: program, now: now)?.query, "utc=1799992800&duration=3600")
    }

    func testM3UCatchupMetadataAndOldCachedItemsDecode() async throws {
        let playlist = """
        #EXTM3U
        #EXTINF:-1 catchup="default" catchup-days="3" catchup-source="https://provider.invalid/archive/{utc}/{duration}",Archive
        https://provider.invalid/live/user/pass/1.m3u8
        #EXTINF:-1,Plain
        https://provider.invalid/live/user/pass/2.m3u8
        """
        let result = try await M3UParser().parse(string: playlist)
        XCTAssertEqual(result.first?.catchup?.days, 3)
        XCTAssertNil(result.last?.catchup)
        let encoded = try JSONEncoder().encode(item("old"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "catchup"); object.removeValue(forKey: "isCatchup")
        XCTAssertNil(try JSONDecoder().decode(M3UItem.self, from: JSONSerialization.data(withJSONObject: object)).catchup)
        let raw = Data(#"{"stream_id":42,"name":"Archive","tv_archive":"1","tv_archive_duration":"7"}"#.utf8)
        let stream = try JSONDecoder().decode(XtreamLiveStream.self, from: raw)
        XCTAssertEqual(stream.tvArchive, 1); XCTAssertEqual(stream.tvArchiveDuration, 7)
    }

    func testCatchupLoadsRealPastListingsAndUsesProviderTimezone() async throws {
        let data = Data("""
        <tv>
          <programme channel="news" start="20261010080000 +0000" stop="20261010090000 +0000"><title>Past news</title></programme>
          <programme channel="other" start="20261010080000 +0000" stop="20261010090000 +0000"><title>Wrong channel</title></programme>
        </tv>
        """.utf8)
        let info = CatchupInfo(mode: "xc", days: 7, source: nil, timezone: "Europe/Helsinki")
        let channel = M3UItem(name: "News", streamURL: URL(string: "https://provider.invalid/live/u/p/42.m3u8")!,
            tvgID: "news", contentType: .live, guideURL: URL(string: "https://provider.invalid/guide.xml"), catchup: info)
        let guide = TVGuide(download: { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("past-guide-\(UUID()).xml")
            try data.write(to: file); return file
        })
        let programs = try await guide.loadCatchup(for: channel)
        XCTAssertEqual(programs.map(\.title), ["Past news"])
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z"))
        let program = try XCTUnwrap(programs.first)
        let url = try XCTUnwrap(info.url(for: channel, program: program, now: now))
        XCTAssertTrue(url.absoluteString.contains("/60/2026-10-10:11-00/42.m3u8"))
    }

    func testCatchupPlaybackDoesNotChangeLibraryHistoryAndCanReturnLive() {
        let suite = "catchup-play-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop() }
        let channel = M3UItem(name: "News", streamURL: URL(string: "https://127.0.0.1:1/live/u/p/42.m3u8")!,
            contentType: .live, catchup: CatchupInfo(mode: "xc", days: 7, source: nil, timezone: "UTC"))
        let now = Date()
        let program = GuideProgram(title: "Past News", description: "", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        manager.playCatchup(channel, program: program)
        XCTAssertEqual(manager.catchupOrigin?.id, channel.id)
        XCTAssertEqual(manager.playbackBadge, "Catch-up TV")
        XCTAssertEqual(manager.currentChannel?.isCatchup, true)
        XCTAssertFalse(manager.isViewingMovieDetails)
        XCTAssertTrue(manager.recentlyWatchedStore.records.isEmpty)
        manager.returnToLive()
        XCTAssertNil(manager.catchupOrigin)
        XCTAssertEqual(manager.currentChannel?.id, channel.id)
    }

    func testAudioResetAndStaleSelectionAreSafe() async throws {
        let controller = AudioTrackController()
        let url = try await alternateAudioMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let playerItem = AVPlayerItem(url: url)
        controller.configure(playerItem)
        controller.refresh()
        for _ in 0..<100 where controller.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.tracks.count, 2)
        let track = try XCTUnwrap(controller.tracks.last)
        controller.select(track.id)
        XCTAssertEqual(controller.selectedID, track.id)
        let loadedGroup = try await playerItem.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loadedGroup)
        guard case .av(let option) = track.source else { return XCTFail("Expected an AVKit audio track") }
        XCTAssertEqual(playerItem.currentMediaSelection.selectedMediaOption(in: group), option)
        controller.configure(AVPlayerItem(url: URL(fileURLWithPath: "/tmp/nonexistent-audio-fixture")))
        XCTAssertTrue(controller.tracks.isEmpty); XCTAssertNil(controller.selectedID)
        controller.select("av:0")
        XCTAssertNil(controller.selectedID)
        controller.reset()
        XCTAssertFalse(controller.showingMenu)
    }

    #if os(macOS)
    func testVLCDiscoversAndSelectsRealAlternateAudio() async throws {
        let url = try await alternateAudioMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = VLCMediaPlayer(library: VLCLibrary(options: ["--no-volume-save", "--no-video"]))
        player.media = VLCMedia(url: url)
        let controller = AudioTrackController()
        controller.configure(player)
        defer { controller.reset(); VLCPlaybackRetirement.shared.retire(player) }
        player.play()
        for _ in 0..<200 {
            controller.refresh()
            if controller.tracks.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.tracks.count, 2)
        let track = try XCTUnwrap(controller.tracks.last)
        controller.select(track.id)
        guard case .vlc(let index) = track.source else { return XCTFail("Expected a VLC audio track") }
        XCTAssertEqual(player.currentAudioTrackIndex, index)
        XCTAssertEqual(controller.selectedID, track.id)
    }
    #endif

    func testRecoveryIsBoundedAndStopsWhenPausedOrReplaced() async throws {
        XCTAssertEqual((0..<3).compactMap { IPTVPlayerManager.recoveryDelay(after: $0) }, [2_000_000_000, 4_000_000_000, 8_000_000_000])
        XCTAssertNil(IPTVPlayerManager.recoveryDelay(after: 3))
        XCTAssertNil(IPTVPlayerManager.recoveryDelay(after: -1))
        let suite = "recovery-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop() }
        let stream = M3UItem(name: "Retry", streamURL: URL(string: "https://127.0.0.1:1/unavailable.m3u8")!, contentType: .live)
        manager.playDirectStream(stream)
        manager.recoverStream()
        XCTAssertEqual(manager.recoveryMessage, "Reconnecting… attempt 1 of 3")
        manager.togglePlayPause()
        XCTAssertNil(manager.recoveryMessage)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertEqual(manager.recoveryAttempts, 0)
        XCTAssertFalse(manager.isPlaying)
        manager.playDirectStream(stream)
        manager.recoverStream()
        manager.stop()
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertNil(manager.currentChannel); XCTAssertNil(manager.recoveryMessage)
        XCTAssertEqual(manager.recoveryAttempts, 0)
        manager.playDirectStream(stream)
        manager.recoverStream()
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertGreaterThanOrEqual(manager.recoveryAttempts, 1, "An interrupted stream must actually attempt to reconnect")
        manager.stop()
    }
}
