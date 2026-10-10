import Foundation
import CryptoKit
import SQLite3

enum GuideSearchError: LocalizedError {
    case database, capacity, slowQuery
    var errorDescription: String? {
        switch self {
        case .database: return "The guide search cache could not be opened or updated."
        case .capacity: return "The guide exceeds the safe cache size, or there is not enough disk space."
        case .slowQuery: return "This search took too long. Try a more specific team or programme name."
        }
    }
}

enum GuideSearchScope: String, CaseIterable, Sendable {
    case now = "On now", later = "Later today"
}

struct GuideSearchHit: Identifiable, Sendable {
    let id: String
    let channelKey: String
    let program: GuideProgram
}

struct GuideSearchPage: Sendable {
    let hits: [GuideSearchHit]
    let hasMore: Bool
}

struct GuideRefreshSummary: Sendable {
    let searchableChannels: Int
    let unavailableChannels: Int
    let failedFeeds: Int
    let failureMessage: String?
}

// Separate connections let searches read the last committed guide while a refresh imports XML.
actor GuideSearchIndex {
    typealias Download = @Sendable (URL) async throws -> URL
    static let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EasyIPTV/GuideSearch", isDirectory: true)
        .appendingPathComponent("guide-v1.sqlite")
    private let url: URL
    private let download: Download
    private var refreshTask: (id: UUID, task: Task<GuideRefreshSummary, Error>)?

    init(url: URL = cacheURL, download: @escaping Download = { try await GuideSearchIndex.downloadFeed($0) }) {
        self.url = url; self.download = download
    }

    deinit { refreshTask?.task.cancel() }

    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func channelKey(_ channel: M3UItem) -> String { key(channel.streamURL.absoluteString) }

    static func matchExpression(_ text: String) -> String? {
        // Treat input as literal words, not user-supplied FTS operators or SQL.
        let words = text.prefix(128).split { !$0.isLetter && !$0.isNumber }.prefix(8)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    func refresh(channels: [M3UItem], force: Bool = false, now: Date = Date(),
                 calendar: Calendar = .current) async throws -> GuideRefreshSummary {
        if let previous = refreshTask, previous.task.isCancelled {
            _ = try? await previous.task.value
            if refreshTask?.id == previous.id { refreshTask = nil }
        }
        try Task.checkCancellation()
        let task: Task<GuideRefreshSummary, Error>, id: UUID
        if let existing = refreshTask { task = existing.task; id = existing.id }
        else {
            id = UUID()
            let url = self.url, download = self.download
            task = Task.detached(priority: .utility) {
                try await Self.importFeeds(channels: channels, url: url, force: force,
                                           now: now, calendar: calendar, download: download)
            }
            refreshTask = (id, task)
        }
        defer { if refreshTask?.id == id { refreshTask = nil } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func search(_ text: String, scope: GuideSearchScope, offset: Int = 0,
                now: Date = Date(), calendar: Calendar = .current) throws -> GuideSearchPage {
        try Task.checkCancellation()
        guard let match = Self.matchExpression(text), FileManager.default.fileExists(atPath: url.path) else {
            return GuideSearchPage(hits: [], hasMore: false)
        }
        let db = try GuideDatabase(url: url, readOnly: true)
        let deadline = QueryDeadline()
        sqlite3_progress_handler(db.handle, 1_000, { pointer in
            guard let pointer else { return 1 }
            let budget = Unmanaged<QueryDeadline>.fromOpaque(pointer).takeUnretainedValue()
            return Task.isCancelled || ProcessInfo.processInfo.systemUptime > budget.end ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { withExtendedLifetime(deadline) { sqlite3_progress_handler(db.handle, 0, nil, nil) } }
        let midnight = calendar.dateInterval(of: .day, for: now)?.end ?? now
        let condition = scope == .now ? "p.start <= ? AND p.end > ?" : "p.start > ? AND p.start < ?"
        let statement = try db.prepare("""
            SELECT c.key, p.id, p.title, p.description, p.start, p.end, p.categories
            FROM guide_fts JOIN programs p ON p.id = guide_fts.rowid
            JOIN channels c ON c.feed = p.feed AND c.tvg = p.tvg
            WHERE guide_fts MATCH ? AND \(condition)
            ORDER BY p.start, p.id, c.key LIMIT 51 OFFSET ?
            """)
        try statement.bind([match, String(now.timeIntervalSince1970),
                            String((scope == .now ? now : midnight).timeIntervalSince1970),
                            String(max(0, offset))])
        var hits: [GuideSearchHit] = []
        while try statement.step() {
            try Task.checkCancellation()
            let key = statement.text(0)
            hits.append(GuideSearchHit(id: "\(key)|\(statement.text(1))", channelKey: key,
                program: GuideProgram(title: statement.text(2), description: statement.text(3),
                                      start: Date(timeIntervalSince1970: statement.number(4)),
                                      end: Date(timeIntervalSince1970: statement.number(5)), categories: statement.text(6))))
        }
        return GuideSearchPage(hits: Array(hits.prefix(50)), hasMore: hits.count > 50)
    }

    private static func importFeeds(channels: [M3UItem], url: URL, force: Bool, now: Date,
                                    calendar: Calendar, download: Download) async throws -> GuideRefreshSummary {
        try Task.checkCancellation()
        let db = try GuideDatabase(url: url)
        let live = channels.filter { $0.contentType == .live }
        var feeds: [URL: Set<String>] = [:]
        var mapped = 0
        try db.transaction {
            try db.execute("DELETE FROM channels")
            let insert = try db.prepare("INSERT OR IGNORE INTO channels(key,feed,tvg) VALUES(?,?,?)")
            for channel in live {
                try Task.checkCancellation()
                guard let tvg = channel.tvgID, !tvg.isEmpty, tvg.utf8.count <= 1_024,
                      let feed = TVGuide.feedURL(for: channel) else { continue }
                feeds[feed, default: []].insert(tvg)
                try insert.bind([channelKey(channel), key(feed.absoluteString), tvg])
                _ = try insert.step()
                mapped += 1
            }
            try db.execute("DELETE FROM programs WHERE feed NOT IN (SELECT feed FROM channels)")
            try db.execute("DELETE FROM freshness WHERE feed NOT IN (SELECT feed FROM channels)")
            let prune = try db.prepare("DELETE FROM programs WHERE end <= ?")
            try prune.bind([String(now.timeIntervalSince1970)])
            _ = try prune.step()
        }
        let midnight = calendar.dateInterval(of: .day, for: now)?.end ?? now
        var failures = 0
        var failureMessage: String?
        for (feed, ids) in feeds.sorted(by: { $0.key.absoluteString < $1.key.absoluteString }) {
            try Task.checkCancellation()
            let feedKey = key(feed.absoluteString)
            let fingerprint = key(ids.sorted().joined(separator: "\n"))
            let cached = try db.prepare("SELECT updated, until, fingerprint FROM freshness WHERE feed = ?")
            try cached.bind([feedKey])
            if !force, try cached.step(), now.timeIntervalSince1970 - cached.number(0) < 10_800,
               cached.number(0) <= now.timeIntervalSince1970,
               cached.number(1) == midnight.timeIntervalSince1970, cached.text(2) == fingerprint { continue }
            do {
                let file = try await download(feed)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                guard let stream = InputStream(url: file) else { throw GuideError.invalidFeed }
                try importXML(XMLParser(stream: stream), db: db, feedKey: feedKey,
                              channelIDs: ids, now: now, calendar: calendar)
                let stamp = try db.prepare("INSERT OR REPLACE INTO freshness VALUES(?,?,?,?)")
                try stamp.bind([feedKey, String(now.timeIntervalSince1970), String(midnight.timeIntervalSince1970), fingerprint])
                _ = try stamp.step()
            } catch {
                try Task.checkCancellation()
                failures += 1
                failureMessage = (error as? GuideSearchError)?.errorDescription
                    ?? (error as? GuideError)?.errorDescription ?? GuideError.download.errorDescription
            }
        }
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return GuideRefreshSummary(searchableChannels: mapped, unavailableChannels: live.count - mapped,
                                   failedFeeds: failures, failureMessage: failureMessage)
    }

    static func importXML(_ parser: XMLParser, db: GuideDatabase, feedKey: String,
                          channelIDs: Set<String>, now: Date, calendar: Calendar) throws {
        try db.transaction {
            let remove = try db.prepare("DELETE FROM programs WHERE feed = ?")
            try remove.bind([feedKey]); _ = try remove.step()
            let insert = try db.prepare("INSERT OR IGNORE INTO programs(feed,tvg,title,description,start,end,categories) VALUES(?,?,?,?,?,?,?)")
            var count = 0
            let delegate = XMLTVPrograms(channelIDs: channelIDs, now: now, calendar: calendar) { channel, program in
                try Task.checkCancellation()
                count += 1
                guard count <= 500_000 else { throw GuideSearchError.capacity }
                try insert.bind([feedKey, channel, program.title, program.description,
                                 String(program.start.timeIntervalSince1970), String(program.end.timeIntervalSince1970), program.categories])
                _ = try insert.step()
            }
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = delegate
            let parsed = parser.parse()
            try Task.checkCancellation()
            if let error = delegate.failure { throw error }
            guard parsed, delegate.isTV else { throw GuideError.invalidFeed }
        }
    }

    static func downloadFeed(_ url: URL) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        if let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < 512 * 1024 * 1024 { throw GuideSearchError.capacity }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let (file, response) = try await session.download(for: request, delegate: GuideDownloadLimit())
        do {
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw GuideError.download }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_024 * 1_024 * 1_024 else { throw GuideSearchError.capacity }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}

private final class QueryDeadline { let end = ProcessInfo.processInfo.systemUptime + 1 }

private final class GuideDownloadLimit: NSObject, URLSessionDownloadDelegate {
    private var checkedAt: Int64 = 0
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // This is a disk/network safety budget, not an in-memory guide-size restriction.
        if totalBytesWritten > 1_024 * 1_024 * 1_024 || totalBytesExpectedToWrite > 1_024 * 1_024 * 1_024 {
            downloadTask.cancel()
        }
        if totalBytesWritten - checkedAt >= 16 * 1024 * 1024 {
            checkedAt = totalBytesWritten
            if let free = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, free < 64 * 1024 * 1024 { downloadTask.cancel() }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

final class GuideDatabase {
    private(set) var handle: OpaquePointer?
    init(url: URL, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle); handle = nil; throw GuideSearchError.database
        }
        do {
            sqlite3_busy_timeout(handle, 2_000)
            try execute("PRAGMA cache_size=-2048; PRAGMA temp_store=FILE; PRAGMA mmap_size=0")
            if !readOnly {
                try execute("""
                    PRAGMA page_size=4096;
                    PRAGMA journal_mode=WAL;
                    PRAGMA journal_size_limit=16777216;
                    PRAGMA max_page_count=65536;
                    CREATE TABLE IF NOT EXISTS channels(key TEXT PRIMARY KEY, feed TEXT NOT NULL, tvg TEXT NOT NULL);
                    CREATE INDEX IF NOT EXISTS channel_guide ON channels(feed,tvg);
                    CREATE TABLE IF NOT EXISTS programs(id INTEGER PRIMARY KEY, feed TEXT NOT NULL, tvg TEXT NOT NULL,
                        title TEXT NOT NULL, description TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
                        categories TEXT NOT NULL, UNIQUE(feed,tvg,start,end,title));
                    CREATE INDEX IF NOT EXISTS program_time ON programs(start,end);
                    CREATE TABLE IF NOT EXISTS freshness(feed TEXT PRIMARY KEY, updated REAL, until REAL, fingerprint TEXT);
                    CREATE VIRTUAL TABLE IF NOT EXISTS guide_fts USING fts5(title,description,categories,content='programs',content_rowid='id');
                    CREATE TRIGGER IF NOT EXISTS program_insert AFTER INSERT ON programs BEGIN
                        INSERT INTO guide_fts(rowid,title,description,categories) VALUES(new.id,new.title,new.description,new.categories);
                    END;
                    CREATE TRIGGER IF NOT EXISTS program_delete AFTER DELETE ON programs BEGIN
                        INSERT INTO guide_fts(guide_fts,rowid,title,description,categories)
                            VALUES('delete',old.id,old.title,old.description,old.categories);
                    END;
                    """)
            }
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        try check(code)
    }
    func prepare(_ sql: String) throws -> GuideStatement { try GuideStatement(db: self, sql: sql) }
    func check(_ code: Int32) throws {
        if code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE { return }
        try Task.checkCancellation()
        if code == SQLITE_FULL { throw GuideSearchError.capacity }
        if code == SQLITE_INTERRUPT { throw GuideSearchError.slowQuery }
        throw GuideSearchError.database
    }
    func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try Task.checkCancellation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
}

final class GuideStatement {
    private let db: GuideDatabase
    private var handle: OpaquePointer?
    init(db: GuideDatabase, sql: String) throws {
        self.db = db
        let code = sqlite3_prepare_v2(db.handle, sql, -1, &handle, nil)
        do { try db.check(code) }
        catch { sqlite3_finalize(handle); handle = nil; throw error }
    }
    deinit { sqlite3_finalize(handle) }
    func bind(_ values: [String]) throws {
        sqlite3_reset(handle); sqlite3_clear_bindings(handle)
        for (index, value) in values.enumerated() {
            try db.check(sqlite3_bind_text(handle, Int32(index + 1), value, -1,
                                          unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
        }
    }
    func step() throws -> Bool { let code = sqlite3_step(handle); try db.check(code); return code == SQLITE_ROW }
    func text(_ column: Int32) -> String { sqlite3_column_text(handle, column).map { String(cString: $0) } ?? "" }
    func number(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
}
