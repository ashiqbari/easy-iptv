#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import EasyIPTV

@MainActor
final class LibraryFilterControlTests: XCTestCase {
    func testPopoverCanReopenAfterChangingSortAndDuringPlaybackUpdates() async throws {
        _ = NSApplication.shared
        let suite = "filter-popover-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let catalog = (0..<10_000).map {
            M3UItem(name: "Channel \($0)", streamURL: URL(string: "https://fixture.invalid/\($0).m3u8")!, contentType: .live)
        }
        var loader = LibraryLoader(); loader.playlist = { _ in catalog }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        await manager.loadPlaylist(from: "https://fixture.invalid/list")
        let hosting = NSHostingView(rootView: LibraryFilterControl(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            manager.stop(); manager.libraryPersistence.invalidatePendingWrites(); window.close()
            defaults.removePersistentDomain(forName: suite)
        }
        func click(_ point: CGPoint) throws {
            let location = hosting.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApp.sendEvent(event)
            }
        }
        func settle() async throws {
            for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 20_000_000) }
        }
        try await settle()
        for order in [LibrarySortOrder.nameAscending, .nameDescending, .provider, .nameAscending] {
            let existingWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            try click(CGPoint(x: hosting.bounds.midX, y: hosting.bounds.midY))
            try await settle()
            let popover = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existingWindows.contains(ObjectIdentifier($0)) },
                                        "Sort/filter must reopen after a previous selection")
            manager.librarySortOrder = order
            for _ in 0..<10 { manager.currentTime += 0.1; try await Task.sleep(nanoseconds: 10_000_000) }
            try await waitForLibraryFilter(manager)
            XCTAssertEqual(manager.librarySortOrder, order)
            XCTAssertTrue(popover.isVisible, "Popover must remain open while results and playback state update")
            try click(CGPoint(x: 2, y: 2))
            try await settle()
            XCTAssertFalse(popover.isVisible, "Clicking outside must dismiss the popover")
        }
    }
}
#endif
