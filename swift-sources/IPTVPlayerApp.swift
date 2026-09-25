//
//  IPTVPlayerApp.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 13+
//

import SwiftUI
import AVFoundation

#if os(macOS)
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: IPTVPlayerManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Observe window close notifications so all playback immediately ceases
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }
    
    @objc private func handleWindowWillClose(_ notification: Notification) {
        // Immediately halt player and audio output so nothing keeps playing in background
        manager?.stop()
    }
    
    /// When the user closes the main window (e.g. clicking the red 'x' button),
    /// terminate the app cleanly instead of leaving a headless background process playing audio.
    /// This also guarantees that clicking the app icon in the Dock or Finder launches it fresh immediately.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        manager?.stop()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }
}
#endif

@main
struct IPTVPlayerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    // MARK: - State Management
    
    @StateObject private var manager = IPTVPlayerManager()
    
    init() {
        configurePlatformPlayback()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
                #if os(macOS)
                .frame(minWidth: 1000, minHeight: 650)
                .onAppear {
                    appDelegate.manager = manager
                }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 820)
        .commands {
            // Media Playback menu in macOS top bar
            CommandMenu("Playback") {
                Button(manager.isPlaying ? "Pause" : "Play") {
                    manager.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                
                Divider()
                
                Button("Next Channel") {
                    manager.nextChannel()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                
                Button("Previous Channel") {
                    manager.previousChannel()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                
                Divider()
                
                Button("Stop Playback") {
                    manager.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
            }
            
            CommandGroup(replacing: .help) {
                Button("IPTV Help & Documentation") {
                    if let url = URL(string: "https://developer.apple.com/documentation/avfoundation") {
                        #if os(macOS)
                        NSWorkspace.shared.open(url)
                        #endif
                    }
                }
            }
        }
        #endif
    }
    
    // MARK: - Platform Audio Setup
    
    private func configurePlatformPlayback() {
        #if os(iOS)
        do {
            // Ensure audio plays when the device is locked or in silent mode
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try audioSession.setActive(true)
        } catch {
            print("Failed to initialize AVAudioSession: \(error.localizedDescription)")
        }
        #endif
    }
}
