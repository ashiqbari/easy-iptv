//
//  ChannelListView.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 15+
//

import SwiftUI

enum LibrarySortOrder: String, CaseIterable, Sendable {
    case provider, nameAscending, nameDescending, recentlyAdded, highestRated
    var title: String {
        switch self {
        case .provider: return "Default order"
        case .nameAscending: return "Name A–Z"
        case .nameDescending: return "Name Z–A"
        case .recentlyAdded: return "Recently added"
        case .highestRated: return "Highest rated"
        }
    }
    func title(for section: M3UItem.ContentType) -> String {
        self == .recentlyAdded && section == .series ? "Recently added / updated" : title
    }
}

/// Comprehensive channel catalog view with instant search filtering, category pill selection,
/// favorite toggling, and visual indicators for currently playing streams.
public struct ChannelListView: View {
    
    @Environment(\.appPalette) private var palette
    @ObservedObject var manager: IPTVPlayerManager
    @State private var revealedNavigationRequest: UUID?
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
            // Keep the section heading below the window toolbar.
            HStack(spacing: 12) {
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

                if manager.isFilteringLibrary {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating results")
                }
                LibraryFilterControl(manager: manager)
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
            } else if manager.isFilteringLibrary && manager.filteredChannels.isEmpty {
                ProgressView("Updating results…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.filteredChannels.isEmpty {
                emptyChannelsView
            } else {
                channelListContent
            }
        }
        .background(palette.surface)
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
        HStack(spacing: 6) {
            ForEach(Self.categoryShortcuts, id: \.self) { category in
                let isSelected = manager.selectedCategory == category
                Button { manager.selectedCategory = category } label: {
                    HStack(spacing: 5) {
                        Image(systemName: category == "Favorites" ? "star.fill" :
                              (category == "All" ? "square.grid.2x2" : "clock.arrow.circlepath"))
                            .font(.caption2).frame(width: 14)
                        ViewThatFits(in: .horizontal) {
                            Text(category).fixedSize(horizontal: true, vertical: false)
                            Text(category == "Recently Watched" ? "Recent" : category)
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32)
                    .foregroundStyle(isSelected ? palette.onAccent : .primary)
                    .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(category)
            }
        }
        .padding(.horizontal, 12)
    }

    /// Main Channel List
    private var channelListContent: some View {
        ScrollViewReader { proxy in
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
            .onAppear { revealNavigationTarget(using: proxy) }
            #if os(macOS)
            .onChange(of: manager.libraryNavigationRequest) { _, _ in revealNavigationTarget(using: proxy) }
            .onChange(of: manager.isFilteringLibrary) { _, filtering in
                if !filtering { revealNavigationTarget(using: proxy) }
            }
            #else
            .onChange(of: manager.libraryNavigationRequest) { _ in revealNavigationTarget(using: proxy) }
            .onChange(of: manager.isFilteringLibrary) { filtering in
                if !filtering { revealNavigationTarget(using: proxy) }
            }
            #endif
        }
    }

    private func revealNavigationTarget(using proxy: ScrollViewProxy) {
        let request = manager.libraryNavigationRequest
        guard revealedNavigationRequest != request, !manager.isFilteringLibrary,
              let target = manager.libraryNavigationTargetID else { return }
        Task { @MainActor in
            await Task.yield()
            guard manager.libraryNavigationRequest == request, revealedNavigationRequest != request,
                  !manager.isFilteringLibrary, manager.filteredChannels.contains(where: { $0.id == target }) else { return }
            proxy.scrollTo(target, anchor: .center)
            revealedNavigationRequest = request
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
            if channel.catchup != nil { Button("Catch-up TV…") { manager.catchupChannel = channel } }
            Button("Hide Channel") { manager.setChannelHidden(channel, hidden: true) }
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
            } else if manager.favoritesOnly || manager.recentlyAddedOnly || manager.minimumRating > 0 {
                Text("No items match these filters.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear filters") { manager.resetLibraryFilters() }
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
                        if channel.catchup != nil {
                            Label("Catch-up available", systemImage: "clock.arrow.circlepath")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
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


struct LibraryFilterControl: View {
    @ObservedObject var manager: IPTVPlayerManager
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: manager.libraryFiltersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Sort and filter")
        .help("Sort and filter the library")
        .popover(isPresented: $showing) {
            LibraryFilterPanel(manager: manager, showing: $showing)
        }
    }
}

private struct LibraryFilterPanel: View {
    @ObservedObject var manager: IPTVPlayerManager
    @Binding var showing: Bool
    @Environment(\.appPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sort and filter").font(.headline)
                Spacer()
                Button("Done") { showing = false }
            }
            ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                Button { manager.librarySortOrder = order } label: {
                    HStack {
                        Text(order.title(for: manager.selectedSection))
                        Spacer()
                        if manager.librarySortOrder == order { Image(systemName: "checkmark") }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled((order == .recentlyAdded && !manager.hasCatalogDates) || (order == .highestRated && !manager.hasRatings))
                .accessibilityLabel(order.title(for: manager.selectedSection))
                .accessibilityAddTraits(manager.librarySortOrder == order ? .isSelected : [])
            }
            Divider()
            Toggle("Favorites only", isOn: $manager.favoritesOnly)
            Toggle(manager.selectedSection == .series ? "Added / updated in the last 30 days" : "Added in the last 30 days", isOn: $manager.recentlyAddedOnly)
                .disabled(!manager.hasCatalogDates)
            Picker("Minimum rating", selection: $manager.minimumRating) {
                Text("Any rating").tag(0.0)
                ForEach([6.0, 7.0, 8.0, 9.0], id: \.self) { rating in
                    Text("\(Int(rating))+ / 10").tag(rating)
                }
            }.disabled(!manager.hasRatings)
            if manager.selectedSection == .series {
                Text("Series recency uses the added date, or the provider’s last update when no added date is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !manager.hasCatalogDates || !manager.hasRatings {
                Text("Added dates and ratings depend on your provider. Missing values are excluded when their filter is active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Reset sort and filters") { manager.resetLibraryFilters() }
                .disabled(!manager.libraryFiltersActive)
        }
        .padding(16).frame(width: 280).background(palette.surface)
    }
}
