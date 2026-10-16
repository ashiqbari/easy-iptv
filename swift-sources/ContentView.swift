//
//  ContentView.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 15+
//

import SwiftUI
#if os(macOS)
import AppKit

private struct PlaybackBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 { value = next }
    }
}

/// Missing anchors occur during layout changes. They must never turn the player
/// into a window-sized overlay over the category/channel panes.
struct LibraryPaneLayout {
    static func visibility(categories: Bool, channels: Bool) -> NavigationSplitViewVisibility {
        categories ? .all : (channels ? .doubleColumn : .detailOnly)
    }

    static func playbackFrame(fullscreen: Bool, containerSize: CGSize, detailBounds: CGRect?) -> CGRect {
        let container = CGRect(origin: .zero, size: containerSize)
        if fullscreen { return container }
        // Native split columns can include titlebar height beyond the visible content area.
        let visible = (detailBounds ?? .zero).intersection(container)
        return visible.isNull ? .zero : visible
    }
}
#endif

/// Main cross-platform container coordinating sidebar categories, channel list, and video player
/// with native navigation split panes and independently scoped sidebar controls.
public struct ContentView: View {
    
    // MARK: - State Management
    
    @ObservedObject var manager: IPTVPlayerManager
    private var palette: AppPalette { AppPalette(appearance: appearance) }
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    #if os(macOS)
    @State private var playbackBounds: CGRect = .zero
    @State private var showingGuideSearch = false
    #endif
    
    public init(manager: IPTVPlayerManager) {
        self.manager = manager
    }
    
    private var libraryContent: some View {
        Group {
#if os(macOS)
            GeometryReader { geometry in
                let bounds = LibraryPaneLayout.playbackFrame(
                    fullscreen: manager.isFullscreen, containerSize: geometry.size,
                    detailBounds: playbackBounds
                )
                ZStack(alignment: .topLeading) {
                    macLibraryLayout
                        .opacity(manager.isFullscreen ? 0 : 1)
                        .allowsHitTesting(!manager.isFullscreen)
                        .accessibilityHidden(manager.isFullscreen)

                    // A sibling keeps the native video surface alive when split-view structure changes.
                    IPTVPlaybackView(manager: manager)
                        .frame(width: bounds.width, height: bounds.height)
                        .clipped()
                        .position(x: bounds.midX, y: bounds.midY)
                        .opacity(manager.showingDashboard && !manager.isFullscreen ? 0 : 1)
                        .allowsHitTesting(!manager.showingDashboard || manager.isFullscreen)
                        .accessibilityHidden(manager.showingDashboard && !manager.isFullscreen)
                }
                .coordinateSpace(name: "libraryPlayback")
                .onPreferenceChange(PlaybackBoundsPreferenceKey.self) { bounds in
                    if bounds.width > 0 && bounds.height > 0 { playbackBounds = bounds }
                }
            }
#else
            if !manager.isFullscreen {
                ZStack {
                    navigationSplitView
                        .opacity(manager.showingDashboard ? 0 : 1)
                        .allowsHitTesting(!manager.showingDashboard)
                        .accessibilityHidden(manager.showingDashboard)
                    if manager.showingDashboard {
                        NavigationStack {
                            DashboardView(manager: manager)
                                .toolbar {
                                    ToolbarItemGroup(placement: .primaryAction) { homeToolbarControls }
                                }
                        }
                    }
                }
            } else {
                IPTVPlaybackView(manager: manager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .ignoresSafeArea()
            }
#endif
        }
    }

    public var body: some View {
        ZStack {
            // Disable controls, not native split-view hit testing, which drops the titlebar inset.
            libraryContent
                .disabled(manager.showingDownloads)
                .accessibilityHidden(manager.showingDownloads)
            if manager.showingDownloads {
                DownloadsDialog(manager: manager, downloads: manager.downloads)
            }
        }

        .sheet(isPresented: $manager.showingSources) {
            SavedSourcesView(manager: manager, store: manager.sources)
        }
        .sheet(isPresented: $manager.showingOrganization) {
            ChannelOrganizationView(manager: manager)
        }
        .sheet(item: $manager.catchupChannel) { channel in
            CatchupView(channel: channel, manager: manager)
        }
        .sheet(isPresented: $manager.showingPlaylistSheet) {
            playlistInputSheet.background(palette.background)
        }
        .sheet(isPresented: $manager.showingAboutSheet) {
            aboutSheet.background(palette.background)
        }
        .sheet(isPresented: $manager.showingSubscriptionInfo) {
            SubscriptionInfoView(manager: manager).id(manager.subscriptionAccount)
        }
        .onChange(of: manager.showingDownloads) { _, showing in
            guard !showing else { return }
            if let record = manager.pendingDownload {
                manager.pendingDownload = nil
                // Let the overlay close before presenting the existing resume choice.
                Task { @MainActor in
                    await Task.yield()
                    manager.playDownload(record)
                }
            }
        }
        .alert("Source issue", isPresented: Binding(get: { manager.sources.error != nil }, set: { if !$0 { manager.sources.error = nil } })) {
            Button("OK") { manager.sources.error = nil }
        } message: { Text(manager.sources.error ?? "") }
        .alert("Download issue", isPresented: Binding(
            get: { manager.downloads.errorMessage != nil },
            set: { if !$0 { manager.downloads.errorMessage = nil } }
        )) {
            Button("OK") { manager.downloads.errorMessage = nil }
        } message: { Text(manager.downloads.errorMessage ?? "") }
        .alert("Continue watching?", isPresented: $manager.showingResumeChoice, presenting: manager.resumeRequest) { request in
            Button("Resume from \(PlaybackProgress.timestamp(request.position))") {
                manager.resolveResume(request, startOver: false)
            }
            Button("Start over") { manager.resolveResume(request, startOver: true) }
            Button("Cancel", role: .cancel) { manager.cancelResume() }
        } message: { request in
            Text(request.item.name)
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.backgroundNotification)) { _ in
            manager.pauseForBackground()
        }
        #if os(macOS)
        .sheet(isPresented: $showingGuideSearch) { GuideSearchView(manager: manager) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow else { return }
            manager.updateFullscreenState(true, window: window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow else { return }
            manager.updateFullscreenState(false, window: window)
        }
        // AppKit avoids stale SwiftUI colors when returning to System appearance.
        .onChange(of: appearance, initial: true) { _, preference in
            switch preference {
            case .system: NSApplication.shared.appearance = nil
            case .light, .warmStone: NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case .dark, .navy, .obsidian, .forest: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            }
        }
        #else
        .preferredColorScheme(appearance.colorScheme)
        #endif
        .tint(AppPalette(appearance: appearance).controlAccent)
        .accentColor(AppPalette(appearance: appearance).accent)
        .environment(\.appPalette, AppPalette(appearance: appearance))
    }

    private static var backgroundNotification: Notification.Name {
        #if os(macOS)
        return NSApplication.didHideNotification
        #else
        return UIApplication.didEnterBackgroundNotification
        #endif
    }

    #if os(macOS)
    private var categoriesVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            LibraryPaneLayout.visibility(categories: manager.showsCategoriesSidebar, channels: manager.showsChannelsSidebar)
        } set: { visibility in
            let visible = visibility == .all
            if visible != manager.showsCategoriesSidebar {
                manager.toggleCategoriesSidebar()
            }
        }
    }

    @ViewBuilder
    private var macLibraryLayout: some View {
        // Keep native per-column titlebars. When channels are hidden, use the
        // two-column form instead of asking .detailOnly to hide both sidebars.
        // The player lives outside either split, so changing this chrome never
        // recreates its rendering surface.
        if manager.showingDashboard {
            NavigationStack {
                DashboardView(manager: manager)
                    .background(playbackBoundsReader)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) { homeToolbarControls }
                    }
            }
            .toolbarBackground(palette.background, for: .windowToolbar)
            .toolbarBackground(palette.isCustom ? .visible : .automatic, for: .windowToolbar)
        } else if manager.showsChannelsSidebar {
            NavigationSplitView(columnVisibility: categoriesVisibility) {
                sidebarView
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
            } content: {
                ChannelListView(manager: manager)
                    .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 620)
            } detail: {
                playbackPlaceholder
            }
            .navigationSplitViewStyle(.balanced)
            .toolbarBackground(palette.background, for: .windowToolbar)
            .toolbarBackground(palette.isCustom ? .visible : .automatic, for: .windowToolbar)
        } else {
            NavigationSplitView(columnVisibility: categoriesVisibility) {
                sidebarView
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
            } detail: {
                playbackPlaceholder
            }
            .navigationSplitViewStyle(.balanced)
            .toolbarBackground(palette.background, for: .windowToolbar)
            .toolbarBackground(palette.isCustom ? .visible : .automatic, for: .windowToolbar)
        }
    }

    private var playbackPlaceholder: some View {
        Color.black
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { manager.showingDashboard = true } label: {
                        Label("Home", systemImage: "house")
                    }
                    .help("Return to Home")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { manager.toggleChannelsSidebar() } label: {
                        Label("Channels Sidebar", systemImage: "sidebar.right")
                    }
                    .help(manager.showsChannelsSidebar ? "Hide the channel sidebar" : "Show the channel sidebar")
                    .keyboardShortcut("2", modifiers: [.command, .shift])

                    if manager.selectedSection == .live {
                        Button { showingGuideSearch = true } label: {
                            Label("Search TV Guide", systemImage: "text.magnifyingglass")
                        }
                        .help("Find channels by current or upcoming programmes")
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    }
                    DownloadHeaderControls(manager: manager, downloads: manager.downloads)
                }
            }
            .background(playbackBoundsReader)
    }

    private var playbackBoundsReader: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: PlaybackBoundsPreferenceKey.self,
                                   value: geometry.frame(in: .named("libraryPlayback")))
        }
    }
    #endif

    private var navigationSplitView: some View {
        NavigationSplitView(columnVisibility: $manager.columnVisibility) {
            sidebarView
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } content: {
            ChannelListView(manager: manager)
                .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 620)
        } detail: {
#if os(macOS)
            playbackPlaceholder
#else
            IPTVPlaybackView(manager: manager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
        }
        .navigationSplitViewStyle(.balanced)
        #if !os(macOS)
        .toolbar { Button { manager.showingDashboard = true } label: { Label("Home", systemImage: "house") } }
        #endif
    }

    // MARK: - Column 1: Sidebar
    
    private var sidebarView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "play.tv.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EasyIPTV").font(.headline)
                    Text("Your viewing library").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { manager.showingSubscriptionInfo = true } label: {
                    Image(systemName: "calendar")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Subscription Info")
                .help("View subscription expiry and account status")
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)

            LibrarySectionTabs(manager: manager)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search categories…", text: $manager.categorySearchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .accessibilityLabel("Search categories")
                Button {
                    manager.categorySearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear category search")
                .help("Clear category search")
                .opacity(manager.categorySearchText.isEmpty ? 0 : 1)
                .disabled(manager.categorySearchText.isEmpty)
                .accessibilityHidden(manager.categorySearchText.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            
            Divider()
            
            List(selection: Binding(get: { manager.showingDashboard ? nil : manager.selectedCategory }, set: { value in
                if let value {
                    manager.showingDashboard = false
                    manager.selectedCategory = value
                }
            })) {
                Section("Quick Access") {
                    if !manager.downloads.isOnline {
                        Text("Offline — open Downloads to watch saved media.").font(.caption).foregroundStyle(.secondary)
                    }
                    categoryRow("All") {
                        Label {
                            HStack {
                                Text("All \(manager.selectedSection.rawValue)")
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(manager.sectionTotalCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: manager.selectedSection.iconName)
                                .foregroundColor(.accentColor)
                        }
                    }
                    
                    categoryRow("Favorites") {
                        Label {
                            HStack {
                                Text("Favorites")
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(manager.favoritesCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                        }
                    }
                    categoryRow("Recently Watched") {
                        Label {
                            HStack {
                                Text("Recently Watched").lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(manager.recentlyWatchedChannels.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                
                Section("Categories") {
                    let customCategories = manager.filteredCategories
                    if customCategories.isEmpty, !manager.categorySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No matching categories")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(customCategories, id: \.self) { category in
                        categoryRow(category) {
                            Label {
                                HStack {
                                    Text(category)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 8)
                                    let count = manager.categoryCounts[category] ?? 0
                                    Text("\(count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                            } icon: {
                                Image(systemName: iconForCategory(category))
                                    .foregroundColor(.purple)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(palette.isCustom ? .hidden : .automatic)
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
        .navigationTitle("IPTV Library")
        .background(palette.background)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                libraryToolbarControls
            }
        }
    }

    private var libraryToolbarControls: some View {
        Group {
            Menu {
                AppearancePicker()
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .help("Choose an appearance theme")

            Menu {
                Button("Add Source…") { manager.showingPlaylistSheet = true }
                Button("Saved Sources…") { manager.showingSources = true }
                Divider()
                Button("Organize Channels…") { manager.showingOrganization = true }
            } label: {
                Label("Sources", systemImage: "tray.2.fill")
            }
            .help("Switch saved sources, add a provider, or organize channels")

            Button {
                manager.showingAboutSheet = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
        }
    }

    private var homeToolbarControls: some View {
        Group {
            libraryToolbarControls
            Button { manager.showingSubscriptionInfo = true } label: {
                Label("Subscription Info", systemImage: "calendar")
            }
            .help("View subscription expiry and account status")
            DownloadHeaderControls(manager: manager, downloads: manager.downloads)
        }
    }

    @ViewBuilder
    private func categoryRow<LabelContent: View>(_ category: String, @ViewBuilder label: () -> LabelContent) -> some View {
        #if os(macOS)
        label().tag(category)
        #else
        NavigationLink(value: category, label: label)
        #endif
    }
    
    // MARK: - Sheets
    
    /// Modern modal for adding an Xtream Codes account or loading an M3U / M3U8 playlist
    private var playlistInputSheet: some View {
        AddSourceSheetView(manager: manager)
    }
    
    /// About & Architecture Sheet
    private var aboutSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "tv.and.mediabox")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
                
                Text("SwiftUI IPTV Player")
                    .font(.title2.bold())
                
                Text("Native IPTV client for iOS 16+ and macOS 15+ built with Swift Concurrency, AVFoundation, and NavigationSplitView. macOS also includes the VLC playback engine.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 10) {
                    bulletPoint(icon: "server.rack", text: "Xtream Codes API integration for Live TV, Movies (VOD), and Series.")
                    bulletPoint(icon: "play.tv.fill", text: "Hardware-accelerated HLS & MP4 playback via AVPlayerLayer.")
                    bulletPoint(icon: "list.bullet.rectangle", text: "Asynchronous #EXTINF M3U parser with regex attribute extraction.")
                    bulletPoint(icon: "macwindow.and.cursor", text: "Unified codebase running on iPhone, iPad, and Mac.")
                    bulletPoint(icon: "star.fill", text: "Persistent favorite channel bookmarking with UserDefaults.")
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
                
                Spacer()
                
                Button("Done") {
                    manager.showingAboutSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(palette.background)
            .navigationTitle("About IPTV Player")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .frame(minWidth: 440, minHeight: 400)
    }
    
    private func bulletPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.footnote)
        }
    }
    
    private func iconForCategory(_ category: String) -> String {
        let lower = category.lowercased()
        if lower.contains("sport") { return "sportscourt.fill" }
        if lower.contains("news") { return "newspaper.fill" }
        if lower.contains("movie") || lower.contains("cinema") { return "film.fill" }
        if lower.contains("music") { return "music.note" }
        if lower.contains("doc") { return "globe.americas.fill" }
        if lower.contains("anim") || lower.contains("kid") { return "sparkles.tv" }
        if lower.contains("sci") { return "atom" }
        return "folder.fill"
    }
}

// MARK: - Add Source Modal View (Xtream Codes API & M3U Playlist)

public struct AddSourceSheetView: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject var manager: IPTVPlayerManager
    
    public init(manager: IPTVPlayerManager) {
        self.manager = manager
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented Tab Picker
                Picker("Source Type", selection: $manager.sourceTab) {
                    Label("Xtream Codes API", systemImage: "server.rack").tag(0)
                    Label("M3U Playlist URL", systemImage: "link").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)
                
                Divider()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if manager.sourceTab == 0 {
                            xtreamCodesSection
                        } else {
                            m3uPlaylistSection
                        }
                    }
                    .padding(24)
                }
                
                Divider()
                
                // Bottom Action Buttons
                HStack {
                    Button("Cancel") {
                        manager.showingPlaylistSheet = false
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Spacer()
                    
                    if manager.sourceTab == 0 {
                        Button {
                            connectXtream()
                        } label: {
                            HStack {
                                if manager.isLoading {
                                    ProgressView().scaleEffect(0.8)
                                }
                                Text("Connect Xtream API")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.xtreamServerURL.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  manager.xtreamUsername.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  manager.xtreamPassword.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  manager.isLoading)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button {
                            loadM3U()
                        } label: {
                            HStack {
                                if manager.isLoading {
                                    ProgressView().scaleEffect(0.8)
                                }
                                Text("Load M3U Playlist")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.inputPlaylistURL.trimmingCharacters(in: .whitespaces).isEmpty || manager.isLoading)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color.secondary.opacity(0.06))
            }
            .background(palette.background)
            .navigationTitle("Add IPTV Source")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 520)
    }
    
    // MARK: - Xtream Codes Form
    
    private var xtreamCodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Description Banner
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Xtream Codes IPTV Protocol")
                        .font(.headline)
                    Text("Enter your provider's server host, username, and password. Live TV channels, Movies (VOD), and TV Series will be automatically categorized.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(10)
            
            // Server URL
            VStack(alignment: .leading, spacing: 6) {
                Label("Server URL (Host & Port)", systemImage: "network")
                    .font(.subheadline.bold())
                TextField("http://domain.com:8080 or https://...", text: $manager.xtreamServerURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
            
            // Username
            VStack(alignment: .leading, spacing: 6) {
                Label("Username", systemImage: "person.fill")
                    .font(.subheadline.bold())
                TextField("Enter username", text: $manager.xtreamUsername)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            
            // Password
            VStack(alignment: .leading, spacing: 6) {
                Label("Password", systemImage: "lock.fill")
                    .font(.subheadline.bold())
                HStack {
                    if manager.isPasswordVisible {
                        TextField("Enter password", text: $manager.xtreamPassword)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Enter password", text: $manager.xtreamPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        manager.isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: manager.isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - M3U Playlist Form
    
    private var m3uPlaylistSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Description Banner
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundColor(.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Standard M3U / M3U8 Playlist")
                        .font(.headline)
                    Text("Paste an HTTP/HTTPS URL pointing to an .m3u or .m3u8 playlist file containing stream links and channel metadata.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(10)
            
            // M3U URL Field
            VStack(alignment: .leading, spacing: 6) {
                Label("Playlist URL", systemImage: "link")
                    .font(.subheadline.bold())
                TextField("https://example.com/playlist.m3u", text: $manager.inputPlaylistURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
            
            // Quick Presets
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Public Presets")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                
                Button {
                    manager.inputPlaylistURL = "https://iptv-org.github.io/iptv/countries/us.m3u"
                } label: {
                    HStack {
                        Image(systemName: "flag.fill").foregroundColor(.accentColor)
                        Text("Public US Live Streams (iptv-org)")
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                
                Button {
                    manager.inputPlaylistURL = "https://iptv-org.github.io/iptv/index.m3u"
                } label: {
                    HStack {
                        Image(systemName: "globe").foregroundColor(.purple)
                        Text("Worldwide Free IPTV Curated Index")
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                
                Button {
                    manager.inputPlaylistURL = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
                } label: {
                    HStack {
                        Image(systemName: "play.circle.fill").foregroundColor(.green)
                        Text("Mux HLS 1080p Adaptive Test Stream")
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Actions
    
    private func connectXtream() {
        var cleanURL = manager.xtreamServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanURL.lowercased().hasPrefix("http://") && !cleanURL.lowercased().hasPrefix("https://") {
            cleanURL = "http://" + cleanURL
        }
        let user = manager.xtreamUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = manager.xtreamPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        
        manager.showingPlaylistSheet = false
        Task {
            await manager.loadXtream(serverURL: cleanURL, username: user, password: pass)
        }
    }
    
    private func loadM3U() {
        let cleanURL = manager.inputPlaylistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.inputPlaylistURL = cleanURL
        manager.showingPlaylistSheet = false
        Task {
            await manager.loadPlaylist(from: cleanURL)
        }
    }
}

struct LibrarySectionTabs: View {
    @ObservedObject var manager: IPTVPlayerManager
    @Environment(\.appPalette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(M3UItem.ContentType.allCases, id: \.self) { section in
                let isSelected = !manager.showingDashboard && manager.selectedSection == section
                Button { manager.browse(section) } label: {
                    Text(section.rawValue)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(isSelected ? palette.onAccent : .primary)
                        .background(isSelected ? palette.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.rawValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library section")
    }
}
