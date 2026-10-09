import XCTest
@testable import EasyIPTV

final class TVGuideTests: XCTestCase {
    func testChannelRequestDoesNotFetchGlobalXMLTVOrRequireTvgID() throws {
        let item = M3UItem(name: "Channel", streamURL: URL(string: "https://provider.example/iptv/live/alice/secret/44.ts")!, contentType: .live)
        let parts = try XCTUnwrap(TVGuide.channelRequest(for: item).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(parts.path, "/iptv/player_api.php")
        XCTAssertEqual(parts.queryItems?.last, URLQueryItem(name: "stream_id", value: "44"))
        XCTAssertTrue(parts.queryItems?.contains(URLQueryItem(name: "action", value: "get_simple_data_table")) == true)
        let custom = M3UItem(name: "Channel", streamURL: item.streamURL, guideURL: URL(string: "https://guide.example/custom.xml"))
        XCTAssertNil(TVGuide.channelRequest(for: custom))
    }

    func testChannelJSONDecodesProviderTextAndNumericOrStringTimestamps() throws {
        let json = """
        {"epg_listings":[
          {"title":"UmVhbCBuZXdz","description":"UHJvdmlkZXIgZGV0YWlscw==","start_timestamp":"1791622800","stop_timestamp":1791626400},
          {"title":"Invalid","start_timestamp":10,"stop_timestamp":9}
        ]}
        """
        let result = try TVGuide.parseChannel(Data(json.utf8))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "Real news")
        XCTAssertEqual(result.first?.description, "Provider details")
        XCTAssertEqual(result.first?.durationMin, 60)
        XCTAssertThrowsError(try TVGuide.parseChannel(Data("{\"user_info\":{}}".utf8)))
        XCTAssertTrue(try TVGuide.parseChannel(Data("{\"epg_listings\":[]}".utf8)).isEmpty)
    }

    func testStreamedXMLAndDayFilterKeepCurrentAndUpcomingOnly() throws {
        let xml = """
        <tv>
          <programme channel="one" start="20261010080000 +0000" stop="20261010093000 +0000"><title>Ended</title></programme>
          <programme channel="one" start="20261010090000 +0000" stop="20261010100000 +0000"><title>Current</title></programme>
          <programme channel="one" start="20261010190000 +0000" stop="20261010220000 +0000"><title>Tonight crossing midnight</title></programme>
          <programme channel="one" start="20261010210000 +0000" stop="20261010220000 +0000"><title>Tomorrow locally</title></programme>
          <programme channel="other" start="20261010093000 +0000" stop="20261010100000 +0000"><title>Wrong channel</title></programme>
        </tv>
        """
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-10T09:30:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Helsinki"))
        let data = Data(xml.utf8)
        let result = try TVGuide.parse(XMLParser(stream: InputStream(data: data)), channelID: "one", now: now, calendar: calendar)
        XCTAssertEqual(result.map(\.title), ["Current", "Tonight crossing midnight"])
        let all = try TVGuide.parse(data, channelID: "one")
        XCTAssertEqual(TVGuide.remainingToday(all, now: now, calendar: calendar).map(\.title), result.map(\.title))
    }

    func testDayBoundaryUsesCalendarAcrossDaylightSavingChange() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T00:30:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Helsinki"))
        let midnight = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T22:00:00Z"))
        let tomorrow = GuideProgram(title: "Tomorrow", description: "", start: midnight, end: midnight.addingTimeInterval(3600))
        let tonight = GuideProgram(title: "Tonight", description: "", start: midnight.addingTimeInterval(-1800), end: midnight)
        XCTAssertEqual(TVGuide.remainingToday([tomorrow, tonight], now: now, calendar: calendar).map(\.title), ["Tonight"])
    }

    func testExactChannelMatchingDatesCDATAAndRealProgress() throws {
        let xml = """
        <tv>
          <programme channel="other" start="20261010100000 +0200" stop="20261010110000 +0200"><title>Wrong channel</title></programme>
          <programme channel="bbc.one" start="20261010110000 +0200" stop="20261010120000 +0200"><title>Next &amp; later</title></programme>
          <programme channel="bbc.one" start="20261010100000 +0200" stop="20261010110000 +0200"><title>Real bulletin</title><desc><![CDATA[Provider <description>]]></desc></programme>
        </tv>
        """
        let programmes = try TVGuide.parse(Data(xml.utf8), channelID: "bbc.one")
        XCTAssertEqual(programmes.map(\.title), ["Real bulletin", "Next & later"])
        let current = try XCTUnwrap(programmes.first)
        XCTAssertEqual(current.description, "Provider <description>")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-10T08:30:00Z"))
        XCTAssertTrue(current.isCurrent(at: now))
        XCTAssertEqual(current.progress(at: now), 0.5)
        XCTAssertEqual(current.durationMin, 60)
        XCTAssertFalse(current.isCurrent(at: current.end))
        XCTAssertEqual(current.progress(at: current.start.addingTimeInterval(-60)), 0)
        XCTAssertEqual(current.progress(at: current.end.addingTimeInterval(60)), 1)
        XCTAssertTrue(try TVGuide.parse(Data(xml.utf8), channelID: "BBC.ONE").isEmpty)
    }

    func testInvalidFeedsFailInsteadOfShowingPartialOrFabricatedSchedule() throws {
        for xml in ["<tv><programme", "<html><tv/></html>", "not XML"] {
            XCTAssertThrowsError(try TVGuide.parse(Data(xml.utf8), channelID: "bbc.one"))
        }
        XCTAssertTrue(try TVGuide.parse(Data("<tv/>".utf8), channelID: "bbc.one").isEmpty)
        let invalid = "<tv><programme channel='bbc.one' start='bad' stop='20261010110000 +0000'><title>Invalid dates</title></programme></tv>"
        XCTAssertTrue(try TVGuide.parse(Data(invalid.utf8), channelID: "bbc.one").isEmpty)
    }

    func testMissingTimezoneIsUTCAndShortTimestampSupported() throws {
        let xml = "<tv><programme channel='one' start='202610101000' stop='202610101100'><title>Actual show</title></programme></tv>"
        let programme = try XCTUnwrap(TVGuide.parse(Data(xml.utf8), channelID: "one").first)
        XCTAssertEqual(programme.start, ISO8601DateFormatter().date(from: "2026-10-10T10:00:00Z"))
    }

    func testXtreamFeedUsesTheSelectedStreamsAccountAndSubpath() throws {
        let item = M3UItem(name: "News", streamURL: URL(string: "https://provider.example:8443/iptv/live/alice/secret/44.m3u8")!, tvgID: "one", contentType: .live)
        let parts = try XCTUnwrap(TVGuide.feedURL(for: item).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(parts.host, "provider.example")
        XCTAssertEqual(parts.port, 8443)
        XCTAssertEqual(parts.path, "/iptv/xmltv.php")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "username", value: "alice"), URLQueryItem(name: "password", value: "secret")])
        let root = M3UItem(name: "News", streamURL: URL(string: "https://provider.example/live/live/secret/44.ts")!, contentType: .live)
        XCTAssertEqual(TVGuide.feedURL(for: root)?.path, "/xmltv.php")
        XCTAssertEqual(URLComponents(url: TVGuide.feedURL(for: root)!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "live")
        XCTAssertNil(TVGuide.feedURL(for: M3UItem(name: "Sports", streamURL: URL(string: "https://cdn.example/channel.ts")!)))
        XCTAssertNil(TVGuide.feedURL(for: M3UItem(name: "News", streamURL: item.streamURL, guideURL: URL(string: "file:///private/etc/passwd"))))
    }

    func testM3UAdvertisedGuideURLIsStoredAndOverridesXtreamGuess() async throws {
        for attribute in ["url-tvg", "x-tvg-url"] {
            let items = try await M3UParser().parse(string: """
            #EXTM3U \(attribute)="https://guide.example/listings.xml"
            #EXTINF:-1 tvg-id="one",Actual channel
            https://stream.example/live/alice/secret/1.ts
            """)
            let item = try XCTUnwrap(items.first)
            XCTAssertEqual(item.tvgID, "one")
            XCTAssertEqual(TVGuide.feedURL(for: item)?.absoluteString, "https://guide.example/listings.xml")
            let restored = try JSONDecoder().decode(M3UItem.self, from: JSONEncoder().encode(item))
            XCTAssertEqual(restored.guideURL, item.guideURL)
        }
    }

    func testUnavailableGuideNeedsNoNetworkOrFakeFallback() async throws {
        let item = M3UItem(name: "ESPN Sports", streamURL: URL(string: "https://cdn.example/1.ts")!, contentType: .live)
        let programmes = try await TVGuide().load(for: item)
        XCTAssertTrue(programmes.isEmpty)
    }
}
