import XCTest
import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
import VLC
#endif
@testable import EasyIPTV

@MainActor
final class SidebarLayoutTests: XCTestCase {
    private func manager() -> IPTVPlayerManager {
        IPTVPlayerManager(progressDefaults: UserDefaults(suiteName: "sidebar-tests-\(UUID())")!)
    }

    func testEachToggleOnlyChangesItsOwnPane() {
        let manager = manager()
        manager.toggleCategoriesSidebar()
        XCTAssertFalse(manager.showsCategoriesSidebar)
        XCTAssertTrue(manager.showsChannelsSidebar)
        manager.toggleChannelsSidebar()
        XCTAssertFalse(manager.showsCategoriesSidebar)
        XCTAssertFalse(manager.showsChannelsSidebar)
        manager.toggleCategoriesSidebar()
        XCTAssertTrue(manager.showsCategoriesSidebar)
        XCTAssertFalse(manager.showsChannelsSidebar)
        manager.toggleChannelsSidebar()
        XCTAssertTrue(manager.showsCategoriesSidebar)
        XCTAssertTrue(manager.showsChannelsSidebar)
    }

    #if os(macOS)
    func testBottomControlsUseMultipleRowsInsteadOfScrollingWhenNarrow() {
        for type in [M3UItem.ContentType.movie, .series] {
            let manager = manager()
            let item = M3UItem(name: "Controls fixture", streamURL: URL(fileURLWithPath: "/private/tmp/nonexistent-sidebar-fixture.mp4"), contentType: type)
            manager.playDirectStream(item)
            if type == .series { manager.seriesEpisodes = [item] }
            manager.player?.replaceCurrentItem(with: nil)
            defer { manager.stop() }
            let hosting = NSHostingController(rootView: IPTVPlaybackView(manager: manager).bottomBar)
            let narrow = hosting.sizeThatFits(in: CGSize(width: 248, height: 600))
            let wide = hosting.sizeThatFits(in: CGSize(width: 1000, height: 600))
            XCTAssertLessThanOrEqual(narrow.width, 248)
            XCTAssertGreaterThan(narrow.height, wide.height + 30)
            XCTAssertGreaterThanOrEqual(wide.height, 44)
        }
    }

    func testChannelToggleKeepsTheMountedVideoSurface() async throws {
        try await checkMountedVideoSurface(useVLC: false)
    }

    func testChannelToggleKeepsTheVLCDrawable() async throws {
        try await checkMountedVideoSurface(useVLC: true)
    }

    private func checkMountedVideoSurface(useVLC: Bool) async throws {
        let manager = manager()
        manager.playDirectStream(M3UItem(name: "Surface fixture", streamURL: URL(fileURLWithPath: "/private/tmp/nonexistent-sidebar-fixture.mp4"), contentType: useVLC ? .live : .movie))
        manager.player?.replaceCurrentItem(with: nil)
        let hosting = NSHostingView(rootView: ContentView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { manager.stop(); window.close() }

        func surface(in view: NSView) -> NSView? {
            if useVLC { return manager.vlcPlayer?.drawable as? NSView }
            if let view = view as? AVPlayerLayerNSView { return view }
            return view.subviews.lazy.compactMap { surface(in: $0) }.first
        }
        func settle() async throws {
            for _ in 0..<10 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await settle()
        let original = try XCTUnwrap(surface(in: hosting))
        XCTAssertGreaterThan(original.bounds.width, 0)
        XCTAssertLessThanOrEqual(original.convert(original.bounds, to: hosting).maxY, hosting.bounds.maxY)
        for _ in 0..<4 {
            manager.toggleChannelsSidebar()
            try await settle()
            let current = try XCTUnwrap(surface(in: hosting))
            XCTAssertTrue(current === original, "Opening or closing channels must not replace the video view")
            XCTAssertTrue(current.window === window)
            XCTAssertGreaterThan(current.bounds.width, 0)
            XCTAssertGreaterThan(current.bounds.height, 0)
            XCTAssertLessThanOrEqual(current.convert(current.bounds, to: hosting).maxY, hosting.bounds.maxY)
        }
    }

    func testNativeSplitVisibilityKeepsTheOtherPaneVisible() {
        XCTAssertEqual(LibraryPaneLayout.visibility(categories: true, channels: true), .all)
        XCTAssertEqual(LibraryPaneLayout.visibility(categories: false, channels: true), .doubleColumn)
        XCTAssertEqual(LibraryPaneLayout.visibility(categories: true, channels: false), .all)
        XCTAssertEqual(LibraryPaneLayout.visibility(categories: false, channels: false), .detailOnly)
    }

    func testFullscreenDoesNotForgetPaneChoices() {
        let manager = manager()
        manager.toggleChannelsSidebar()
        manager.updateFullscreenState(true)
        manager.toggleCategoriesSidebar()
        manager.toggleChannelsSidebar()
        manager.updateFullscreenState(false)
        XCTAssertTrue(manager.showsCategoriesSidebar)
        XCTAssertFalse(manager.showsChannelsSidebar)
    }

    func testMissingAnchorCannotCoverNavigationAndNormalBoundsStayScoped() {
        let size = CGSize(width: 1320, height: 820)
        XCTAssertEqual(LibraryPaneLayout.playbackFrame(fullscreen: false, containerSize: size, detailBounds: nil), .zero)
        let detail = CGRect(x: 700, y: 0, width: 620, height: 820)
        XCTAssertEqual(LibraryPaneLayout.playbackFrame(fullscreen: false, containerSize: size, detailBounds: detail), detail)
        XCTAssertEqual(LibraryPaneLayout.playbackFrame(fullscreen: true, containerSize: size, detailBounds: detail), CGRect(origin: .zero, size: size))
    }

    func testNormalWindowClampsTitlebarOverflowAndOffscreenBounds() {
        let size = CGSize(width: 1320, height: 800)
        XCTAssertEqual(LibraryPaneLayout.playbackFrame(fullscreen: false, containerSize: size,
                       detailBounds: CGRect(x: 701, y: 52, width: 619, height: 800)),
                       CGRect(x: 701, y: 52, width: 619, height: 748))
        XCTAssertEqual(LibraryPaneLayout.playbackFrame(fullscreen: false, containerSize: size, detailBounds: .zero), .zero)
        XCTAssertEqual(LibraryPaneLayout.playbackFrame(fullscreen: false, containerSize: size,
                       detailBounds: CGRect(x: 1500, y: 0, width: 100, height: 100)), .zero)
    }
    #endif

    func testSidebarTogglesDoNotReplaceOrStopPlayback() throws {
        let manager = manager()
        manager.playDirectStream(M3UItem(name: "Fixture", streamURL: URL(fileURLWithPath: "/private/tmp/nonexistent-sidebar-fixture.mp4"), contentType: .movie))
        let player = try XCTUnwrap(manager.player)
        let item = player.currentItem
        for _ in 0..<4 {
            manager.toggleCategoriesSidebar()
            manager.toggleChannelsSidebar()
            XCTAssertTrue(manager.player === player)
            XCTAssertTrue(player.currentItem === item)
        }
        manager.stop()
    }
}
