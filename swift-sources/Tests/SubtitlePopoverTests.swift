#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import EasyIPTV

@MainActor
final class SubtitlePopoverTests: XCTestCase {
    func testSubtitlePanelStaysInsidePlayerAtSmallWindowSizes() async throws {
        _ = NSApplication.shared
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        for size in [CGSize(width: 800, height: 450), CGSize(width: 500, height: 320)] {
            let suite = "subtitle-panel-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            let manager = IPTVPlayerManager(progressDefaults: defaults)
            manager.playAVKitFixture(M3UItem(name: "Subtitle placement", streamURL: url, contentType: .movie))
            manager.showVideoControls = true
            let hosting = NSHostingView(rootView: IPTVPlaybackView(manager: manager))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 200), size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            defer {
                manager.subtitles.showingMenu = false
                manager.stop()
                window.close()
                defaults.removePersistentDomain(forName: suite)
            }
            let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
            manager.subtitles.showingMenu = true
            for _ in 0..<20 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertFalse(NSApp.windows.contains {
                !existing.contains(ObjectIdentifier($0)) && $0.isVisible
            }, "Subtitle controls must stay in the player window")
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            let panel = try XCTUnwrap(scrollViews(hosting).first)
            let frame = panel.convert(panel.bounds, to: hosting)
            XCTAssertTrue(hosting.bounds.insetBy(dx: 10, dy: 10).contains(frame), "\(frame) exceeds player \(hosting.bounds)")
            XCTAssertGreaterThan(frame.height, 150)
            let bottomGap = hosting.isFlipped ? hosting.bounds.maxY - frame.maxY : frame.minY
            XCTAssertGreaterThan(bottomGap, 40, "The panel must sit above the playback controls")
            let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/subtitle-panel-\(Int(size.width)).png"))
        }
    }
}
#endif
