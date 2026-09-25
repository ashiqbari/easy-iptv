//
//  IPTVPlayerManager.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 13+
//

import Foundation
import AVFoundation
import Combine
import SwiftUI
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// Available format engine override modes for troubleshooting video streaming
public enum StreamFormatOverride: String, CaseIterable, Sendable {
    case auto = "Auto (AVKit)"
    case mp4 = "MP4 Stream (.mp4)"
    case mkv = "MKV Format (.mkv)"
    case hls = "Apple HLS (.m3u8)"
    case ts = "Raw MPEG-TS (.ts)"
    
    public var title: String { rawValue }
}

#if os(macOS)
/// Thread-safe, nonisolated manager for macOS power assertion lifecycle.
/// Prevents display sleep and screen lock during video playback and ensures safe deinit.
private final class DisplaySleepManager: @unchecked Sendable {
    private var sleepAssertionID: IOPMAssertionID = 0
    private var isSleepDisabled: Bool = false
    private var playbackActivity: NSObjectProtocol?
    private let lock = NSLock()

    func enable() {
        lock.lock()
        defer { lock.unlock() }
        guard !isSleepDisabled else { return }
        let reason = "EasyIPTV Video Playback" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
        if result == kIOReturnSuccess {
            isSleepDisabled = true
        }
        if playbackActivity == nil {
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "EasyIPTV Active Video Stream"
            )
        }
    }

    func disable() {
        lock.lock()
        defer { lock.unlock() }
        if isSleepDisabled {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
            isSleepDisabled = false
        }
        if let activity = playbackActivity {
            ProcessInfo.processInfo.endActivity(activity)
            playbackActivity = nil
        }
    }

    deinit {
        disable()
    }
}
#endif

/// Central coordinator handling playlist fetching, channel categorization, search filtering,
/// persistent favorites management, and AVPlayer lifecycle.
@MainActor
public final class IPTVPlayerManager: ObservableObject {
    
    // MARK: - Published State
    
    /// The full list of parsed channels from the active playlist.
    @Published public private(set) var channels: [M3UItem] = []
    
    /// Precomputed dynamic list of categories for the selected section.
    @Published public private(set) var categories: [String] = ["All", "★ Favorites"]
    
    /// Precomputed category channel count lookup table [CategoryName: Count].
    @Published public private(set) var categoryCounts: [String: Int] = [:]
    
    /// Total favorites count for the active section.
    @Published public private(set) var favoritesCount: Int = 0
    
    /// Total channel count for the active section.
    @Published public private(set) var sectionTotalCount: Int = 0
    
    /// Precomputed filtered list of channels for instant rendering without UI lag.
    @Published public private(set) var filteredChannels: [M3UItem] = []
    
    /// The fundamental IPTV category section: Live TV, Movies, or TV Shows.
    @Published public var selectedSection: M3UItem.ContentType = .live {
        didSet {
            if oldValue != selectedSection {
                selectedCategory = "All"
                reindexCategoriesAndChannels()
                if selectedSection == .series {
                    if let firstSeries = filteredChannels.first {
                        fetchAndShowSeries(firstSeries)
                    }
                }
            }
        }
    }
    
    /// Currently selected category filter (defaults to "All").
    @Published public var selectedCategory: String = "All" {
        didSet {
            if oldValue != selectedCategory {
                updateFilteredChannelsOnly()
            }
        }
    }
    
    /// Current search query string.
    @Published public var searchText: String = "" {
        didSet {
            if oldValue != searchText {
                updateFilteredChannelsOnly()
            }
        }
    }
    
    /// The currently selected and playing channel.
    @Published public var currentChannel: M3UItem? = nil
    
    /// Indicates whether a network playlist download/parsing operation is running.
    @Published public var isLoading: Bool = false
    
    /// User-visible error message, if any occurred.
    @Published public var errorMessage: String? = nil
    
    /// Playback state indicator.
    @Published public var isPlaying: Bool = false {
        didSet {
            #if os(macOS)
            if isPlaying {
                enableDisplaySleepPrevention()
            } else {
                disableDisplaySleepPrevention()
            }
            #endif
        }
    }
    
    /// Stream buffer state indicator.
    @Published public var isBuffering: Bool = false
    
    /// The URL string of the loaded playlist.
    @Published public var playlistURLString: String = ""
    
    // MARK: - UI & Navigation State
    
    /// Navigation split view visibility state.
    @Published public var columnVisibility: NavigationSplitViewVisibility = .all
    
    /// Controls whether the playlist input modal is visible.
    @Published public var showingPlaylistSheet: Bool = false
    
    /// Tab index for Source Sheet (0: Xtream Codes, 1: M3U Playlist)
    @Published public var sourceTab: Int = 0
    
    /// Xtream Codes Form Draft State
    @Published public var xtreamServerURL: String = ""
    @Published public var xtreamUsername: String = ""
    @Published public var xtreamPassword: String = ""
    @Published public var isPasswordVisible: Bool = false
    
    /// Draft URL in the playlist input modal.
    @Published public var inputPlaylistURL: String = ""
    
    /// Controls whether the About modal is visible.
    @Published public var showingAboutSheet: Bool = false
    
    /// Controls whether playback HUD overlays are shown over the video.
    @Published public var showVideoControls: Bool = true
    
    /// Video gravity aspect fit / fill mode.
    @Published public var videoGravity: AVLayerVideoGravity = .resizeAspect
    
    /// Indicates whether the active video playback view is expanded to fullscreen.
    @Published public var isFullscreen: Bool = false
    
    /// Current playback progress in seconds for VOD (MP4 movies and TV shows).
    @Published public var currentTime: Double = 0.0
    
    /// Total duration in seconds for VOD media.
    @Published public var duration: Double = 0.0
    
    /// Flag indicating if the user is actively dragging the seek slider.
    @Published public var isSeeking: Bool = false
    
    /// Currently loaded episodes for a selected TV Series.
    @Published public var seriesEpisodes: [M3UItem] = []
    
    /// Currently selected season name (e.g. "Season 1", "Season 2").
    @Published public var selectedSeason: String = ""
    
    /// Unique list of season names present in `seriesEpisodes` in numeric sorted order.
    public var availableSeasons: [String] {
        let seasons = Set(seriesEpisodes.map { $0.groupTitle })
        let sorted = seasons.sorted { a, b in
            let numA = Int(a.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
            let numB = Int(b.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
            if numA != numB {
                return numA < numB
            }
            return a < b
        }
        return sorted.isEmpty ? ["Season 1"] : sorted
    }
    
    /// Filtered list of episodes belonging strictly to the selected season.
    public var filteredEpisodesForSelectedSeason: [M3UItem] {
        let seasons = availableSeasons
        let active = seasons.contains(selectedSeason) ? selectedSeason : (seasons.first ?? "Season 1")
        let matching = seriesEpisodes.filter { $0.groupTitle == active }
        if !matching.isEmpty {
            return matching
        }
        return seriesEpisodes
    }
    
    /// Selects an active season for the TV series overview.
    public func selectSeason(_ season: String) {
        self.selectedSeason = season
        self.episodeScrollIndex = 0
    }
    
    /// View mode for series episodes (false = horizontal scroll row with navigation arrows, true = full grid).
    @Published public var isSeriesGridView: Bool = false
    
    /// Current scroll target index for horizontal episode carousel navigation.
    @Published public var episodeScrollIndex: Int = 0
    
    /// Scrolls the episode row right to the next batch of episodes.
    public func scrollEpisodesNext() {
        let maxIndex = max(0, filteredEpisodesForSelectedSeason.count - 1)
        if episodeScrollIndex + 3 <= maxIndex {
            episodeScrollIndex += 3
        } else {
            episodeScrollIndex = maxIndex
        }
    }
    
    /// Scrolls the episode row left to the previous batch of episodes.
    public func scrollEpisodesPrev() {
        if episodeScrollIndex >= 3 {
            episodeScrollIndex -= 3
        } else {
            episodeScrollIndex = 0
        }
    }
    
    /// Flag indicating if episodes drawer is visible.
    @Published public var showingEpisodesDrawer: Bool = false
    
    /// Flag indicating if user is on the rich TV Series overview & episodes page.
    @Published public var isViewingSeriesDetails: Bool = false
    
    /// Loading indicator for series episode resolution.
    @Published public var isLoadingEpisodes: Bool = false
    
    /// Live TV Electronic Program Guide (EPG) modal sheet visibility.
    @Published public var showingEPGSheet: Bool = false
    
    /// Video playback format override engine for fixing stream container errors.
    @Published public var formatOverride: StreamFormatOverride = .auto
    
    private var controlsTimer: Task<Void, Never>? = nil
    private var timeObserverToken: Any? = nil
    
    // MARK: - Playback Properties
    
    /// The underlying native AVPlayer instance.
    @Published public private(set) var player: AVPlayer?
    
    // MARK: - Private Members
    
    private let parser = M3UParser()
    private let xtreamManager = XtreamCodesManager()
    private var cancellables = Set<AnyCancellable>()
    private var playerItemStatusObserver: NSKeyValueObservation?
    private var playerTimeControlObserver: NSKeyValueObservation?
    
    // UserDefaults Keys
    private let favoritesKey = "com.iptvplayer.favoriteStreamURLs"
    private let lastPlaylistKey = "com.iptvplayer.lastPlaylistURL"
    
    /// Persistent storage of favorite stream URLs.
    @Published private var favoriteStreamURLs: Set<String> = []
    
    #if os(macOS)
    private let sleepManager = DisplaySleepManager()
    
    /// Prevents macOS from locking the screen or sleeping the display while video is playing.
    public func enableDisplaySleepPrevention() {
        sleepManager.enable()
    }
    
    /// Re-enables normal macOS display sleep and screen lock behavior when playback pauses or stops.
    public func disableDisplaySleepPrevention() {
        sleepManager.disable()
    }
    #endif
    
    // MARK: - Initialization
    
    public init() {
        loadPersistedState()
        setupAudioSessionIfAvailable()
    }
    
    deinit {
        #if os(macOS)
        sleepManager.disable()
        #endif
        playerItemStatusObserver?.invalidate()
        playerTimeControlObserver?.invalidate()
    }
    
    // MARK: - Fast High-Performance Indexing & Filtering
    
    /// Re-indexes categories, computes counts in a single O(N) pass, and filters channels for the active section.
    public func reindexCategoriesAndChannels() {
        var counts: [String: Int] = [:]
        var groups = Set<String>()
        var favCount = 0
        var secTotal = 0
        
        for channel in channels where channel.contentType == selectedSection {
            secTotal += 1
            let grp = channel.displayGroup
            counts[grp, default: 0] += 1
            groups.insert(grp)
            if favoriteStreamURLs.contains(channel.streamURL.absoluteString) {
                favCount += 1
            }
        }
        
        let sortedGroups = groups.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        self.categories = ["All", "Favorites"] + sortedGroups
        self.categoryCounts = counts
        self.favoritesCount = favCount
        self.sectionTotalCount = secTotal
        
        updateFilteredChannelsOnly()
    }
    
    /// Instant 0ms filtering when switching category or typing search queries.
    public func updateFilteredChannelsOnly() {
        var result = channels.filter { $0.contentType == selectedSection }
        
        // 1. Category Filtering
        if selectedCategory == "Favorites" || selectedCategory == "★ Favorites" {
            result = result.filter { favoriteStreamURLs.contains($0.streamURL.absoluteString) }
        } else if selectedCategory != "All" {
            result = result.filter { $0.displayGroup == selectedCategory }
        }
        
        // 2. Search Text Filtering
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { item in
                item.name.localizedCaseInsensitiveContains(query) ||
                item.groupTitle.localizedCaseInsensitiveContains(query)
            }
        }
        
        self.filteredChannels = result
    }
    
    // MARK: - Playlist Loading
    
    /// Fetches and parses an M3U/M3U8 playlist from a web URL.
    /// - Parameter urlString: Remote HTTP/HTTPS URL string.
    public func loadPlaylist(from urlString: String) async {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            self.errorMessage = "Please enter a valid HTTP or HTTPS playlist URL."
            return
        }
        
        self.isLoading = true
        self.errorMessage = nil
        self.playlistURLString = urlString
        
        do {
            let parsedChannels = try await parser.parse(from: url)
            
            // Map favorites onto newly parsed channels
            self.channels = parsedChannels.map { item in
                var updated = item
                updated.isFavorite = self.favoriteStreamURLs.contains(item.streamURL.absoluteString)
                return updated
            }
            
            self.reindexCategoriesAndChannels()
            
            // Persist the successfully loaded playlist URL and cached channels to disk
            UserDefaults.standard.set(urlString, forKey: lastPlaylistKey)
            self.persistLoadedChannels()
            self.isLoading = false
            
            // Auto-play the first channel if none is currently selected
            if let first = self.filteredChannels.first ?? self.channels.first, self.currentChannel == nil {
                self.playChannel(first)
            }
        } catch {
            self.isLoading = false
            self.errorMessage = error.localizedDescription
        }
    }
    
    /// Connects to an Xtream Codes IPTV server, loads Live TV immediately, then loads VOD and Series in background.
    /// - Parameters:
    ///   - serverURL: Server base address (e.g. "http://domain.com:8080").
    ///   - username: User account username.
    ///   - password: User account password.
    public func loadXtream(serverURL: String, username: String, password: String) async {
        self.isLoading = true
        self.errorMessage = nil
        self.playlistURLString = "Xtream: \(username)"
        
        do {
            // Step 1: Immediately fetch Live Channels so user can watch without 30s delay
            let live = try await xtreamManager.fetchLiveChannels(serverURL: serverURL, username: username, password: password)
            let mappedLive = live.map { item in
                var updated = item
                updated.isFavorite = self.favoriteStreamURLs.contains(item.streamURL.absoluteString)
                return updated
            }
            
            self.channels = mappedLive
            self.selectedSection = .live
            self.selectedCategory = "All"
            self.reindexCategoriesAndChannels()
            self.persistLoadedChannels()
            
            // Save Xtream account info so user does not need to re-enter
            UserDefaults.standard.set([
                "server": serverURL,
                "username": username,
                "password": password
            ], forKey: "com.iptvplayer.savedXtream")
            
            self.isLoading = false
            
            if let first = self.filteredChannels.first ?? self.channels.first, self.currentChannel == nil {
                self.playChannel(first)
            }
            
            // Step 2: Concurrently fetch VOD movies and Series in background
            Task { [weak self] in
                guard let self = self else { return }
                async let movies = (try? self.xtreamManager.fetchVodStreams(serverURL: serverURL, username: username, password: password)) ?? []
                async let series = (try? self.xtreamManager.fetchSeries(serverURL: serverURL, username: username, password: password)) ?? []
                let additional = await (movies + series)
                if !additional.isEmpty {
                    let mappedAdditional = additional.map { item in
                        var updated = item
                        updated.isFavorite = self.favoriteStreamURLs.contains(item.streamURL.absoluteString)
                        return updated
                    }
                    self.channels.append(contentsOf: mappedAdditional)
                    self.reindexCategoriesAndChannels()
                    self.persistLoadedChannels()
                }
            }
        } catch {
            self.isLoading = false
            self.errorMessage = error.localizedDescription
        }
    }
    
    /// Loads sample public live HLS streams for immediate testing.
    public func loadSampleChannels() {
        self.channels = M3UItem.sampleItems.map { item in
            var updated = item
            updated.isFavorite = self.favoriteStreamURLs.contains(item.streamURL.absoluteString)
            return updated
        }
        self.reindexCategoriesAndChannels()
        self.playlistURLString = "Demo Public HLS Channels"
        
        if let first = self.filteredChannels.first ?? self.channels.first {
            self.playChannel(first)
        }
    }
    
    // MARK: - Playback Control
    
    /// Selects a channel or VOD item and begins hardware-accelerated playback.
    /// For TV Shows, it opens the rich Series Overview & Episodes browser first.
    /// - Parameter item: The target channel or show.
    public func playChannel(_ item: M3UItem) {
        if item.contentType == .series {
            fetchAndShowSeries(item)
            return
        }
        // Immediately reset and dismiss series episode options when switching to Live TV or Movies
        self.isViewingSeriesDetails = false
        self.seriesEpisodes = []
        self.showingEpisodesDrawer = false
        playDirectStream(item)
    }
    
    /// Plays an individual stream, movie, or resolved TV episode directly.
    public func playDirectStream(_ item: M3UItem) {
        self.currentChannel = item
        self.isViewingSeriesDetails = false
        if item.contentType != .series {
            self.seriesEpisodes = []
            self.showingEpisodesDrawer = false
        }
        self.errorMessage = nil
        self.isBuffering = true
        self.currentTime = 0.0
        self.duration = 0.0
        
        let asset = AVURLAsset(url: item.streamURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let playerItem = AVPlayerItem(asset: asset)
        
        if item.isVOD {
            playerItem.preferredForwardBufferDuration = 0 // Progressive buffering for MP4
        } else {
            playerItem.preferredForwardBufferDuration = 3.0 // Low-latency for Live TV
        }
        
        if let existingPlayer = self.player {
            existingPlayer.pause()
            existingPlayer.replaceCurrentItem(with: nil)
            existingPlayer.automaticallyWaitsToMinimizeStalling = true
            existingPlayer.replaceCurrentItem(with: playerItem)
            existingPlayer.rate = 1.0
        } else {
            let newPlayer = AVPlayer(playerItem: playerItem)
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            self.player = newPlayer
        }
        
        setupTimeObserver()
        observePlayerItem(playerItem)
        self.player?.play()
        self.isPlaying = true
    }
    
    /// Queries the Xtream server for a TV show's seasons and episodes,
    /// stops playback, and presents the rich Series Overview & Episodes grid first.
    public func fetchAndShowSeries(_ item: M3UItem) {
        self.currentChannel = item
        self.isViewingSeriesDetails = true
        
        // Stop any active video so that the rich Series Overview hero is visible immediately
        self.player?.pause()
        self.player?.replaceCurrentItem(with: nil)
        self.isPlaying = false
        self.isBuffering = false
        self.errorMessage = nil
        self.isLoadingEpisodes = true
        self.seriesEpisodes = []
        
        // Extract series ID from URL path (e.g. /series/user/pass/123.mp4)
        var seriesId = 0
        let urlStr = item.streamURL.absoluteString
        if let match = urlStr.range(of: #"/series/[^/]+/[^/]+/(\d+)"#, options: .regularExpression) {
            let sub = urlStr[match]
            if let lastSlash = sub.lastIndex(of: "/"), let parsed = Int(sub[sub.index(after: lastSlash)...]) {
                seriesId = parsed
            }
        }
        
        let server = self.xtreamServerURL
        let user = self.xtreamUsername
        let pass = self.xtreamPassword
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let eps = try await self.xtreamManager.fetchSeriesEpisodes(
                    serverURL: server,
                    username: user,
                    password: pass,
                    seriesId: seriesId
                )
                self.seriesEpisodes = eps
                self.isLoadingEpisodes = false
            } catch {
                self.isLoadingEpisodes = false
                if self.seriesEpisodes.isEmpty {
                    self.seriesEpisodes = [item]
                }
            }
        }
    }
    
    public func fetchAndPlaySeries(_ item: M3UItem) {
        fetchAndShowSeries(item)
    }
    
    /// Re-syncs and refreshes the current Xtream Codes server or M3U playlist to fetch updated channels.
    public func refreshPlaylist() async {
        if let saved = UserDefaults.standard.dictionary(forKey: "com.iptvplayer.savedXtream") as? [String: String],
           let server = saved["server"], let user = saved["username"], let pass = saved["password"], !server.isEmpty {
            await loadXtream(serverURL: server, username: user, password: pass)
        } else if let savedURL = UserDefaults.standard.string(forKey: lastPlaylistKey), !savedURL.isEmpty {
            await loadPlaylist(from: savedURL)
        }
    }
    
    /// Overrides video container format (.mp4, .mkv, .ts, .m3u8) to fix "Cannot Open" codec errors.
    public func applyFormatOverride(_ format: StreamFormatOverride) {
        self.formatOverride = format
        guard let current = currentChannel else { return }
        
        var newUrlString = current.streamURL.absoluteString
        switch format {
        case .mp4:
            newUrlString = newUrlString.replacingOccurrences(of: #"\.(mkv|avi|ts|m3u8)$"#, with: ".mp4", options: .regularExpression)
        case .mkv:
            newUrlString = newUrlString.replacingOccurrences(of: #"\.(mp4|avi|ts|m3u8)$"#, with: ".mkv", options: .regularExpression)
        case .hls:
            newUrlString = newUrlString.replacingOccurrences(of: #"\.(mp4|mkv|avi|ts)$"#, with: ".m3u8", options: .regularExpression)
        case .ts:
            newUrlString = newUrlString.replacingOccurrences(of: #"\.(mp4|mkv|avi|m3u8)$"#, with: ".ts", options: .regularExpression)
        case .auto:
            break
        }
        
        if let newURL = URL(string: newUrlString) {
            let updatedItem = M3UItem(
                id: current.id,
                name: current.name,
                groupTitle: current.groupTitle,
                logoURL: current.logoURL,
                streamURL: newURL,
                tvgID: current.tvgID,
                tvgName: current.tvgName,
                isFavorite: current.isFavorite,
                contentType: current.contentType
            )
            self.playDirectStream(updatedItem)
        }
    }
    
    /// Sets up a 0.5s periodic observer to track duration and progress for VOD MP4 media.
    private func setupTimeObserver() {
        removeTimeObserver()
        guard let pl = self.player else { return }
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = pl.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isSeeking else { return }
                let sec = time.seconds
                if sec.isFinite && sec >= 0 {
                    self.currentTime = sec
                }
                if let item = self.player?.currentItem {
                    let dur = item.duration.seconds
                    if dur.isFinite && dur > 0 {
                        self.duration = dur
                    }
                }
            }
        }
    }
    
    private func removeTimeObserver() {
        if let token = timeObserverToken, let pl = player {
            pl.removeTimeObserver(token)
        }
        timeObserverToken = nil
    }
    
    /// Seeks to a specific timestamp in seconds (for MP4 movies & shows).
    public func seek(to seconds: Double) {
        guard let player = self.player, seconds.isFinite else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        self.currentTime = seconds
    }
    
    /// Jumps forward or backward by a delta in seconds (e.g. +10s or -10s).
    public func seekBy(seconds: Double) {
        let maxDur = duration > 0 ? duration : 999999
        let target = max(0, min(maxDur, currentTime + seconds))
        seek(to: target)
    }
    
    /// Formatted current playback time string (e.g. "01:23:45" or "05:12").
    public var formattedCurrentTime: String {
        formatSeconds(currentTime)
    }
    
    /// Formatted total duration string (e.g. "02:15:30").
    public var formattedDuration: String {
        formatSeconds(duration)
    }
    
    private func formatSeconds(_ sec: Double) -> String {
        guard sec.isFinite && sec >= 0 else { return "00:00" }
        let total = Int(sec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
    
    /// Toggles full screen mode: on macOS toggles native window full screen and detail-only view.
    public func toggleFullscreen() {
        isFullscreen.toggle()
        #if os(macOS)
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            if isFullscreen {
                columnVisibility = .detailOnly
                window.toolbar?.isVisible = false
                window.titleVisibility = .hidden
                if !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            } else {
                columnVisibility = .all
                window.toolbar?.isVisible = true
                window.titleVisibility = .visible
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        }
        #else
        columnVisibility = isFullscreen ? .detailOnly : .all
        #endif
    }
    
    /// Toggles between play and pause.
    public func togglePlayPause() {
        guard let player = self.player else { return }
        if isPlaying {
            player.pause()
            self.isPlaying = false
        } else {
            player.play()
            self.isPlaying = true
        }
    }
    
    /// Stops playback and releases the current player item.
    public func stop() {
        #if os(macOS)
        disableDisplaySleepPrevention()
        #endif
        removeTimeObserver()
        self.player?.pause()
        self.player?.replaceCurrentItem(with: nil)
        self.isPlaying = false
        self.isBuffering = false
        self.currentChannel = nil
        self.seriesEpisodes = []
        self.showingEpisodesDrawer = false
        self.currentTime = 0.0
        self.duration = 0.0
    }
    
    /// Skips to the next channel in the current filtered list.
    public func nextChannel() {
        let list = filteredChannels
        guard !list.isEmpty, let current = currentChannel,
              let currentIndex = list.firstIndex(where: { $0.id == current.id }) else {
            if let first = list.first { playChannel(first) }
            return
        }
        
        let nextIndex = (currentIndex + 1) % list.count
        playChannel(list[nextIndex])
    }
    
    /// Skips to the previous channel in the current filtered list.
    public func previousChannel() {
        let list = filteredChannels
        guard !list.isEmpty, let current = currentChannel,
              let currentIndex = list.firstIndex(where: { $0.id == current.id }) else {
            if let last = list.last { playChannel(last) }
            return
        }
        
        let prevIndex = (currentIndex - 1 + list.count) % list.count
        playChannel(list[prevIndex])
    }
    
    /// Toggles visibility of the video player HUD overlay with auto-hide timer.
    public func toggleVideoControls() {
        showVideoControls.toggle()
        if showVideoControls {
            scheduleControlsAutoHide()
        } else {
            controlsTimer?.cancel()
        }
    }
    
    /// Schedules auto-hide of controls after 4 seconds of inactivity.
    public func scheduleControlsAutoHide() {
        controlsTimer?.cancel()
        controlsTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation {
                    self?.showVideoControls = false
                }
            }
        }
    }
    
    // MARK: - Favorites Management
    
    /// Toggles favorite status for a given channel and persists the updated set.
    public func toggleFavorite(_ item: M3UItem) {
        let streamString = item.streamURL.absoluteString
        if favoriteStreamURLs.contains(streamString) {
            favoriteStreamURLs.remove(streamString)
        } else {
            favoriteStreamURLs.insert(streamString)
        }
        
        // Sync favorite flag in channels array
        if let idx = channels.firstIndex(where: { $0.id == item.id }) {
            channels[idx].isFavorite = favoriteStreamURLs.contains(streamString)
        }
        
        // Update currentChannel if matching
        if currentChannel?.id == item.id {
            currentChannel?.isFavorite = favoriteStreamURLs.contains(streamString)
        }
        
        persistFavorites()
        reindexCategoriesAndChannels()
    }
    
    /// Checks if a channel is marked as favorite.
    public func isFavorite(_ item: M3UItem) -> Bool {
        return favoriteStreamURLs.contains(item.streamURL.absoluteString)
    }
    
    // MARK: - Private Observers & Helpers
    
    private func observePlayerItem(_ playerItem: AVPlayerItem) {
        playerItemStatusObserver?.invalidate()
        playerTimeControlObserver?.invalidate()
        
        // Observe status (readyToPlay, failed, unknown)
        playerItemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    self.isPlaying = true
                case .failed:
                    self.isBuffering = false
                    self.isPlaying = false
                    self.errorMessage = item.error?.localizedDescription ?? "Playback encountered an unexpected streaming error."
                case .unknown:
                    self.isBuffering = true
                @unknown default:
                    break
                }
            }
        }
        
        // Observe timeControlStatus (playing, paused, waitingToPlayAtSpecifiedRate)
        if let player = self.player {
            playerTimeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.isPlaying = pl.timeControlStatus == .playing
                    self.isBuffering = pl.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
        }
    }
    
    private func setupAudioSessionIfAvailable() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
        #endif
    }
    
    private var cachedChannelsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EasyIPTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("cached_channels.json")
    }
    
    private func persistLoadedChannels() {
        let currentChannels = self.channels
        let currentURLString = self.playlistURLString
        let url = cachedChannelsURL
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(currentChannels)
                try data.write(to: url, options: .atomic)
                UserDefaults.standard.set(currentURLString, forKey: "com.iptvplayer.lastPlaylistURL")
            } catch {
                print("Failed to save channels to disk: \(error)")
            }
        }
    }
    
    private func loadPersistedState() {
        if let savedFavorites = UserDefaults.standard.stringArray(forKey: favoritesKey) {
            self.favoriteStreamURLs = Set(savedFavorites)
        }
        if let lastURL = UserDefaults.standard.string(forKey: lastPlaylistKey), !lastURL.isEmpty {
            self.playlistURLString = lastURL
        }
        if let savedXtream = UserDefaults.standard.dictionary(forKey: "com.iptvplayer.savedXtream") as? [String: String] {
            self.xtreamServerURL = savedXtream["server"] ?? ""
            self.xtreamUsername = savedXtream["username"] ?? ""
            self.xtreamPassword = savedXtream["password"] ?? ""
        }
        
        // Restore cached channels from disk so user never loses their library across app exits
        let url = cachedChannelsURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let loaded = try JSONDecoder().decode([M3UItem].self, from: data)
                if !loaded.isEmpty {
                    self.channels = loaded.map { item in
                        var updated = item
                        updated.isFavorite = self.favoriteStreamURLs.contains(item.streamURL.absoluteString)
                        return updated
                    }
                    self.reindexCategoriesAndChannels()
                    if let first = self.filteredChannels.first ?? self.channels.first {
                        self.playChannel(first)
                    }
                }
            } catch {
                print("Could not load cached channels: \(error)")
            }
        }
    }
    
    /// Clears all loaded channels, resets player, and removes cached files from disk.
    public func clearAllData() {
        self.stop()
        self.channels = []
        self.currentChannel = nil
        self.playlistURLString = ""
        self.reindexCategoriesAndChannels()
        try? FileManager.default.removeItem(at: cachedChannelsURL)
        UserDefaults.standard.removeObject(forKey: lastPlaylistKey)
        UserDefaults.standard.removeObject(forKey: "com.iptvplayer.savedXtream")
    }
    
    private func persistFavorites() {
        UserDefaults.standard.set(Array(favoriteStreamURLs), forKey: favoritesKey)
    }
}
