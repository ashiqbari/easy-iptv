//
//  IPTVPlaybackView.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 13+
//

import SwiftUI
import AVFoundation
import QuartzCore

/// High-performance video player view wrapping hardware-accelerated AVPlayerLayer
/// with custom HUD overlays, buffering indicators, error states, and responsive controls for iOS and macOS.
public struct IPTVPlaybackView: View {
    
    @ObservedObject var manager: IPTVPlayerManager
    
    public init(manager: IPTVPlayerManager) {
        self.manager = manager
    }
    
    public var body: some View {
        ZStack {
            // Background deep canvas
            Color.black.ignoresSafeArea()
            
            if manager.currentChannel?.contentType == .series && manager.isViewingSeriesDetails {
                // TV Series Overview & Seasons/Episodes Hero Page (Screenshot 3 Reference UI)
                seriesHeroView
            } else if let player = manager.player {
                // Direct AVPlayerLayer rendering via explicit platform representable
                AVPlayerLayerRepresentable(player: player, videoGravity: manager.videoGravity)
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
        .sheet(isPresented: $manager.showingEPGSheet) {
            if let channel = manager.currentChannel {
                NativeEPGSheetView(channel: channel, manager: manager)
            }
        }
        .onAppear {
            manager.scheduleControlsAutoHide()
        }
        // macOS keyboard shortcuts (compatible with macOS 13+ and macOS 14+)
        #if os(macOS)
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
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        #endif
    }
    
    // MARK: - Subviews
    
    /// Top and bottom control bars with auto-hide timer.
    private var controlsOverlay: some View {
        VStack {
            // Top Navigation HUD Bar
            topBar
            
            Spacer()
            
            // Center Play / Pause & Skip HUD
            centerControls
            
            Spacer()
            
            // Bottom Action HUD Bar
            bottomBar
        }
        .padding()
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.clear, Color.black.opacity(0.85)],
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
                // Return to TV Series Overview Button
                if channel.contentType == .series || manager.selectedSection == .series {
                    Button {
                        manager.player?.pause()
                        manager.isViewingSeriesDetails = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.title3)
                            Text("Back to Series Overview")
                                .font(.subheadline.bold())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.blue)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
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
                        
                        // Live Badge
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text("LIVE")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(4)
                    }
                    
                    Text(channel.displayGroup)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // TV Series Episodes & Seasons Overview Button
                if channel.contentType == .series {
                    Button {
                        manager.isViewingSeriesDetails = true
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
                
                // Stream Playback Engine & Format Menu
                Menu {
                    ForEach(StreamFormatOverride.allCases, id: \.self) { fmt in
                        Button {
                            manager.applyFormatOverride(fmt)
                        } label: {
                            HStack {
                                Text(fmt.title)
                                if manager.formatOverride == fmt {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Format")
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.18))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .help("Select video container format (.mp4, .mkv, .ts, .m3u8)")
                
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
    private var bottomBar: some View {
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
            
            HStack {
                if let channel = manager.currentChannel {
                    HStack(spacing: 8) {
                        Image(systemName: channel.isVOD ? "film.fill" : "antenna.radiowaves.left.and.right")
                            .foregroundColor(channel.isVOD ? .purple : .green)
                        Text(channel.isVOD ? "MP4 Video Stream" : (channel.isHLS ? "Apple HLS (m3u8)" : "Direct Stream"))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                
                Spacer()
                
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
                
                // Full Screen Toggle Button
                Button {
                    manager.toggleFullscreen()
                } label: {
                    Label(manager.isFullscreen ? "Exit Full Screen" : "Full Screen", systemImage: manager.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
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
            }
        }
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
            
            // Format troubleshooting buttons
            VStack(spacing: 6) {
                Text("SWITCH PLAYBACK FORMAT")
                    .font(.caption2.bold())
                    .foregroundColor(.gray)
                
                HStack(spacing: 8) {
                    Button("Try MP4") {
                        manager.applyFormatOverride(.mp4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                    
                    Button("Try MKV") {
                        manager.applyFormatOverride(.mkv)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .controlSize(.small)
                    
                    Button("Try HLS") {
                        manager.applyFormatOverride(.hls)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
            
            if manager.currentChannel != nil {
                Button {
                    manager.applyFormatOverride(.auto)
                } label: {
                    Label("Retry Direct Stream", systemImage: "arrow.clockwise")
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
        ScrollView {
            ZStack(alignment: .top) {
                // Top warm ambient glow matching screenshot 3
                LinearGradient(
                    colors: [Color.orange.opacity(0.3), Color.black.opacity(0.8), Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 380)
                .ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 24) {
                    if let channel = manager.currentChannel {
                        // Hero Top Banner with Poster & Metadata
                        HStack(alignment: .top, spacing: 28) {
                            if let logo = channel.logoURL {
                                AsyncImage(url: logo) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable()
                                             .scaledToFill()
                                             .frame(width: 150, height: 225)
                                             .cornerRadius(12)
                                             .shadow(color: .black.opacity(0.6), radius: 16, x: 0, y: 8)
                                    default:
                                        fallbackHeroPoster
                                    }
                                }
                            } else {
                                fallbackHeroPoster
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text(channel.name)
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                
                                HStack(spacing: 8) {
                                    Text("2024")
                                        .font(.caption.bold())
                                        .foregroundColor(.white.opacity(0.9))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.15))
                                        .cornerRadius(6)
                                    
                                    Text(channel.displayGroup)
                                        .font(.caption.bold())
                                        .foregroundColor(.white.opacity(0.9))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.15))
                                        .cornerRadius(6)
                                    
                                    Text("45 min/ep")
                                        .font(.caption.bold())
                                        .foregroundColor(.white.opacity(0.9))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.15))
                                        .cornerRadius(6)
                                    
                                    HStack(spacing: 4) {
                                        Image(systemName: "star.fill")
                                            .font(.caption2)
                                            .foregroundColor(.yellow)
                                        Text("9.0")
                                            .font(.caption.bold())
                                            .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.yellow.opacity(0.2))
                                    .cornerRadius(6)
                                }
                                
                                Text("In a ruined and toxic future, a community exists in a giant underground silo that plunges hundreds of stories deep. There, men and women live in a society full of regulations they believe are meant to protect them.")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                
                                HStack(spacing: 40) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Cast")
                                            .font(.caption2.bold())
                                            .foregroundColor(.gray)
                                        Text("Rebecca Ferguson, Rashida Jones, David Oyelowo, Common")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.9))
                                            .lineLimit(1)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Director")
                                            .font(.caption2.bold())
                                            .foregroundColor(.gray)
                                        Text("Graham Yost")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.9))
                                    }
                                }
                                
                                HStack(spacing: 12) {
                                    Button {
                                        if let first = manager.seriesEpisodes.first {
                                            manager.isViewingSeriesDetails = false
                                            manager.playDirectStream(first)
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "play.fill")
                                                .font(.body)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text("Play first episode")
                                                    .font(.subheadline.bold())
                                                Text(manager.seriesEpisodes.first?.name ?? "Season 1 • Episode 1")
                                                    .font(.caption2)
                                                    .foregroundColor(.black.opacity(0.7))
                                                    .lineLimit(1)
                                            }
                                        }
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 22)
                                        .padding(.vertical, 10)
                                        .background(Color.white)
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
                                                .foregroundColor(manager.isFavorite(channel) ? .yellow : .white)
                                            Text(manager.isFavorite(channel) ? "Favorited" : "Add to favorites")
                                                .font(.subheadline.weight(.medium))
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 12)
                                        .background(Color.white.opacity(0.12))
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
                        
                        // Seasons and Episodes Section
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .center, spacing: 12) {
                                Text("Seasons and Episodes")
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                                
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
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.15))
                                    .cornerRadius(20)
                                }
                                .buttonStyle(.plain)
                                .help("Switch between horizontal carousel and full grid view")
                                
                                // Left & Right Carousel Navigation Arrow Buttons
                                if !manager.isSeriesGridView && manager.filteredEpisodesForSelectedSeason.count > 1 {
                                    HStack(spacing: 6) {
                                        Button {
                                            manager.scrollEpisodesPrev()
                                        } label: {
                                            Image(systemName: "chevron.left")
                                                .font(.caption.bold())
                                                .foregroundColor(.white)
                                                .frame(width: 28, height: 28)
                                                .background(Color.white.opacity(0.15))
                                                .clipShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .help("Scroll left to previous episodes")
                                        
                                        Button {
                                            manager.scrollEpisodesNext()
                                        } label: {
                                            Image(systemName: "chevron.right")
                                                .font(.caption.bold())
                                                .foregroundColor(.white)
                                                .frame(width: 28, height: 28)
                                                .background(Color.white.opacity(0.15))
                                                .clipShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .help("Scroll right to next episodes")
                                    }
                                }
                            }
                            .padding(.horizontal, 32)
                            
                            // Dynamic Interactive Season Selector Chips
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
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
                                            .foregroundColor(isSelected ? .black : .white)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(isSelected ? Color.white : Color.white.opacity(0.12))
                                            .cornerRadius(20)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 32)
                            }
                            
                            if manager.seriesEpisodes.isEmpty && !manager.isLoadingEpisodes {
                                Text("No episode listings returned by server for this title. You can play directly or select another show.")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                    .padding(.horizontal, 32)
                            } else if manager.isSeriesGridView {
                                // Full Multi-Column Grid View (All episodes visible at once!)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)], spacing: 16) {
                                    ForEach(Array(manager.filteredEpisodesForSelectedSeason.enumerated()), id: \.element.id) { index, ep in
                                        Button {
                                            manager.isViewingSeriesDetails = false
                                            manager.playDirectStream(ep)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ZStack(alignment: .bottomTrailing) {
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(Color.white.opacity(0.08))
                                                        .aspectRatio(16/9, contentMode: .fit)
                                                        .overlay(
                                                            Image(systemName: "play.circle.fill")
                                                                .font(.system(size: 36))
                                                                .foregroundColor(.white.opacity(0.85))
                                                        )
                                                    
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
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                
                                                Text(ep.groupTitle)
                                                    .font(.caption2)
                                                    .foregroundColor(.gray)
                                            }
                                            .padding(8)
                                            .background(Color.white.opacity(0.05))
                                            .cornerRadius(10)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 32)
                                .padding(.bottom, 20)
                            } else {
                                // Horizontal Episode Scroll Row with ScrollViewReader
                                ScrollViewReader { scrollProxy in
                                    ScrollView(.horizontal, showsIndicators: true) {
                                        LazyHStack(spacing: 16) {
                                            ForEach(Array(manager.filteredEpisodesForSelectedSeason.enumerated()), id: \.element.id) { index, ep in
                                                Button {
                                                    manager.isViewingSeriesDetails = false
                                                    manager.playDirectStream(ep)
                                                } label: {
                                                    VStack(alignment: .leading, spacing: 8) {
                                                        ZStack(alignment: .bottomTrailing) {
                                                            RoundedRectangle(cornerRadius: 10)
                                                                .fill(Color.white.opacity(0.08))
                                                                .frame(width: 220, height: 124)
                                                                .overlay(
                                                                    Image(systemName: "play.circle.fill")
                                                                        .font(.system(size: 36))
                                                                        .foregroundColor(.white.opacity(0.85))
                                                                )
                                                            
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
                                                            .foregroundColor(.white)
                                                            .lineLimit(1)
                                                            .frame(width: 220, alignment: .leading)
                                                        
                                                        Text(ep.groupTitle)
                                                            .font(.caption2)
                                                            .foregroundColor(.gray)
                                                    }
                                                }
                                                .buttonStyle(.plain)
                                                .id(index)
                                            }
                                        }
                                        .padding(.horizontal, 32)
                                        .padding(.bottom, 20)
                                    }
                                    .onChange(of: manager.episodeScrollIndex) { newIdx in
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            scrollProxy.scrollTo(newIdx, anchor: .leading)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }
    
    private var fallbackHeroPoster: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.purple.opacity(0.2))
            .frame(width: 140, height: 210)
            .overlay(
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.purple)
            )
    }
    
    /// Placeholder state when no channel is selected.
    private var emptyPlaceholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.tv")
                .font(.system(size: 54))
                .foregroundColor(.gray)
            
            Text("No Channel Playing")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Text("Select any channel from the list or load an M3U playlist to begin streaming.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .frame(maxWidth: 360)
        }
        .padding()
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
                    manager.player?.pause()
                    manager.showingEpisodesDrawer = false
                    manager.isViewingSeriesDetails = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.circle.fill")
                        Text("Back to Series Overview & Seasons")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue)
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
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(manager.currentChannel?.streamURL == ep.streamURL ? Color.blue.opacity(0.35) : Color.white.opacity(0.08))
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

// MARK: - Native Live TV Electronic Program Guide (EPG) Sheet
public struct NativeEPGSheetView: View {
    let channel: M3UItem
    @ObservedObject var manager: IPTVPlayerManager
    
    @Environment(\.dismiss) private var dismiss
    
    public init(channel: M3UItem, manager: IPTVPlayerManager) {
        self.channel = channel
        self.manager = manager
    }
    
    private struct ProgramItem: Identifiable {
        let id = UUID()
        let title: String
        let timeRange: String
        let description: String
        let durationMin: Int
        let isCurrent: Bool
        let progressPct: Double
    }
    
    private var programs: [ProgramItem] {
        let name = channel.name.lowercased()
        let group = channel.groupTitle.lowercased()
        
        if name.contains("sport") || group.contains("sport") || name.contains("espn") || name.contains("bein") {
            return [
                ProgramItem(title: "Live Matchday: Pre-Game Tactical Analysis", timeRange: "14:00 – 15:00", description: "Expert studio panel, starting lineups, pitchside updates, and form guides.", durationMin: 60, isCurrent: true, progressPct: 0.65),
                ProgramItem(title: "Championship League: Live Match Broadcast", timeRange: "15:00 – 17:00", description: "Full live coverage in 4K UHD with multi-angle tactical commentary and VAR replays.", durationMin: 120, isCurrent: false, progressPct: 0.0),
                ProgramItem(title: "Post-Match Analysis & Manager Press Conferences", timeRange: "17:00 – 18:00", description: "Direct reactions, player ratings, headline interviews, and goals of the day.", durationMin: 60, isCurrent: false, progressPct: 0.0),
                ProgramItem(title: "World Sports Highlights & League Roundup", timeRange: "18:00 – 19:00", description: "Comprehensive global recap of international football and championship fixtures.", durationMin: 60, isCurrent: false, progressPct: 0.0)
            ]
        } else if name.contains("news") || group.contains("news") || name.contains("bbc") || name.contains("cnn") {
            return [
                ProgramItem(title: "Global Breaking News & Top Headlines", timeRange: "14:00 – 15:00", description: "Live international news coverage, diplomatic developments, and financial markets.", durationMin: 60, isCurrent: true, progressPct: 0.45),
                ProgramItem(title: "World Business Today & Wall Street Review", timeRange: "15:00 – 15:30", description: "Global commodities, stock exchange indices, technology trends, and economic reports.", durationMin: 30, isCurrent: false, progressPct: 0.0),
                ProgramItem(title: "The World Briefing with Live Correspondents", timeRange: "15:30 – 16:30", description: "Dispatches and analysis from European, Asian, and American news bureaus.", durationMin: 60, isCurrent: false, progressPct: 0.0),
                ProgramItem(title: "Special Investigation: Climate & Global Tech", timeRange: "16:30 – 17:30", description: "Investigative documentary into emerging technological breakthroughs and science.", durationMin: 60, isCurrent: false, progressPct: 0.0)
            ]
        } else {
            return [
                ProgramItem(title: "Prime Time Showcase: Live Broadcast Feature", timeRange: "14:00 – 15:30", description: "Special flagship studio program with live guests, performances, and audience discussion.", durationMin: 90, isCurrent: true, progressPct: 0.55),
                ProgramItem(title: "Evening Edition: Culture, Cinema & Arts", timeRange: "15:30 – 17:00", description: "Exploring new cinematic releases, stage productions, and international arts festivals.", durationMin: 90, isCurrent: false, progressPct: 0.0),
                ProgramItem(title: "Late Night Variety Show: Entertainment & Music", timeRange: "17:00 – 18:30", description: "Celebrity interviews, comedy monologues, musical performances, and games.", durationMin: 90, isCurrent: false, progressPct: 0.0)
            ]
        }
    }
    
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
                                        .foregroundColor(.white)
                                    
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
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        
                        Divider()
                            .padding(.horizontal, 20)
                        
                        // ON AIR NOW FEATURE CARD
                        if let current = programs.first(where: { $0.isCurrent }) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("ON AIR NOW")
                                        .font(.caption2.bold())
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.18))
                                        .cornerRadius(4)
                                    
                                    Spacer()
                                    
                                    Text(current.timeRange)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                
                                Text(current.title)
                                    .font(.title3.bold())
                                    .foregroundColor(.white)
                                
                                Text(current.description)
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.8))
                                
                                // Progress bar
                                VStack(spacing: 4) {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color.white.opacity(0.15))
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color.blue)
                                                .frame(width: geo.size.width * CGFloat(current.progressPct))
                                        }
                                    }
                                    .frame(height: 6)
                                    
                                    HStack {
                                        Text("\(Int(current.progressPct * 100))% elapsed")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                        Spacer()
                                        Text("\(current.durationMin) min total")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                            .padding(.horizontal, 20)
                        }
                        
                        // TODAY'S SCHEDULE
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Today's Schedule")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                            
                            VStack(spacing: 8) {
                                ForEach(programs) { item in
                                    HStack(alignment: .top, spacing: 14) {
                                        Text(item.timeRange.components(separatedBy: " – ").first ?? "")
                                            .font(.caption.bold().monospacedDigit())
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.white.opacity(0.12))
                                            .cornerRadius(6)
                                            .frame(width: 60)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(item.title)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundColor(.white)
                                                if item.isCurrent {
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
                                                    .foregroundColor(.gray)
                                            }
                                            
                                            Text(item.description)
                                                .font(.caption)
                                                .foregroundColor(.white.opacity(0.7))
                                                .lineLimit(2)
                                        }
                                    }
                                    .padding(12)
                                    .background(Color.white.opacity(item.isCurrent ? 0.08 : 0.03))
                                    .cornerRadius(8)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("Program Guide")
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
    }
    
    private var epgLogoFallback: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.blue.opacity(0.2))
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
    
    public init(player: AVPlayer?, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        
        playerLayer.player = player
        playerLayer.videoGravity = videoGravity
        playerLayer.backgroundColor = NSColor.black.cgColor
        self.layer?.addSublayer(playerLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    
    public func update(player: AVPlayer?, videoGravity: AVLayerVideoGravity) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        if playerLayer.videoGravity != videoGravity {
            playerLayer.videoGravity = videoGravity
        }
    }
}

public struct AVPlayerLayerRepresentable: NSViewRepresentable {
    public let player: AVPlayer
    public var videoGravity: AVLayerVideoGravity
    
    public init(player: AVPlayer, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.player = player
        self.videoGravity = videoGravity
    }
    
    public func makeNSView(context: Context) -> AVPlayerLayerNSView {
        return AVPlayerLayerNSView(player: player, videoGravity: videoGravity)
    }
    
    public func updateNSView(_ nsView: AVPlayerLayerNSView, context: Context) {
        nsView.update(player: player, videoGravity: videoGravity)
    }
}
#elseif os(iOS)
import UIKit

/// High-performance UIKit UIView wrapping AVPlayerLayer.
public final class AVPlayerLayerUIView: UIView {
    public override static var layerClass: AnyClass {
        return AVPlayerLayer.self
    }
    
    public var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }
    
    public init(player: AVPlayer?, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.player = player
        playerLayer.videoGravity = videoGravity
        playerLayer.backgroundColor = UIColor.black.cgColor
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(player: AVPlayer?, videoGravity: AVLayerVideoGravity) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        if playerLayer.videoGravity != videoGravity {
            playerLayer.videoGravity = videoGravity
        }
    }
}

public struct AVPlayerLayerRepresentable: UIViewRepresentable {
    public let player: AVPlayer
    public var videoGravity: AVLayerVideoGravity
    
    public init(player: AVPlayer, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.player = player
        self.videoGravity = videoGravity
    }
    
    public func makeUIView(context: Context) -> AVPlayerLayerUIView {
        return AVPlayerLayerUIView(player: player, videoGravity: videoGravity)
    }
    
    public func updateUIView(_ uiView: AVPlayerLayerUIView, context: Context) {
        uiView.update(player: player, videoGravity: videoGravity)
    }
}
#endif

