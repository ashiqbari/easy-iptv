import XCTest
import SwiftUI
#if os(macOS)
import AppKit
import VLC
#endif
@testable import EasyIPTV

@MainActor
final class SearchTests: XCTestCase {
    func testTopShortcutsDoNotIncludeProviderCategories() {
        XCTAssertEqual(ChannelListView.categoryShortcuts, ["All", "Favorites"])
    }

    func testDownloadsDialogPreservesCategorySearchAndPlayer() async throws {
        try await checkDownloadsDialog(useVLC: false)
    }

    #if os(macOS)
    func testDownloadsDialogKeepsVLCDrawableMounted() async throws {
        try await checkDownloadsDialog(useVLC: true)
    }
    #endif

    private func checkDownloadsDialog(useVLC: Bool) async throws {
        let suite = "downloads-shortcut-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop() }
        manager.playDirectStream(M3UItem(name: "Fixture", streamURL: URL(fileURLWithPath: "/private/tmp/downloads-shortcut.mp4"), contentType: useVLC ? .live : .movie))
        manager.player?.replaceCurrentItem(with: nil)
        manager.selectedCategory = "Favorites"
        manager.searchText = "Fixture"
        let player = manager.player
        #if os(macOS)
        let hosting = NSHostingView(rootView: ContentView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        let vlcPlayer = manager.vlcPlayer
        func surface(_ view: NSView) -> NSView? {
            if useVLC { return manager.vlcPlayer?.drawable as? NSView }
            return (view as? AVPlayerLayerNSView) ?? view.subviews.lazy.compactMap { surface($0) }.first
        }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let original = try XCTUnwrap(surface(hosting))
        #endif
        for showing in [true, false, true, false] {
            manager.showingDownloads = showing
            #if os(macOS)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(surface(hosting) === original, "The modal must not remount the video surface")
            XCTAssertTrue(manager.vlcPlayer === vlcPlayer)
            #endif
            XCTAssertEqual(manager.selectedCategory, "Favorites")
            XCTAssertEqual(manager.searchText, "Fixture")
            XCTAssertTrue(manager.player === player)
        }
    }

    func testDownloadsBadgeOnlyCountsQueuedAndDownloading() {
        let item = M3UItem(name: "Fixture", streamURL: URL(fileURLWithPath: "/private/tmp/badge.mp4"), contentType: .movie)
        var records = [DownloadStatus.queued, .downloading, .paused, .failed, .downloaded].map {
            DownloadRecord(id: UUID().uuidString, item: item, series: nil, status: $0)
        }
        XCTAssertEqual(DownloadHeaderControls.activeCount(records), 2)
        records[0].status = .paused
        records[1].status = .downloaded
        XCTAssertEqual(DownloadHeaderControls.activeCount(records), 0)
        XCTAssertEqual(DownloadHeaderControls.activeCount([]), 0)
    }

    func testDownloadsDialogFitsNarrowAndDesktopContainers() {
        XCTAssertEqual(DownloadsDialog.size(in: CGSize(width: 390, height: 844)), CGSize(width: 366, height: 820))
        XCTAssertEqual(DownloadsDialog.size(in: CGSize(width: 1320, height: 820)), CGSize(width: 760, height: 720))
        XCTAssertEqual(DownloadsDialog.size(in: CGSize(width: 320, height: 480)), CGSize(width: 296, height: 456))
        XCTAssertEqual(DownloadsDialog.size(in: .zero), .zero)
    }

    #if os(macOS)
    func testDownloadsDialogClosesOnEscape() async throws {
        let suite = "downloads-modal-keyboard-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop() }
        manager.showingDownloads = true
        let hosting = NSHostingView(rootView: DownloadsView(manager: manager, downloads: manager.downloads))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        window.makeFirstResponder(hosting)
        try await Task.sleep(nanoseconds: 100_000_000)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        hosting.keyDown(with: escape)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(manager.showingDownloads)
    }
    #endif

    func testCategorySearchIsIndependentOfChannelSearchSelectionAndPlayback() async throws {
        let suite = "category-search-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let items = [
            M3UItem(name: "Match", groupTitle: "Café Sports", streamURL: URL(fileURLWithPath: "/private/tmp/category-match.mp4"), contentType: .movie),
            M3UItem(name: "Bulletin", groupTitle: "World News", streamURL: URL(fileURLWithPath: "/private/tmp/category-news.mp4"), contentType: .movie),
            M3UItem(name: "Live", groupTitle: "Live Sports", streamURL: URL(fileURLWithPath: "/private/tmp/category-live.ts"), contentType: .live),
            M3UItem(name: "Series", groupTitle: "Drama Series", streamURL: URL(fileURLWithPath: "/private/tmp/category-series.mp4"), contentType: .series)
        ]
        var loader = LibraryLoader()
        loader.playlist = { _ in items }
        loader.seriesDetails = { _ in SeriesDetails(details: nil, episodes: []) }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        manager.selectedSection = .movie
        await manager.loadPlaylist(from: "https://fixture.invalid/category-search.m3u")
        manager.playDirectStream(items[0]); manager.player?.replaceCurrentItem(with: nil)
        manager.selectedCategory = "Café Sports"
        manager.searchText = "Match"
        let player = try XCTUnwrap(manager.player)
        let filtered = manager.filteredChannels.map(\.id)
        #if os(macOS)
        let hosting = NSHostingView(rootView: ContentView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        #endif
        for (query, expected) in [(" NeWs ", ["World News"]), ("cafe", ["Café Sports"]), ("missing", []), ("", ["Café Sports", "World News"])] {
            manager.categorySearchText = query
            XCTAssertEqual(manager.filteredCategories, expected)
            #if os(macOS)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
            #endif
            XCTAssertEqual(manager.searchText, "Match")
            XCTAssertEqual(manager.selectedCategory, "Café Sports", "Hiding the selected category must not change the channel selection")
            XCTAssertEqual(manager.filteredChannels.map(\.id), filtered)
            XCTAssertTrue(manager.player === player)
            XCTAssertEqual(manager.currentChannel?.id, items[0].id)
        }
        manager.categorySearchText = "news"
        #if os(macOS)
        manager.toggleCategoriesSidebar(); manager.toggleCategoriesSidebar()
        XCTAssertEqual(manager.categorySearchText, "news")
        #endif
        manager.selectedSection = .live
        XCTAssertEqual(manager.categorySearchText, "")
        XCTAssertEqual(manager.filteredCategories, ["Live Sports"])
        manager.categorySearchText = "news"
        manager.selectedSection = .series
        XCTAssertEqual(manager.categorySearchText, "")
        XCTAssertEqual(manager.filteredCategories, ["Drama Series"])
        await manager.libraryPersistence.waitForIdle()
    }

    func testClearingCategorySearchRestoresLargeCategorySetWithoutChangingChannels() async throws {
        let suite = "category-search-large-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let items = (0..<1_000).map {
            M3UItem(name: "Movie \($0)", groupTitle: String(format: "Category %04d", $0),
                    streamURL: URL(fileURLWithPath: "/private/tmp/category-search-\($0).mp4"), contentType: .movie)
        }
        var loader = LibraryLoader(); loader.playlist = { _ in items }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        manager.selectedSection = .movie
        await manager.loadPlaylist(from: "https://fixture.invalid/category-search-large.m3u")
        for _ in 0..<5 {
            manager.categorySearchText = "Category 0999"
            XCTAssertEqual(manager.filteredCategories, ["Category 0999"])
            manager.categorySearchText = " "
            XCTAssertEqual(manager.filteredCategories.count, 1_000)
            XCTAssertEqual(manager.filteredChannels.count, 1_000)
            XCTAssertEqual(manager.selectedCategory, "All")
        }
        await manager.libraryPersistence.waitForIdle()
    }

    func testReturningToAllRestoresLargeLibraryWithoutReplacingPlayer() async throws {
        let suite = "category-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let items = (0..<10_000).map {
            M3UItem(name: "Movie \($0)", groupTitle: $0 == 0 ? "Small" : "Large",
                    streamURL: URL(fileURLWithPath: "/private/tmp/category-fixture-\($0).mp4"), contentType: .movie)
        }
        var loader = LibraryLoader()
        loader.playlist = { _ in items }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        manager.selectedSection = .movie
        await manager.loadPlaylist(from: "https://fixture.invalid/categories.m3u")
        manager.playDirectStream(items[0])
        manager.player?.replaceCurrentItem(with: nil)
        let player = try XCTUnwrap(manager.player)
        manager.toggleFavorite(items[0])
        XCTAssertTrue(manager.categories.contains("Small"), "Provider categories must remain available in the sidebar")

        #if os(macOS)
        let hosting = NSHostingView(rootView: ChannelListView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        #endif
        for category in ["Favorites", "Small", "Favorites"] {
            manager.selectedCategory = category
            XCTAssertEqual(manager.filteredChannels.count, 1)
            #if os(macOS)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertNil(table(in: hosting), "macOS channel rows must not use eager native table height measurement")
            #endif
            // List must also reject animation inherited from a parent/sidebar action.
            withAnimation(.default) { manager.selectedCategory = "All" }
            XCTAssertEqual(manager.filteredChannels.map(\.id), items.map(\.id))
            #if os(macOS)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertNil(table(in: hosting), "Restoring All must stay on the lazy rendering path")
            #endif
            XCTAssertTrue(manager.player === player)
            XCTAssertEqual(manager.currentChannel?.id, items[0].id)
        }
        manager.searchText = "Movie 9999"
        manager.selectedCategory = "Favorites"
        XCTAssertTrue(manager.filteredChannels.isEmpty)
        manager.selectedCategory = "All"
        XCTAssertEqual(manager.filteredChannels.map(\.id), [items[9999].id])
        XCTAssertEqual(manager.searchText, "Movie 9999")
        manager.searchText = ""
        manager.toggleFavorite(items[0])
        manager.selectedCategory = "Favorites"
        XCTAssertTrue(manager.filteredChannels.isEmpty)
        manager.selectedCategory = "All"
        XCTAssertEqual(manager.filteredChannels.count, items.count)
        XCTAssertTrue(manager.player === player)
        await manager.libraryPersistence.waitForIdle()
    }

    func testClearMatchesManualDeletionAndPreservesCategoryAndPlayback() async throws {
        let suite = "search-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let items = (0..<10_000).map {
            M3UItem(name: "Movie \($0)", groupTitle: $0 % 2 == 0 ? "Even" : "Odd",
                    streamURL: URL(fileURLWithPath: "/private/tmp/search-fixture-\($0).mp4"), contentType: .movie)
        }
        var loader = LibraryLoader()
        loader.playlist = { _ in items }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        manager.selectedSection = .movie
        await manager.loadPlaylist(from: "https://fixture.invalid/list.m3u")
        manager.player?.replaceCurrentItem(with: nil)
        manager.selectedCategory = "Even"
        let playing = try XCTUnwrap(manager.currentChannel?.id)
        manager.searchText = "Movie 9998"
        XCTAssertEqual(manager.filteredChannels.count, 1)
        let view = ChannelListView(manager: manager)
        #if os(macOS)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 20_000_000)
        #endif
        view.clearSearch()
        #if os(macOS)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertGreaterThan(hosting.bounds.height, 0)
        #endif
        let clearedIDs = manager.filteredChannels.map(\.id)
        XCTAssertEqual(clearedIDs.count, 5_000)
        XCTAssertEqual(manager.selectedCategory, "Even")
        XCTAssertEqual(manager.currentChannel?.id, playing)
        manager.searchText = "Movie 9998"
        while !manager.searchText.isEmpty { manager.searchText.removeLast() }
        XCTAssertEqual(manager.filteredChannels.map(\.id), clearedIDs)
        manager.searchText = "no matching title"
        XCTAssertTrue(manager.filteredChannels.isEmpty)
        view.clearSearch()
        XCTAssertEqual(manager.filteredChannels.map(\.id), clearedIDs)
        #if os(macOS)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 20_000_000)
        #endif
        view.clearSearch()
        XCTAssertEqual(manager.filteredChannels.map(\.id), clearedIDs)
        await manager.libraryPersistence.waitForIdle()
    }

    #if os(macOS)
    func testClearDisablesInheritedButtonAnimations() async throws {
        let suite = "search-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        manager.searchText = "query"
        var clearTransaction: Transaction?
        let hosting = NSHostingView(rootView: SearchTransactionView(manager: manager) { query, transaction in
            if query.isEmpty { clearTransaction = transaction }
        })
        hosting.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 20_000_000)
        withAnimation(.default) { ChannelListView(manager: manager).clearSearch() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 20_000_000)
        let transaction = try XCTUnwrap(clearTransaction)
        XCTAssertTrue(transaction.disablesAnimations)
        XCTAssertNil(transaction.animation)
    }
    #endif
}

#if os(macOS)
private struct SearchTransactionView: View {
    @ObservedObject var manager: IPTVPlayerManager
    let record: (String, Transaction) -> Void
    var body: some View { SearchTransactionProbe(query: manager.searchText, record: record) }
}

private struct SearchTransactionProbe: NSViewRepresentable {
    let query: String
    let record: (String, Transaction) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { record(query, context.transaction) }
}
#endif
