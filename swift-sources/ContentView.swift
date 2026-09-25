//
//  ContentView.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 13+
//

import SwiftUI

/// Main cross-platform container coordinating sidebar categories, channel list, and video player
/// using modern three-column `NavigationSplitView`.
public struct ContentView: View {
    
    // MARK: - State Management
    
    @ObservedObject var manager: IPTVPlayerManager
    
    public init(manager: IPTVPlayerManager) {
        self.manager = manager
    }
    
    public var body: some View {
        Group {
            if !manager.isFullscreen {
                NavigationSplitView(columnVisibility: $manager.columnVisibility) {
                    // COLUMN 1: Categories Sidebar
                    sidebarView
                        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
                } content: {
                    // COLUMN 2: Filtered Channel List
                    ChannelListView(manager: manager)
                        .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 620)
                } detail: {
                    // COLUMN 3: Active Video Player
                    IPTVPlaybackView(manager: manager)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                // TRUE BORDERLESS FULLSCREEN VIEW:
                // Completely replaces window split hierarchy so no window toolbar or top bar is visible
                IPTVPlaybackView(manager: manager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $manager.showingPlaylistSheet) {
            playlistInputSheet
        }
        .sheet(isPresented: $manager.showingAboutSheet) {
            aboutSheet
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            manager.stop()
        }
        #endif
    }
    
    // MARK: - Column 1: Sidebar
    
    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Clean Segmented Section Switcher directly on top of Quick Access
            Picker("Section", selection: $manager.selectedSection) {
                ForEach(M3UItem.ContentType.allCases, id: \.self) { section in
                    Label(section.rawValue, systemImage: section.iconName).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
            
            Divider()
            
            List(selection: $manager.selectedCategory) {
                Section("Quick Access") {
                    NavigationLink(value: "All") {
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
                                .foregroundColor(.blue)
                        }
                    }
                    
                    NavigationLink(value: "Favorites") {
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
                }
                
                Section("Categories") {
                    let customCategories = manager.categories.filter { $0 != "All" && $0 != "Favorites" && $0 != "★ Favorites" }
                    ForEach(customCategories, id: \.self) { category in
                        NavigationLink(value: category) {
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
        }
        .navigationTitle("IPTV Library")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    manager.showingPlaylistSheet = true
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                }
                .help("Add Xtream Codes API account or M3U playlist URL")
                
                Button {
                    manager.showingAboutSheet = true
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            }
        }
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
                
                Text("Native cross-platform IPTV client for iOS 16+ and macOS 13+ built with Swift Concurrency, AVFoundation, and NavigationSplitView.")
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
                        Image(systemName: "flag.fill").foregroundColor(.blue)
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
