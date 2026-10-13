//
//  ChannelListView.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 15+
//

import SwiftUI

/// Comprehensive channel catalog view with instant search filtering, category pill selection,
/// favorite toggling, and visual indicators for currently playing streams.
public struct ChannelListView: View {
    
    @ObservedObject var manager: IPTVPlayerManager
    #if !os(macOS)
    @State private var showingGuideSearch = false
    #endif
    static let categoryShortcuts = ["All", "Favorites", "Recently Watched"]
    
    public init(manager: IPTVPlayerManager) {
        self.manager = manager
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Panel chrome belongs below the window toolbar, not in its button row.
            HStack(spacing: 12) {
                Button { manager.toggleChannelsSidebar() } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hide Channels")
                .help("Show or hide only the channel sidebar")
                .keyboardShortcut("2", modifiers: [.command, .shift])
                VStack(alignment: .leading, spacing: 3) {
                    Text(manager.selectedSection.rawValue)
                        .font(.title3.weight(.bold))
                    Text("\(manager.selectedCategory) · \(manager.filteredChannels.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            #endif
            // Integrated Search Bar with Generous Bottom Margin
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                
                TextField("Search in \(manager.selectedSection.rawValue)...", text: $manager.searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
                .help("Clear Search")
                .opacity(manager.searchText.isEmpty ? 0 : 1)
                .disabled(manager.searchText.isEmpty)
                .accessibilityHidden(manager.searchText.isEmpty)
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

            if manager.selectedCategory == "Recently Watched", !manager.recentlyWatchedChannels.isEmpty {
                HStack {
                    Spacer()
                    Button("Clear History") { manager.clearRecentlyWatched() }
                        .buttonStyle(.borderless)
                        .help("Clear recently watched history for \(manager.selectedSection.rawValue)")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            
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
        #if !os(macOS)
        .navigationTitle("Channels (\(manager.filteredChannels.count))")
        .sheet(isPresented: $showingGuideSearch) { GuideSearchView(manager: manager) }
        .toolbar {
            if manager.selectedSection == .live {
                ToolbarItem(placement: .automatic) {
                    Button { showingGuideSearch = true } label: { Label("Search TV Guide", systemImage: "text.magnifyingglass") }
                        .help("Find channels by current or upcoming programmes")
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
            }
            ToolbarItemGroup(placement: .automatic) {
                DownloadHeaderControls(manager: manager, downloads: manager.downloads)
            }
        }
        #endif
    }
    
    // MARK: - Subviews

    func clearSearch() {
        // Clearing can restore thousands of rows; don't animate the bulk insertion.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            manager.searchText = ""
        }
    }
    
    /// Provider categories belong in the sidebar, not the top shortcuts.
    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.categoryShortcuts, id: \.self) { category in
                    let isSelected = manager.selectedCategory == category
                    Button {
                        manager.selectedCategory = category
                    } label: {
                        HStack(spacing: 6) {
                            if category == "Favorites" || category == "★ Favorites" {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                Text("Favorites")
                                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            } else {
                                Image(systemName: category == "All" ? "square.grid.2x2" : "clock.arrow.circlepath")
                                    .font(.caption2)
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
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
    }
    
    /// Main Channel List
    private var channelListContent: some View {
        Group {
            #if os(macOS)
            // NSTableView measures inserted rows eagerly; All can exhaust SwiftUI's graph storage.
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(manager.filteredChannels) { channel in
                        channelRow(channel)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
            #else
            List(manager.filteredChannels) { channel in
                channelRow(channel)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            .listStyle(.plain)
            #endif
        }
        .transaction {
            // Restoring All can insert thousands of rows in a single update.
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }

    private func channelRow(_ channel: M3UItem) -> some View {
        let isRecent = manager.selectedCategory == "Recently Watched"
        let record = isRecent ? manager.recentlyWatchedRecord(for: channel) : nil
        let episodeLabel = record.flatMap { record -> String? in
            guard let season = record.season, let episode = record.episode else { return nil }
            return "Last watched: S\(season) · E\(episode)"
        }
        return ChannelRowView(
            channel: channel,
            isPlaying: manager.isCurrentPlayback(channel),
            onSelect: {
                if isRecent { manager.playRecentlyWatched(channel) }
                else { manager.playChannel(channel) }
            },
            onToggleFavorite: { manager.toggleFavorite(channel) },
            subtitle: episodeLabel
        )
        .contextMenu {
            if isRecent {
                Button("Remove from Recently Watched") { manager.removeRecentlyWatched(channel) }
            }
        }
    }
    
    /// Loading indicator
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
            Text("Loading your library…")
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
            
            Text(manager.selectedCategory == "Recently Watched" ? "Nothing Recently Watched" : "Nothing Here Yet")
                .font(.headline)
            
            if !manager.searchText.isEmpty {
                Text("No channels matching \"\(manager.searchText)\" in category \"\(manager.selectedCategory)\".")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button("Clear Search", action: clearSearch)
                .buttonStyle(.borderedProminent)
            } else if manager.selectedCategory == "Recently Watched" {
                Text("\(manager.selectedSection.rawValue) you play will appear here, newest first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if manager.selectedCategory == "Favorites" || manager.selectedCategory == "★ Favorites" {
                Text("Keep your go-to picks here. Select the star beside any item to save it.")
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
    var subtitle: String? = nil
    
    @State private var isHovered = false

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    channelLogo
                    VStack(alignment: .leading, spacing: 5) {
                        Text(channel.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle ?? channel.displayGroup)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if isPlaying {
                            Label("Now playing", systemImage: "waveform")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(channel.name)
            .accessibilityValue(subtitle ?? channel.displayGroup)
            .accessibilityAddTraits(isPlaying ? .isSelected : [])

            Button(action: onToggleFavorite) {
                Image(systemName: channel.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(channel.isFavorite ? Color.orange : Color.secondary)
                    .font(.body)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(channel.isFavorite ? "Remove from" : "Add to") Favorites: \(channel.name)")
            .help(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(10)
        .background(
            isPlaying ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(isHovered ? 0.1 : 0.04),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isPlaying ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.1), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
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
        .frame(width: 48, height: 48)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPlaying ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
    
    private var fallbackLogo: some View {
        Image(systemName: channel.contentType.iconName)
            .foregroundColor(.secondary)
            .font(.system(size: 20))
    }
}
