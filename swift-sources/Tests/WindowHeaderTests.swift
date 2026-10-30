#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import EasyIPTV

@MainActor
final class WindowHeaderTests: XCTestCase {
    func testHeaderDoubleClickResizesAndRestoresDashboardAndLibrary() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "header-test-\(UUID())")!
        let manager = IPTVPlayerManager(progressDefaults: defaults)
        let controller = NSWindowController(window: NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false))
        let window = try XCTUnwrap(controller.window)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: ContentView(manager: manager))
        window.makeKeyAndOrderFront(nil)
        defer { manager.stop(); window.close() }
        let preference = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        try XCTSkipIf(preference == "None" || preference == "Minimize", "Resize test requires the system zoom preference")

        func doubleClickHeader() async throws {
            let point = NSPoint(x: window.frame.width - 100, y: window.frame.height - 12)
            XCTAssertFalse((window.toolbar?.items ?? []).contains { item in
                guard let view = item.view else { return false }
                return view.convert(view.bounds, to: nil).contains(point)
            }, "The test must double-click empty header space")
            for count in [1, 2] {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: count, pressure: 1)), atStart: false)
                }
            }
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        for dashboard in [true, false] {
            manager.showingDashboard = dashboard
            try await Task.sleep(nanoseconds: 300_000_000)
            let before = window.frame
            try await doubleClickHeader()
            XCTAssertNotEqual(window.frame.size, before.size, "dashboard=\(dashboard)")
            try await doubleClickHeader()
            XCTAssertEqual(window.frame, before, "A second double-click restores the window")
        }
    }

    func testHeaderHandlerLeavesSingleClicksContentAndButtonsAlone() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WindowHeaderNSView()
        window.contentView = view
        defer { view.stopTracking(); window.close() }
        func event(_ point: NSPoint, count: Int = 2) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        XCTAssertFalse(view.handle(try event(NSPoint(x: 450, y: 300))))
        XCTAssertFalse(view.handle(try event(NSPoint(x: 450, y: 590), count: 1)))
        let button = NSButton(frame: CGRect(x: 400, y: 575, width: 100, height: 25))
        let container = try XCTUnwrap(window.contentView?.superview)
        container.addSubview(button)
        XCTAssertFalse(view.handle(try event(NSPoint(x: 450, y: 590))))
    }
}
#endif
