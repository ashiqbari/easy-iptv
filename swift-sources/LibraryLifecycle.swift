import Foundation

/// Injectable, stateless loading operations keep lifecycle tests off real providers.
struct LibraryLoader: Sendable {
    typealias Fetch = @Sendable (String, String, String) async throws -> [M3UItem]
    var live: Fetch
    var movies: Fetch
    var series: Fetch
    var playlist: @Sendable (URL) async throws -> [M3UItem]

    init(service: XtreamCodesManager = XtreamCodesManager(), parser: M3UParser = M3UParser()) {
        live = { try await service.fetchLiveChannels(serverURL: $0, username: $1, password: $2) }
        movies = { try await service.fetchVodStreams(serverURL: $0, username: $1, password: $2) }
        series = { try await service.fetchSeries(serverURL: $0, username: $1, password: $2) }
        playlist = { try await parser.parse(from: $0) }
    }
}

/// At most one encoding snapshot and one pending snapshot are retained. Writes
/// are serialized; clearing invalidates even an encoding already in progress.
final class LibraryPersistence: @unchecked Sendable {
    let url: URL
    private let defaults: UserDefaults
    private let encode: @Sendable ([M3UItem]) throws -> Data
    private let queue = DispatchQueue(label: "EasyIPTV.library-persistence", qos: .utility)
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var pending: (channels: [M3UItem], source: String, revision: UInt64)?
    private var working = false

    init(url: URL, defaults: UserDefaults, encode: @escaping @Sendable ([M3UItem]) throws -> Data = { try JSONEncoder().encode($0) }) {
        self.url = url
        self.defaults = defaults
        self.encode = encode
    }

    func save(channels: [M3UItem], source: String) {
        lock.lock()
        revision &+= 1
        pending = (channels, source, revision)
        let schedule = !working
        working = true
        lock.unlock()
        if schedule { queue.async { [self] in drain() } }
    }

    func invalidatePendingWrites() {
        lock.lock()
        revision &+= 1
        pending = nil
        lock.unlock()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        pending = nil
        try? FileManager.default.removeItem(at: url)
        defaults.removeObject(forKey: "com.iptvplayer.lastPlaylistURL")
    }

    func waitForIdle() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let snapshot = pending else {
                working = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            do {
                let data = try encode(snapshot.channels)
                lock.lock()
                defer { lock.unlock() }
                guard revision == snapshot.revision else { continue }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                defaults.set(snapshot.source, forKey: "com.iptvplayer.lastPlaylistURL")
            } catch { print("Failed to save channels: \(error.localizedDescription)") }
        }
    }
}
