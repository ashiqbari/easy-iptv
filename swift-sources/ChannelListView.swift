//
//  ChannelListView.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 13+
//

import SwiftUI

/// Comprehensive channel catalog view with instant search filtering, category pill selection,
/// favorite toggling, and visual indicators for currently playing streams.
public struct ChannelListView: View {
    
    @ObservedObject var manager: IPTVPlayerManager
    
    public init(manager: IPTVPlayerManager) {
        self.manager = manager
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Integrated Search Bar with Generous Bottom Margin
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                
                TextField("Search in \(manager.selectedSection.rawValue)...", text: $manager.searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                
                if !manager.searchText.isEmpty {
                    Button {
                        manager.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 14) // Increased generous bottom margin
            
            // Horizontal Category Selector Pills
            categoryFilterBar
                .padding(.bottom, 10)
                .background(categoryBarBackground)
            
            Divider()
            
            // Channel List
            if manager.isLoading {
                loadingView
            } else if manager.filteredChannels.isEmpty {
                emptyChannelsView
            } else {
                channelListContent
            }
        }
        .navigationTitle("Channels (\(manager.filteredChannels.count))")
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                Button {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.leading")
                }
                .help("Toggle sidebar visibility")
            }
            #endif
            
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await manager.refreshPlaylist()
                    }
                } label: {
                    Label("Refresh & Sync", systemImage: "arrow.clockwise")
                }
                .help("Refresh and sync latest channels, movies, and TV shows")
                .disabled(manager.isLoading)
            }
        }
    }
    
    // MARK: - Subviews
    
    /// Horizontal category scroll view
    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(manager.categories, id: \.self) { category in
                    let isSelected = manager.selectedCategory == category
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            manager.selectedCategory = category
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if category == "Favorites" || category == "★ Favorites" {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundColor(isSelected ? .black : .yellow)
                                Text("Favorites")
                                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            } else {
                                Text(category)
                                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.15)
                        )
                        .foregroundColor(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
    
    /// Main Channel List
    private var channelListContent: some View {
        List(manager.filteredChannels) { channel in
            ChannelRowView(
                channel: channel,
                isPlaying: manager.currentChannel?.id == channel.id,
                onSelect: {
                    manager.playChannel(channel)
                },
                onToggleFavorite: {
                    manager.toggleFavorite(channel)
                }
            )
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            #if os(macOS)
            .listRowSeparator(.visible)
            #endif
        }
        .listStyle(.plain)
    }
    
    /// Loading indicator
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
            Text("Loading Playlist…")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// Empty search results or no channels loaded
    private var emptyChannelsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Channels Found")
                .font(.headline)
            
            if !manager.searchText.isEmpty {
                Text("No channels matching \"\(manager.searchText)\" in category \"\(manager.selectedCategory)\".")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button("Clear Search") {
                    manager.searchText = ""
                }
                .buttonStyle(.borderedProminent)
            } else if manager.selectedCategory == "★ Favorites" {
                Text("You haven't added any favorite channels yet. Tap the star icon on any channel to add it here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text("Load an M3U playlist URL or enter Xtream Codes to start watching.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button {
                    manager.showingPlaylistSheet = true
                } label: {
                    Label("Add Source (Xtream API / M3U)", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var categoryBarBackground: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

// MARK: - Channel Row Subview

public struct ChannelRowView: View {
    let channel: M3UItem
    let isPlaying: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void
    
    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Channel Logo
                channelLogo
                
                // Channel Title & Metadata
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(channel.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isPlaying ? .accentColor : .primary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        if isPlaying {
                            Image(systemName: "waveform")
                                .font(.caption.bold())
                                .foregroundColor(.accentColor)
                        }
                    }
                    
                    HStack(spacing: 6) {
                        Text(channel.displayGroup)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text(channel.isHLS ? "HLS" : "MP4")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(3)
                    }
                }
                .layoutPriority(1)
                
                Spacer()
                
                // Favorite Star Button
                Button(action: onToggleFavorite) {
                    Image(systemName: channel.isFavorite ? "star.fill" : "star")
                        .foregroundColor(channel.isFavorite ? .yellow : .secondary.opacity(0.6))
                        .font(.body)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var channelLogo: some View {
        Group {
            if let logoURL = channel.logoURL {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                             .scaledToFit()
                    default:
                        fallbackLogo
                    }
                }
            } else {
                fallbackLogo
            }
        }
        .frame(width: 44, height: 44)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPlaying ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
    
    private var fallbackLogo: some View {
        Image(systemName: "tv")
            .foregroundColor(.secondary)
            .font(.system(size: 20))
    }
}
