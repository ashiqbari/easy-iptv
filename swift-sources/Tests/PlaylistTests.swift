import XCTest
@testable import EasyIPTV

final class PlaylistTests: XCTestCase {
    func testMetadataQuotesUnicodeAndCommasInTitles() async throws {
        let items = try await M3UParser().parse(string: """
        #EXTM3U
        #EXTINF:-1 TVG-NAME="İstanbul, News" tvg-id='news-1' GROUP-TITLE='News' tvg-logo="https://fixture.invalid/icon.png",News, International
        #EXTVLCOPT:network-caching=1000
        https://fixture.invalid/live.m3u8
        """)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.name, "News, International")
        XCTAssertEqual(item.tvgName, "İstanbul, News")
        XCTAssertEqual(item.tvgID, "news-1")
        XCTAssertEqual(item.groupTitle, "News")
        XCTAssertEqual(item.logoURL?.absoluteString, "https://fixture.invalid/icon.png")
        XCTAssertTrue(item.isHLS)
        XCTAssertEqual(item.contentType, .live)
    }

    func testEncodedStreamURLAndCredentialsArePreserved() async throws {
        let url = "https://fixture.invalid/movie/a%20b.mp4?token=a%2Bb%26c"
        let items = try await M3UParser().parse(string: "#EXTINF:-1,Movie\n\(url)")
        XCTAssertEqual(items.first?.streamURL.absoluteString, url)
    }

    func testMissingTitleFallsBackAndUnpairedLinesAreIgnored() async throws {
        let items = try await M3UParser().parse(string: """
        https://fixture.invalid/ignored.mp4
        #EXTINF:-1 tvg-name="Fallback",
        https://fixture.invalid/one.ts
        #EXTINF:-1,
        https://fixture.invalid/two.ts
        #EXTINF:-1,Missing URL
        """)
        XCTAssertEqual(items.map(\.name), ["Fallback", "two.ts"])
        XCTAssertEqual(items.map(\.displayGroup), ["General", "General"])
    }

    func testEmptyPlaylistsFailAndParserDoesNotCarryMetadataBetweenCalls() async throws {
        let parser = M3UParser()
        for playlist in ["", "#EXTM3U\n# comment", "#EXTINF:-1,Missing"] {
            do { _ = try await parser.parse(string: playlist); XCTFail("Expected empty playlist") }
            catch { XCTAssertTrue(error is M3UParserError) }
        }
        let items = try await parser.parse(string: "#EXTINF:-1,Fresh\nhttps://fixture.invalid/fresh.ts")
        XCTAssertEqual(items.first?.name, "Fresh")
    }

    func testMovieEpisodeClassificationAndExplicitType() {
        XCTAssertEqual(M3UItem.detectType(group: "Movies", name: "Title", url: URL(string: "https://fixture.invalid/1")!), .movie)
        XCTAssertEqual(M3UItem.detectType(group: "General", name: "Show S02 E03", url: URL(string: "https://fixture.invalid/1.mp4")!), .series)
        let live = M3UItem(name: "  Live  ", groupTitle: "", streamURL: URL(string: "https://fixture.invalid/movie/1.mp4")!, contentType: .live)
        XCTAssertEqual(live.name, "Live")
        XCTAssertEqual(live.displayGroup, "General")
        XCTAssertEqual(live.contentType, .live)
    }
}
