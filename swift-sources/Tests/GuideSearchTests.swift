import XCTest
import SQLite3
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import EasyIPTV

private actor GuideDownloads {
    var payload = ""
    var count = 0
    var delay: UInt64 = 0
    func configure(_ xml: String, delay: UInt64 = 0) { payload = xml; self.delay = delay }
    func requests() -> Int { count }
    func download(_ url: URL) async throws -> URL {
        count += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        try Task.checkCancellation()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("guide-test-\(UUID()).xml")
        try Data(payload.utf8).write(to: file)
        return file
    }
}

final class GuideSearchTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-10-10T09:30:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var xml: String {
        """
        <tv>
          <programme channel="one" start="20261010090000 +0000" stop="20261010100000 +0000"><title>Arsenal v Chelsea</title><desc>Live Premier League coverage</desc><category>Football</category></programme>
          <programme channel="one" start="20261010140000 +0000" stop="20261010160000 +0000"><title>Later match</title><desc>Barcelona plays today</desc><category>Football</category></programme>
          <programme channel="one" start="20261010080000 +0000" stop="20261010093000 +0000"><title>Ended football</title></programme>
          <programme channel="one" start="20261011090000 +0000" stop="20261011100000 +0000"><title>Tomorrow football</title></programme>
          <programme channel="unknown" start="20261010090000 +0000" stop="20261010100000 +0000"><title>Unmapped football</title></programme>
        </tv>
        """
    }
    private func channel(_ id: Int = 1, provider: String = "provider", tvg: String? = "one") -> M3UItem {
        M3UItem(name: "Sports \(id)", streamURL: URL(string: "https://\(provider).example/live/alice/secret/\(id).ts")!,
                tvgID: tvg, contentType: .live)
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("guide-search-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func store(_ downloads: GuideDownloads) -> GuideSearchIndex {
        GuideSearchIndex(url: root.appendingPathComponent("guide.sqlite"), download: { try await downloads.download($0) })
    }

    func testSearchMatchesTitlesDescriptionsCategoriesAndTimeWindow() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let index = store(downloads)
        let summary = try await index.refresh(channels: [channel(), channel(2, tvg: nil)], now: now, calendar: calendar)
        XCTAssertEqual(summary.searchableChannels, 1)
        XCTAssertEqual(summary.unavailableChannels, 1)
        XCTAssertEqual(summary.failedFeeds, 0)
        for word in ["arsenal", "PREMIER", "football", "chel"] {
            let page = try await index.search(word, scope: .now, now: now, calendar: calendar)
            XCTAssertEqual(page.hits.map(\.program.title), ["Arsenal v Chelsea"])
            XCTAssertEqual(page.hits.first?.channelKey, GuideSearchIndex.channelKey(channel()))
        }
        let later = try await index.search("barcelona", scope: .later, now: now, calendar: calendar)
        XCTAssertEqual(later.hits.map(\.program.title), ["Later match"])
        let end = try await index.search("arsenal", scope: .now, now: now.addingTimeInterval(1800), calendar: calendar)
        XCTAssertTrue(end.hits.isEmpty, "Programme stop times are exclusive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("guide.sqlite").path))
    }

    func testPaginationIncludesAllPlayableVariantsWithoutUnboundedResults() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let index = store(downloads)
        _ = try await index.refresh(channels: (1...105).map { channel($0) }, now: now, calendar: calendar)
        let first = try await index.search("football", scope: .now, now: now, calendar: calendar)
        let second = try await index.search("football", scope: .now, offset: 50, now: now, calendar: calendar)
        let third = try await index.search("football", scope: .now, offset: 100, now: now, calendar: calendar)
        XCTAssertEqual(first.hits.count, 50); XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.hits.count, 50); XCTAssertTrue(second.hasMore)
        XCTAssertEqual(third.hits.count, 5); XCTAssertFalse(third.hasMore)
        XCTAssertEqual(Set((first.hits + second.hits + third.hits).map(\.channelKey)).count, 105)
        let requests = await downloads.requests(); XCTAssertEqual(requests, 1)
    }

    func testCacheSurvivesReopeningAndRefreshesAfterTTLOrMidnight() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let first = store(downloads)
        _ = try await first.refresh(channels: [channel()], now: now, calendar: calendar)
        let reopened = store(downloads)
        _ = try await reopened.refresh(channels: [channel()], now: now.addingTimeInterval(60), calendar: calendar)
        var requests = await downloads.requests(); XCTAssertEqual(requests, 1)
        _ = try await reopened.refresh(channels: [channel()], now: now.addingTimeInterval(10_801), calendar: calendar)
        requests = await downloads.requests(); XCTAssertEqual(requests, 2)
        let tonight = now.addingTimeInterval(13 * 3600)
        _ = try await reopened.refresh(channels: [channel()], now: tonight, calendar: calendar)
        _ = try await reopened.refresh(channels: [channel()], now: tonight.addingTimeInterval(2 * 3600), calendar: calendar)
        requests = await downloads.requests(); XCTAssertEqual(requests, 4, "New local day must refresh even inside the TTL")
    }

    func testCacheHitKeepsRealDownloadTimeAndExpiry() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let index = store(downloads)
        let first = try await index.refresh(channels: [channel()], now: now, calendar: calendar)
        let cached = try await index.refresh(channels: [channel()], now: now.addingTimeInterval(10_000), calendar: calendar)
        XCTAssertEqual(first.downloadedFeeds, 1)
        XCTAssertEqual(cached.downloadedFeeds, 0)
        XCTAssertEqual(cached.lastUpdated, now)
        XCTAssertEqual(cached.nextRefresh, now.addingTimeInterval(10_800))
        XCTAssertEqual(cached.nextRefresh, first.nextRefresh)
    }

    func testDownloadTimestampAndFailureBelongToSelectedChannelFeed() async throws {
        let firstDownloads = GuideDownloads(); await firstDownloads.configure(xml)
        let secondDownloads = GuideDownloads(); await secondDownloads.configure(xml)
        let index = GuideSearchIndex(url: root.appendingPathComponent("guide.sqlite"), download: { url in
            if url.host == "provider.example" { return try await firstDownloads.download(url) }
            return try await secondDownloads.download(url)
        })
        let firstChannel = channel()
        let secondChannel = channel(2, provider: "second")
        let channels = [firstChannel, secondChannel]
        _ = try await index.refresh(channels: channels, now: now, calendar: calendar)
        await firstDownloads.configure("<tv/>")
        let refreshedAt = now.addingTimeInterval(60)
        let summary = try await index.refresh(channels: channels, force: true, now: refreshedAt, calendar: calendar)
        XCTAssertEqual(summary.lastUpdated, refreshedAt)
        XCTAssertEqual(summary.failedFeeds, 1)
        let first = try await index.downloadStatus(for: firstChannel)
        let second = try await index.downloadStatus(for: secondChannel)
        XCTAssertEqual(first.updatedAt, now)
        XCTAssertTrue(first.failed)
        XCTAssertEqual(second.updatedAt, refreshedAt)
        XCTAssertFalse(second.failed)
    }

    func testEmptyAndUnmatchedFeedsKeepPreviousListingsAndRetryWithoutForcing() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let index = store(downloads)
        _ = try await index.refresh(channels: [channel()], now: now, calendar: calendar)
        var lastDownload = now
        for (offset, payload) in ["<tv/>", xml.replacingOccurrences(of: "channel=\"one\"", with: "channel=\"wrong\"")].enumerated() {
            let failedAt = now.addingTimeInterval(Double(offset * 100 + 10))
            await downloads.configure(payload)
            let failed = try await index.refresh(channels: [channel()], force: true, now: failedAt, calendar: calendar)
            XCTAssertEqual(failed.failedFeeds, 1)
            XCTAssertEqual(failed.lastUpdated, lastDownload)
            XCTAssertEqual(failed.nextRefresh, failedAt.addingTimeInterval(60))
            let retained = try await index.search("arsenal", scope: .now, now: now, calendar: calendar)
            XCTAssertEqual(retained.hits.count, 1)
            await downloads.configure(xml)
            let retry = try await index.refresh(channels: [channel()], now: failedAt.addingTimeInterval(60), calendar: calendar)
            XCTAssertEqual(retry.downloadedFeeds, 1, "A failed forced refresh must bypass a still-young old cache on retry")
            XCTAssertEqual(retry.failedFeeds, 0)
            lastDownload = failedAt.addingTimeInterval(60)
        }
    }

    func testCoverageReportsValidIDsWithoutMatchingListings() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let summary = try await store(downloads).refresh(channels: [channel(), channel(2, tvg: "missing"), channel(3, tvg: nil)], now: now, calendar: calendar)
        XCTAssertEqual(summary.searchableChannels, 1)
        XCTAssertEqual(summary.channelsWithoutListings, 1)
        XCTAssertEqual(summary.unavailableChannels, 1)
    }

    func testCancelledReaderDoesNotCancelAnotherViewsRefresh() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml, delay: 200_000_000)
        let index = store(downloads), items = [channel()]
        let first = Task { try await index.refresh(channels: items, now: now, calendar: calendar) }
        while await downloads.requests() == 0 { await Task.yield() }
        let second = Task { try await index.refresh(channels: items, now: now, calendar: calendar) }
        try await Task.sleep(nanoseconds: 30_000_000)
        first.cancel()
        let summary = try await second.value
        XCTAssertEqual(summary.downloadedFeeds, 1)
        do { _ = try await first.value; XCTFail("Cancelled reader must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await downloads.requests()
        XCTAssertEqual(requests, 1)
    }

    func testManualRefreshUpdatesTheSameListingsUsedByTheChannelGuide() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let index = store(downloads), item = channel()
        _ = try await index.refresh(channels: [item], now: now, calendar: calendar)
        let before = try await index.programs(for: item, now: now, calendar: calendar)
        XCTAssertEqual(before.first?.title, "Arsenal v Chelsea")
        await downloads.configure(xml.replacingOccurrences(of: "Arsenal", with: "Liverpool"))
        _ = try await index.refresh(channels: [item], force: true, now: now, calendar: calendar)
        let after = try await index.programs(for: item, now: now, calendar: calendar)
        XCTAssertEqual(after.first?.title, "Liverpool v Chelsea")
        let search = try await index.search("liverpool", scope: .now, now: now, calendar: calendar)
        XCTAssertEqual(search.hits.first?.program.title, after.first?.title)
    }

    func testConcurrentRefreshesShareOneDownload() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml, delay: 100_000_000)
        let index = store(downloads), items = [channel()]
        async let a = index.refresh(channels: items, now: now, calendar: calendar)
        async let b = index.refresh(channels: items, now: now, calendar: calendar)
        _ = try await (a, b)
        let requests = await downloads.requests(); XCTAssertEqual(requests, 1)
    }

    func testForcedRefreshDoesNotJoinAnUnforcedDownload() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml, delay: 100_000_000)
        let index = store(downloads), items = [channel()]
        let initial = Task { try await index.refresh(channels: items, now: now, calendar: calendar) }
        while await downloads.requests() == 0 { await Task.yield() }
        let forced = try await index.refresh(channels: items, force: true, now: now, calendar: calendar)
        _ = try await initial.value
        XCTAssertEqual(forced.downloadedFeeds, 1)
        let requests = await downloads.requests()
        XCTAssertEqual(requests, 2)
    }

    func testSearchReadsLastCommittedIndexWhileWriterIsImporting() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let index = store(downloads)
        _ = try await index.refresh(channels: [channel()], now: now, calendar: calendar)
        let writer = try GuideDatabase(url: root.appendingPathComponent("guide.sqlite"))
        try writer.execute("BEGIN IMMEDIATE; DELETE FROM programs")
        defer { try? writer.execute("ROLLBACK") }
        let page = try await index.search("arsenal", scope: .now, now: now, calendar: calendar)
        XCTAssertEqual(page.hits.count, 1, "A partial refresh must not hide the previously committed guide")
    }

    func testMalformedRefreshKeepsPreviousGuideAndFailureIsRetried() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let index = store(downloads)
        _ = try await index.refresh(channels: [channel()], now: now, calendar: calendar)
        await downloads.configure("<tv><programme")
        let failed = try await index.refresh(channels: [channel()], force: true, now: now, calendar: calendar)
        XCTAssertEqual(failed.failedFeeds, 1)
        XCTAssertEqual(failed.failureMessage, GuideError.invalidFeed.errorDescription)
        let old = try await index.search("arsenal", scope: .now, now: now, calendar: calendar)
        XCTAssertEqual(old.hits.count, 1)
        let emptyRoot = GuideSearchIndex(url: root.appendingPathComponent("failed.sqlite"), download: { try await downloads.download($0) })
        _ = try await emptyRoot.refresh(channels: [channel()], now: now, calendar: calendar)
        await downloads.configure(xml.replacingOccurrences(of: "Arsenal", with: "Liverpool"))
        _ = try await emptyRoot.refresh(channels: [channel()], now: now, calendar: calendar)
        let retry = try await emptyRoot.search("liverpool", scope: .now, now: now, calendar: calendar)
        XCTAssertEqual(retry.hits.count, 1)
        _ = try await index.refresh(channels: [channel()], force: true, now: now, calendar: calendar)
        let removed = try await index.search("arsenal", scope: .now, now: now, calendar: calendar)
        XCTAssertTrue(removed.hits.isEmpty, "FTS entries must be deleted with their old programme rows")
    }

    func testSourceSwitchAndRemovedChannelsCannotLeakOldResults() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let index = store(downloads)
        _ = try await index.refresh(channels: [channel(), channel(2)], now: now, calendar: calendar)
        _ = try await index.refresh(channels: [channel(2)], now: now, calendar: calendar)
        var page = try await index.search("arsenal", scope: .now, now: now, calendar: calendar)
        XCTAssertEqual(page.hits.map(\.channelKey), [GuideSearchIndex.channelKey(channel(2))])
        await downloads.configure(xml.replacingOccurrences(of: "Arsenal", with: "Liverpool"))
        _ = try await index.refresh(channels: [channel(provider: "other")], now: now, calendar: calendar)
        page = try await index.search("arsenal", scope: .now, now: now, calendar: calendar)
        XCTAssertTrue(page.hits.isEmpty)
        _ = try await index.refresh(channels: [], now: now, calendar: calendar)
        page = try await index.search("football", scope: .now, now: now, calendar: calendar)
        XCTAssertTrue(page.hits.isEmpty)
    }

    func testCancelledRefreshAllowsImmediateSourceSwitch() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml, delay: 500_000_000)
        let index = store(downloads), items = [channel()]
        let first = Task { try await index.refresh(channels: items, now: now, calendar: calendar) }
        while await downloads.requests() == 0 { await Task.yield() }
        first.cancel()
        await downloads.configure(xml, delay: 0)
        _ = try await index.refresh(channels: [channel(provider: "other")], now: now, calendar: calendar)
        do { _ = try await first.value; XCTFail("Cancelled work must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let page = try await index.search("arsenal", scope: .now, now: now, calendar: calendar)
        XCTAssertEqual(page.hits.map(\.channelKey), [GuideSearchIndex.channelKey(channel(provider: "other"))])
    }

    func testEmptyAndSpecialQueriesDoNotExecuteFTSSyntax() async throws {
        let index = store(GuideDownloads())
        for word in ["", "   ", "\"*():-'", String(repeating: "*", count: 10_000)] {
            let page = try await index.search(word, scope: .now)
            XCTAssertTrue(page.hits.isEmpty)
        }
        XCTAssertEqual(GuideSearchIndex.matchExpression("Arsenal OR Chelsea"), "\"Arsenal\"* AND \"OR\"* AND \"Chelsea\"*")
        XCTAssertEqual(GuideSearchIndex.matchExpression("Paris Saint-Germain"), "\"Paris\"* AND \"Saint\"* AND \"Germain\"*")
        XCTAssertEqual(GuideSearchIndex.matchExpression(String(repeating: "team ", count: 1000))?.components(separatedBy: " AND ").count, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("guide.sqlite").path))
    }

    func testStreamingParserBoundsFieldsRejectsEntitiesAndDoesNotCollectRows() throws {
        let oversized = "<tv><programme channel='one' start='20261010090000' stop='20261010100000'><title>\(String(repeating: "a", count: 100_000))</title><desc>\(String(repeating: "b", count: 100_000))</desc><category>Football</category></programme></tv>"
        var received = 0
        let delegate = XMLTVPrograms(channelIDs: ["one"], now: now, calendar: calendar) { _, program in
            received += 1
            XCTAssertEqual(program.title.count, 1_024)
            XCTAssertEqual(program.description.count, 8_192)
            XCTAssertTrue(program.categories.contains("Football"))
        }
        let parser = XMLParser(stream: InputStream(data: Data(oversized.utf8))); parser.delegate = delegate
        XCTAssertTrue(parser.parse()); XCTAssertEqual(received, 1); XCTAssertTrue(delegate.programs.isEmpty)
        let entity = "<!DOCTYPE tv [<!ENTITY x 'expanded'>]><tv><programme channel='one' start='20261010090000' stop='20261010100000'><title>&x;</title></programme></tv>"
        XCTAssertThrowsError(try TVGuide.parse(Data(entity.utf8), channelID: "one"))
    }

    func testLargeDiskBackedFeedReturnsOnlyOnePage() async throws {
        let file = root.appendingPathComponent("large.xml")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: Data("<tv>".utf8))
        for i in 0..<20_000 {
            try writer.write(contentsOf: Data("<programme channel='one' start='20261010090000' stop='20261010100000'><title>Football match \(i)</title><desc>League coverage</desc></programme>".utf8))
        }
        try writer.write(contentsOf: Data("</tv>".utf8)); try writer.close()
        let index = GuideSearchIndex(url: root.appendingPathComponent("large.sqlite"), download: { _ in
            let copy = file.deletingLastPathComponent().appendingPathComponent("download.xml")
            try FileManager.default.copyItem(at: file, to: copy)
            return copy
        })
        _ = try await index.refresh(channels: [channel()], now: now, calendar: calendar)
        let began = Date()
        let page = try await index.search("football", scope: .now, now: now, calendar: calendar)
        print("Guide search fixture: 20,000 programmes; query took \(Date().timeIntervalSince(began)) seconds")
        XCTAssertEqual(page.hits.count, 50); XCTAssertTrue(page.hasMore)
        let db = try GuideDatabase(url: root.appendingPathComponent("large.sqlite"), readOnly: true)
        let count = try db.prepare("SELECT count(*) FROM programs"); XCTAssertTrue(try count.step())
        XCTAssertEqual(count.number(0), 20_000)
    }

    func testDatabaseCapacityFailureRollsBackInsteadOfErasingGoodGuide() async throws {
        let downloads = GuideDownloads(); await downloads.configure(xml)
        let index = store(downloads)
        _ = try await index.refresh(channels: [channel()], now: now, calendar: calendar)
        let db = try GuideDatabase(url: root.appendingPathComponent("guide.sqlite"))
        let pages = try db.prepare("PRAGMA page_count"); XCTAssertTrue(try pages.step())
        try db.execute("PRAGMA max_page_count=\(Int(pages.number(0)) + 3)")
        let descriptions = String(repeating: "football sports coverage ", count: 500)
        let records = (0..<200).map {
            "<programme channel='one' start='20261010090000' stop='20261010100000'><title>Replacement \($0)</title><desc>\(descriptions)</desc></programme>"
        }.joined()
        let parser = XMLParser(stream: InputStream(data: Data("<tv>\(records)</tv>".utf8)))
        XCTAssertThrowsError(try GuideSearchIndex.importXML(parser, db: db,
            feedKey: GuideSearchIndex.key(TVGuide.feedURL(for: channel())!.absoluteString),
            channelIDs: ["one"], now: now, calendar: calendar))
        let old = try await index.search("arsenal", scope: .now, now: now, calendar: calendar)
        XCTAssertEqual(old.hits.count, 1)
    }

    func testParserRollbackAndCacheUseCalendarDayAcrossDST() async throws {
        let downloads = GuideDownloads()
        await downloads.configure("""
        <tv>
          <programme channel="one" start="20261025000000 +0000" stop="20261025010000 +0000"><title>Current football</title></programme>
          <programme channel="one" start="20261025213000 +0000" stop="20261025230000 +0000"><title>Tonight football</title></programme>
          <programme channel="one" start="20261025220000 +0000" stop="20261025230000 +0000"><title>Tomorrow football</title></programme>
        </tv>
        """)
        var local = calendar; local.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        let date = ISO8601DateFormatter().date(from: "2026-10-25T00:30:00Z")!
        let index = store(downloads)
        _ = try await index.refresh(channels: [channel()], now: date, calendar: local)
        let later = try await index.search("football", scope: .later, now: date, calendar: local)
        XCTAssertEqual(later.hits.map(\.program.title), ["Tonight football"])
    }
}

@MainActor
final class GuideSearchModelTests: XCTestCase {
    #if os(macOS)
    func testClosingSearchViewKeepsRefreshAndSearchRunningForReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guide-background-\(UUID())")
        let suite = "guide-background-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        let downloads = GuideDownloads()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMddHHmmss Z"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        await downloads.configure("""
        <tv><programme channel="one" start="\(formatter.string(from: Date().addingTimeInterval(-60)))" stop="\(formatter.string(from: Date().addingTimeInterval(600)))"><title>Background news</title></programme></tv>
        """, delay: 500_000_000)
        let index = GuideSearchIndex(url: root.appendingPathComponent("guide.sqlite"), download: { try await downloads.download($0) })
        let model = GuideSearchModel(index: index)
        manager.guideSearchModel = model
        let channel = M3UItem(name: "News", streamURL: URL(string: "https://provider.example/live/user/pass/1.ts")!, tvgID: "one", contentType: .live)
        model.setChannels([channel])
        model.query = "background"
        let host = NSHostingView(rootView: AnyView(GuideSearchView(manager: manager)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer {
            model.cancel()
            window.close()
            manager.libraryPersistence.invalidatePendingWrites()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(model.indexing)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        for _ in 0..<200 where model.indexing || model.searching {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.indexing)
        XCTAssertNil(model.importError)
        XCTAssertEqual(model.hits.map(\.program.title), ["Background news"])
        XCTAssertFalse(model.searching)
        var idleUpdates = 0
        let observation = model.objectWillChange.sink { idleUpdates += 1 }
        try await Task.sleep(nanoseconds: 500_000_000)
        observation.cancel()
        XCTAssertEqual(idleUpdates, 0, "Completed work must leave the closed search idle")
        let completedRequests = await downloads.requests()
        XCTAssertEqual(completedRequests, 1)
        host.rootView = AnyView(GuideSearchView(manager: manager))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(manager.guideSearchModel === model)
        XCTAssertEqual(model.query, "background")
        XCTAssertEqual(model.hits.count, 1)
        let requests = await downloads.requests()
        XCTAssertEqual(requests, 1, "Reopening must reuse the completed guide update")
    }
    #endif

    func testChannelViewUsesSharedXMLTVAndRetainsListingsOnFailedRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-guide-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = GuideDownloads()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMddHHmmss Z"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let xml = """
        <tv><programme channel="one" start="\(formatter.string(from: Date().addingTimeInterval(-60)))" stop="\(formatter.string(from: Date().addingTimeInterval(600)))"><title>Shared news</title></programme></tv>
        """
        await downloads.configure(xml)
        let index = GuideSearchIndex(url: root.appendingPathComponent("guide.sqlite"), download: { try await downloads.download($0) })
        let channel = M3UItem(name: "News", streamURL: URL(string: "https://provider.example/live/user/pass/1.ts")!, tvgID: "one", contentType: .live)
        let guide = TVGuide { _ in XCTFail("A usable XMLTV cache must not fetch the separate channel endpoint"); throw GuideError.download }
        let first = try await guide.load(for: channel, index: index, channels: [channel], force: false)
        XCTAssertEqual(first.programs.first?.title, "Shared news")
        await downloads.configure("<tv/>")
        let retained = try await guide.load(for: channel, index: index, channels: [channel], force: true)
        XCTAssertEqual(retained.programs.first?.title, "Shared news")
        XCTAssertEqual(retained.updatedAt, first.updatedAt)
        XCTAssertNotNil(retained.message)
        XCTAssertLessThanOrEqual(retained.nextRefresh.timeIntervalSinceNow, 60)
    }

    func testChannelViewFallsBackToAPIWhenXMLTVIsUnusable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fallback-guide-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = GuideDownloads(); await downloads.configure("<tv/>")
        let index = GuideSearchIndex(url: root.appendingPathComponent("guide.sqlite"), download: { try await downloads.download($0) })
        let channel = M3UItem(name: "News", streamURL: URL(string: "https://provider.example/live/user/pass/1.ts")!, tvgID: "one", contentType: .live)
        let guide = TVGuide { _ in
            let file = root.appendingPathComponent("channel.json")
            let json = "{\"epg_listings\":[{\"title\":\"Actual channel news\",\"start_timestamp\":\(Date().addingTimeInterval(-60).timeIntervalSince1970),\"end_timestamp\":\(Date().addingTimeInterval(600).timeIntervalSince1970)}]}"
            try Data(json.utf8).write(to: file)
            return file
        }
        let result = try await guide.load(for: channel, index: index, channels: [channel], force: true)
        XCTAssertEqual(result.programs.first?.title, "Actual channel news")
        XCTAssertNotNil(result.message)
        XCTAssertLessThanOrEqual(result.nextRefresh.timeIntervalSinceNow, 60)
    }

    func testModelUsesCacheExpiryAndRetriesFailuresInOneMinute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guide-clock-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = GuideDownloads()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMddHHmmss Z"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        await downloads.configure("""
        <tv><programme channel="one" start="\(formatter.string(from: Date().addingTimeInterval(-60)))" stop="\(formatter.string(from: Date().addingTimeInterval(600)))"><title>News</title></programme></tv>
        """)
        let index = GuideSearchIndex(url: root.appendingPathComponent("guide.sqlite"), download: { try await downloads.download($0) })
        let channel = M3UItem(name: "News", streamURL: URL(string: "https://provider.example/live/user/pass/1.ts")!, tvgID: "one", contentType: .live)
        let now = Date()
        // Keep the cached seed in today even when this test runs just after midnight.
        let elapsedToday = now.timeIntervalSince(Calendar.current.startOfDay(for: now))
        let downloadedAt = now.addingTimeInterval(-min(10_000, elapsedToday / 2))
        let seeded = try await index.refresh(channels: [channel], now: downloadedAt)
        let model = GuideSearchModel(index: index)
        defer { model.cancel() }
        model.setChannels([channel])
        for _ in 0..<100 where model.indexing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.nextRefresh.timeIntervalSince1970, seeded.nextRefresh.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(model.summary?.lastUpdated).timeIntervalSince1970, downloadedAt.timeIntervalSince1970, accuracy: 0.001)
        await downloads.configure("<tv>", delay: 100_000_000)
        model.refresh(force: true)
        model.tick(now: .distantFuture)
        for _ in 0..<100 where model.indexing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.summary?.failedFeeds, 1)
        XCTAssertLessThanOrEqual(model.nextRefresh.timeIntervalSinceNow, 60)
        XCTAssertGreaterThan(model.nextRefresh.timeIntervalSinceNow, 50)
        let requests = await downloads.requests()
        XCTAssertEqual(requests, 2, "Timer must not restart an in-progress refresh")
    }

    func testDebounceClearingAndSourceSwitchDiscardStaleResultsWithoutTouchingPlayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guide-model-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = GuideDownloads()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMddHHmmss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        await downloads.configure("""
        <tv><programme channel="one" start="\(formatter.string(from: Date().addingTimeInterval(-1800)))" stop="\(formatter.string(from: Date().addingTimeInterval(1800)))"><title>Arsenal football</title></programme></tv>
        """)
        let index = GuideSearchIndex(url: root.appendingPathComponent("guide.sqlite"), download: { try await downloads.download($0) })
        let model = GuideSearchModel(index: index)
        let suite = "guide-model-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); model.cancel() }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites() }
        let playing = M3UItem(name: "Movie", streamURL: root.appendingPathComponent("no-network.mp4"), contentType: .movie)
        manager.playDirectStream(playing); manager.player?.replaceCurrentItem(with: nil)
        let player = try XCTUnwrap(manager.player)
        let channel = M3UItem(name: "Sports", streamURL: URL(string: "https://provider.example/live/alice/secret/1.ts")!, tvgID: "one", contentType: .live)
        model.setChannels([channel])
        for _ in 0..<100 where model.indexing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.indexing)
        model.query = "missing"; model.query = "arsenal"
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(model.hits.map(\.program.title), ["Arsenal football"])
        model.query = "football"; model.query = ""
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(model.hits.isEmpty); XCTAssertFalse(model.searching)
        model.query = "arsenal"; model.setChannels([])
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(model.hits.isEmpty); XCTAssertTrue(model.channelsByKey.isEmpty)
        XCTAssertTrue(manager.player === player)
        XCTAssertEqual(manager.currentChannel?.id, playing.id)
    }
}
