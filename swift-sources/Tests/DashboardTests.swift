import XCTest
import SwiftUI
#if os(macOS)
import AppKit
import VLC
#endif
@testable import EasyIPTV

@MainActor
final class DashboardTests: XCTestCase {
    func testHomeLoadsWithoutAutoplayAndResolvesCurrentLibraryHistory() async {
        let suite = "dashboard-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = item("Movie", type: .movie)
        let completed = item("Completed", type: .movie)
        let show = item("Series", type: .series)
        let episode = item("Episode", type: .series)
        let live = item("Live", type: .live)
        let missing = item("Removed", type: .movie)
        var loader = LibraryLoader()
        loader.playlist = { _ in [movie, completed, show, live] }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        manager.recentlyWatchedStore.record(missing)
        manager.recentlyWatchedStore.record(movie)
        manager.recentlyWatchedStore.record(completed)
        manager.recentlyWatchedStore.record(episode, series: show)
        manager.recentlyWatchedStore.record(live)
        manager.progressStore.save(item: missing, position: 100, duration: 1000)
        manager.progressStore.save(item: movie, position: 120, duration: 1000)
        manager.progressStore.save(item: completed, position: 999, duration: 1000)
        manager.progressStore.save(item: episode, position: 240, duration: 1000)
        await manager.loadPlaylist(from: "https://fixture.invalid/playlist")
        XCTAssertTrue(manager.showingDashboard)
        XCTAssertNil(manager.currentChannel)
        XCTAssertNil(manager.player)
        XCTAssertEqual(manager.dashboardCounts, [.live: 1, .movie: 2, .series: 1])
        XCTAssertEqual(manager.dashboardContinueWatching.map(\.item.id), [show.id, movie.id])
        XCTAssertEqual(manager.dashboardContinueWatching.first?.progress.position, 240)
        XCTAssertEqual(manager.dashboardRecentChannels.map(\.id), [live.id])
        manager.toggleFavorite(live)
        XCTAssertEqual(manager.dashboardFavorites.map(\.id), [live.id])
        manager.toggleFavorite(live)
        XCTAssertTrue(manager.dashboardFavorites.isEmpty)
        manager.searchText = "old search"
        manager.browse(.movie)
        XCTAssertFalse(manager.showingDashboard)
        XCTAssertEqual(manager.selectedSection, .movie)
        XCTAssertEqual(manager.selectedCategory, "All")
        XCTAssertEqual(manager.searchText, "")
        manager.showingDashboard = true
        manager.playChannel(movie)
        XCTAssertFalse(manager.showingDashboard)
        XCTAssertTrue(manager.isViewingMovieDetails)
        manager.clearAllData()
        XCTAssertTrue(manager.showingDashboard)
        XCTAssertTrue(manager.dashboardContinueWatching.isEmpty)
        XCTAssertTrue(manager.dashboardRecentChannels.isEmpty)
        XCTAssertTrue(manager.dashboardCounts.isEmpty)
    }

    func testDashboardItemsRestoreSectionCategoryAndVisibleTarget() async throws {
        let suite = "dashboard-routes-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let live = M3UItem(name: "News channel", groupTitle: "News", streamURL: URL(fileURLWithPath: "/private/tmp/dashboard-live.mov"), contentType: .live)
        let movie = M3UItem(name: "Movie", groupTitle: "Action", streamURL: URL(fileURLWithPath: "/private/tmp/dashboard-movie.mov"), contentType: .movie)
        let show = M3UItem(name: "Show", groupTitle: "Comedy", streamURL: URL(fileURLWithPath: "/private/tmp/dashboard-show.mov"), contentType: .series)
        var loader = LibraryLoader()
        loader.playlist = { _ in [live, movie, show] }
        loader.seriesDetails = { _ in SeriesDetails(details: nil, episodes: []) }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites(); defaults.removePersistentDomain(forName: suite) }
        await manager.loadPlaylist(from: "https://fixture.invalid/dashboard")
        manager.recentlyWatchedStore.record(live)
        for target in [live, movie, show] {
            manager.browse(target.contentType == .movie ? .series : .movie)
            manager.selectedCategory = "Recently Watched"
            manager.searchText = "unrelated search"
            manager.categorySearchText = "unrelated category"
            manager.favoritesOnly = true
            manager.recentlyAddedOnly = true
            manager.minimumRating = 9
            manager.showingDashboard = true
            manager.openDashboardItem(target, resume: target.contentType == .live)
            XCTAssertFalse(manager.showingDashboard)
            XCTAssertEqual(manager.selectedSection, target.contentType)
            XCTAssertEqual(manager.selectedCategory, target.displayGroup)
            XCTAssertEqual(manager.libraryNavigationTargetID, target.id)
            XCTAssertTrue(manager.filteredChannels.contains { $0.id == target.id })
            XCTAssertEqual(manager.searchText, "")
            XCTAssertEqual(manager.categorySearchText, "")
            XCTAssertFalse(manager.favoritesOnly)
            XCTAssertFalse(manager.recentlyAddedOnly)
            XCTAssertEqual(manager.minimumRating, 0)
            if target.contentType == .live { XCTAssertEqual(manager.currentChannel?.id, live.id) }
            if target.contentType == .movie { XCTAssertEqual(manager.movieOverviewItem?.id, movie.id) }
            if target.contentType == .series {
                XCTAssertTrue(manager.isViewingSeriesDetails)
                XCTAssertEqual(manager.seriesDetailsItem?.id, show.id)
                XCTAssertNil(manager.player, "Opening a favorite show must not autoplay an episode")
            }
            manager.stop()
        }
    }

    func testContinueWatchingSeriesAndBackRestoreShowCategoryWithoutReload() async throws {
        let suite = "dashboard-series-route-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let show = M3UItem(name: "Show", groupTitle: "Drama", streamURL: URL(fileURLWithPath: "/private/tmp/dashboard-series-overview.mov"), contentType: .series, seriesID: "42")
        let episode = M3UItem(name: "Episode", groupTitle: "Season 2", streamURL: url, contentType: .series, seriesID: "42", seasonNumber: 2, episodeNumber: 3)
        var loader = LibraryLoader()
        loader.playlist = { _ in [show] }
        loader.seriesDetails = { _ in SeriesDetails(details: nil, episodes: [episode]) }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        await manager.loadPlaylist(from: "https://fixture.invalid/dashboard")
        manager.recentlyWatchedStore.record(episode, series: show)
        manager.progressStore.save(item: episode, position: 120, duration: 300)
        manager.browse(.live)
        manager.showingDashboard = true
        manager.openDashboardItem(show, resume: true)
        try await waitForDashboard { manager.currentChannel?.id == episode.id }
        XCTAssertEqual(manager.selectedSection, .series)
        XCTAssertEqual(manager.selectedCategory, "Drama")
        XCTAssertEqual(manager.libraryNavigationTargetID, show.id)
        let player = try XCTUnwrap(manager.player)
        let playerItem = try XCTUnwrap(player.currentItem)
        #if os(macOS)
        let hosting = NSHostingView(rootView: ContentView(manager: manager))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        try await waitForDashboard { hosting.layoutSubtreeIfNeeded(); return manager.isPlaying && manager.pictureInPicture.isPossible }
        #endif
        manager.browse(.movie)
        manager.searchText = "stale search"
        manager.showingDashboard = true
        #if os(macOS)
        try await waitForDashboard { manager.pictureInPicture.isActive }
        #endif
        manager.pictureInPicture.restorePlayer()
        XCTAssertFalse(manager.pictureInPicture.isActive)
        XCTAssertFalse(manager.showingDashboard)
        XCTAssertFalse(manager.isViewingSeriesDetails)
        XCTAssertEqual(manager.selectedSection, .series)
        XCTAssertEqual(manager.selectedCategory, "Drama", "Use the show's category, not the episode's season")
        XCTAssertEqual(manager.selectedSeason, "Season 2")
        XCTAssertEqual(manager.libraryNavigationTargetID, show.id)
        XCTAssertEqual(manager.currentChannel?.id, episode.id)
        XCTAssertTrue(manager.player === player)
        XCTAssertTrue(player.currentItem === playerItem)
        manager.showingDashboard = true
        manager.openDashboardItem(show, resume: true)
        XCTAssertTrue(manager.player === player, "Continue watching the active show must return without a reload")
    }

    private func waitForDashboard(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Dashboard navigation did not finish")
        throw NSError(domain: "DashboardTests", code: 1)
    }

    func testDashboardDoesNotTruncateLargeSections() async {
        let suite = "dashboard-capacity-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let movies = (0..<20).map { item("Movie\($0)", type: .movie) }
        let live = (0..<20).map { item("Live\($0)", type: .live) }
        var loader = LibraryLoader()
        loader.playlist = { _ in movies + live }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        await manager.loadPlaylist(from: "https://fixture.invalid/playlist")
        for movie in movies {
            manager.recentlyWatchedStore.record(movie)
            manager.progressStore.save(item: movie, position: 60, duration: 1000)
        }
        for channel in live {
            manager.recentlyWatchedStore.record(channel)
            manager.toggleFavorite(channel)
        }
        XCTAssertEqual(manager.dashboardContinueWatching.count, 20)
        XCTAssertEqual(manager.dashboardRecentChannels.count, 20)
        XCTAssertEqual(manager.dashboardFavorites.count, 20)
    }

    private func item(_ name: String, type: M3UItem.ContentType) -> M3UItem {
        M3UItem(name: name, streamURL: URL(string: "https://fixture.invalid/\(name)")!, contentType: type)
    }

    #if os(macOS)
    func testShelfConstrainsItsViewportAndCanScrollToLastItem() async throws {
        let items = (0..<20).map { item("Channel\($0)", type: .live) }
        let hosting = NSHostingView(rootView: DashboardShelf(items: items, width: 320, cardWidth: 200) { item in
            Text(item.name).frame(width: 200, height: 100)
        })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        for _ in 0..<10 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 20_000_000) }
        func scrollView(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView($0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(hosting))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, 320)
        XCTAssertGreaterThan(document.bounds.width, 20 * 200)
        scroll.contentView.scroll(to: NSPoint(x: document.bounds.maxX - scroll.contentSize.width, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.documentVisibleRect.minX, 0)
        XCTAssertEqual(scroll.documentVisibleRect.maxX, document.bounds.maxX, accuracy: 1)
    }

    func testDashboardNavigationScrollsToTargetAfterAsyncFiltering() async throws {
        let suite = "dashboard-scroll-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let movies = (0..<1200).map { index in
            M3UItem(name: "Movie \(index)", groupTitle: "Action", streamURL: URL(fileURLWithPath: "/private/tmp/dashboard-scroll-\(index).mov"), contentType: .movie)
        }
        var loader = LibraryLoader()
        loader.playlist = { _ in movies }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites(); defaults.removePersistentDomain(forName: suite) }
        await manager.loadPlaylist(from: "https://fixture.invalid/dashboard")
        manager.librarySortOrder = .nameAscending
        manager.openDashboardItem(movies[1100])
        let hosting = NSHostingView(rootView: ChannelListView(manager: manager))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func findScroll(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        try await waitForDashboard {
            hosting.layoutSubtreeIfNeeded()
            return !manager.isFilteringLibrary && (findScroll(hosting)?.documentVisibleRect.minY ?? 0) > 300
        }
        let scroll = try XCTUnwrap(findScroll(hosting))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let previous = manager.libraryNavigationRequest
        manager.openDashboardItem(movies[1100])
        XCTAssertNotEqual(manager.libraryNavigationRequest, previous)
        try await waitForDashboard {
            hosting.layoutSubtreeIfNeeded()
            return scroll.documentVisibleRect.minY > 300
        }
    }

    func testDashboardLayoutsAndPlayerSurviveHomeNavigation() async throws {
        let suite = "dashboard-layout-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = item("The art of a quiet evening", type: .movie)
        let live = item("World news", type: .live)
        let show = item("Weekend stories", type: .series)
        var loader = LibraryLoader()
        loader.playlist = { _ in [movie, live, show] }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        await manager.loadPlaylist(from: "https://fixture.invalid/playlist")
        manager.recentlyWatchedStore.record(movie)
        manager.recentlyWatchedStore.record(live)
        manager.progressStore.save(item: movie, position: 900, duration: 3600)
        manager.toggleFavorite(live)
        manager.toggleFavorite(show)
        for scheme in [ColorScheme.light, .dark] {
            let controller = NSHostingController(rootView: DashboardView(manager: manager).environment(\.colorScheme, scheme).environment(\.appPalette, AppPalette(appearance: scheme == .dark ? .navy : .light)))
            for width in [320.0, 390, 700, 1000, 1600] {
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 820))
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertGreaterThan(size.height, 0)
            }
            // Save the actual SwiftUI render for visual inspection without launching the app.
            let view = controller.view
            view.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/easyiptv-dashboard-\(scheme).png"))
            }
        }
        for useVLC in [false, true] {
            let fixture = M3UItem(name: "Player fixture", streamURL: URL(fileURLWithPath: "/private/tmp/dashboard-fixture.mp4"), contentType: useVLC ? .live : .movie)
            manager.playDirectStream(fixture)
            manager.player?.replaceCurrentItem(with: nil)
            let hosting = NSHostingView(rootView: ContentView(manager: manager))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }
            func settle() async throws {
                for _ in 0..<10 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 20_000_000) }
            }
            func surface(_ view: NSView) -> NSView? {
                if useVLC { return manager.vlcPlayer?.drawable as? NSView }
                return (view as? AVPlayerLayerNSView) ?? view.subviews.lazy.compactMap { surface($0) }.first
            }
            try await settle()
            let original = try XCTUnwrap(surface(hosting))
            let player = manager.player
            let vlcPlayer = manager.vlcPlayer
            let categoriesVisible = manager.showsCategoriesSidebar
            let channelsVisible = manager.showsChannelsSidebar
            func searchFields(_ view: NSView) -> [NSTextField] {
                if let field = view as? NSTextField, field.placeholderString?.hasPrefix("Search") == true { return [field] }
                return view.subviews.flatMap { searchFields($0) }
            }
            for home in [true, false, true, false] {
                manager.showingDashboard = home
                window.setContentSize(home ? CGSize(width: 720, height: 500) : CGSize(width: 1320, height: 820))
                try await settle()
                let toolbar = try XCTUnwrap(window.toolbar)
                let labels = (toolbar.visibleItems ?? []).map(\.label)
                if home {
                    XCTAssertTrue(searchFields(hosting).isEmpty, "Home must not contain category or channel sidebars")
                    for label in ["Appearance", "Sources", "Subscription Info", "Downloads"] {
                        XCTAssertTrue(labels.contains(label), "Home must keep \(label) available")
                    }
                    XCTAssertFalse(labels.contains("Channels Sidebar"))
                    XCTAssertFalse(labels.contains("Search TV Guide"))
                } else {
                    XCTAssertEqual(searchFields(hosting).count, 2)
                    XCTAssertTrue(labels.contains("Home"), "The library needs a toolbar route back to Home")
                }
                XCTAssertEqual(manager.showsCategoriesSidebar, categoriesVisible)
                XCTAssertEqual(manager.showsChannelsSidebar, channelsVisible)
                XCTAssertTrue(surface(hosting) === original)
                XCTAssertTrue(manager.player === player)
                XCTAssertTrue(manager.vlcPlayer === vlcPlayer)
                XCTAssertGreaterThan(original.bounds.width, 0)
            }
        }
    }
    #endif
}
