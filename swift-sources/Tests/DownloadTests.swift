import XCTest
import AVFoundation
import Network
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import EasyIPTV

/// A loopback HTTP server exercises URLSession's real download callbacks without a provider.
private final class DownloadHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "download-tests.http")
    private let lock = NSLock()
    private var waiting: [String: NWConnection] = [:]
    private var connections: [NWConnection] = []
    private var hits: [String: Int] = [:]
    private var released = Set<String>()
    var media = Data(repeating: 0x41, count: 64 * 1024)
    let subtitle = Data("1\n00:00:00,000 --> 00:05:00,000\nOffline subtitle\n".utf8)
    private var port: NWEndpoint.Port!

    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.port = self?.listener.port; continuation.resume() }
                if case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")! }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return hits[path] ?? 0 }
    func release(_ path: String) {
        lock.lock(); released.insert(path); let connection = waiting.removeValue(forKey: path); lock.unlock()
        if let connection { send(connection, path: path) }
    }
    func stop() {
        listener.cancel()
        lock.lock(); let connections = self.connections; self.connections = []; waiting = [:]; lock.unlock()
        connections.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] next, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var data = data; data.append(next ?? Data())
            guard data.count < 16384 else { connection.cancel(); return }
            let request = String(data: data, encoding: .utf8) ?? ""
            guard request.contains("\r\n\r\n") else {
                if !complete { self.receive(connection, data: data) }; return
            }
            let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
            self.lock.lock(); self.hits[path, default: 0] += 1
            let ready = self.released.contains(path) || path.contains("subtitle") || path.contains("invalid")
            if !ready { self.waiting[path] = connection }
            self.lock.unlock()
            if ready { self.send(connection, path: path) }
        }
    }
    private func send(_ connection: NWConnection, path: String) {
        let invalid = path.contains("invalid"), subtitle = path.contains("subtitle")
        let body = invalid ? Data("<html>Login required</html>".utf8) : subtitle ? self.subtitle : media
        let type = invalid ? "text/html" : subtitle ? "text/plain" : "video/mp4"
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

@MainActor
final class DownloadTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Download fixture timed out")
    }
    private func store(_ root: URL, preferences: UserDefaults = UserDefaults(suiteName: "download-tests-\(UUID())")!, subtitles: @escaping @Sendable (M3UItem) async throws -> [SubtitleSource] = { $0.subtitleSources ?? [] }) -> DownloadManager {
        DownloadManager(root: root, configuration: .ephemeral, monitorNetwork: false, preferences: preferences, subtitleFetch: subtitles)
    }
    private func item(_ server: DownloadHTTPFixture, _ name: String, episode: Int? = nil) -> M3UItem {
        M3UItem(name: name, groupTitle: episode == nil ? "Movies" : "Season 1", streamURL: server.url("/\(name).mov"),
                contentType: episode == nil ? .movie : .series, mediaID: name, seriesID: episode == nil ? nil : "42",
                seasonNumber: episode == nil ? nil : 1, episodeNumber: episode)
    }

    func testQueueLimitDuplicateClicksPauseResumeAndAutomaticAdvance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID())")
        let server = try DownloadHTTPFixture(); try await server.start()
        let store = store(root)
        defer { store.invalidate(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await wait { store.ready }
        let items = (1...4).map { item(server, "movie\($0)") }
        for item in items { store.enqueue(item); store.enqueue(item) }
        XCTAssertEqual(store.records.count, 4)
        XCTAssertEqual(store.records.filter { $0.status == .downloading }.count, 2)
        XCTAssertEqual(store.records.filter { $0.status == .queued }.count, 2)
        try await wait { server.count("/movie1.mov") == 1 && server.count("/movie2.mov") == 1 }
        let id = try XCTUnwrap(store.record(for: items[0])).id
        store.pause(id); store.pause(id)
        XCTAssertEqual(store.record(for: items[0])?.status, .paused)
        try await wait { server.count("/movie3.mov") == 1 }
        store.resume(id); store.resume(id)
        XCTAssertEqual(store.record(for: items[0])?.status, .queued)
        server.release("/movie2.mov")
        try await wait { store.record(for: items[1])?.status == .downloaded }
        XCTAssertEqual(store.record(for: items[0])?.status, .downloading)
        try await wait { server.count("/movie1.mov") == 2 }
        XCTAssertEqual(server.count("/movie1.mov"), 2, "Without response headers, URLSession restarts instead of inventing resume data")
        server.release("/movie1.mov"); server.release("/movie3.mov"); server.release("/movie4.mov")
        try await wait { store.records.allSatisfy { $0.status == .downloaded } }
        XCTAssertEqual(store.records.count, 4)
        XCTAssertTrue(store.records.allSatisfy { $0.bytes == Int64(server.media.count) && $0.progress == 1 })
    }

    func testPreferencesPersistAndQueueLimitChangesWithoutInterruptingActiveDownloads() async throws {
        let suite = "download-preferences-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let server = try DownloadHTTPFixture(); try await server.start()
        let store = store(root, preferences: defaults)
        defer {
            store.invalidate(); server.stop(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try await wait { store.ready }
        XCTAssertEqual(store.maxConcurrentDownloads, 2)
        XCTAssertTrue(store.saveProviderSubtitles)
        XCTAssertTrue(store.saveArtwork)
        store.maxConcurrentDownloads = 1
        let items = (1...3).map { item(server, "limit\($0)") }
        items.forEach { store.enqueue($0) }
        XCTAssertEqual(store.records.filter { $0.status == .downloading }.count, 1)
        store.maxConcurrentDownloads = 2
        try await wait { server.count("/limit1.mov") == 1 && server.count("/limit2.mov") == 1 }
        store.maxConcurrentDownloads = 1
        XCTAssertEqual(store.records.filter { $0.status == .downloading }.count, 2)
        server.release("/limit1.mov")
        try await wait { store.record(for: items[0])?.status == .downloaded }
        XCTAssertEqual(store.record(for: items[2])?.status, .queued)
        XCTAssertEqual(server.count("/limit3.mov"), 0)
        server.release("/limit2.mov")
        try await wait { server.count("/limit3.mov") == 1 }
        server.release("/limit3.mov")
        try await wait { store.records.allSatisfy { $0.status == .downloaded } }
        store.maxConcurrentDownloads = 99
        XCTAssertEqual(store.maxConcurrentDownloads, 4)
        store.maxConcurrentDownloads = 0
        XCTAssertEqual(store.maxConcurrentDownloads, 1)
        store.saveProviderSubtitles = false
        store.saveArtwork = false
        let reopened = self.store(root.appendingPathComponent("reopened"), preferences: defaults)
        defer { reopened.invalidate() }
        try await wait { reopened.ready }
        XCTAssertEqual(reopened.maxConcurrentDownloads, 1)
        XCTAssertFalse(reopened.saveProviderSubtitles)
        XCTAssertFalse(reopened.saveArtwork)
        defaults.set(-10, forKey: "com.easyiptv.downloads.concurrent")
        let invalid = self.store(root.appendingPathComponent("invalid"), preferences: defaults)
        defer { invalid.invalidate() }
        XCTAssertEqual(invalid.maxConcurrentDownloads, 1)
    }

    func testOptionalSubtitleAndArtworkDownloadsRespectPreferences() async throws {
        let suite = "download-extras-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let server = try DownloadHTTPFixture(); try await server.start()
        let store = store(root, preferences: defaults, subtitles: { _ in
            [SubtitleSource(url: server.url("/subtitle.srt"), label: "English")]
        })
        defer {
            store.invalidate(); server.stop(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try await wait { store.ready }
        server.release("/poster")
        for includeExtras in [false, true] {
            store.saveProviderSubtitles = includeExtras; store.saveArtwork = includeExtras
            let movie = M3UItem(name: "Extras \(includeExtras)", logoURL: server.url("/poster"),
                streamURL: server.url("/extras-\(includeExtras).mov"), contentType: .movie)
            store.enqueue(movie)
            server.release("/extras-\(includeExtras).mov")
            try await wait { store.record(for: movie)?.status == .downloaded }
            let record = try XCTUnwrap(store.record(for: movie))
            XCTAssertNotNil(store.localURL(for: movie))
            XCTAssertEqual(record.subtitles.count, includeExtras ? 1 : 0)
            XCTAssertEqual(record.posterPath != nil, includeExtras)
            XCTAssertEqual(server.count("/subtitle.srt"), includeExtras ? 1 : 0)
            XCTAssertEqual(server.count("/poster"), includeExtras ? 1 : 0)
        }
        store.saveProviderSubtitles = false; store.saveArtwork = false
        let downloaded = try XCTUnwrap(store.records.last)
        XCTAssertEqual(downloaded.subtitles.count, 1, "Preferences must not delete saved extras")
        XCTAssertNotNil(downloaded.posterPath)
    }

    #if os(macOS)
    func testPreferencesFitNarrowAndWideDownloads() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-layout-\(UUID())")
        let store = store(root)
        defer { store.invalidate(); try? FileManager.default.removeItem(at: root) }
        try await wait { store.ready }
        for width in [296.0, 760.0] {
            let controller = NSHostingController(rootView: DownloadPreferencesView(downloads: store)
                .padding().frame(width: width)
                .background(AppPalette(appearance: .forest).background)
                .environment(\.appPalette, AppPalette(appearance: .forest)).environment(\.colorScheme, .dark))
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 1000))
            XCTAssertEqual(size.width, width, accuracy: 1)
            XCTAssertLessThan(size.height, 350)
            XCTAssertGreaterThan(size.height, 100)
        }
    }
    #endif

    func testFailureRetryCancelAndStaleCallbacksDoNotResurrectDeletedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID())")
        let server = try DownloadHTTPFixture(); try await server.start()
        let store = store(root)
        defer { store.invalidate(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await wait { store.ready }
        let invalid = item(server, "invalid")
        store.enqueue(invalid)
        try await wait { store.record(for: invalid)?.status == .failed }
        let failed = try XCTUnwrap(store.record(for: invalid))
        XCTAssertTrue(failed.message?.contains("page") == true)
        XCTAssertNil(store.localURL(for: invalid))
        store.retry(failed.id); store.retry(failed.id)
        try await wait { store.record(for: invalid)?.status == .failed && server.count("/invalid.mov") == 2 }
        XCTAssertNotEqual(store.record(for: invalid)?.attempt, failed.attempt)
        let pending = item(server, "pending")
        store.enqueue(pending)
        let cancelled = try XCTUnwrap(store.record(for: pending))
        store.remove(cancelled.id); store.remove(cancelled.id)
        try await wait { store.record(for: pending) == nil }
        store.completed(store.token(cancelled), error: nil)
        XCTAssertNil(store.record(for: pending))
        store.enqueue(pending)
        XCTAssertNotEqual(store.record(for: pending)?.attempt, cancelled.attempt)
        store.completed(store.token(cancelled), error: "old request failed")
        XCTAssertEqual(store.record(for: pending)?.status, .downloading)
    }

    func testOfflinePlaybackKeepsIdentitySubtitlesResumeNextEpisodeAndDeletionProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID())")
        let media = try await silentMedia()
        let server = try DownloadHTTPFixture(); server.media = try Data(contentsOf: media); try await server.start()
        let store = store(root, subtitles: { _ in [SubtitleSource(url: server.url("/subtitle.srt"), label: "English")] })
        let suite = "downloads-progress-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let manager = IPTVPlayerManager(progressDefaults: defaults, downloads: store)
        let originalFontSize = manager.subtitles.fontSize
        defer { manager.subtitles.fontSize = originalFontSize; manager.stop(); store.invalidate(); server.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: media) }
        try await wait { store.ready }
        let series = M3UItem(name: "Saved Show", streamURL: server.url("/series/42"), contentType: .series, seriesID: "42")
        let first = item(server, "episode1", episode: 1), second = item(server, "episode2", episode: 2)
        store.enqueue(first, series: series); store.enqueue(second, series: series)
        server.release("/episode1.mov"); server.release("/episode2.mov")
        try await wait { store.records.allSatisfy { $0.status == .downloaded } }
        let record = try XCTUnwrap(store.record(for: first))
        await store.flush()
        let reopened = self.store(root, subtitles: { _ in XCTFail("Offline playback must not re-fetch provider subtitles"); return [] })
        defer { reopened.invalidate() }
        try await wait { reopened.ready }
        XCTAssertEqual(reopened.records.filter { $0.status == .downloaded }.count, 2)
        XCTAssertEqual(reopened.localURL(for: first), store.localURL(for: first))
        XCTAssertEqual(record.subtitles.count, 1)
        let subtitle = try XCTUnwrap(record.subtitles.first)
        XCTAssertTrue(subtitle.url.isFileURL)
        XCTAssertEqual(try SubtitleDocument(data: Data(contentsOf: subtitle.url)).text(at: 10), "Offline subtitle")
        server.stop()
        store.updateConnectivity(false)
        manager.progressStore.save(item: first, position: 120, duration: 300)
        manager.playDownload(record)
        let request = try XCTUnwrap(manager.resumeRequest)
        XCTAssertEqual(request.position, 120)
        manager.resolveResume(request, startOver: false)
        try await wait { (manager.player?.currentTime().seconds ?? 0) >= 119 }
        XCTAssertEqual(manager.currentChannel?.streamURL, first.streamURL)
        XCTAssertEqual((manager.player?.currentItem?.asset as? AVURLAsset)?.url, store.localURL(for: first))
        try await wait { manager.subtitles.tracks.contains { $0.id == subtitle.id } }
        manager.subtitles.select(subtitle.id)
        try await wait { manager.subtitles.text == "Offline subtitle" }
        manager.subtitles.fontSize = 32
        XCTAssertEqual(manager.subtitles.fontSize, 32)
        manager.returnToSeries(); XCTAssertNil(manager.player); XCTAssertFalse(manager.isPlaying)
        XCTAssertNotNil(manager.progressStore.progress(for: first)?.resumePosition)
        manager.playDownload(try XCTUnwrap(store.record(for: second)))
        manager.previousChannel()
        XCTAssertEqual(manager.resumeRequest?.item.subtitleCacheKey, first.subtitleCacheKey)
        manager.stop()
        manager.playDownload(record); manager.resolveResume(try XCTUnwrap(manager.resumeRequest), startOver: false)
        manager.nextChannel()
        XCTAssertEqual(manager.currentChannel?.subtitleCacheKey, second.subtitleCacheKey)
        let saved = manager.progressStore.progress(for: first)
        store.remove(try XCTUnwrap(store.record(for: second)).id)
        try await wait { store.record(for: second) == nil }
        XCTAssertNil(manager.player, "Deleting an actively playing local item must stop playback first")
        XCTAssertEqual(manager.progressStore.progress(for: first), saved)
        XCTAssertEqual(PlaybackProgressStore.key(for: first), record.id)
    }

    func testManifestReloadMissingMediaAndPathValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID())")
        let storage = DownloadStorage(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await storage.load()
        let item = M3UItem(name: "Fixture", streamURL: URL(string: "https://fixture.invalid/movie/1.mp4")!, contentType: .movie)
        var record = DownloadRecord(id: PlaybackProgressStore.key(for: item), item: item, series: nil)
        record.status = .downloaded
        record.videoPath = try await storage.saveData(Data([1, 2, 3]), id: record.id, attempt: record.attempt, filename: "video.mp4")
        try await storage.save([record], revision: 2)
        try await storage.save([], revision: 1)
        XCTAssertNil(storage.url("../outside.mp4"))
        XCTAssertFalse(DownloadStorage.validHLSLocation(URL(fileURLWithPath: "/private/tmp/some.movpkg")))
        let restored = try await storage.load()
        XCTAssertEqual(restored.count, 1); XCTAssertEqual(restored[0].status, .downloaded)
        try await storage.delete(record)
        let missing = try await storage.load()
        XCTAssertEqual(missing[0].status, .failed)
        XCTAssertTrue(missing[0].message?.contains("missing") == true)
    }

    func testStreamingSubtitleCacheIsReplacedByOfflineSourcesAndBackAgain() async throws {
        let media = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: media) }
        let item = M3UItem(name: "Subtitle mode", streamURL: URL(string: "https://fixture.invalid/movie.mp4")!, contentType: .movie)
        let remote = SubtitleSource(url: URL(string: "https://fixture.invalid/subtitle.srt")!, label: "Provider")
        let local = SubtitleSource(url: media.deletingLastPathComponent().appendingPathComponent("fixture.srt"), label: "Offline")
        let controller = SubtitleController()
        var fetches = 0
        controller.reset(for: item)
        controller.configure(item: AVPlayerItem(url: media), provider: { fetches += 1; return [remote] })
        try await wait { controller.tracks.contains { $0.id == remote.id } }
        controller.reset(for: item)
        controller.configure(item: AVPlayerItem(url: media), provider: { XCTFail("Offline sources should be cached"); return [] }, offlineSources: [local])
        XCTAssertTrue(controller.tracks.contains { $0.id == local.id })
        XCTAssertFalse(controller.tracks.contains { $0.id == remote.id })
        XCTAssertEqual(fetches, 1)
        controller.reset(for: item)
        controller.configure(item: AVPlayerItem(url: media), provider: { fetches += 1; return [remote] })
        try await wait { controller.tracks.contains { $0.id == remote.id } }
        XCTAssertEqual(fetches, 2)
        controller.reset(for: nil)
    }

    func testNativeHLSConfigurationIncludesDefaultMediaSelection() async throws {
        let media = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: media) }
        let configuration = try await DownloadManager.hlsConfiguration(asset: AVURLAsset(url: media), title: "Offline fixture")
        XCTAssertEqual(configuration.primaryContentConfiguration.mediaSelections.count, 1)
    }
}
