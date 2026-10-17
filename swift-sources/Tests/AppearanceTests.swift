import XCTest
import SwiftUI
#if os(macOS)
import AppKit
import VLC
#endif
@testable import EasyIPTV

@MainActor
final class AppearanceTests: XCTestCase {
    func testAppearanceDefaultsPersistsAndFallsBackForInvalidValues() {
        let suite = "appearance-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = AppStorage<AppearancePreference>(wrappedValue: .system, AppearancePreference.storageKey, store: defaults)
        XCTAssertEqual(preference.wrappedValue, .system)
        XCTAssertNil(preference.wrappedValue.colorScheme)
        for option in AppearancePreference.allCases {
            preference.wrappedValue = option
            let reopened = AppStorage<AppearancePreference>(wrappedValue: .system, AppearancePreference.storageKey, store: defaults)
            XCTAssertEqual(reopened.wrappedValue, option)
            XCTAssertEqual(defaults.string(forKey: AppearancePreference.storageKey), option.rawValue)
        }
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
        XCTAssertEqual(AppearancePreference.navy.colorScheme, .dark)
        XCTAssertTrue(AppPalette(appearance: .navy).isCustom)
        XCTAssertNotEqual(AppPalette(appearance: .navy).background, AppPalette().background)
        for option in [AppearancePreference.obsidian, .forest, .warmStone] {
            let palette = AppPalette(appearance: option)
            XCTAssertTrue(palette.isCustom)
            XCTAssertNotEqual(palette.background, AppPalette(appearance: .navy).background)
            XCTAssertEqual(palette.onAccent, option == .warmStone ? .white : .black)
            XCTAssertEqual(option.colorScheme, option == .warmStone ? .light : .dark)
        }
        XCTAssertEqual(AppearancePreference.warmStone.title, "Warm Stone")
        defaults.set("unknown", forKey: AppearancePreference.storageKey)
        let invalid = AppStorage<AppearancePreference>(wrappedValue: .system, AppearancePreference.storageKey, store: defaults)
        XCTAssertEqual(invalid.wrappedValue, .system)
    }

    #if os(macOS)
    func testCustomThemeTextContrast() throws {
        func luminance(_ color: Color) throws -> Double {
            let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { value in
                value <= 0.04045 ? Double(value) / 12.92 : pow((Double(value) + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        func contrast(_ first: Color, _ second: Color) throws -> Double {
            let a = try luminance(first), b = try luminance(second)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        for theme in [AppearancePreference.obsidian, .forest, .warmStone] {
            let palette = AppPalette(appearance: theme)
            let text: Color = theme == .warmStone ? .black : .white
            XCTAssertGreaterThanOrEqual(try contrast(text, palette.background), 4.5)
            XCTAssertGreaterThanOrEqual(try contrast(text, palette.surface), 4.5)
            XCTAssertGreaterThanOrEqual(try contrast(palette.onAccent, palette.accent), 4.5)
            XCTAssertGreaterThanOrEqual(try contrast(.white, palette.controlAccent), 4.5)
        }
    }

    func testCatalogCardsFitNarrowPanelsWithLongTitles() {
        let item = M3UItem(name: "A long movie or channel name that should wrap without pushing the favorite control out of the panel",
                           streamURL: URL(fileURLWithPath: "/private/tmp/catalog-layout.mp4"), contentType: .movie)
        for playing in [false, true] {
            let hosting = NSHostingController(rootView: ChannelRowView(channel: item, isPlaying: playing,
                                                                       onSelect: {}, onToggleFavorite: {}))
            for width in [260.0, 376.0] {
                let size = hosting.sizeThatFits(in: CGSize(width: width, height: 600))
                XCTAssertLessThanOrEqual(size.width, width)
                XCTAssertGreaterThanOrEqual(size.height, 68)
                XCTAssertLessThan(size.height, 150)
            }
        }
    }

    func testAppearanceChangesKeepAVPlayerSurfaceMounted() async throws {
        try await checkAppearanceChanges(useVLC: false)
    }

    func testAppearanceChangesKeepVLCDrawableMounted() async throws {
        try await checkAppearanceChanges(useVLC: true)
    }

    private func checkAppearanceChanges(useVLC: Bool) async throws {
        let suite = "appearance-surface-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        manager.playDirectStream(M3UItem(name: "Theme fixture", streamURL: URL(fileURLWithPath: "/private/tmp/appearance-fixture.mp4"), contentType: useVLC ? .live : .movie))
        if !useVLC, let item = manager.currentChannel { manager.playAVKitFixture(item) }
        manager.player?.replaceCurrentItem(with: nil)
        let player = manager.player
        let vlcPlayer = manager.vlcPlayer
        let application = NSApplication.shared
        let originalAppAppearance = application.appearance
        application.appearance = nil
        let systemScheme: ColorScheme = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        defer { application.appearance = originalAppAppearance }
        let probe = AppearanceProbeView()
        let hosting = NSHostingView(rootView: ContentView(manager: manager)
            .background(AppearanceProbe(view: probe)).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites(); window.close() }

        func settle() async throws {
            for _ in 0..<10 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func surface(in view: NSView) -> NSView? {
            if useVLC { return manager.vlcPlayer?.drawable as? NSView }
            if let view = view as? AVPlayerLayerNSView { return view }
            return view.subviews.lazy.compactMap { surface(in: $0) }.first
        }
        try await settle()
        let original = try XCTUnwrap(surface(in: hosting))
        for option in [AppearancePreference.light, .navy, .obsidian, .forest, .warmStone, .system, .dark, .light, .system] {
            defaults.set(option.rawValue, forKey: AppearancePreference.storageKey)
            try await settle()
            let expected = option.colorScheme ?? systemScheme
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected == .dark ? .darkAqua : .aqua)
            XCTAssertEqual(probe.colorScheme, expected, "SwiftUI content must update without a click, not just the window chrome")
            XCTAssertTrue(try XCTUnwrap(surface(in: hosting)) === original)
            XCTAssertTrue(manager.player === player)
            XCTAssertTrue(manager.vlcPlayer === vlcPlayer)
            XCTAssertTrue(original.window === window)
            XCTAssertGreaterThan(original.bounds.width, 0)
            XCTAssertGreaterThan(original.bounds.height, 0)
        }
        application.appearance = NSAppearance(named: .darkAqua)
        try await settle()
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua, "System follows macOS appearance changes")
        XCTAssertEqual(probe.colorScheme, .dark)
        application.appearance = NSAppearance(named: .aqua)
        try await settle()
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(probe.colorScheme, .light)
        XCTAssertTrue(try XCTUnwrap(surface(in: hosting)) === original)
    }
    #endif
}

#if os(macOS)
private final class AppearanceProbeView: NSView {
    var colorScheme: ColorScheme?
}

private struct AppearanceProbe: NSViewRepresentable {
    let view: AppearanceProbeView
    func makeNSView(context: Context) -> AppearanceProbeView { view }
    func updateNSView(_ view: AppearanceProbeView, context: Context) {
        view.colorScheme = context.environment.colorScheme
    }
}
#endif
