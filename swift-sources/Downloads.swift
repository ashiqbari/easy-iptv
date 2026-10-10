import AVFoundation
import Combine
import Foundation
import Network

enum DownloadStatus: String, Codable {
    case queued, downloading, paused, failed, downloaded
}

struct DownloadRecord: Identifiable, Codable {
    let id: String
    let item: M3UItem
    let series: M3UItem?
    var details: MediaDetails?
    var status: DownloadStatus = .queued
    var attempt = UUID()
    var progress = 0.0
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0
    var videoPath: String?
    var hlsURL: URL?
    var subtitles: [SubtitleSource] = []
    var posterPath: String?
    var message: String?
    var mediaComplete = false
    var resumeData: Data?

    var title: String {
        switch status {
        case .queued: return "Queued"
        case .downloading: return "Downloading \(Int(progress * 100))%"
        case .paused: return "Paused"
        case .failed: return "Failed — Retry"
        case .downloaded: return "Downloaded"
        }
    }
    var seriesKey: String { series.map { PlaybackProgressStore.key(for: $0) } ?? item.seriesID ?? item.groupTitle }
}

/// Serial disk work keeps movie bytes, package enumeration, and manifest writes off the UI thread.
actor DownloadStorage {
    nonisolated let root: URL
    private var savedRevision = 0
    init(root: URL) { self.root = root }

    nonisolated func url(_ relativePath: String) -> URL? {
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), !relativePath.contains("..") else { return nil }
        return url
    }

    nonisolated static func validHLSLocation(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension == "movpkg" else { return false }
        let path = url.standardizedFileURL.path
        let roots = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            + FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return roots.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    func load() throws -> [DownloadRecord] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = root
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        let manifest = root.appendingPathComponent("downloads.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        guard (try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 16 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        var records = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: manifest))
        var ids = Set<String>()
        records = records.filter { $0.id == PlaybackProgressStore.key(for: $0.item) && ids.insert($0.id).inserted }
        for index in records.indices {
            if let path = records[index].videoPath, url(path) == nil { records[index].videoPath = nil }
            if let location = records[index].hlsURL, !Self.validHLSLocation(location) {
                // iOS may relocate the app container during updates or restores.
                let parts = location.standardizedFileURL.pathComponents
                let rebased = [FileManager.SearchPathDirectory.libraryDirectory, .documentDirectory].compactMap { directory -> URL? in
                    let name = directory == .libraryDirectory ? "Library" : "Documents"
                    guard let boundary = parts.lastIndex(of: name), let base = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return nil }
                    let candidate = base.appendingPathComponent(parts.dropFirst(boundary + 1).joined(separator: "/"))
                    return Self.validHLSLocation(candidate) && FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
                }.first
                records[index].hlsURL = rebased
            }
            let id = records[index].id, attempt = records[index].attempt
            records[index].subtitles = records[index].subtitles.compactMap { source in
                guard source.url.isFileURL, source.url.path.contains("/\(id)/\(attempt)/"),
                      let local = url("\(id)/\(attempt)/\(source.url.lastPathComponent)") else { return nil }
                return SubtitleSource(url: local, label: source.label)
            }
            if records[index].status == .downloaded {
                let video = records[index].videoPath.flatMap(url) ?? records[index].hlsURL
                if video == nil || !FileManager.default.fileExists(atPath: video!.path) {
                    records[index].status = .failed
                    records[index].message = "The offline file is missing. Download it again."
                }
            }
        }
        return records
    }

    func save(_ records: [DownloadRecord], revision: Int = 1) throws {
        guard revision >= savedRevision else { return }
        savedRevision = revision
        let target = root.appendingPathComponent("downloads.json")
        try JSONEncoder().encode(records).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    func saveData(_ data: Data, id: String, attempt: UUID, filename: String) throws -> String {
        try Task.checkCancellation()
        let path = "\(id)/\(attempt)/\(filename)"
        guard let target = url(path) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return path
    }

    func saveSubtitle(_ data: Data, id: String, attempt: UUID, number: Int) throws -> String {
        _ = try SubtitleDocument(data: data)
        return try saveData(data, id: id, attempt: attempt, filename: "subtitle-\(number).vtt")
    }

    func deleteAttempt(_ record: DownloadRecord) throws {
        guard record.id.count == 64, record.id.allSatisfy(\.isHexDigit), let folder = url("\(record.id)/\(record.attempt)") else { return }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        if let hls = record.hlsURL, Self.validHLSLocation(hls), FileManager.default.fileExists(atPath: hls.path) {
            try FileManager.default.removeItem(at: hls)
        }
    }

    func size(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        var total: Int64 = 0
        while let file = contents?.nextObject() as? URL {
            if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    func delete(_ record: DownloadRecord) throws {
        guard record.id.count == 64, record.id.allSatisfy(\.isHexDigit) else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = root.appendingPathComponent(record.id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        if let hls = record.hlsURL, Self.validHLSLocation(hls), FileManager.default.fileExists(atPath: hls.path) {
            try FileManager.default.removeItem(at: hls)
        }
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var ready = false
    @Published private(set) var loading = true
    @Published private(set) var isOnline = true
    @Published var errorMessage: String?
    @Published private(set) var deleting = Set<String>()
    let storage: DownloadStorage
    private var delegate: DownloadDelegate!
    private var fileSession: URLSession!
    private let fileConfiguration: URLSessionConfiguration
    private var hlsSession: AVAssetDownloadURLSession?
    private var tasks: [String: URLSessionTask] = [:]
    private var pausing = Set<String>()
    private var finishing: [String: Task<Void, Never>] = [:]
    private var preparing: [String: Task<Void, Never>] = [:]
    private let monitor = NWPathMonitor()
    private let subtitleFetch: @Sendable (M3UItem) async throws -> [SubtitleSource]
    private let hlsIdentifier: String
    private var lastProgress = [String: Date]()
    private var saveTask: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var revision = 0
    private var invalidated = false
    private var backgroundCompletions: [String: () -> Void] = [:]

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EasyIPTV/Downloads"), configuration: URLSessionConfiguration? = nil,
         monitorNetwork: Bool = true,
         subtitleFetch: @escaping @Sendable (M3UItem) async throws -> [SubtitleSource] = { try await XtreamCodesManager().fetchSubtitleSources(for: $0) }) {
        storage = DownloadStorage(root: root)
        self.subtitleFetch = subtitleFetch
        hlsIdentifier = "com.easyiptv.downloads.hls.v1"
        let config = configuration ?? .background(withIdentifier: "com.easyiptv.downloads.files.v1")
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        fileConfiguration = config
        delegate = DownloadDelegate(storage: storage)
        delegate.owner = self
        if monitorNetwork {
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in self?.updateConnectivity(path.status == .satisfied) }
            }
            monitor.start(queue: DispatchQueue(label: "EasyIPTV.download-network"))
        }
        startup = Task { [weak self, storage] in
            do {
                let records = try await storage.load()
                guard let self, !Task.isCancelled else { return }
                self.records = records
                self.fileSession = URLSession(configuration: self.fileConfiguration, delegate: self.delegate, delegateQueue: self.delegate.queue)
                var existing = await self.fileSession.allTasks
                if records.contains(where: { $0.item.isHLS && $0.status != .downloaded }) || self.backgroundCompletions[self.hlsIdentifier] != nil {
                    existing += await self.assetSession().allTasks
                }
                for task in existing {
                    guard let record = self.records.first(where: { self.token($0) == task.taskDescription }),
                          record.status != .downloaded && record.status != .failed else { task.cancel(); continue }
                    if task.state == .running { task.suspend() }
                    self.tasks[record.id] = task
                }
                for index in self.records.indices where self.records[index].status == .downloading && self.finishing[self.records[index].id] == nil {
                    self.records[index].status = .queued
                }
                self.ready = true
                self.loading = false
                for record in self.records where record.mediaComplete && record.status != .downloaded && record.status != .failed {
                    self.completed(self.token(record), error: nil)
                }
                self.persist(); self.pump()
            } catch {
                self?.loading = false
                self?.errorMessage = "Couldn't open the downloads library. \(error.localizedDescription)"
            }
        }
    }

    deinit {
        monitor.cancel(); startup?.cancel(); saveTask?.cancel()
        finishing.values.forEach { $0.cancel() }
        preparing.values.forEach { $0.cancel() }
        fileSession?.finishTasksAndInvalidate(); hlsSession?.finishTasksAndInvalidate()
    }

    private func assetSession() -> AVAssetDownloadURLSession {
        if let hlsSession { return hlsSession }
        let config = URLSessionConfiguration.background(withIdentifier: hlsIdentifier)
        hlsSession = AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: delegate, delegateQueue: delegate.queue)
        return hlsSession!
    }

    func record(for item: M3UItem) -> DownloadRecord? { records.first { $0.id == PlaybackProgressStore.key(for: item) } }
    func updateConnectivity(_ online: Bool) { isOnline = online }
    func localURL(for item: M3UItem) -> URL? {
        guard let record = record(for: item), record.status == .downloaded else { return nil }
        let url = record.videoPath.flatMap(storage.url) ?? record.hlsURL
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    func poster(for record: DownloadRecord) -> URL? { record.posterPath.flatMap(storage.url) ?? record.item.logoURL ?? record.series?.logoURL }
    func updateDetails(for item: M3UItem, details: MediaDetails?) {
        guard let details, let index = records.firstIndex(where: { $0.id == PlaybackProgressStore.key(for: item) }) else { return }
        records[index].details = details
        persist()
    }
    func canPause(_ record: DownloadRecord) -> Bool { finishing[record.id] == nil }
    func token(_ record: DownloadRecord) -> String { "\(record.id)|\(record.attempt)" }
    private func index(_ token: String) -> Int? { records.firstIndex { self.token($0) == token } }

    func enqueue(_ item: M3UItem, series: M3UItem? = nil, details: MediaDetails? = nil) {
        guard ready, record(for: item) == nil else { return }
        guard item.contentType != .live, ["http", "https"].contains(item.streamURL.scheme?.lowercased() ?? "") else {
            errorMessage = "Only movie and episode HTTP/HTTPS media can be downloaded."; return
        }
        guard item.streamURL.pathExtension.lowercased() != "mpd" else {
            errorMessage = "DASH downloads aren't supported by this player."; return
        }
        records.append(DownloadRecord(id: PlaybackProgressStore.key(for: item), item: item, series: series, details: details))
        persist(); pump()
    }

    private func pump() {
        guard ready else { return }
        while records.filter({ $0.status == .downloading }).count < 2,
              let index = records.firstIndex(where: { $0.status == .queued && !deleting.contains($0.id) && !pausing.contains($0.id) }) {
            let record = records[index]
            let task: URLSessionTask
            if let existing = tasks[record.id] { task = existing }
            else if record.item.isHLS {
                records[index].status = .downloading
                prepareHLS(record)
                persist()
                continue
            } else {
                task = record.resumeData.map { fileSession.downloadTask(withResumeData: $0) } ?? fileSession.downloadTask(with: record.item.streamURL)
                records[index].resumeData = nil
            }
            task.taskDescription = token(record)
            tasks[record.id] = task
            records[index].status = .downloading
            records[index].message = nil
            task.resume()
            persist()
        }
    }

    private func prepareHLS(_ record: DownloadRecord) {
        let token = token(record), asset = AVURLAsset(url: record.item.streamURL)
        preparing[record.id] = Task { [weak self] in
            do {
                let configuration = try await withTaskCancellationHandler(operation: {
                    try await Self.hlsConfiguration(asset: asset, title: record.item.name)
                }, onCancel: { asset.cancelLoading() })
                guard let self, let index = self.index(token), self.records[index].status == .downloading else { return }
                let task = self.assetSession().makeAssetDownloadTask(downloadConfiguration: configuration)
                task.taskDescription = token
                self.tasks[record.id] = task
                self.preparing[record.id] = nil
                task.resume()
            } catch {
                guard !Task.isCancelled, let self, self.index(token) != nil else { asset.cancelLoading(); return }
                self.preparing[record.id] = nil
                self.completed(token, error: "This HLS source couldn't be prepared for offline playback. It may be unavailable or protected.")
            }
        }
    }

    static func hlsConfiguration(asset: AVURLAsset, title: String) async throws -> AVAssetDownloadConfiguration {
        let preferred = try await asset.load(.preferredMediaSelection)
        let group = try await asset.loadMediaSelectionGroup(for: .legible)
        try Task.checkCancellation()
        var selections: [AVMediaSelection] = [preferred]
        for option in group?.options ?? [] {
            if let group, let selection = preferred.mutableCopy() as? AVMutableMediaSelection {
                selection.select(option, in: group)
                selections.append(selection)
            }
        }
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: title)
        configuration.primaryContentConfiguration.mediaSelections = selections
        return configuration
    }

    func pause(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              [.downloading, .queued].contains(records[index].status), finishing[id] == nil else { return }
        records[index].status = .paused
        if let preparation = preparing.removeValue(forKey: id) {
            preparation.cancel(); records[index].attempt = UUID()
        }
        if let task = tasks[id] as? URLSessionDownloadTask {
            tasks[id] = nil
            lastProgress[token(records[index])] = nil
            records[index].attempt = UUID()
            let token = token(records[index])
            pausing.insert(id)
            task.cancel { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self, !self.invalidated else { return }
                    self.pausing.remove(id)
                    if let index = self.index(token), !self.deleting.contains(id) {
                        self.records[index].resumeData = data.flatMap { $0.count <= 256 * 1024 ? $0 : nil }
                        if self.records[index].resumeData == nil {
                            self.records[index].bytes = 0; self.records[index].progress = 0
                            self.records[index].message = "This provider couldn't preserve a partial transfer. Resume starts it again."
                        }
                    }
                    self.persist(); self.pump()
                }
            }
        } else if let task = tasks[id], task.state == .running { task.suspend() }
        persist(); pump()
    }
    func resume(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].status == .paused else { return }
        records[index].status = .queued
        persist(); pump()
    }
    func retry(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].status == .failed
            || (records[index].status == .downloaded && localURL(for: records[index].item) == nil) else { return }
        let previous = records[index]
        Task { [storage] in try? await storage.deleteAttempt(previous) }
        records[index].attempt = UUID(); records[index].progress = 0
        records[index].bytes = 0; records[index].message = nil
        records[index].videoPath = nil; records[index].hlsURL = nil
        records[index].mediaComplete = false
        records[index].resumeData = nil
        records[index].status = .queued
        persist(); pump()
    }

    func remove(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), deleting.insert(id).inserted else { return }
        let record = records[index]
        lastProgress[token(record)] = nil
        if let data = record.resumeData { fileSession.downloadTask(withResumeData: data).cancel() }
        records[index].attempt = UUID(); records[index].status = .paused
        tasks.removeValue(forKey: id)?.cancel()
        finishing.removeValue(forKey: id)?.cancel()
        preparing.removeValue(forKey: id)?.cancel()
        persist(); pump()
        Task { [weak self, storage] in
            do {
                try await storage.delete(record)
                guard let self else { return }
                self.records.removeAll { $0.id == id }; self.deleting.remove(id)
                self.persist()
            } catch {
                guard let self, let index = self.records.firstIndex(where: { $0.id == id }) else { return }
                self.records[index].status = .failed
                self.records[index].message = "Couldn't delete the files. \(error.localizedDescription)"
                self.deleting.remove(id); self.persist()
            }
        }
    }

    func update(_ token: String, bytes: Int64, total: Int64, fraction: Double? = nil) {
        guard let index = index(token), records[index].status == .downloading else { return }
        guard Date().timeIntervalSince(lastProgress[token] ?? .distantPast) >= 0.25 else { return }
        lastProgress[token] = Date()
        records[index].bytes = max(0, bytes); records[index].totalBytes = max(0, total)
        let progress = fraction ?? (total > 0 ? Double(bytes) / Double(total) : 0)
        records[index].progress = progress.isFinite ? min(0.99, max(0, progress)) : 0
    }

    func received(_ token: String, videoPath: String? = nil, hlsURL: URL? = nil) {
        guard !invalidated else { return }
        guard let index = index(token), !deleting.contains(records[index].id) else {
            if let path = videoPath, let url = storage.url(path) {
                Task.detached { try? FileManager.default.removeItem(at: url) }
            }
            if let hlsURL, DownloadStorage.validHLSLocation(hlsURL) {
                Task.detached { try? FileManager.default.removeItem(at: hlsURL) }
            }
            return
        }
        if let videoPath { records[index].videoPath = videoPath }
        if let hlsURL, DownloadStorage.validHLSLocation(hlsURL) { records[index].hlsURL = hlsURL }
        persist()
    }

    func completed(_ token: String, error: String?) {
        guard !invalidated, let index = index(token) else { return }
        let record = records[index]
        tasks[record.id] = nil; lastProgress[token] = nil
        guard record.status != .downloaded, finishing[record.id] == nil, !deleting.contains(record.id) else { return }
        guard error == nil, let video = record.videoPath.flatMap(storage.url) ?? record.hlsURL else {
            records[index].status = .failed
            records[index].mediaComplete = false
            records[index].message = error ?? "The provider returned no offline media. Try again."
            persist(); pump(); return
        }
        let fetchSubtitles = subtitleFetch
        records[index].mediaComplete = true
        records[index].status = .downloading
        records[index].message = "Saving subtitles and artwork…"
        finishing[record.id] = Task { [weak self, storage] in
            if (try? await AVURLAsset(url: video).load(.hasProtectedContent)) == true {
                guard let self, !Task.isCancelled else { return }
                self.finishing[record.id] = nil
                self.completed(token, error: "DRM-protected media can't be saved for offline playback by this player.")
                try? await storage.deleteAttempt(record)
                return
            }
            guard !Task.isCancelled else { return }
            var subtitles: [SubtitleSource] = []
            var posterPath: String?
            var warning: String?
            do {
                let sources = try await fetchSubtitles(record.item)
                var urls = Set<URL>()
                for (number, source) in sources.filter({ urls.insert($0.url).inserted }).enumerated() {
                    try Task.checkCancellation()
                    do {
                        let data = try await SubtitleFileCache.download(source.url)
                        let path = try await storage.saveSubtitle(data, id: record.id, attempt: record.attempt, number: number)
                        if let url = storage.url(path) { subtitles.append(SubtitleSource(url: url, label: source.label)) }
                    } catch {
                        try Task.checkCancellation()
                        warning = "Some provider subtitles couldn't be saved. Embedded tracks are still available."
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                warning = "Provider subtitles couldn't be saved. Embedded tracks are still available."
            }
            if let poster = record.details?.poster ?? record.item.logoURL ?? record.series?.logoURL {
                // Artwork is optional and uses the same bounded fetch as subtitle sidecars.
                if let data = try? await SubtitleFileCache.download(poster) {
                    posterPath = try? await storage.saveData(data, id: record.id, attempt: record.attempt, filename: "poster")
                }
            }
            let bytes = await storage.size(video)
            guard let self, !Task.isCancelled, let index = self.index(token), !self.deleting.contains(record.id) else {
                return
            }
            if bytes == 0 {
                self.finishing[record.id] = nil
                self.completed(token, error: "The offline media file is missing or inaccessible. Download it again.")
                return
            }
            self.records[index].bytes = bytes; self.records[index].totalBytes = bytes
            self.records[index].subtitles = subtitles; self.records[index].posterPath = posterPath
            self.records[index].status = .downloaded; self.records[index].progress = 1
            self.records[index].message = warning
            self.finishing[record.id] = nil
            self.persist(); self.pump()
        }
        persist()
    }

    private func persist() {
        revision += 1
        let revision = revision, snapshot = records
        saveTask?.cancel()
        saveTask = Task { [weak self, storage] in
            do {
                try Task.checkCancellation()
                try await storage.save(snapshot, revision: revision)
            } catch {
                guard !Task.isCancelled, self?.revision == revision else { return }
                self?.errorMessage = "Couldn't save download status. \(error.localizedDescription)"
            }
        }
    }

    func handleBackgroundEvents(_ identifier: String, completion: @escaping () -> Void) {
        backgroundCompletions[identifier] = completion
        if ready, identifier == hlsIdentifier { _ = assetSession() }
    }
    func finishBackgroundEvents(_ identifier: String) async {
        await flush()
        backgroundCompletions.removeValue(forKey: identifier)?()
    }

    func invalidate() {
        invalidated = true; ready = false
        startup?.cancel(); monitor.cancel()
        finishing.values.forEach { $0.cancel() }; finishing.removeAll()
        preparing.values.forEach { $0.cancel() }; preparing.removeAll()
        fileSession?.invalidateAndCancel(); hlsSession?.invalidateAndCancel()
    }
    func flush() async { await saveTask?.value }

}

/// URLSession owns its delegate; the weak owner avoids retaining the download manager forever.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    weak var owner: DownloadManager?
    let storage: DownloadStorage
    let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "EasyIPTV.download-events"
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        return queue
    }()
    private var fileErrors: [String: String] = [:]
    private var files: [String: String] = [:]
    private var assets: [String: URL] = [:]
    init(storage: DownloadStorage) { self.storage = storage }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor [weak owner] in await owner?.finishBackgroundEvents(identifier) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let token = downloadTask.taskDescription else { return }
        Task { @MainActor [weak owner] in owner?.update(token, bytes: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let token = downloadTask.taskDescription else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                fileErrors[token] = "The provider rejected the download (HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0))."; return
            }
            let type = response.mimeType?.lowercased() ?? ""
            guard !type.contains("html"), !type.contains("json"), !type.contains("mpegurl") else {
                fileErrors[token] = "The provider returned a page or playlist instead of a media file."; return
            }
            let parts = token.split(separator: "|")
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit), UUID(uuidString: String(parts[1])) != nil else { return }
            let ext = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? "mp4"
            let suffix = ["mp4", "mkv", "avi", "mov", "m4v", "ts", "webm"].contains(ext) ? ext : "mp4"
            let path = "\(parts[0])/\(parts[1])/video.\(suffix)"
            guard let target = storage.url(path) else { return }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { fileErrors[token] = "The downloaded file was empty."; return }
            let handle = try FileHandle(forReadingFrom: location)
            let prefix = try handle.read(upToCount: 256) ?? Data()
            try handle.close()
            let text = String(data: prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !text.hasPrefix("#extm3u"), !text.hasPrefix("<html"), !text.hasPrefix("<!doctype html") else {
                fileErrors[token] = "The provider returned a playlist or login page instead of a media file."; return
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
            files[token] = path
        } catch { fileErrors[token] = "Couldn't save the video. Check available disk space and retry." }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let token = assetDownloadTask.taskDescription else { return }
        assets[token] = location
    }
    @available(macOS 14, iOS 18, *)
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        guard let token = assetDownloadTask.taskDescription else { return }
        assets[token] = location
        Task { @MainActor [weak owner] in owner?.received(token, hlsURL: location) }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let token = assetDownloadTask.taskDescription else { return }
        let duration = timeRangeExpectedToLoad.duration.seconds
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        Task { @MainActor [weak owner] in owner?.update(token, bytes: 0, total: 0, fraction: duration > 0 ? loaded / duration : 0) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let token = task.taskDescription else { return }
        let path = files.removeValue(forKey: token), asset = assets.removeValue(forKey: token)
        let message = fileErrors.removeValue(forKey: token) ?? error.map { error in
            let code = (error as NSError).code
            if code == NSURLErrorNotConnectedToInternet { return "No internet connection. Reconnect and retry the download." }
            if code == NSURLErrorCancelled { return "Download cancelled. Retry to start again." }
            return "Download failed. Check your connection, provider access, and free disk space, then retry."
        }
        Task { @MainActor [weak owner] in
            owner?.received(token, videoPath: path, hlsURL: asset)
            owner?.completed(token, error: message)
        }
    }
}
