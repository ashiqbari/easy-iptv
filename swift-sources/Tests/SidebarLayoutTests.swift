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
        let manager = IPTVPlayerManager(progressDefaults: UserDefaults(suiteName: "sidebar-tests-\(UUID())")!)
        manager.showingDashboard = false
        return manager
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
    func testChannelPanelStaysBelowHeaderAcrossTogglesAndWindowSizes() async throws {
        let manager = manager()
        let hosting = NSHostingView(rootView: ContentView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 820),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.contentView = hosting
        defer { manager.stop(); window.close() }

        func searchFields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.placeholderString?.hasPrefix("Search") == true { return [field] }
            return view.subviews.flatMap { searchFields($0) }
        }
        func settle() async throws {
            for _ in 0..<10 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        for size in [CGSize(width: 1320, height: 820), CGSize(width: 1000, height: 650)] {
            window.setContentSize(size)
            try await settle()
            let headerBoundary = window.contentLayoutRect.maxY
            let headerFrames = Dictionary(uniqueKeysWithValues: (window.toolbar?.items ?? []).compactMap { item -> (String, CGRect)? in
                guard ["Channels Sidebar", "Search TV Guide", "Refresh Library", "Downloads"].contains(item.label), let view = item.view else { return nil }
                return (item.label, view.convert(view.bounds, to: nil))
            })
            for showing in [true, false, true, false, true] {
                if manager.showsChannelsSidebar != showing { manager.toggleChannelsSidebar() }
                try await settle()
                XCTAssertEqual(window.contentLayoutRect.maxY, headerBoundary, accuracy: 1,
                               "Toggling Channels must not move or resize the window header")
                let toolbar = try XCTUnwrap(window.toolbar)
                for label in ["Appearance", "Add Source", "About", "Channels Sidebar", "Search TV Guide", "Refresh Library", "Downloads"] {
                    let item = try XCTUnwrap(toolbar.visibleItems?.first { $0.label == label },
                                             "\(label) must remain visible in the header")
                    XCTAssertTrue(item.isEnabled)
                    if let view = item.view {
                        let frame = view.convert(view.bounds, to: nil)
                        XCTAssertGreaterThanOrEqual(frame.minY, headerBoundary,
                                                   "Header controls must not share the channel panel's content area")
                        if let original = headerFrames[label] {
                            XCTAssertEqual(frame, original, "\(label) must not move when Channels toggles")
                        }
                    }
                }
                let labels = (toolbar.visibleItems ?? []).map(\.label)
                XCTAssertLessThan(try XCTUnwrap(labels.firstIndex(of: "Channels Sidebar")),
                                  try XCTUnwrap(labels.firstIndex(of: "Search TV Guide")))
                let fields = searchFields(hosting)
                let channelSearch = fields.first { $0.placeholderString == "Search in Live TV..." }
                XCTAssertEqual(channelSearch != nil, showing)
                if let channelSearch {
                    let frame = channelSearch.convert(channelSearch.bounds, to: nil)
                    XCTAssertLessThanOrEqual(frame.maxY, headerBoundary,
                                             "The panel search must stay below the native header")
                    XCTAssertGreaterThanOrEqual(frame.minY, window.contentLayoutRect.minY)
                    // The panel heading must have room above search inside the content area.
                    XCTAssertGreaterThan(headerBoundary - frame.maxY, 30)
                }
            }
        }
    }

    func testDownloadsDialogDoesNotMoveSidebarContentIntoTitlebar() async throws {
        let manager = manager()
        let hosting = NSHostingView(rootView: ContentView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 820),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.contentView = hosting
        defer { manager.stop(); window.close() }

        func searchFields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.placeholderString?.hasPrefix("Search") == true { return [field] }
            return view.subviews.flatMap { searchFields($0) }
        }
        func settle() async throws {
            for _ in 0..<10 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await settle()
        let original = Dictionary(uniqueKeysWithValues: searchFields(hosting).map {
            ($0.placeholderString!, $0.convert($0.bounds, to: hosting))
        })
        XCTAssertEqual(original.count, 2)
        for showing in [true, false, true, false] {
            manager.showingDownloads = showing
            try await settle()
            let fields = searchFields(hosting)
            XCTAssertEqual(fields.count, original.count)
            for field in fields {
                let expected = try XCTUnwrap(original[field.placeholderString!])
                let current = field.convert(field.bounds, to: hosting)
                XCTAssertEqual(current.minY, expected.minY, accuracy: 1, "Opening Downloads must preserve the titlebar inset")
            }
        }
    }

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

    func testFullscreenExitKeepsTitleHiddenAndRestoresToolbar() {
        _ = NSApplication.shared
        let manager = manager()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "EasyIPTV"
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "fullscreen-title-test")
        defer { manager.stop(); window.close() }
        manager.updateFullscreenState(true, window: window)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.toolbar?.isVisible, false)
        manager.updateFullscreenState(false, window: window)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.toolbar?.isVisible, true)
        window.miniaturize(nil)
        window.deminiaturize(nil)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.toolbar?.isVisible, true)
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
