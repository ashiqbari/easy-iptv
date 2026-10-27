import XCTest
import AVFoundation
#if os(macOS)
import SwiftVLC
#endif
@testable import EasyIPTV

final class LanguagePreferenceTests: XCTestCase {
    func testLanguageMatching() {
        XCTAssertTrue(LanguagePreference.matches("en", language: "eng", label: "Track 1"))
        XCTAssertTrue(LanguagePreference.matches("fr", language: "fr-CA", label: "Track 2"))
        XCTAssertTrue(LanguagePreference.matches("en", language: nil, label: "English (CC)"))
        XCTAssertFalse(LanguagePreference.matches("en", language: "fr", label: "English"))
        XCTAssertFalse(LanguagePreference.matches("en", language: nil, label: "Bengali"))
        XCTAssertFalse(LanguagePreference.matches("", language: "en", label: "English"))
    }

    func testLanguageNamesMatchWholeWordsAnywhereInLabels() {
        for label in ["Track 2 - English", "Track 2 - [English]", "Track 2 - ENGLISH (Stereo)", "Track 2 - eng", "Track 2 - [en]"] {
            XCTAssertTrue(LanguagePreference.matches("en", language: nil, label: label), label)
            XCTAssertTrue(LanguagePreference.matches("en", language: "und", label: label), label)
        }
        for label in ["Track 2 - Bengali", "Track 2 - Englishman", "Track 2 - French"] {
            XCTAssertFalse(LanguagePreference.matches("en", language: nil, label: label), label)
        }
        XCTAssertFalse(LanguagePreference.matches("en", language: "fr", label: "Track 2 - [English]"))
    }

    @MainActor
    func testAudioPreferenceAndManualOverride() async throws {
        let suite = "language-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fr", forKey: LanguagePreference.audioKey)
        let url = try await alternateAudioMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = AVPlayerItem(url: url)
        let controller = AudioTrackController(defaults: defaults)
        controller.configure(item)
        for _ in 0..<200 where controller.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        let french = try XCTUnwrap(controller.tracks.first { $0.language == "fr" })
        let english = try XCTUnwrap(controller.tracks.first { $0.language == "en" })
        XCTAssertEqual(controller.selectedID, french.id)
        controller.select(english.id)
        controller.refresh()
        for _ in 0..<200 where controller.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.selectedID, english.id)
        controller.configure(item)
        for _ in 0..<200 where controller.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.selectedID, french.id)
        withExtendedLifetime(item) {}
    }

    @MainActor
    func testLiveAudioIgnoresPreferenceAndAllowsManualSelection() async throws {
        let suite = "language-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fr", forKey: LanguagePreference.audioKey)
        let url = try await alternateAudioMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = AVPlayerItem(url: url)
        let controller = AudioTrackController(defaults: defaults)
        controller.configure(item, applyLanguagePreference: false)
        for _ in 0..<200 where controller.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        let english = try XCTUnwrap(controller.tracks.first { $0.language == "en" })
        let french = try XCTUnwrap(controller.tracks.first { $0.language == "fr" })
        XCTAssertEqual(controller.selectedID, english.id)
        controller.select(french.id)
        XCTAssertEqual(controller.selectedID, french.id)
        withExtendedLifetime(item) {}
        #if os(macOS)
        let player = SwiftVLC.Player(instance: try VLCInstance(arguments: VLCInstance.defaultArguments + ["--no-video", "--aout=dummy"]))
        player.load(try SwiftVLC.Media(url: url))
        controller.configure(player, applyLanguagePreference: false)
        defer { controller.reset(); player.stop() }
        try player.play()
        for _ in 0..<200 {
            controller.refresh()
            if controller.selectedID != nil && controller.tracks.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let selected = try XCTUnwrap(controller.tracks.first { $0.id == controller.selectedID })
        XCTAssertTrue(LanguagePreference.matches("en", language: selected.language, label: selected.name))
        let alternate = try XCTUnwrap(controller.tracks.first { LanguagePreference.matches("fr", language: $0.language, label: $0.name) })
        controller.select(alternate.id)
        XCTAssertEqual(controller.selectedID, alternate.id)
        #endif
    }

    #if os(macOS)
    @MainActor
    func testVLCSelectsPreferredAudioWhenTracksArrive() async throws {
        let suite = "language-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fr", forKey: LanguagePreference.audioKey)
        let url = try await alternateAudioMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = SwiftVLC.Player(instance: try VLCInstance(arguments: VLCInstance.defaultArguments + ["--no-video", "--aout=dummy"]))
        player.load(try SwiftVLC.Media(url: url))
        let controller = AudioTrackController(defaults: defaults)
        controller.configure(player)
        defer { controller.reset(); player.stop() }
        try player.play()
        for _ in 0..<200 {
            controller.refresh()
            if let selected = controller.tracks.first(where: { $0.id == controller.selectedID }),
               LanguagePreference.matches("fr", language: selected.language, label: selected.name) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let track = try XCTUnwrap(controller.tracks.first { $0.id == controller.selectedID })
        XCTAssertTrue(LanguagePreference.matches("fr", language: track.language, label: track.name))
    }

    @MainActor
    func testDelayedSubtitlePreferenceAndOffRestoration() async throws {
        let suite = "language-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en", forKey: LanguagePreference.subtitleKey)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("language-\(UUID()).srt")
        try "1\n00:00:00,000 --> 00:00:05,000\nHello\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let movie = M3UItem(name: "Movie", streamURL: URL(string: "https://example.invalid/movie")!, contentType: .movie)
        let player = SwiftVLC.Player()
        let controller = SubtitleController(defaults: defaults)
        controller.reset(for: movie)
        controller.configure(player: player) {
            try await Task.sleep(nanoseconds: 20_000_000)
            return [SubtitleSource(url: url, label: "English")]
        }
        for _ in 0..<200 where controller.selectedID == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.selectedID, url.absoluteString)
        controller.select(nil)
        controller.loadTracksIfNeeded()
        XCTAssertNil(controller.selectedID)
        let saved = controller.playbackSelection
        controller.reset(for: movie)
        controller.restoreSelection(saved)
        controller.configure(player: player) { [SubtitleSource(url: url, label: "English")] }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(controller.selectedID)
        let live = M3UItem(name: "Live MP4", streamURL: URL(string: "https://example.invalid/live.mp4")!, contentType: .live)
        controller.reset(for: live)
        controller.configure(player: player) { [SubtitleSource(url: url, label: "English")] }
        for _ in 0..<200 where controller.tracks.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.tracks.isEmpty)
        XCTAssertNil(controller.selectedID, "A live channel with an MP4 URL must ignore subtitle preferences")
        XCTAssertFalse(controller.isLoadingFile)
        controller.reset(for: nil)
        withExtendedLifetime(player) {}
    }
    #endif
}
