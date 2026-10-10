import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import EasyIPTV

@MainActor
final class SearchTests: XCTestCase {
    func testTopShortcutsDoNotIncludeProviderCategories() {
        XCTAssertEqual(ChannelListView.categoryShortcuts, ["All", "Favorites"])
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
