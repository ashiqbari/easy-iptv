import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import EasyIPTV

final class MovieDetailsTests: XCTestCase {
    func testProviderMetadataAndRecommendations() throws {
        let details = try MediaDetails.parse(Data("""
        {"info":{"name":"A Movie","movie_image":"https://fixture.invalid/poster.jpg",
        "backdrop_path":["https://fixture.invalid/banner.jpg"],"releasedate":"2023-04-12",
        "duration_secs":"7200","rating":8.5,"certification":"PG-13","genre":"Drama",
        "plot":"A real synopsis","cast":"First, Second","director":"Director",
        "writer":"Writer","producer":"Producer","youtube_trailer":"abcdefghijk"},
        "recommendations":[{"stream_id":42},"43"],"movie_data":{"name":"List title"}}
        """.utf8))
        XCTAssertEqual(details.title, "A Movie")
        XCTAssertEqual(details.year, "2023")
        XCTAssertEqual(details.runtime, "120 min")
        XCTAssertEqual(details.rating, "8.5")
        XCTAssertEqual(details.certification, "PG-13")
        XCTAssertEqual(details.genres, "Drama")
        XCTAssertEqual(details.plot, "A real synopsis")
        XCTAssertEqual(details.cast, "First, Second")
        XCTAssertEqual(details.director, "Director")
        XCTAssertEqual(details.writer, "Writer")
        XCTAssertEqual(details.producer, "Producer")
        XCTAssertEqual(details.poster?.lastPathComponent, "poster.jpg")
        XCTAssertEqual(details.backdrop?.lastPathComponent, "banner.jpg")
        XCTAssertEqual(details.trailer?.absoluteString, "https://www.youtube.com/watch?v=abcdefghijk")
        XCTAssertEqual(details.recommendedIDs, ["42", "43"])
    }

    func testMissingFieldsAndUnsafeLinksAreNotShown() throws {
        let details = try MediaDetails.parse(Data("""
        {"info":{"plot":" ","cast":null,"director":"N/A","rating":"null",
        "movie_image":"file:///private/data","trailer":"javascript:alert(1)",
        "duration_secs":"1e300"},"movie_data":{"name":"Fallback"}}
        """.utf8))
        XCTAssertEqual(details.title, "Fallback")
        XCTAssertNil(details.plot)
        XCTAssertNil(details.cast)
        XCTAssertNil(details.director)
        XCTAssertNil(details.rating)
        XCTAssertNil(details.poster)
        XCTAssertNil(details.trailer)
        XCTAssertNil(details.runtime)
        XCTAssertThrowsError(try MediaDetails.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try MediaDetails.parse(Data("not json".utf8)))
    }

    @MainActor func testSelectionDetailsPlaybackAndBackPreserveLibraryState() throws {
        let suite = "movie-details-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop() }
        let item = M3UItem(name: "Movie", streamURL: URL(fileURLWithPath: "/private/tmp/movie-details-fixture.mp4"), contentType: .movie)
        manager.selectedSection = .movie
        manager.selectedCategory = "Drama"
        manager.searchText = "Movie"
        manager.progressStore.save(item: item, position: 120, duration: 1200)
        manager.playChannel(item)
        XCTAssertTrue(manager.isViewingMovieDetails)
        XCTAssertNil(manager.player)
        XCTAssertNil(manager.resumeRequest)
        XCTAssertEqual(manager.movieOverviewItem?.id, item.id)
        manager.showVideoControls = false
        manager.playMovie()
        XCTAssertTrue(manager.showVideoControls)
        XCTAssertFalse(manager.isViewingMovieDetails)
        XCTAssertNotNil(manager.player)
        XCTAssertNil(manager.resumeRequest, "Details page already offers the resume choice")
        let player = try XCTUnwrap(manager.player)
        manager.returnToMovie()
        XCTAssertNil(manager.player)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(manager.isViewingMovieDetails)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.resumePosition, 120)
        XCTAssertEqual(manager.searchText, "Movie")
        XCTAssertEqual(manager.selectedCategory, "Drama")
        manager.playMovie(startOver: true)
        XCTAssertNil(manager.progressStore.progress(for: item))
        manager.stop()
        XCTAssertNil(manager.movieOverviewItem)
        XCTAssertFalse(manager.isViewingMovieDetails)
        XCTAssertEqual(manager.searchText, "Movie")
        XCTAssertEqual(manager.selectedCategory, "Drama")
    }

    @MainActor func testM3UMovieHasDetailsWithoutProviderRequest() async throws {
        let item = M3UItem(name: "Movie", streamURL: URL(string: "https://fixture.invalid/movie.mp4")!, contentType: .movie)
        let details = try await XtreamCodesManager().fetchMovieDetails(for: item)
        XCTAssertNil(details)
    }

    @MainActor func testCompletedMovieStaysWatchedUntilPlayIsChosen() {
        let suite = "movie-details-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop() }
        let item = M3UItem(name: "Watched Movie", streamURL: URL(fileURLWithPath: "/private/tmp/movie-details-fixture.mp4"), contentType: .movie)
        manager.progressStore.save(item: item, position: 1190, duration: 1200)
        manager.playChannel(item)
        XCTAssertEqual(manager.progressStore.progress(for: item)?.completed, true)
        XCTAssertNil(manager.progressStore.progress(for: item)?.resumePosition)
        manager.playMovie()
        XCTAssertNil(manager.progressStore.progress(for: item))
        XCTAssertNil(manager.resumeRequest)
    }

    #if os(macOS)
    @MainActor func testSharedRatingBadgeOnlyAppearsWhenProvided() {
        var details = MediaDetails()
        let empty = NSHostingController(rootView: MediaMetadataView(details: details))
            .sizeThatFits(in: CGSize(width: 300, height: 200))
        details.rating = "8.2"
        let rated = NSHostingController(rootView: MediaMetadataView(details: details))
            .sizeThatFits(in: CGSize(width: 300, height: 200))
        XCTAssertGreaterThan(rated.height, empty.height)
        XCTAssertGreaterThan(rated.width, 0)
    }

    @MainActor func testDetailsFitBothNarrowAndWidePanes() {
        let suite = "movie-details-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        let item = M3UItem(name: "A movie with a long title that must wrap instead of hiding the play button",
                          streamURL: URL(fileURLWithPath: "/private/tmp/movie-details-fixture.mp4"), contentType: .movie)
        manager.playChannel(item)
        defer { manager.stop() }
        let controller = NSHostingController(rootView: MovieDetailsView(item: item, manager: manager))
        for width: CGFloat in [248, 1000] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 700))
            XCTAssertLessThanOrEqual(size.width, width)
            XCTAssertGreaterThan(size.height, 0)
        }
    }
    #endif
}
