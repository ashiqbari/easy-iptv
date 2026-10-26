#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import EasyIPTV

@MainActor
final class PlaybackErrorInteractionTests: XCTestCase {
    func testErrorActionsReceiveClicksAbovePlaybackControlsForBothEngines() async throws {
        _ = NSApplication.shared
        let url = try await silentMedia()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = M3UItem(name: "Episode", streamURL: url, contentType: .series)
        for useVLC in [false, true] {
            // shortcut: click points assume this fixed window and default text size; update them if the error panel layout changes.
            for (action, y) in [("retry", 325.0), ("startOver", 362.0), ("vlc", 403.0), ("avkit", 447.0)] {
                let suite = "error-buttons-\(UUID())", defaults = UserDefaults(suiteName: suite)!
                let manager = IPTVPlayerManager(progressDefaults: defaults)
                manager.progressStore.save(item: item, position: 120, duration: 0)
                manager.continueWatching(item)
                if !useVLC { manager.playAVKitFixture(item) }
                manager.player?.replaceCurrentItem(with: nil)
                await manager.vlcPlayer?.shutdown()
                manager.isPlaying = false; manager.isBuffering = false
                manager.errorMessage = "This stream could not resume at the saved position. Try again, switch player, or choose Start over."
                let originalAV = manager.player, originalVLC = manager.vlcPlayer
                let hosting = NSHostingView(rootView: IPTVPlaybackView(manager: manager)
                    .environment(\.appPalette, AppPalette(appearance: .forest)).environment(\.colorScheme, .dark))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
                defer {
                    manager.stop(); manager.libraryPersistence.invalidatePendingWrites(); window.close()
                    defaults.removePersistentDomain(forName: suite)
                }
                manager.notePlayerActivity()
                for _ in 0..<20 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000) }
                XCTAssertTrue(manager.canStartOverAfterResumeFailure)
                let point = CGPoint(x: hosting.bounds.midX, y: hosting.isFlipped ? y : hosting.bounds.height - y)
                let location = hosting.convert(point, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    NSApp.sendEvent(event)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                let context = "\(action), initial engine \(useVLC ? "VLC" : "AVKit")"
                if action != "startOver" {
                    XCTAssertEqual(manager.progressStore.progress(for: item)?.position, 120, context)
                }
                switch action {
                case "retry":
                    XCTAssertTrue(useVLC ? manager.vlcPlayer !== originalVLC : manager.player !== originalAV, context)
                case "startOver":
                    XCTAssertNil(manager.progressStore.progress(for: item), context)
                    XCTAssertFalse(manager.canStartOverAfterResumeFailure, context)
                case "vlc":
                    XCTAssertTrue(manager.useVLCPlayback, context)
                    XCTAssertTrue(manager.vlcPlayer !== originalVLC, context)
                default:
                    XCTAssertFalse(manager.useVLCPlayback, context)
                    XCTAssertTrue(manager.player !== originalAV, context)
                }
            }
        }
    }
}
#endif
