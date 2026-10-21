import XCTest
import AVFoundation
import SwiftUI
#if os(macOS)
import VLC
import AppKit
#endif
@testable import EasyIPTV

final class LifecycleTests: XCTestCase {
    @MainActor func testRefreshAfterSwitchingToM3UUsesTheActivePlaylist() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        var loader = emptyLoader()
        let current = item("current-playlist")
        loader.playlist = { _ in [current] }
        let manager = fixture.manager(loader)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        await manager.loadXtream(serverURL: "https://old.invalid", username: "old", password: "fake")
        await manager.loadPlaylist(from: "https://current.invalid/list.m3u")
        XCTAssertNil(fixture.defaults.object(forKey: "com.iptvplayer.savedXtream"))
        await manager.refreshPlaylist()
        XCTAssertEqual(manager.playlistURLString, "https://current.invalid/list.m3u")
        XCTAssertEqual(manager.channels.map(\.name), [current.name])
    }

    private func item(_ name: String) -> M3UItem {
        M3UItem(name: name, streamURL: URL(string: "https://fixture.invalid/\(name).mp4")!, contentType: .movie)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Lifecycle condition timed out")
        throw NSError(domain: "LifecycleTests", code: 1)
    }

    @MainActor func testSubtitleResetReleasesControllerBeforeUncooperativeProviderReturns() async throws {
        let gate = SuspendedItems()
        defer { gate.complete([]) }
        var controller: SubtitleController? = SubtitleController()
        let reference = WeakReference(controller)
        let avItem = AVPlayerItem(asset: AVMutableComposition())
        controller?.reset(for: item("movie"))
        controller?.configure(item: avItem) { _ = try await gate.wait(); return [] }
        try await waitUntil { gate.started }
        controller?.reset(for: nil)
        controller = nil
        try await waitUntil { reference.value == nil }
        XCTAssertNil(reference.value, "Cancellation must not wait for a provider to release the controller")
    }

    @MainActor func testSubtitleDeinitCancelsPendingProviderWithoutExplicitReset() async throws {
        let gate = SuspendedItems(cooperative: true)
        defer { gate.complete([]) }
        var controller: SubtitleController? = SubtitleController()
        let reference = WeakReference(controller)
        let avItem = AVPlayerItem(asset: AVMutableComposition())
        controller?.reset(for: item("movie"))
        controller?.configure(item: avItem) { _ = try await gate.wait(); return [] }
        try await waitUntil { gate.started }
        controller = nil
        try await waitUntil { reference.value == nil && gate.cancelled }
    }

    @MainActor func testClearRejectsLateBackgroundLibraryResponse() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let gate = SuspendedItems()
        defer { gate.complete([]) }
        var loader = emptyLoader()
        loader.movies = { _, _, _ in try await gate.wait() }
        let manager = fixture.manager(loader)
        await manager.loadXtream(serverURL: "https://old.invalid", username: "old", password: "fake")
        try await waitUntil { gate.started }
        manager.clearAllData()
        gate.complete([item("old")])
        try await waitUntil { gate.cancelled }
        try await Task.sleep(nanoseconds: 30_000_000)
        await manager.libraryPersistence.waitForIdle()
        XCTAssertTrue(manager.channels.isEmpty)
        XCTAssertFalse(manager.isLoading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
        XCTAssertNil(fixture.defaults.object(forKey: "com.iptvplayer.savedXtream"))
    }

    @MainActor func testNewProviderRejectsOldMoviesAndOldForegroundResponses() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let oldMovies = SuspendedItems(), oldLive = SuspendedItems()
        defer { oldMovies.complete([]); oldLive.complete([]) }
        var loader = emptyLoader()
        let latest = item("latest")
        loader.live = { server, _, _ in server.contains("slow") ? try await oldLive.wait() : [] }
        loader.movies = { server, _, _ in server.contains("old") ? try await oldMovies.wait() : [latest] }
        let manager = fixture.manager(loader)
        await manager.loadXtream(serverURL: "https://old.invalid", username: "old", password: "fake")
        try await waitUntil { oldMovies.started }
        let pending = Task { await manager.loadXtream(serverURL: "https://slow.invalid", username: "slow", password: "fake") }
        try await waitUntil { oldLive.started }
        await manager.loadXtream(serverURL: "https://latest.invalid", username: "latest", password: "fake")
        try await waitUntil { manager.channels.map(\.name) == ["latest"] }
        oldMovies.complete([item("obsolete")])
        oldLive.complete([item("obsolete-live")])
        await pending.value
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(manager.channels.map(\.name), ["latest"])
        XCTAssertEqual(manager.playlistURLString, "Xtream: latest")
        XCTAssertFalse(manager.isLoading)
        manager.stop()
        await manager.libraryPersistence.waitForIdle()
    }

    @MainActor func testManagerDeinitCancelsLibraryTaskAndReleasesOwner() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let gate = SuspendedItems(cooperative: true)
        defer { gate.complete([]) }
        var loader = emptyLoader()
        loader.movies = { _, _, _ in try await gate.wait() }
        var manager: IPTVPlayerManager? = fixture.manager(loader)
        let reference = WeakReference(manager)
        await manager?.loadXtream(serverURL: "https://fixture.invalid", username: "test", password: "fake")
        try await waitUntil { gate.started }
        await manager?.libraryPersistence.waitForIdle()
        manager = nil
        try await waitUntil { reference.value == nil && gate.cancelled }
    }

    @MainActor func testCancelledForegroundLoadClearsLoadingState() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let gate = SuspendedItems(cooperative: true)
        defer { gate.complete([]) }
        var loader = emptyLoader()
        loader.live = { _, _, _ in try await gate.wait() }
        let manager = fixture.manager(loader)
        let request = Task { await manager.loadXtream(serverURL: "https://fixture.invalid", username: "test", password: "fake") }
        try await waitUntil { gate.started }
        request.cancel()
        await request.value
        XCTAssertTrue(gate.cancelled)
        XCTAssertFalse(manager.isLoading)
        XCTAssertTrue(manager.channels.isEmpty)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor func testClearRejectsLateM3UResponseAndRefreshUsesIsolatedStorage() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let gate = SuspendedItems()
        defer { gate.complete([]) }
        var loader = emptyLoader()
        loader.playlist = { _ in try await gate.wait() }
        fixture.defaults.set("https://fixture.invalid/list.m3u", forKey: "com.iptvplayer.lastPlaylistURL")
        let manager = fixture.manager(loader)
        let request = Task { await manager.refreshPlaylist() }
        try await waitUntil { gate.started }
        manager.clearAllData()
        gate.complete([item("obsolete")])
        await request.value
        XCTAssertTrue(manager.channels.isEmpty)
        XCTAssertFalse(manager.isLoading)
        XCTAssertEqual(manager.playlistURLString, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
        XCTAssertNil(fixture.defaults.object(forKey: "com.iptvplayer.lastPlaylistURL"))
    }

    @MainActor func testManagerDeinitClearsAVPlayerEvenWhenExternallyRetained() async throws {
        var manager: IPTVPlayerManager? = IPTVPlayerManager(progressDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let reference = WeakReference(manager)
        manager?.playAVKitFixture(M3UItem(name: "Local", streamURL: URL(fileURLWithPath: "/private/tmp/nonexistent-lifecycle-fixture.mp4"), contentType: .movie))
        let player = try XCTUnwrap(manager?.player)
        manager = nil
        try await waitUntil { reference.value == nil }
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
    }

    #if os(macOS)
    @MainActor func testBrowsingKeepsAVPlayerAndSurfacePlaying() async throws {
        try await checkBrowsingPlayback(useVLC: false)
    }

    @MainActor func testBrowsingKeepsVLCPlayerAndDrawablePlaying() async throws {
        try await checkBrowsingPlayback(useVLC: true)
    }

    @MainActor private func checkBrowsingPlayback(useVLC: Bool) async throws {
        let suite = "browse-playback-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let live = M3UItem(name: "Live", streamURL: url, contentType: .live)
        let movie = M3UItem(name: "Movie", streamURL: url, contentType: .movie)
        let show = M3UItem(name: "Show", streamURL: url, contentType: .series)
        var loader = emptyLoader()
        loader.playlist = { _ in [live, movie, show] }
        loader.seriesDetails = { _ in SeriesDetails(details: nil, episodes: [show]) }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        await manager.loadPlaylist(from: "https://fixture.invalid/library.m3u")
        if useVLC { manager.playDirectStream(live) }
        else { manager.playAVKitFixture(live) }
        let player = manager.player
        let avItem = player?.currentItem
        let vlc = manager.vlcPlayer
        let hosting = NSHostingView(rootView: ContentView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            manager.stop(); manager.libraryPersistence.invalidatePendingWrites(); window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        func settle() async throws {
            for _ in 0..<10 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func surface(in view: NSView) -> NSView? {
            if view === hosting, let floating = manager.pictureInPicture.floatingWindow?.contentView,
               let surface = surface(in: floating) { return surface }
            if useVLC { return manager.vlcPlayer?.drawable as? NSView }
            if view is AVPlayerLayerNSView { return view }
            return view.subviews.lazy.compactMap { surface(in: $0) }.first
        }
        try await settle()
        try await waitUntil { manager.isPlaying && (useVLC ? (vlc?.time.intValue ?? 0) > 0 : (player?.currentTime().seconds ?? 0) > 0) }
        let original = try XCTUnwrap(surface(in: hosting))
        let start = useVLC ? Double(vlc!.time.intValue) / 1000 : player!.currentTime().seconds
        for section in [M3UItem.ContentType.movie, .series, .live] {
            manager.selectedSection = section
            manager.selectedCategory = "Recently Watched"
            manager.selectedCategory = "All"
            try await settle()
            XCTAssertTrue(manager.player === player)
            XCTAssertTrue(manager.vlcPlayer === vlc)
            XCTAssertTrue(surface(in: hosting) === original)
            XCTAssertEqual(manager.currentChannel?.id, live.id)
            XCTAssertTrue(manager.isPlaying)
        }
        manager.playChannel(movie)
        try await settle()
        XCTAssertTrue(manager.isViewingMovieDetails)
        XCTAssertTrue(surface(in: hosting) === original)
        XCTAssertEqual(manager.currentChannel?.id, live.id)
        manager.playChannel(show)
        try await settle()
        XCTAssertTrue(manager.isViewingSeriesDetails)
        XCTAssertTrue(surface(in: hosting) === original)
        XCTAssertEqual(manager.currentChannel?.id, live.id)
        manager.dismissDetails()
        try await settle()
        XCTAssertTrue(manager.isCurrentPlayback(live))
        XCTAssertFalse(manager.isCurrentPlayback(show))
        XCTAssertTrue(manager.player === player)
        XCTAssertTrue(manager.vlcPlayer === vlc)
        XCTAssertTrue(manager.isPlaying)
        let end = useVLC ? Double(vlc!.time.intValue) / 1000 : player!.currentTime().seconds
        XCTAssertGreaterThan(end, start)
        manager.playChannel(movie)
        manager.playMovie()
        XCTAssertEqual(manager.currentChannel?.id, movie.id)
        XCTAssertFalse(manager.isViewingMovieDetails)
        if let player { XCTAssertFalse(manager.player === player) }
        if let player { XCTAssertNil(player.currentItem) }
        XCTAssertNotNil(manager.vlcPlayer)
        manager.stop()
        XCTAssertNil(manager.currentChannel)
        XCTAssertNil(manager.player)
    }

    @MainActor func testVLCChannelSwitchesReuseLibraryAndPreserveVolume() async throws {
        let suite = "vlc-channel-switch-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        let surface = VLCVideoSurfaceNSView()
        defer {
            manager.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        manager.playbackVolume = 0.35
        manager.playChannel(M3UItem(name: "First channel", streamURL: url, contentType: .live))
        let library = try XCTUnwrap(manager.vlcPlayer?.libraryInstance)
        for index in 0..<8 {
            let previous = WeakReference(manager.vlcPlayer)
            manager.playChannel(M3UItem(name: "Channel \(index)", streamURL: url, contentType: .live))
            let player = try XCTUnwrap(manager.vlcPlayer)
            XCTAssertTrue(player.libraryInstance === library)
            surface.update(player: player, shouldPlay: true, screenSize: .auto)
            try await waitUntil { manager.isPlaying && previous.value == nil }
            manager.playbackVolume = 0.35
            XCTAssertEqual(player.audio?.volume, 35)
            XCTAssertEqual(defaults.float(forKey: "com.iptvplayer.playbackVolume"), 0.35)
            manager.toggleMute()
            XCTAssertEqual(player.audio?.volume, 0)
            manager.toggleMute()
            XCTAssertEqual(player.audio?.volume, 35)
        }
    }

    @MainActor func testVLCRetirementReleasesPlayerAndDrawableAfterManagerDeinit() async throws {
        var manager: IPTVPlayerManager? = IPTVPlayerManager(progressDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let reference = WeakReference(manager)
        weak var playerReference: VLCMediaPlayer?
        weak var viewReference: NSView?
        autoreleasepool {
            manager?.playAVKitFixture(M3UItem(name: "Local", streamURL: URL(fileURLWithPath: "/private/tmp/nonexistent-lifecycle-fixture.mp4"), contentType: .movie))
            manager?.playCurrentStreamWithVLC()
            let player = manager!.vlcPlayer!
            let view = NSView()
            player.drawable = view
            playerReference = player
            viewReference = view
        }
        manager = nil
        try await waitUntil { reference.value == nil && playerReference == nil && viewReference == nil }
    }
    #endif

    func testClearDuringEncodingCannotRecreateLibraryCache() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let started = expectation(description: "Encoding began")
        let resume = DispatchSemaphore(value: 0)
        let writer = LibraryPersistence(url: fixture.cache, defaults: fixture.defaults) { items in
            started.fulfill()
            resume.wait()
            return try JSONEncoder().encode(items)
        }
        writer.save(channels: [item("old")], source: "old")
        await fulfillment(of: [started], timeout: 5)
        writer.clear()
        resume.signal()
        await writer.waitForIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
        XCTAssertNil(fixture.defaults.string(forKey: "com.iptvplayer.lastPlaylistURL"))
    }

    func testPersistenceCoalescesSnapshotsAndWritesOnlyLatest() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let started = expectation(description: "First encoding began")
        let resume = DispatchSemaphore(value: 0)
        let calls = EncodingCalls()
        let writer = LibraryPersistence(url: fixture.cache, defaults: fixture.defaults) { items in
            if calls.record(items.first!.name) == 1 { started.fulfill(); resume.wait() }
            return try JSONEncoder().encode(items)
        }
        writer.save(channels: [item("first")], source: "first")
        await fulfillment(of: [started], timeout: 5)
        writer.save(channels: [item("second")], source: "second")
        writer.save(channels: [item("latest")], source: "latest")
        resume.signal()
        await writer.waitForIdle()
        let saved = try JSONDecoder().decode([M3UItem].self, from: Data(contentsOf: fixture.cache))
        XCTAssertEqual(saved.map(\.name), ["latest"])
        XCTAssertEqual(calls.names, ["first", "latest"])
        XCTAssertEqual(fixture.defaults.string(forKey: "com.iptvplayer.lastPlaylistURL"), "latest")
    }

    private func emptyLoader() -> LibraryLoader {
        var loader = LibraryLoader()
        loader.live = { _, _, _ in [] }
        loader.movies = { _, _, _ in [] }
        loader.series = { _, _, _ in [] }
        loader.playlist = { _ in [] }
        return loader
    }
}

@MainActor private final class SuspendedItems {
    var started = false
    var cancelled = false
    let cooperative: Bool
    private var continuation: CheckedContinuation<[M3UItem], Error>?
    init(cooperative: Bool = false) { self.cooperative = cooperative }

    func wait() async throws -> [M3UItem] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0; started = true }
        } onCancel: {
            Task { @MainActor in
                self.cancelled = true
                if self.cooperative {
                    self.continuation?.resume(throwing: CancellationError())
                    self.continuation = nil
                }
            }
        }
    }

    func complete(_ items: [M3UItem]) { continuation?.resume(returning: items); continuation = nil }
}

private struct LibraryFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    var cache: URL { directory.appendingPathComponent("cache.json") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "library-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }
    @MainActor func manager(_ loader: LibraryLoader) -> IPTVPlayerManager {
        IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader, cacheURL: cache)
    }
    func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
}

private final class WeakReference<Object: AnyObject> {
    weak var value: Object?
    init(_ value: Object?) { self.value = value }
}

private final class EncodingCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var names: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }; values.append(name); return values.count
    }
}
