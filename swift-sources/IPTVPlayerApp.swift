//
//  IPTVPlayerApp.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 15+
//

import SwiftUI
import AVFoundation

#if os(iOS)
final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.shared.handleBackgroundEvents(identifier, completion: completionHandler)
    }
}
#endif

enum AppearancePreference: String, CaseIterable {
    static let storageKey = "appearance"
    case system, light, dark, navy, obsidian, forest, warmStone

    var title: String { self == .warmStone ? "Warm Stone" : rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .warmStone: return .light
        case .dark, .navy, .obsidian, .forest: return .dark
        }
    }
}

struct AppPalette {
    var appearance: AppearancePreference = .system
    var isCustom: Bool { [.navy, .obsidian, .forest, .warmStone].contains(appearance) }
    var onAccent: Color { [.navy, .obsidian, .forest].contains(appearance) ? .black : .white }
    var background: Color {
        switch appearance {
        case .navy: return Color(red: 0.035, green: 0.06, blue: 0.12)
        case .obsidian: return Color(red: 21/255, green: 21/255, blue: 25/255)
        case .forest: return Color(red: 16/255, green: 35/255, blue: 30/255)
        case .warmStone: return Color(red: 245/255, green: 241/255, blue: 233/255)
        default: break
        }
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }
    var surface: Color {
        switch appearance {
        case .navy: return Color(red: 0.075, green: 0.11, blue: 0.18)
        case .obsidian: return Color(red: 34/255, green: 33/255, blue: 42/255)
        case .forest: return Color(red: 25/255, green: 51/255, blue: 43/255)
        case .warmStone: return Color(red: 1, green: 252/255, blue: 246/255)
        default: break
        }
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }
    var playbackBackground: Color { isCustom && appearance.colorScheme == .dark ? background : .black }
    var controlAccent: Color {
        switch appearance {
        case .navy: return Color(red: 0.02, green: 0.42, blue: 0.46)
        case .obsidian: return Color(red: 114/255, green: 81/255, blue: 190/255)
        case .forest: return Color(red: 37/255, green: 112/255, blue: 82/255)
        case .warmStone: return accent
        default: return .blue
        }
    }
    var accent: Color {
        switch appearance {
        case .navy: return Color(red: 0.12, green: 0.72, blue: 0.78)
        case .obsidian: return Color(red: 167/255, green: 139/255, blue: 250/255)
        case .forest: return Color(red: 110/255, green: 231/255, blue: 183/255)
        case .warmStone: return Color(red: 172/255, green: 73/255, blue: 47/255)
        default: return .blue
        }
    }
}

private struct AppPaletteKey: EnvironmentKey {
    static let defaultValue = AppPalette()
}

extension EnvironmentValues {
    var appPalette: AppPalette {
        get { self[AppPaletteKey.self] }
        set { self[AppPaletteKey.self] = newValue }
    }
}

struct AppearancePicker: View {
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system

    var body: some View {
        Picker("Appearance", selection: $appearance) {
            ForEach(AppearancePreference.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.inline)
    }
}

#if os(macOS)
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: IPTVPlayerManager?
    
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
    #else
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) var appDelegate
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
                .frame(minWidth: 720, minHeight: 500)
                .onAppear {
                    appDelegate.manager = manager
                }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandMenu("Appearance") {
                AppearancePicker()
            }
            CommandMenu("Downloads") {
                Button("Show Downloads") { manager.showingDownloads = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            // Media Playback menu in macOS top bar
            CommandMenu("Playback") {
                Toggle("Auto Picture-in-Picture", isOn: $manager.autoPictureInPicture)
                Button("Picture in Picture") { manager.pictureInPicture.toggle() }
                    .disabled(!manager.pictureInPicture.isPossible)
                Divider()
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
