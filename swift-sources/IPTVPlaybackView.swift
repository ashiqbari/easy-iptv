//
//  IPTVPlaybackView.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 15+
//

import SwiftUI
import AVFoundation
import QuartzCore

private struct PlaybackBadge: View {
    @ObservedObject var manager: IPTVPlayerManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let title = manager.playbackBadge {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((title == "LIVE" ? Color.red : Color.white.opacity(0.2)))
                    .cornerRadius(4)
                    .help("LIVE means within 30 seconds of the stream's reported live edge. Live TV means the position cannot be verified.")
            }
        }
    }
}

#if os(macOS)
/// Observes input without replacing the AVPlayer/VLC surface or swallowing its events.
struct PlaybackActivityTracking: NSViewRepresentable {
    let manager: IPTVPlayerManager
    func makeNSView(context: Context) -> PlaybackActivityNSView { PlaybackActivityNSView(manager: manager) }
    func updateNSView(_ view: PlaybackActivityNSView, context: Context) { }
    static func dismantleNSView(_ view: PlaybackActivityNSView, coordinator: ()) { view.stopTracking() }
}

private struct PlaybackControlTracking: NSViewRepresentable {
    let manager: IPTVPlayerManager
    let region: String
    func makeNSView(context: Context) -> PlaybackControlNSView { PlaybackControlNSView(manager: manager, region: region) }
    func updateNSView(_ view: PlaybackControlNSView, context: Context) { }
    static func dismantleNSView(_ view: PlaybackControlNSView, coordinator: ()) { view.stopTracking() }
}

final class PlaybackControlNSView: NSView {
    private weak var manager: IPTVPlayerManager?
    private let region: String
    init(manager: IPTVPlayerManager, region: String) { self.manager = manager; self.region = region; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { manager?.setControlsInteraction(region, active: true) }
    override func mouseExited(with event: NSEvent) { manager?.setControlsInteraction(region, active: false) }
    func stopTracking() {
        Task { @MainActor [weak manager, region] in manager?.setControlsInteraction(region, active: false) }
    }
}

private extension View {
    func playbackControlHover(_ manager: IPTVPlayerManager, region: String) -> some View {
        background(PlaybackControlTracking(manager: manager, region: region))
    }
}

final class PlaybackActivityNSView: NSView {
    private weak var manager: IPTVPlayerManager?
    private weak var trackedWindow: NSWindow?
    private var previousMouseMovedEvents = false
    private var monitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var area: NSTrackingArea?
    private var trackedMenus = Set<String>()

    init(manager: IPTVPlayerManager) { self.manager = manager; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopTracking()
        guard let window else { return }
        trackedWindow = window
        previousMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.manager?.isFullscreen == true else { return }
                self?.updatePointer()
            }
        }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: name == NSWindow.didResignKeyNotification ? window : nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updatePointer(activity: false)
                    self?.manager?.scheduleControlsAutoHide()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        })
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu else { return }
                    let key = "menu-\(ObjectIdentifier(menu))"
                    if name == NSMenu.didBeginTrackingNotification {
                        guard self.manager?.currentChannel != nil else { return }
                        self.trackedMenus.insert(key)
                        self.manager?.setControlsInteraction(key, active: true)
                    } else if self.trackedMenus.remove(key) != nil {
                        self.manager?.setControlsInteraction(key, active: false)
                    }
                }
            })
        }
        updatePointerAfterLayout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: nil)
        area = next
        addTrackingArea(next)
    }
    override func mouseEntered(with event: NSEvent) { updatePointer() }
    override func mouseMoved(with event: NSEvent) { updatePointer() }
    override func mouseExited(with event: NSEvent) { leavePlayer() }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { updatePointerAfterLayout() }
    }

    private func updatePointerAfterLayout() {
        // Native layout runs inside SwiftUI updates; publish activity on the next turn.
        Task { @MainActor [weak self] in
            guard self?.trackedWindow != nil else { return }
            self?.updatePointer()
        }
    }

    func handle(_ event: NSEvent) {
        guard let manager, event.window === window else { return }
        if event.type == .keyDown || event.type == .flagsChanged {
            manager.notePlayerActivity()
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            manager.pointerInsidePlayer = true
            manager.notePlayerActivity()
        } else { leavePlayer() }
    }

    private func updatePointer(activity: Bool = true) {
        guard let window, let manager, !bounds.isEmpty else { return }
        let inside = window.isVisible && !window.isMiniaturized && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if inside {
            manager.pointerInsidePlayer = true
            if activity { manager.notePlayerActivity() }
        } else { leavePlayer() }
    }
    private func leavePlayer() {
        manager?.pointerLeftPlayer()
    }

    func stopTracking() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        let wasTracking = trackedWindow != nil
        trackedWindow?.acceptsMouseMovedEvents = previousMouseMovedEvents
        trackedWindow = nil
        let menus = trackedMenus
        trackedMenus = []
        guard wasTracking else { return }
        Task { @MainActor [weak self, weak manager] in
            for key in menus { manager?.setControlsInteraction(key, active: false) }
            guard self?.trackedWindow == nil else { return }
            manager?.pointerLeftPlayer()
        }
    }
}
#endif

#if !os(macOS)
private extension View {
    func playbackControlHover(_ manager: IPTVPlayerManager, region: String) -> some View {
        onHover { manager.setControlsInteraction(region, active: $0) }
    }
}
#endif

private struct EpisodePositions: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
#if os(macOS)
import VLC
import AppKit
#endif

/// High-performance video player view wrapping hardware-accelerated AVPlayerLayer
/// with custom HUD overlays, buffering indicators, error states, and responsive controls for iOS and macOS.
public struct IPTVPlaybackView: View {
    @Environment(\.appPalette) private var palette
    
    @ObservedObject var manager: IPTVPlayerManager
    @State private var visibilityID = UUID()
    @State private var showingPlaybackDiagnostics = false
    
    public init(manager: IPTVPlayerManager) {
        self.manager = manager
    }
    
    public var body: some View {
        ZStack {
            // Background deep canvas
            palette.playbackBackground.ignoresSafeArea()
            
            Group {
#if os(macOS)
                if manager.useVLCPlayback {
                    if let player = manager.vlcPlayer {
                        VLCVideoSurface(
                            player: player,
                            shouldPlay: manager.isPlaying || manager.isBuffering,
                            screenSize: manager.screenSize
                        )
                            .ignoresSafeArea()
                            .overlay {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { manager.toggleFullscreen() }
                                    .onTapGesture(count: 1) { manager.toggleVideoControls() }
                            }
                        SubtitleOverlay(controller: manager.subtitles, controlsVisible: manager.showVideoControls)
                        if manager.isBuffering { bufferingOverlay }
                        if let errorMsg = manager.errorMessage { errorOverlay(message: errorMsg) }
                        if manager.showVideoControls { controlsOverlay }
                        if manager.showingEpisodesDrawer && manager.currentChannel?.contentType == .series && !manager.seriesEpisodes.isEmpty {
                            episodesDrawerOverlay
                        }
                    } else {
                        bufferingOverlay
                    }
                } else {
                    avPlaybackContent
                }
#else
                avPlaybackContent
#endif
            }
            .opacity(manager.isViewingMovieDetails || manager.isViewingSeriesDetails ? 0 : 1)
            .allowsHitTesting(!manager.isViewingMovieDetails && !manager.isViewingSeriesDetails)
            .accessibilityHidden(manager.isViewingMovieDetails || manager.isViewingSeriesDetails)

            if manager.isViewingMovieDetails, let movie = manager.movieOverviewItem {
                MovieDetailsView(item: movie, manager: manager)
                    .background(palette.background)
            } else if manager.isViewingSeriesDetails {
                seriesHeroView.background(palette.background)
            }
        }
        .sheet(isPresented: $manager.showingEPGSheet) {
            if let channel = manager.currentChannel {
                NativeEPGSheetView(channel: channel, manager: manager)
            }
        }
        .onAppear {
            manager.playerViewAppeared(visibilityID)
            manager.scheduleControlsAutoHide()
        }
        .onDisappear {
            manager.cancelControlsAutoHide()
            manager.playerViewDisappeared(visibilityID)
        }
        // macOS keyboard shortcuts (macOS 15+)
        #if os(macOS)
        .overlay(alignment: .topLeading) {
            if showingPlaybackDiagnostics {
                PlaybackDiagnosticsView(manager: manager).padding(20).allowsHitTesting(false)
            }
        }
        .onChange(of: manager.controlsAutoHideBlocked) { _, _ in manager.notePlayerActivity() }
        .background { PlaybackActivityTracking(manager: manager) }
        .background {
            HStack(spacing: 0) {
                Button("") { manager.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { manager.toggleFullscreen() }
                    .keyboardShortcut("f", modifiers: [])
                Button("") { manager.seekBy(seconds: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { manager.seekBy(seconds: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { showingPlaybackDiagnostics.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        #else
        .onChange(of: manager.controlsAutoHideBlocked) { _ in manager.notePlayerActivity() }
        #endif
    }

    @ViewBuilder
    private var avPlaybackContent: some View {
        if let player = manager.player {
                // Direct AVPlayerLayer rendering via explicit platform representable
                AVPlayerLayerRepresentable(player: player, videoGravity: manager.videoGravity, screenSize: manager.screenSize)
                    .ignoresSafeArea()
                    .overlay(
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                manager.toggleFullscreen()
                            }
                            .onTapGesture(count: 1) {
                                manager.toggleVideoControls()
                            }
                    )
                
                SubtitleOverlay(controller: manager.subtitles, controlsVisible: manager.showVideoControls)

                // Buffering Spinner Overlay
                if manager.isBuffering {
                    bufferingOverlay
                }
                
                // Error Alert Overlay with Instant Format Fix Buttons
                if let errorMsg = manager.errorMessage {
                    errorOverlay(message: errorMsg)
                }
                
                // HUD Controls Overlay
                if manager.showVideoControls {
                    controlsOverlay
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                }
                
                // Series Episodes Slide-in Drawer (Only for TV Shows during playback)
                if manager.showingEpisodesDrawer && manager.currentChannel?.contentType == .series && !manager.seriesEpisodes.isEmpty {
                    episodesDrawerOverlay
                        .transition(.move(edge: .trailing))
                }
        } else {
            emptyPlaceholderView
        }
    }
    
    // MARK: - Subviews
    
    /// Top and bottom control bars with auto-hide timer.
    private var controlsOverlay: some View {
        VStack {
            // Top Navigation HUD Bar
            topBar.playbackControlHover(manager, region: "topBar")
                .onDisappear { manager.setControlsInteraction("topBar", active: false) }
            
            Spacer()
            
            // Center Play / Pause & Skip HUD
            centerControls.playbackControlHover(manager, region: "centerControls")
                .onDisappear { manager.setControlsInteraction("centerControls", active: false) }
            
            Spacer()
            
            // Bottom Action HUD Bar
            bottomBar.playbackControlHover(manager, region: "bottomBar")
                .onDisappear { manager.setControlsInteraction("bottomBar", active: false) }
        }
        .padding()
        .background(
            LinearGradient(
                colors: [palette.playbackBackground.opacity(0.95), Color.clear, palette.playbackBackground.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
    
    /// Top channel information header.
    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            if let channel = manager.currentChannel {
                if channel.contentType == .movie {
                    Button { manager.returnToMovie() } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(8)
                    .help("Return to movie details")
                }
                // Return to TV Series Overview Button
                if channel.contentType == .series || manager.selectedSection == .series {
                    Button {
                        manager.returnToSeries()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(8)
                    .help("Return to Series Overview & Seasons")
                }
                
                // Channel Logo
                if let logo = channel.logoURL {
                    AsyncImage(url: logo) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable()
                                 .scaledToFit()
                                 .frame(width: 38, height: 38)
                                 .cornerRadius(6)
                        default:
                            fallbackLogo
                        }
                    }
                } else {
                    fallbackLogo
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(channel.name)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        if manager.downloads.localURL(for: channel) != nil {
                            Label("Downloaded", systemImage: "checkmark.circle.fill").font(.caption2.bold()).foregroundStyle(.white)
                        } else {
                            PlaybackBadge(manager: manager)
                        }
                    }
                    
                    Text(channel.displayGroup)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // TV Series Episodes & Seasons Overview Button
                if channel.contentType == .series {
                    Button {
                        manager.returnToSeries()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.grid.2x2.fill")
                            Text("All Episodes")
                        }
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.purple.opacity(0.85))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("View Series Overview & Seasons")
                }
                
                // Live TV EPG Program Guide Button
                if channel.contentType == .live || (!channel.isVOD && channel.contentType != .series) {
                    Button {
                        manager.showingEPGSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar.badge.clock")
                            Text("TV Guide")
                        }
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Live TV Electronic Program Schedule (EPG)")
                }
                
                // Playback engine selector
                #if os(macOS)
                Menu {
                    Button {
                        if manager.useVLCPlayback, let channel = manager.currentChannel {
                            manager.playDirectStreamWithAVKit(channel)
                        } else {
                            manager.playCurrentStreamWithVLC()
                        }
                    } label: {
                        Label(manager.useVLCPlayback ? "Use AVKit" : "Play with VLC", systemImage: "play.rectangle")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.rectangle")
                        Text("Player")
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.18))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .help("Choose the playback engine")
                #endif
                
                // Favorite Toggle
                Button {
                    manager.toggleFavorite(channel)
                } label: {
                    Image(systemName: manager.isFavorite(channel) ? "star.fill" : "star")
                        .foregroundColor(manager.isFavorite(channel) ? .yellow : .white)
                        .font(.title3)
                        .padding(8)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Bookmark Favorite")
                
                // Fullscreen Toggle
                Button {
                    manager.toggleFullscreen()
                } label: {
                    Image(systemName: manager.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .foregroundColor(.white)
                        .font(.title3)
                        .padding(8)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(manager.isFullscreen ? "Exit Full Screen (F / Esc)" : "Enter Full Screen (F)")
            }
        }
    }
    
    /// Center transport buttons (Previous, Skip -10s, Play/Pause, Skip +10s, Next).
    private var centerControls: some View {
        HStack(spacing: 24) {
            // Previous Channel / Item
            Button {
                manager.previousChannel()
                manager.scheduleControlsAutoHide()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            
            // Rewind 10s (VOD only)
            if manager.currentChannel?.isVOD == true {
                Button {
                    manager.seekBy(seconds: -10)
                    manager.scheduleControlsAutoHide()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            
            // Play / Pause Toggle
            Button {
                manager.togglePlayPause()
                manager.scheduleControlsAutoHide()
            } label: {
                Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .padding(20)
                    .background(Color.white.opacity(0.25))
                    .clipShape(Circle())
                    .shadow(radius: 8)
            }
            .buttonStyle(.plain)
            
            // Fast Forward 10s (VOD only)
            if manager.currentChannel?.isVOD == true {
                Button {
                    manager.seekBy(seconds: 10)
                    manager.scheduleControlsAutoHide()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            
            // Next Channel / Item
            Button {
                manager.nextChannel()
                manager.scheduleControlsAutoHide()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
    
    /// Bottom status bar showing stream format, timeline scrubber, and action buttons.
    var bottomBar: some View {
        VStack(spacing: 8) {
            // VOD Scrubber Timeline (for MP4 movies and TV series)
            if let channel = manager.currentChannel, channel.isVOD {
                HStack(spacing: 12) {
                    Text(manager.formattedCurrentTime)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 64, alignment: .trailing)
                    
                    Slider(
                        value: Binding(
                            get: { manager.currentTime },
                            set: { newVal in
                                manager.isSeeking = true
                                manager.currentTime = newVal
                            }
                        ),
                        in: 0...max(manager.duration, 1.0),
                        onEditingChanged: { editing in
                            if !editing {
                                manager.seek(to: manager.currentTime)
                                manager.isSeeking = false
                            }
                        }
                    )
                    .accentColor(.blue)
                    
                    Text(manager.duration > 0 ? manager.formattedDuration : "--:--")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 64, alignment: .leading)
                }
            }
            
            ViewThatFits(in: .horizontal) {
                bottomActions.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    streamStatus
                    HStack {
                        episodeAndSubtitleControls
                        aspectRatioControl
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 4) {
                        volumeControls
                        Spacer(minLength: 0)
                        playbackActions.labelStyle(.iconOnly)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var bottomActions: some View {
        HStack {
            streamStatus
            Spacer()
            episodeAndSubtitleControls
            aspectRatioControl
            volumeControls
            playbackActions
        }
    }

    @ViewBuilder
    private var streamStatus: some View {
        if let channel = manager.currentChannel {
            HStack(spacing: 8) {
                Image(systemName: channel.isVOD ? "film.fill" : "antenna.radiowaves.left.and.right")
                    .foregroundColor(channel.isVOD ? .purple : .green)
                Text(channel.isVOD ? "MP4 Video Stream" : (channel.isHLS ? "Apple HLS (m3u8)" : "Direct Stream"))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }

    @ViewBuilder
    private var episodeAndSubtitleControls: some View {
        // Series Episodes Selector Button (Only shown when active channel is a TV Series)
        if manager.currentChannel?.contentType == .series && !manager.seriesEpisodes.isEmpty {
            Button {
                manager.showingEpisodesDrawer.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.number")
                    Text("Episodes (\(manager.seriesEpisodes.count))")
                }
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.purple.opacity(0.85))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Browse & Play TV Series Episodes")
        }

        if manager.currentChannel?.isVOD == true {
            SubtitleControls(manager: manager, controller: manager.subtitles)
        }
    }

    private var aspectRatioControl: some View {
        Menu {
            Picker("Aspect ratio", selection: $manager.screenSize) {
                ForEach(VideoScreenSize.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.inline)
            Button("Reset to Auto") { manager.screenSize = .auto }
        } label: {
            Label(manager.screenSize.shortTitle, systemImage: "aspectratio")
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.2))
                .cornerRadius(6)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .accessibilityLabel("Aspect ratio: \(manager.screenSize.title)")
        .help("Change aspect ratio (\(manager.screenSize.title))")
    }

    private var volumeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: manager.playbackVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundColor(.white)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(manager.playbackVolume) },
                    set: { manager.playbackVolume = Float($0) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        manager.cancelControlsAutoHide()
                    } else {
                        manager.scheduleControlsAutoHide()
                    }
                }
            )
            .tint(.white)
            .frame(width: 100)
            .accessibilityLabel("Playback volume")
            Text("\(Int((manager.playbackVolume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
                .frame(minWidth: 36, alignment: .trailing)
                .help("Playback volume")
        }
        .help("Playback volume")
    }

    @ViewBuilder
    private var playbackActions: some View {
        // Full Screen Toggle Button
        Button {
            manager.toggleFullscreen()
        } label: {
            Label(
                manager.isFullscreen ? "Exit Full Screen" : "Full Screen",
                systemImage: manager.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            )
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.2))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(manager.isFullscreen ? "Exit Full Screen (F)" : "Make Full Screen (F)")

        // Stop button
        Button {
            manager.stop()
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.6))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help("Stop playback")
    }

    private var fallbackLogo: some View {
        Image(systemName: "tv")
            .foregroundColor(.white)
            .frame(width: 38, height: 38)
            .background(Color.white.opacity(0.1))
            .cornerRadius(6)
    }
    
    /// Buffering spinner overlay.
    private var bufferingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.4)
            Text("Buffering stream…")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(20)
        .background(Color.black.opacity(0.75))
        .cornerRadius(12)
    }
    
    /// Error overlay when a stream fails to load with instant format repair options.
    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundColor(.orange)
            
            Text("Stream Playback Notice")
                .font(.headline.bold())
                .foregroundColor(.white)
            
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: 340)

            #if os(macOS)
            Button {
                manager.playCurrentStreamWithVLC()
            } label: {
                Label("Try playback with VLC", systemImage: "play.rectangle.fill")
                    .font(.footnote.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.85))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            #endif
            
            if let channel = manager.currentChannel {
                Button {
                    manager.playDirectStreamWithAVKit(channel)
                } label: {
                    Label("Retry with AVKit", systemImage: "arrow.clockwise")
                        .font(.footnote.bold())
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(24)
        .background(Color.black.opacity(0.88))
        .cornerRadius(16)
        .padding()
    }
    
    /// TV Series Overview & Seasons / Episodes Grid Page (Matches Reference UI in Screenshot 3)
    private var seriesHeroView: some View {
        ScrollViewReader { gridProxy in
        ScrollView {
            ZStack(alignment: .top) {
                // Top warm ambient glow matching screenshot 3
                LinearGradient(
                    colors: [Color.orange.opacity(0.3), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 380)
                .ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 24) {
                    if let channel = manager.seriesDetailsItem {
                        if let backdrop = manager.seriesDetails?.backdrop {
                            AsyncImage(url: backdrop) { image in
                                image.resizable().scaledToFill()
                            } placeholder: { Color.primary.opacity(0.08) }
                            .frame(height: 180).clipped().cornerRadius(12)
                            .padding(.horizontal, 32)
                            .accessibilityHidden(true)
                        }
                        // Hero Top Banner with Poster & Metadata
                        HStack(alignment: .top, spacing: 28) {
                            HeroArtworkView(url: manager.seriesDetails?.poster ?? channel.logoURL, symbol: "play.tv.fill")
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text(manager.seriesDetails?.title ?? channel.name)
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                
                                MediaMetadataView(details: manager.seriesDetails)
                                MediaDescriptionView(details: manager.seriesDetails)
                                    .font(.subheadline)
                                if manager.isLoadingEpisodes {
                                    ProgressView("Loading series details…")
                                }
                                if manager.seriesDetailsFailed {
                                    Text("Series details couldn't be loaded.").font(.caption).foregroundStyle(.secondary)
                                    Button("Retry") { manager.fetchAndShowSeries(channel) }
                                }
                                
                                HStack(spacing: 12) {
                                    Button {
                                        if let episode = manager.continueWatchingEpisode {
                                            manager.continueWatching(episode)
                                        } else if let first = manager.seriesEpisodes.first {
                                            manager.playDirectStream(first)
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "play.fill")
                                                .font(.body)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(manager.continueWatchingEpisode == nil ? "Play first episode" : "Continue watching")
                                                    .font(.subheadline.bold())
                                                Text(manager.continueWatchingEpisode?.name ?? manager.seriesEpisodes.first?.name ?? (manager.isLoadingEpisodes ? "Loading episodes…" : "No episodes available"))
                                                    .font(.caption2)
                                                    .foregroundColor((palette.navy ? Color.black : .white).opacity(0.85))
                                                    .lineLimit(1)
                                            }
                                        }
                                        .foregroundColor(palette.navy ? .black : .white)
                                        .padding(.horizontal, 22)
                                        .padding(.vertical, 10)
                                        .background(Color.accentColor)
                                        .cornerRadius(10)
                                        .shadow(color: .blue.opacity(0.3), radius: 12, x: 0, y: 4)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(manager.seriesEpisodes.isEmpty)

                                    Button {
                                        manager.toggleFavorite(channel)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: manager.isFavorite(channel) ? "star.fill" : "plus")
                                                .foregroundColor(manager.isFavorite(channel) ? .yellow : .primary)
                                            Text(manager.isFavorite(channel) ? "Favorited" : "Add to favorites")
                                                .font(.subheadline.weight(.medium))
                                        }
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 12)
                                        .background(Color.primary.opacity(0.12))
                                        .cornerRadius(10)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.top, 6)
                            }
                            
                            Spacer()
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 32)
                        
                        // Keep navigation reachable as the grid scrolls.
                        LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                            Section {
                            
                            DownloadSeasonControl(manager: manager)
                                .buttonStyle(.bordered)
                                .padding(.horizontal, 32)

                            // Dynamic Interactive Season Selector Chips
                            seasonSelector
                            
                            if manager.seriesEpisodes.isEmpty && !manager.isLoadingEpisodes {
                                Text("No episode listings available for this title. Try again or select another show.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 32)
                            } else if manager.isSeriesGridView {
                                // Full Multi-Column Grid View (All episodes visible at once!)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)], spacing: 16) {
                                    ForEach(Array(manager.filteredEpisodesForSelectedSeason.enumerated()), id: \.offset) { index, ep in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Button {
                                                manager.playDirectStream(ep)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    ZStack(alignment: .bottomTrailing) {
                                                        EpisodeArtworkView(url: ep.logoURL ?? manager.seriesDetailsItem?.logoURL)

                                                        Text("\(index + 1)")
                                                            .font(.caption.bold())
                                                            .foregroundColor(.white)
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 3)
                                                            .background(Color.black.opacity(0.85))
                                                            .cornerRadius(4)
                                                            .padding(8)
                                                    }

                                                    Text(ep.name)
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundColor(.primary)
                                                        .lineLimit(1)

                                                    Text(ep.groupTitle)
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                    MediaProgressView(store: manager.progressStore, item: ep)
                                                }
                                                .padding(8)
                                                .background(Color.primary.opacity(0.05))
                                                .cornerRadius(10)
                                            }
                                            .buttonStyle(.plain)
                                            DownloadControl(item: ep, series: manager.downloadSeriesItem, details: manager.seriesMetadata, downloads: manager.downloads)
                                                .buttonStyle(.bordered)
                                        }
                                        .background(GeometryReader { geometry in
                                            Color.clear.preference(key: EpisodePositions.self, value: [index: geometry.frame(in: .named("seriesGridViewport")).minY])
                                        })
                                    }
                                }
                                .padding(.horizontal, 32)
                                .padding(.bottom, 20)
                            } else {
                                // Horizontal Episode Scroll Row with ScrollViewReader
                                ScrollViewReader { scrollProxy in
                                    ScrollView(.horizontal, showsIndicators: true) {
                                        LazyHStack(spacing: 16) {
                                            ForEach(Array(manager.filteredEpisodesForSelectedSeason.enumerated()), id: \.offset) { index, ep in
                                                VStack(alignment: .leading, spacing: 8) {
                                                    Button {
                                                        manager.playDirectStream(ep)
                                                    } label: {
                                                        VStack(alignment: .leading, spacing: 8) {
                                                            ZStack(alignment: .bottomTrailing) {
                                                                EpisodeArtworkView(url: ep.logoURL ?? manager.seriesDetailsItem?.logoURL)
                                                                    .frame(width: 220, height: 124)

                                                                Text("\(index + 1)")
                                                                    .font(.caption.bold())
                                                                    .foregroundColor(.white)
                                                                    .padding(.horizontal, 8)
                                                                    .padding(.vertical, 3)
                                                                    .background(Color.black.opacity(0.85))
                                                                    .cornerRadius(4)
                                                                    .padding(8)
                                                            }

                                                            Text(ep.name)
                                                                .font(.caption.weight(.semibold))
                                                                .foregroundColor(.primary)
                                                                .lineLimit(1)
                                                                .frame(width: 220, alignment: .leading)
                                                            
                                                            Text(ep.groupTitle)
                                                                .font(.caption2)
                                                                .foregroundColor(.secondary)
                                                            MediaProgressView(store: manager.progressStore, item: ep)
                                                                .frame(width: 220, alignment: .leading)
                                                        }
                                                    }
                                                    .buttonStyle(.plain)
                                                    DownloadControl(item: ep, series: manager.downloadSeriesItem, details: manager.seriesMetadata, downloads: manager.downloads)
                                                        .buttonStyle(.bordered)
                                                }
                                                .background(GeometryReader { geometry in
                                                    Color.clear.preference(key: EpisodePositions.self, value: [index: geometry.frame(in: .named("seriesCarouselViewport")).minX])
                                                })
                                            }
                                        }
                                        .padding(.horizontal, 32)
                                        .padding(.bottom, 20)
                                    }
                                    .coordinateSpace(name: "seriesCarouselViewport")
                                    .onChange(of: manager.episodeScrollRequest) { _, _ in
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            scrollProxy.scrollTo(manager.episodeScrollIndex, anchor: .leading)
                                        }
                                    }
                                }
                            }
                            } header: {
                                episodeNavigationBar
                                    .padding(.vertical, 8)
                                    .background(palette.background)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .foregroundStyle(.primary)
        .background(palette.background)
        .coordinateSpace(name: "seriesGridViewport")
        .onPreferenceChange(EpisodePositions.self) { positions in
            manager.visibleEpisodeIndex = positions.min {
                abs($0.value) == abs($1.value) ? $0.key < $1.key : abs($0.value) < abs($1.value)
            }?.key ?? 0
        }
        .onChange(of: manager.episodeScrollRequest) { _, _ in
            guard manager.isSeriesGridView else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                gridProxy.scrollTo(manager.episodeScrollIndex, anchor: .top)
            }
        }
        }
    }
    
    private var episodeNavigationBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Seasons and Episodes")
                .font(.title2.bold())
                .foregroundColor(.primary)

            Spacer()

            // View Mode Toggle (Horizontal Row vs Multi-Column Grid)
            Button {
                manager.isSeriesGridView.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: manager.isSeriesGridView ? "rectangle.grid.1x2.fill" : "square.grid.2x2.fill")
                    Text(manager.isSeriesGridView ? "Carousel View" : "Grid View")
                }
                .font(.caption.bold())
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.15))
                .cornerRadius(20)
            }
            .buttonStyle(.plain)
            .help("Switch between horizontal carousel and full grid view")

            if manager.filteredEpisodesForSelectedSeason.count > 1 {
                HStack(spacing: 6) {
                    Button {
                        manager.scrollEpisodesPrev(from: manager.visibleEpisodeIndex)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.visibleEpisodeIndex == 0)
                    .accessibilityLabel("Previous episodes")
                    .help("Previous episodes")

                    Button {
                        manager.scrollEpisodesNext(from: manager.visibleEpisodeIndex)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.visibleEpisodeIndex >= manager.filteredEpisodesForSelectedSeason.count - 1)
                    .accessibilityLabel("Next episodes")
                    .help("Next episodes")
                }
            }
        }
        .padding(.horizontal, 32)
    }

    var seasonSelector: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(manager.availableSeasons, id: \.self) { season in
                let activeSeason = manager.selectedSeason.isEmpty ? (manager.availableSeasons.first ?? "Season 1") : manager.selectedSeason
                let isSelected = activeSeason == season
                let epCount = manager.seriesEpisodes.filter { $0.groupTitle == season }.count

                Button {
                    manager.selectSeason(season)
                } label: {
                    HStack(spacing: 6) {
                        Text(season)
                            .font(.subheadline.weight(isSelected ? .bold : .medium))
                        if epCount > 0 {
                            Text("(\(epCount))")
                                .font(.caption2)
                                .opacity(0.85)
                        }
                    }
                    .foregroundColor(isSelected ? (palette.navy ? .black : .white) : .primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(isSelected ? Color.accentColor : Color.primary.opacity(0.12))
                    .cornerRadius(20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 32)
    }

    /// Placeholder state when no channel is selected.
    private var emptyPlaceholderView: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.12, blue: 0.19), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 24) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 28))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                VStack(spacing: 10) {
                    Text("Make time for a good watch.")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Browse live TV, discover a movie, or settle into a series. Choose something from your library to begin.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(maxWidth: 360)
                }
                Button { manager.showingPlaylistSheet = true } label: {
                    Label("Add Source", systemImage: "plus.circle")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if let error = manager.errorMessage {
                    Text(error).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Open Downloads") { manager.showingDownloads = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    /// Slide-in drawer for TV Series episodes browsing and selection.
    private var episodesDrawerOverlay: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Series Episodes")
                            .font(.headline.bold())
                            .foregroundColor(.white)
                        Text("\(manager.seriesEpisodes.count) episode\(manager.seriesEpisodes.count == 1 ? "" : "s") available")
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }
                    Spacer()
                    Button {
                        manager.showingEpisodesDrawer = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding([.top, .horizontal])
                
                Button {
                    manager.returnToSeries()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(manager.seriesEpisodes) { ep in
                            Button {
                                manager.playDirectStream(ep)
                                manager.showingEpisodesDrawer = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: manager.currentChannel?.streamURL == ep.streamURL ? "speaker.wave.2.fill" : "play.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(manager.currentChannel?.streamURL == ep.streamURL ? .blue : .white)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ep.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(ep.groupTitle)
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.6))
                                        MediaProgressView(store: manager.progressStore, item: ep)
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(manager.currentChannel?.streamURL == ep.streamURL ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .frame(width: 320)
            .background(Color.black.opacity(0.92))
            .cornerRadius(12)
            .padding()
            .shadow(radius: 20)
        }
    }
}

struct MediaProgressView: View {
    @ObservedObject var store: PlaybackProgressStore
    let item: M3UItem

    var body: some View {
        if let progress = store.progress(for: item) {
            if progress.completed {
                Label("Watched", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundColor(.gray)
            } else if let position = progress.resumePosition {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Continue from \(PlaybackProgress.timestamp(position))", systemImage: "play.circle")
                        .font(.caption2).foregroundColor(.blue)
                    if progress.duration > 0 {
                        ProgressView(value: progress.fraction).tint(.blue)
                            .accessibilityLabel("Playback progress")
                            .accessibilityValue("\(Int(progress.fraction * 100)) percent")
                    }
                }
            }
        }
    }
}

private struct EpisodeArtworkView: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.08)

            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }

            Image(systemName: "play.circle.fill")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.5), radius: 5)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.title2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.08))
    }
}

// MARK: - Native Live TV Electronic Program Guide (EPG) Sheet
public struct NativeEPGSheetView: View {
    @Environment(\.appPalette) private var palette
    let channel: M3UItem
    @ObservedObject var manager: IPTVPlayerManager
    
    @Environment(\.dismiss) private var dismiss
    
    public init(channel: M3UItem, manager: IPTVPlayerManager) {
        self.channel = channel
        self.manager = manager
        _seenGuideRevision = State(initialValue: manager.guideRevision)
    }
    
    @State private var programs: [GuideProgram] = []
    @State private var isLoading = true
    @State private var guideError: String?
    @State private var now = Date()
    @State private var reload = 0
    @State private var forceGuideRefresh = false
    @State private var guideUpdatedAt: Date?
    @State private var nextGuideRefresh = Date.distantPast
    @State private var guideStatus: String?
    @State private var seenGuideRevision: UUID
    @State private var guideRefreshID = UUID()
    @State private var loadedGuideChannel: String?
    private let guide = TVGuide()
    private var remainingPrograms: [GuideProgram] { TVGuide.remainingToday(programs, now: now) }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Channel Header
                        HStack(spacing: 12) {
                            if let logo = channel.logoURL {
                                AsyncImage(url: logo) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable()
                                            .scaledToFit()
                                            .frame(width: 44, height: 44)
                                            .cornerRadius(8)
                                    default:
                                        epgLogoFallback
                                    }
                                }
                            } else {
                                epgLogoFallback
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(channel.name)
                                        .font(.headline.bold())
                                        .foregroundColor(.primary)
                                    
                                    Text("LIVE EPG")
                                        .font(.caption2.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red)
                                        .cornerRadius(4)
                                }
                                Text(channel.displayGroup)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        
                        Divider()
                            .padding(.horizontal, 20)

                        if let guideUpdatedAt {
                            Text("\(isLoading ? "Previous download" : "Last downloaded") \(guideUpdatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                        }
                        if let guideStatus, !isLoading {
                            Text(guideStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                        }
                        
                        // ON AIR NOW FEATURE CARD
                        if isLoading {
                            ProgressView("Loading TV guide…").padding(20)
                        } else if let guideError {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(guideError)
                                Button("Retry") { forceGuideRefresh = true; reload += 1 }
                            }
                            .padding(20)
                        } else if remainingPrograms.isEmpty {
                            Text("No TV guide available for the rest of today on this channel.")
                                .foregroundStyle(.secondary)
                                .padding(20)
                        }
                        if let current = remainingPrograms.first(where: { $0.isCurrent(at: now) }) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("ON AIR NOW")
                                        .font(.caption2.bold())
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.18))
                                        .cornerRadius(4)
                                    
                                    Spacer()
                                    
                                    Text(current.timeRange)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.primary)
                                }
                                
                                Text(current.title)
                                    .font(.title3.bold())
                                    .foregroundColor(.primary)
                                
                                Text(current.description)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                // Progress bar
                                VStack(spacing: 4) {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color.primary.opacity(0.15))
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color.accentColor)
                                                .frame(width: geo.size.width * CGFloat(current.progress(at: now)))
                                        }
                                    }
                                    .frame(height: 6)
                                    
                                    HStack {
                                        Text("\(Int(current.progress(at: now) * 100))% elapsed")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                        Spacer()
                                        Text("\(current.durationMin) min total")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .padding(16)
                            .background(Color.primary.opacity(0.06))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                            )
                            .padding(.horizontal, 20)
                        }
                        
                        // TODAY'S SCHEDULE
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Rest of today's schedule")
                                .font(.headline.bold())
                                .foregroundColor(.primary)
                                .padding(.horizontal, 20)
                            
                            VStack(spacing: 8) {
                                ForEach(remainingPrograms) { item in
                                    HStack(alignment: .top, spacing: 14) {
                                        Text(item.start.formatted(date: .omitted, time: .shortened))
                                            .font(.caption.bold().monospacedDigit())
                                            .foregroundColor(.primary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.primary.opacity(0.12))
                                            .cornerRadius(6)
                                            .frame(width: 60)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(item.title)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundColor(.primary)
                                                if item.isCurrent(at: now) {
                                                    Text("NOW")
                                                        .font(.system(size: 9, weight: .bold))
                                                        .foregroundColor(.white)
                                                        .padding(.horizontal, 4)
                                                        .padding(.vertical, 1)
                                                        .background(Color.red)
                                                        .cornerRadius(3)
                                                }
                                                Spacer()
                                                Text("\(item.durationMin)m")
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            Text(item.description)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                            Text(item.timeRange).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(12)
                                    .background(Color.primary.opacity(item.isCurrent(at: now) ? 0.08 : 0.03))
                                    .cornerRadius(8)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
            .background(palette.background)
            .navigationTitle("Program Guide")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        forceGuideRefresh = true
                        reload += 1
                    } label: {
                        Label("Refresh guides", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .help("Download fresh guide listings for the current library")
                }
            }
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        manager.showingEPGSheet = false
                    }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        manager.showingEPGSheet = false
                    }
                }
            }
            #endif
        }
        .frame(minWidth: 500, minHeight: 450)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) {
            now = $0
            if !isLoading, now >= nextGuideRefresh { reload += 1 }
        }
        .onReceive(manager.$guideRevision) { revision in
            if revision != seenGuideRevision {
                seenGuideRevision = revision
                reload += 1
            }
        }
        .task(id: "\(channel.subtitleCacheKey)|\(reload)|\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)") {
            if loadedGuideChannel != channel.subtitleCacheKey {
                programs = []
                guideUpdatedAt = nil
                guideStatus = nil
                loadedGuideChannel = channel.subtitleCacheKey
            }
            let force = forceGuideRefresh
            forceGuideRefresh = false
            isLoading = true
            guideError = nil
            do {
                let result = try await guide.load(for: channel, index: manager.guideIndex, channels: manager.channels, force: force)
                try Task.checkCancellation()
                programs = result.programs
                guideUpdatedAt = result.updatedAt
                nextGuideRefresh = result.nextRefresh
                guideStatus = result.message ?? (force ? "Guide refreshed." : "Guide listings loaded.")
            } catch {
                guard !Task.isCancelled else { return }
                guideError = error.localizedDescription
                guideStatus = remainingPrograms.isEmpty ? nil : "Refresh failed. Showing previously loaded listings."
                nextGuideRefresh = Date().addingTimeInterval(60)
            }
            isLoading = false
            if force {
                seenGuideRevision = guideRefreshID
                manager.guideRevision = guideRefreshID
            }
        }
    }
    
    private var epgLogoFallback: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.2))
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "tv.fill")
                    .foregroundColor(.blue)
            )
    }
}

#if os(macOS)
import AppKit

/// High-performance AppKit NSView wrapping AVPlayerLayer directly.
/// Eliminates SwiftUI's internal _AVKit_SwiftUI dynamic metadata resolution crash on macOS
/// and provides 60fps hardware-accelerated video presentation via Metal / CoreAnimation.
public final class AVPlayerLayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var screenSize: VideoScreenSize = .auto
    
    public init(player: AVPlayer?, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        
        playerLayer.player = player
        playerLayer.videoGravity = videoGravity
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.masksToBounds = true
        self.layer?.addSublayer(playerLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = screenSize.videoRect(in: bounds)
        CATransaction.commit()
    }
    
    public func update(player: AVPlayer?, videoGravity: AVLayerVideoGravity, screenSize: VideoScreenSize = .auto) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        let gravity = screenSize == .auto ? videoGravity : screenSize.gravity
        if playerLayer.videoGravity != gravity {
            playerLayer.videoGravity = gravity
        }
        if self.screenSize != screenSize {
            self.screenSize = screenSize
            needsLayout = true
        }
    }
}

public struct AVPlayerLayerRepresentable: NSViewRepresentable {
    public let player: AVPlayer
    public var videoGravity: AVLayerVideoGravity
    public var screenSize: VideoScreenSize
    
    public init(player: AVPlayer, videoGravity: AVLayerVideoGravity = .resizeAspect, screenSize: VideoScreenSize = .auto) {
        self.player = player
        self.videoGravity = videoGravity
        self.screenSize = screenSize
    }
    
    public func makeNSView(context: Context) -> AVPlayerLayerNSView {
        let view = AVPlayerLayerNSView(player: player, videoGravity: videoGravity)
        view.update(player: player, videoGravity: videoGravity, screenSize: screenSize)
        return view
    }
    
    public func updateNSView(_ nsView: AVPlayerLayerNSView, context: Context) {
        nsView.update(player: player, videoGravity: videoGravity, screenSize: screenSize)
    }
}

/// AppKit surface that attaches a VLCMediaPlayer to a native view.
struct PlaybackDiagnosticsView: View {
    @ObservedObject var manager: IPTVPlayerManager
    @State private var report = "Reading playback statistics…"

    static func rate(current: Int, previous: Int?, elapsed: Double) -> Double? {
        guard let previous, current >= previous, elapsed > 0 else { return nil }
        return Double(current - previous) / elapsed
    }

    private var playerIdentity: ObjectIdentifier {
        if let player = manager.vlcPlayer { return ObjectIdentifier(player) }
        if let player = manager.player { return ObjectIdentifier(player) }
        return ObjectIdentifier(manager)
    }

    var body: some View {
        Text(report).font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white).padding(10).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .task(id: playerIdentity) {
                var frames: Int?, bytes: Int?
                var sampledAt = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    let now = ProcessInfo.processInfo.systemUptime
                    let elapsed = now - sampledAt
                    if manager.useVLCPlayback, let player = manager.vlcPlayer, let media = player.media {
                        let stats = media.statistics
                        let size = player.videoSize
                        let fps = Self.rate(current: Int(stats.displayedPictures), previous: frames, elapsed: elapsed)
                        let throughput = Self.rate(current: Int(stats.readBytes), previous: bytes, elapsed: elapsed).map { $0 * 8 / 1_000_000 }
                        report = "VLC · \(Int(size.width))×\(Int(size.height))\nDisplayed FPS: \(fps.map { String(format: "%.1f", $0) } ?? "—") · Lost frames: \(stats.lostPictures)\nInput: \(throughput.map { String(format: "%.2f Mbps", $0) } ?? "—")\nBuffer: \(manager.isBuffering ? "buffering" : "not buffering") (seconds unavailable)"
                        frames = Int(stats.displayedPictures); bytes = Int(stats.readBytes)
                    } else if let item = manager.player?.currentItem {
                        let size = item.presentationSize
                        let event = item.accessLog()?.events.last
                        let clock = item.currentTime().seconds
                        let buffer = item.loadedTimeRanges.map(\.timeRangeValue).first {
                            $0.start.seconds <= clock && CMTimeRangeGetEnd($0).seconds >= clock
                        }.map { CMTimeRangeGetEnd($0).seconds - clock } ?? 0
                        report = "AVKit · \(Int(size.width))×\(Int(size.height))\nDropped frames: \(event.map { String($0.numberOfDroppedVideoFrames) } ?? "—")\nObserved bitrate: \(event.map { String(format: "%.2f Mbps", $0.observedBitrate / 1_000_000) } ?? "—")\nBuffer: \(String(format: "%.1f s", buffer)) · \(manager.isBuffering ? "buffering" : "not buffering")"
                    } else { report = "No active playback" }
                    sampledAt = now
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
    }
}

final class VLCVideoSurfaceNSView: NSView {
    private weak var player: VLCMediaPlayer?
    private var screenSize: VideoScreenSize = .auto
    private var appliedAspect: String?
    private var appliedCrop: String?
    private var hasAppliedSettings = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(player: VLCMediaPlayer, shouldPlay: Bool, screenSize: VideoScreenSize) {
        let attaching = (player.drawable as? NSView) !== self
        if self.player !== player { hasAppliedSettings = false }
        self.player = player
        self.screenSize = screenSize
        if attaching { player.drawable = self }
        applyScreenSize()
        if attaching && shouldPlay && !player.isPlaying && !player.willPlay { player.play() }
    }

    override func layout() {
        super.layout()
        applyScreenSize()
    }

    private func applyScreenSize() {
        guard let player, bounds.width > 0, bounds.height > 0 else { return }
        let areaRatio = "\(max(1, Int(bounds.width.rounded()))):\(max(1, Int(bounds.height.rounded())))"
        let aspect = screenSize.ratio != nil ? screenSize.title : screenSize == .stretch ? areaRatio : nil
        let crop = screenSize == .zoom ? areaRatio : nil
        if !hasAppliedSettings || aspect != appliedAspect {
            if let aspect {
                var bytes = Array(aspect.utf8CString)
                bytes.withUnsafeMutableBufferPointer { player.videoAspectRatio = $0.baseAddress }
            } else { player.videoAspectRatio = nil }
            appliedAspect = aspect
        }
        if !hasAppliedSettings || crop != appliedCrop {
            if let crop {
                var bytes = Array(crop.utf8CString)
                bytes.withUnsafeMutableBufferPointer { player.videoCropGeometry = $0.baseAddress }
            } else { player.videoCropGeometry = nil }
            appliedCrop = crop
        }
        hasAppliedSettings = true
    }
}

private struct VLCVideoSurface: NSViewRepresentable {
    let player: VLCMediaPlayer
    let shouldPlay: Bool
    let screenSize: VideoScreenSize

    func makeNSView(context: Context) -> VLCVideoSurfaceNSView {
        let view = VLCVideoSurfaceNSView()
        view.update(player: player, shouldPlay: shouldPlay, screenSize: screenSize)
        return view
    }

    func updateNSView(_ nsView: VLCVideoSurfaceNSView, context: Context) {
        nsView.update(player: player, shouldPlay: shouldPlay, screenSize: screenSize)
    }

    static func dismantleNSView(_ nsView: VLCVideoSurfaceNSView, coordinator: ()) {
        // The manager owns and stops the VLC player when changing playback engines.
    }
}
#elseif os(iOS)
import UIKit

/// High-performance UIKit UIView wrapping AVPlayerLayer.
public final class AVPlayerLayerUIView: UIView {
    public let playerLayer = AVPlayerLayer()
    private var screenSize: VideoScreenSize = .auto
    
    public init(player: AVPlayer?, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(playerLayer)
        playerLayer.player = player
        playerLayer.videoGravity = videoGravity
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.masksToBounds = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = screenSize.videoRect(in: bounds)
        CATransaction.commit()
    }

    public func update(player: AVPlayer?, videoGravity: AVLayerVideoGravity, screenSize: VideoScreenSize = .auto) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        let gravity = screenSize == .auto ? videoGravity : screenSize.gravity
        if playerLayer.videoGravity != gravity {
            playerLayer.videoGravity = gravity
        }
        if self.screenSize != screenSize {
            self.screenSize = screenSize
            setNeedsLayout()
        }
    }
}

public struct AVPlayerLayerRepresentable: UIViewRepresentable {
    public let player: AVPlayer
    public var videoGravity: AVLayerVideoGravity
    public var screenSize: VideoScreenSize
    
    public init(player: AVPlayer, videoGravity: AVLayerVideoGravity = .resizeAspect, screenSize: VideoScreenSize = .auto) {
        self.player = player
        self.videoGravity = videoGravity
        self.screenSize = screenSize
    }
    
    public func makeUIView(context: Context) -> AVPlayerLayerUIView {
        let view = AVPlayerLayerUIView(player: player, videoGravity: videoGravity)
        view.update(player: player, videoGravity: videoGravity, screenSize: screenSize)
        return view
    }
    
    public func updateUIView(_ uiView: AVPlayerLayerUIView, context: Context) {
        uiView.update(player: player, videoGravity: videoGravity, screenSize: screenSize)
    }
}
#endif
