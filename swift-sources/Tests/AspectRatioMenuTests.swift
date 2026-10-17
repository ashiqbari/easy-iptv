import XCTest
import SwiftUI
import AppKit
@testable import EasyIPTV

@MainActor
final class AspectRatioMenuTests: XCTestCase {
    func testOptionsStayOpenDuringPlaybackAndCanBeSelectedDirectly() async throws {
        _ = NSApplication.shared
        let suite = "aspect-menu-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = try await silentMedia()
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        manager.playAVKitFixture(M3UItem(name: "Aspect menu fixture", streamURL: url, contentType: .movie))
        let hosting = NSHostingView(rootView: IPTVPlaybackView(manager: manager))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            manager.stop(); window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        func aspectButton(in view: NSView) -> NSPopUpButton? {
            if let button = view as? NSPopUpButton, button.accessibilityLabel() == "Auto" { return button }
            return view.subviews.lazy.compactMap { aspectButton(in: $0) }.first
        }
        let button = try XCTUnwrap(aspectButton(in: hosting))
        let menu = try XCTUnwrap(button.menu)
        let probe = AspectMenuProbe(manager: manager, menu: menu)
        let observers = [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: menu, queue: .main) { _ in
                MainActor.assumeIsolated { probe.isTracking = name == NSMenu.didBeginTrackingNotification }
            }
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }
        // Native menus run a nested event loop; exercise playback updates in that loop.
        let timer = Timer(timeInterval: 0.2, target: probe, selector: #selector(AspectMenuProbe.tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); menu.cancelTracking() }
        window.orderFront(nil)
        button.performClick(nil)
        XCTAssertTrue(probe.completed, "The menu must remain open until an option is selected")
        XCTAssertEqual(manager.screenSize, .standard)
    }
}

@MainActor
private final class AspectMenuProbe: NSObject {
    let manager: IPTVPlayerManager
    let menu: NSMenu
    var isTracking = false
    var completed = false
    private var ticks = 0

    init(manager: IPTVPlayerManager, menu: NSMenu) { self.manager = manager; self.menu = menu }

    @objc func tick() {
        ticks += 1
        manager.currentTime += 0.2
        manager.pointerLeftPlayer()
        manager.hideControlsIfIdle()
        XCTAssertTrue(isTracking)
        XCTAssertTrue(manager.showVideoControls)
        XCTAssertTrue(manager.controlsAutoHideBlocked)
        guard ticks == 6 else { return }
        XCTAssertTrue(VideoScreenSize.allCases.allSatisfy { mode in menu.items.contains { $0.title == mode.title } })
        XCTAssertFalse(menu.items.contains { $0.submenu != nil }, "Ratios should be selectable without opening another menu")
        if let index = menu.items.firstIndex(where: { $0.title == VideoScreenSize.standard.title }) {
            menu.performActionForItem(at: index)
        } else { XCTFail("Missing 4:3 option") }
        completed = true
        menu.cancelTracking()
    }
}
