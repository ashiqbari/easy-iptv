#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import EasyIPTV

@MainActor
final class EpisodePanelLayoutTests: XCTestCase {
    func testPanelFitsContentsCapsAtTenRowsAndScrollsInSmallWindows() async throws {
        _ = NSApplication.shared
        let suite = "episode-panel-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        defer { manager.stop(); manager.libraryPersistence.invalidatePendingWrites(); defaults.removePersistentDomain(forName: suite) }
        let episodes = (1...15).map { (number: Int) in
            M3UItem(name: "Episode \(number)", groupTitle: "Season 1", streamURL: URL(fileURLWithPath: "/private/tmp/episode-panel-\(number).mp4"), contentType: .series, seasonNumber: 1, episodeNumber: number)
        }
        for episode in episodes.prefix(2) { manager.progressStore.save(item: episode, position: 19, duration: 300) }
        var tenRowHeight: CGFloat = 0
        for count in [3, 10, 15] {
            manager.seriesEpisodes = Array(episodes.prefix(count))
            let hosting = NSHostingView(rootView: EpisodePlaybackPanel(manager: manager)
                .environment(\.appPalette, AppPalette(appearance: .forest)).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            func settle() async throws {
                for _ in 0..<10 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 20_000_000) }
            }
            func findScroll(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap(findScroll).first
            }
            try await settle()
            let scroll = try XCTUnwrap(findScroll(hosting))
            let document = try XCTUnwrap(scroll.documentView)
            let height = scroll.contentView.bounds.height
            XCTAssertGreaterThan(height, 80)
            XCTAssertLessThan(height, 800, "The panel must leave unused player space outside its background")
            if count <= 10 { XCTAssertEqual(height, document.frame.height, accuracy: 1) }
            if count == 10 { tenRowHeight = height }
            if count == 15 {
                XCTAssertEqual(height, tenRowHeight, accuracy: 1, "More episodes must not expand the panel past ten rows")
                XCTAssertGreaterThan(document.frame.height, height)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: document.frame.height - height))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
                window.setContentSize(CGSize(width: 280, height: 250))
                try await settle()
                XCTAssertLessThan(scroll.contentView.bounds.height, height)
                let frame = scroll.convert(scroll.bounds, to: hosting)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, hosting.bounds.maxX)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, hosting.bounds.maxY)
            }

        }
    }
}
#endif
