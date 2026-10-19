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
    func testSectionTabClicksAndHighlightStayInSync() async throws {
        _ = NSApplication.shared
        let suite = "section-tabs-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 260, height: 38),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { manager.stop(); window.close(); defaults.removePersistentDomain(forName: suite) }
        for appearance in [AppearancePreference.light, .dark, .forest] {
            let palette = AppPalette(appearance: appearance)
            let hosting = NSHostingView(rootView: LibrarySectionTabs(manager: manager)
                .environment(\.appPalette, palette).background(palette.background)
                .preferredColorScheme(appearance.colorScheme))
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            for width in [260.0, 420.0] {
                window.setContentSize(CGSize(width: width, height: 38))
                func settle() async throws {
                    for _ in 0..<10 {
                        hosting.layoutSubtreeIfNeeded()
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
                var unselectedColors: [NSColor] = []
                func checkHighlight(_ selected: M3UItem.ContentType?) throws {
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    for (index, section) in M3UItem.ContentType.allCases.enumerated() {
                        let x = 12 + CGFloat(index) * (width - 6) / 3
                        let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / width),
                            y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                        if selected == nil {
                            unselectedColors.append(color)
                            continue
                        }
                        let background = unselectedColors[index]
                        let isHighlighted = max(abs(color.redComponent - background.redComponent),
                            abs(color.greenComponent - background.greenComponent),
                            abs(color.blueComponent - background.blueComponent)) > 0.2
                        XCTAssertEqual(isHighlighted, selected == section,
                                       "Only \(String(describing: selected)) should be highlighted in \(appearance)")
                    }
                }
                manager.showingDashboard = true
                try await settle()
                try checkHighlight(nil)
                for section in [M3UItem.ContentType.series, .live, .movie, .series, .movie, .live] {
                    let index = try XCTUnwrap(M3UItem.ContentType.allCases.firstIndex(of: section))
                    let point = CGPoint(x: width * (CGFloat(index) + 0.5) / 3, y: hosting.bounds.midY)
                    let location = hosting.convert(point, to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
                    }
                    try await settle()
                    XCTAssertFalse(manager.showingDashboard)
                    XCTAssertEqual(manager.selectedSection, section)
                    try checkHighlight(section)
                }
                manager.browse(.series)
                try await settle()
                try checkHighlight(.series)
            }
        }
    }

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
                for label in ["Appearance", "Sources", "About", "Channels Sidebar", "Search TV Guide", "Refresh Library", "Downloads"] {
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
                XCTAssertNotNil(channelSearch, "Channels stays mounted so its width can animate")
                if showing, let channelSearch {
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
            manager.playAVKitFixture(item)
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

    func testChannelTogglesWithCategoriesHiddenKeepPlaybackBoundsStable() async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let manager = manager()
        manager.playAVKitFixture(M3UItem(name: "Sidebar transition", streamURL: URL(fileURLWithPath: "/private/tmp/nonexistent-sidebar-fixture.mp4"), contentType: .movie))
        manager.player?.replaceCurrentItem(with: nil)
        let hosting = NSHostingView(rootView: ContentView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 820),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.becomeKey()
        defer { manager.stop(); window.close() }

        func surface(in view: NSView) -> NSView? {
            if view is AVPlayerLayerNSView { return view }
            return view.subviews.lazy.compactMap { surface(in: $0) }.first
        }
        func categorySearch(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Search categories…" { return field }
            return view.subviews.lazy.compactMap { categorySearch(in: $0) }.first
        }
        func categorySplit(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { categorySplit(in: $0) }.first
        }
        func sample() async throws -> CGFloat {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
            let video = try XCTUnwrap(surface(in: hosting))
            if let layer = video.layer?.presentation(), let root = hosting.layer?.presentation() {
                return layer.convert(layer.bounds, to: root).minX
            }
            return video.convert(video.bounds, to: hosting).minX
        }
        for _ in 0..<30 { _ = try await sample() }
        manager.toggleCategoriesSidebar()
        for _ in 0..<30 { _ = try await sample() }
        let originalSplit = try XCTUnwrap(categorySplit(in: hosting))
        for _ in 0..<4 {
            let start = try await sample()
            let wasShowingChannels = manager.showsChannelsSidebar
            let button = try XCTUnwrap(window.toolbar?.visibleItems?.first { $0.label == "Channels Sidebar" }?.view)
            let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            var positions = [start]
            for _ in 0..<40 {
                positions.append(try await sample())
                if let search = categorySearch(in: hosting) {
                    XCTAssertTrue(search.isHiddenOrHasHiddenAncestor || search.visibleRect.isEmpty,
                                  "The hidden category panel must not flash during the Channels transition")
                }
            }
            let end = try XCTUnwrap(positions.last)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertTrue(positions.contains { $0 > min(start, end) + 1 && $0 < max(start, end) - 1 },
                              "Channels must resize the playback area smoothly rather than jump between endpoints")
            }
            XCTAssertTrue(categorySplit(in: hosting) === originalSplit,
                          "Toggling Channels must not recreate the collapsed Categories split view")
            XCTAssertEqual(manager.showsChannelsSidebar, !wasShowingChannels)
            for position in positions {
                XCTAssertGreaterThanOrEqual(position, min(start, end) - 1)
                XCTAssertLessThanOrEqual(position, max(start, end) + 1)
            }
            XCTAssertFalse(manager.showsCategoriesSidebar)
        }
        let dividerX = try await sample() - 0.5
        let start = hosting.convert(NSPoint(x: dividerX + 3, y: hosting.bounds.midY), to: nil)
        for (type, offset) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, 20.0),
                               (.leftMouseDragged, 40.0), (.leftMouseDragged, 60.0), (.leftMouseDragged, 80.0), (.leftMouseUp, 80.0)] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + offset, y: start.y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for _ in 0..<20 { _ = try await sample() }
        let resized = try await sample()
        XCTAssertEqual(resized, dividerX + 80.5, accuracy: 2, "The animated pane must retain draggable resizing")
    }

    private func checkMountedVideoSurface(useVLC: Bool) async throws {
        let manager = manager()
        manager.playDirectStream(M3UItem(name: "Surface fixture", streamURL: URL(fileURLWithPath: "/private/tmp/nonexistent-sidebar-fixture.mp4"), contentType: useVLC ? .live : .movie))
        if !useVLC, let item = manager.currentChannel { manager.playAVKitFixture(item) }
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
        XCTAssertEqual(LibraryPaneLayout.visibility(categories: true), .all)
        XCTAssertEqual(LibraryPaneLayout.visibility(categories: false), .detailOnly)
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
        manager.playAVKitFixture(M3UItem(name: "Fixture", streamURL: URL(fileURLWithPath: "/private/tmp/nonexistent-sidebar-fixture.mp4"), contentType: .movie))
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
