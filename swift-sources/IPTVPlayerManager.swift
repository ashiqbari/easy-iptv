//
//  IPTVPlayerManager.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 15+
//

import Foundation
import AVFoundation
import Combine
import SwiftUI
#if os(macOS)
import VLC
#endif
#if os(macOS)
import IOKit.pwr_mgt
#endif

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
public final class IPTVPlayerManager: NSObject, ObservableObject {
    let subtitles = SubtitleController()
    let progressStore: PlaybackProgressStore
    @Published var showingResumeChoice = false
    @Published var resumeRequest: PlaybackResumeRequest? {
        didSet { showingResumeChoice = resumeRequest != nil }
    }
    private var seriesOverviewItem: M3UItem?
    private var pendingResumePosition: Double?
    private var vlcResumeSeekIssued = false
    private var resumeTimeoutTask: Task<Void, Never>?
    private var wantsPlayback = false
    private var playbackFinished = false
    private var lastProgressSave = Date.distantPast
    private var playbackEndObserver: NSObjectProtocol?
    private var visiblePlayerViews: Set<UUID> = []
    private let storageDefaults: UserDefaults
    private let libraryLoader: LibraryLoader
    let libraryPersistence: LibraryPersistence
    private var libraryGeneration = UUID()
    private var foregroundLibraryTask: Task<[M3UItem], Error>?
    private var backgroundLibraryTask: Task<Void, Never>?
    private var seriesLoadTask: Task<Void, Never>?
    private var seriesGeneration = UUID()
    
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
                stop()
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

    /// Uses VLC's broader codec and container support instead of AVPlayer on macOS.
    @Published public var useVLCPlayback: Bool = false
    
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
    // Desktop panes are independent; fullscreen temporarily hides navigation
    // without overwriting the user's choices for either pane.
    @Published public private(set) var showsCategoriesSidebar = true
    @Published public private(set) var showsChannelsSidebar = true

    public func toggleCategoriesSidebar() {
        guard !isFullscreen else { return }
        showsCategoriesSidebar.toggle()
    }

    public func toggleChannelsSidebar() {
        guard !isFullscreen else { return }
        showsChannelsSidebar.toggle()
    }
    
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
    @Published public var currentTime: Double = 0.0 {
        didSet { subtitles.updateTime(currentTime) }
    }
    
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
    @Published private(set) var seriesDetails: MediaDetails?
    @Published private(set) var seriesDetailsFailed = false
    @Published private(set) var isViewingMovieDetails = false
    @Published private(set) var movieOverviewItem: M3UItem?
    
    /// Loading indicator for series episode resolution.
    @Published public var isLoadingEpisodes: Bool = false
    
    /// Live TV Electronic Program Guide (EPG) modal sheet visibility.
    @Published public var showingEPGSheet: Bool = false
    
    private var controlsTimer: Task<Void, Never>? = nil
    private var timeObserverToken: Any? = nil
    
    // MARK: - Playback Properties
    
    /// The underlying native AVPlayer instance.
    @Published public private(set) var player: AVPlayer? {
        didSet { cleanupPlayer = player; cleanupAsset = player?.currentItem?.asset }
    }
    // Stored references are accessible from nonisolated deinit; Published's
    // computed accessors are MainActor-isolated on older Swift toolchains.
    private var cleanupPlayer: AVPlayer?
    private var cleanupAsset: AVAsset?

    /// Playback volume shared by AVPlayer and VLC (0.0 through 1.0).
    @Published public var playbackVolume: Float = UserDefaults.standard.object(forKey: "com.iptvplayer.playbackVolume") == nil
        ? 0.8
        : UserDefaults.standard.float(forKey: "com.iptvplayer.playbackVolume") {
        didSet { applyPlaybackVolume() }
    }

    #if os(macOS)
    /// VLC playback instance used for streams AVPlayer cannot decode.
    @Published public private(set) var vlcPlayer: VLCMediaPlayer? {
        didSet { cleanupVLCPlayer = vlcPlayer }
    }
    private var cleanupVLCPlayer: VLCMediaPlayer?
    #endif
    
    // MARK: - Private Members
    
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
    
    public override init() {
        progressStore = PlaybackProgressStore()
        storageDefaults = .standard
        libraryLoader = LibraryLoader()
        libraryPersistence = LibraryPersistence(url: Self.defaultCacheURL, defaults: .standard)
        super.init()
        observeProgress()
        loadPersistedState()
        setupAudioSessionIfAvailable()
    }

    /// Isolated storage and no automatic playlist playback for lifecycle tests.
    init(progressDefaults: UserDefaults, libraryLoader: LibraryLoader = LibraryLoader(), cacheURL: URL? = nil) {
        progressStore = PlaybackProgressStore(defaults: progressDefaults)
        storageDefaults = progressDefaults
        self.libraryLoader = libraryLoader
        libraryPersistence = LibraryPersistence(url: cacheURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyIPTVTests-\(UUID())/cached_channels.json"), defaults: progressDefaults)
        super.init()
        observeProgress()
    }

    private func observeProgress() {
        progressStore.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }
    
    deinit {
        foregroundLibraryTask?.cancel()
        backgroundLibraryTask?.cancel()
        seriesLoadTask?.cancel()
        controlsTimer?.cancel()
        resumeTimeoutTask?.cancel()
        libraryPersistence.invalidatePendingWrites()
        cleanupPlayer?.pause()
        cleanupPlayer?.currentItem?.cancelPendingSeeks()
        cleanupAsset?.cancelLoading()
        if let token = timeObserverToken { cleanupPlayer?.removeTimeObserver(token) }
        cleanupPlayer?.replaceCurrentItem(with: nil)
        #if os(macOS)
        if let vlcPlayer = cleanupVLCPlayer {
            Task { @MainActor in VLCPlaybackRetirement.shared.retire(vlcPlayer) }
        }
        sleepManager.disable()
        #endif
        playerItemStatusObserver?.invalidate()
        playerTimeControlObserver?.invalidate()
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
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

    private func beginLibraryLoad() -> UUID {
        foregroundLibraryTask?.cancel()
        backgroundLibraryTask?.cancel()
        libraryPersistence.invalidatePendingWrites()
        libraryGeneration = UUID()
        return libraryGeneration
    }

    private func acceptLibraryResponse(_ generation: UUID) -> Bool {
        guard libraryGeneration == generation else { return false }
        foregroundLibraryTask = nil
        guard !Task.isCancelled else { isLoading = false; return false }
        return true
    }
    
    /// Fetches and parses an M3U/M3U8 playlist from a web URL.
    /// - Parameter urlString: Remote HTTP/HTTPS URL string.
    public func loadPlaylist(from urlString: String) async {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            self.errorMessage = "Please enter a valid HTTP or HTTPS playlist URL."
            return
        }
        
        let generation = beginLibraryLoad()
        let loader = libraryLoader
        let task = Task { try await loader.playlist(url) }
        foregroundLibraryTask = task
        self.isLoading = true
        self.errorMessage = nil
        self.playlistURLString = urlString
        
        do {
            let parsedChannels = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard acceptLibraryResponse(generation) else { return }
            
            // Map favorites onto newly parsed channels
            self.channels = parsedChannels.map { item in
                var updated = item
                updated.isFavorite = self.favoriteStreamURLs.contains(item.streamURL.absoluteString)
                return updated
            }
            
            self.reindexCategoriesAndChannels()
            
            // Persist the successfully loaded playlist URL and cached channels to disk
            storageDefaults.set(urlString, forKey: lastPlaylistKey)
            self.persistLoadedChannels()
            self.isLoading = false
            
            // Auto-play the first channel if none is currently selected
            if let first = self.filteredChannels.first ?? self.channels.first, self.currentChannel == nil {
                self.playChannel(first)
            }
        } catch {
            guard acceptLibraryResponse(generation) else { return }
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
        let generation = beginLibraryLoad()
        let loader = libraryLoader
        let task = Task { try await loader.live(serverURL, username, password) }
        foregroundLibraryTask = task
        self.isLoading = true
        self.errorMessage = nil
        self.playlistURLString = "Xtream: \(username)"
        
        do {
            // Step 1: Immediately fetch Live Channels so user can watch without 30s delay
            let live = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard acceptLibraryResponse(generation) else { return }
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
            storageDefaults.set([
                "server": serverURL,
                "username": username,
                "password": password
            ], forKey: "com.iptvplayer.savedXtream")
            
            self.isLoading = false
            
            if let first = self.filteredChannels.first ?? self.channels.first, self.currentChannel == nil {
                self.playChannel(first)
            }
            
            // Step 2: Concurrently fetch VOD movies and Series in background
            backgroundLibraryTask = Task { [weak self] in
                async let movies = (try? loader.movies(serverURL, username, password)) ?? []
                async let series = (try? loader.series(serverURL, username, password)) ?? []
                let additional = await (movies + series)
                guard let self, !Task.isCancelled, self.libraryGeneration == generation else { return }
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
                self.backgroundLibraryTask = nil
            }
        } catch {
            guard acceptLibraryResponse(generation) else { return }
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
    
    /// Opens movie/series details, or begins playback for a live channel.
    /// - Parameter item: The target channel or show.
    public func playChannel(_ item: M3UItem) {
        if item.contentType == .movie {
            showMovieDetails(item)
            return
        }
        if item.contentType == .series {
            fetchAndShowSeries(item)
            return
        }
        // Reset series options when switching to Live TV.
        seriesOverviewItem = nil
        self.isViewingSeriesDetails = false
        self.seriesEpisodes = []
        self.showingEpisodesDrawer = false
        playDirectStream(item)
    }

    func showMovieDetails(_ item: M3UItem) {
        stop()
        movieOverviewItem = item
        currentChannel = item
        isViewingMovieDetails = true
    }

    func playMovie(startOver: Bool = false) {
        guard let item = movieOverviewItem else { return }
        if startOver { progressStore.clear(item) }
        continueWatching(item)
        showVideoControls = true
        scheduleControlsAutoHide()
    }

    func returnToMovie() {
        guard let item = movieOverviewItem ?? currentChannel, item.contentType == .movie else { return }
        tearDownPlayback()
        resumeRequest = nil
        currentChannel = item
        movieOverviewItem = item
        isViewingMovieDetails = true
        showVideoControls = true
    }
    
    /// Plays an individual stream, movie, or resolved TV episode directly.
    public func playDirectStream(_ item: M3UItem) {
        #if os(macOS)
        requestPlayback(item, useVLC: item.contentType == .live)
        #else
        requestPlayback(item, useVLC: false)
        #endif
    }

    private func requestPlayback(_ item: M3UItem, useVLC: Bool) {
        tearDownPlayback(nextItem: item)
        resumeRequest = nil
        if item.isVOD, let position = progressStore.progress(for: item)?.resumePosition {
            resumeRequest = PlaybackResumeRequest(item: item, position: position, useVLC: useVLC)
        } else {
            playDirectStream(item, useVLC: useVLC)
        }
    }

    func resolveResume(_ request: PlaybackResumeRequest, startOver: Bool) {
        guard resumeRequest?.id == request.id else { return }
        resumeRequest = nil
        if startOver { progressStore.clear(request.item) }
        playDirectStream(request.item, useVLC: request.useVLC, position: startOver ? nil : request.position)
    }

    func cancelResume() { resumeRequest = nil }

    var continueWatchingEpisode: M3UItem? {
        seriesEpisodes.filter { progressStore.progress(for: $0)?.resumePosition != nil }
            .max { (progressStore.progress(for: $0)?.updatedAt ?? .distantPast) < (progressStore.progress(for: $1)?.updatedAt ?? .distantPast) }
    }

    func continueWatching(_ item: M3UItem) {
        let position = progressStore.progress(for: item)?.resumePosition
        playDirectStream(item, useVLC: false, position: position)
    }

    #if os(macOS)
    /// Retries the selected stream explicitly with AVKit, even when it is a live channel.
    public func playDirectStreamWithAVKit(_ item: M3UItem) {
        let position = currentChannel?.subtitleCacheKey == item.subtitleCacheKey ? (pendingResumePosition ?? playbackPosition()) : nil
        playDirectStream(item, useVLC: false, position: position)
    }
    #endif

    private func playDirectStream(_ item: M3UItem, useVLC: Bool, position: Double? = nil) {
        tearDownPlayback(nextItem: item)
        resumeRequest = nil
        pendingResumePosition = position.flatMap { $0 > 0 ? $0 : nil }
        wantsPlayback = true
        playbackFinished = false
        if position == nil, progressStore.progress(for: item)?.completed == true { progressStore.clear(item) }
        lastProgressSave = Date()
        subtitles.reset(for: item.isVOD ? item : nil)
        #if os(macOS)
        stopVLCPlayback()
        #endif
        self.currentChannel = item
        self.isViewingSeriesDetails = false
        self.isViewingMovieDetails = false
        movieOverviewItem = item.contentType == .movie ? item : nil
        self.useVLCPlayback = false
        if item.contentType != .series {
            self.seriesEpisodes = []
            self.showingEpisodesDrawer = false
        }
        self.errorMessage = nil
        self.isBuffering = true
        self.currentTime = 0.0
        self.duration = 0.0

        #if os(macOS)
        if useVLC {
            startVLCPlayback(for: item)
            return
        }
        #endif
        
        let asset = AVURLAsset(url: item.streamURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let playerItem = AVPlayerItem(asset: asset)
        if item.isVOD {
            subtitles.configure(item: playerItem, provider: subtitleProvider(for: item))
        }
        
        if item.isVOD {
            playerItem.preferredForwardBufferDuration = 0 // Progressive buffering for MP4
        } else {
            playerItem.preferredForwardBufferDuration = 3.0 // Low-latency for Live TV
        }
        
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        self.player = newPlayer
        self.player?.volume = playbackVolume
        
        setupTimeObserver()
        observePlayerItem(playerItem)
        if pendingResumePosition == nil { self.player?.play() }
        self.isPlaying = pendingResumePosition == nil
    }

    #if os(macOS)
    /// Switches the selected stream to VLC's in-app playback engine.
    public func playCurrentStreamWithVLC() {
        guard let currentChannel, !isViewingSeriesDetails, resumeRequest == nil else { return }
        let position = pendingResumePosition ?? playbackPosition()
        playDirectStream(currentChannel, useVLC: true, position: position)
    }

    private func startVLCPlayback(for item: M3UItem) {
        subtitles.reset(for: item.isVOD ? item : nil)
        stopVLCPlayback()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removeTimeObserver()
        playerItemStatusObserver?.invalidate()
        playerTimeControlObserver?.invalidate()
        let vlc = VLCMediaPlayer()
        vlc.delegate = self
        vlc.media = VLCMedia(url: item.streamURL)
        vlcPlayer = vlc
        if item.isVOD {
            subtitles.configure(player: vlc, provider: subtitleProvider(for: item))
        }
        vlc.audio?.volume = pendingResumePosition == nil ? Int32((playbackVolume * 100).rounded()) : 0
        useVLCPlayback = true
        errorMessage = nil
        isBuffering = true
        isPlaying = false
        if pendingResumePosition != nil {
            resumeTimeoutTask = Task { @MainActor [weak self, weak vlc] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, let vlc, self.vlcPlayer === vlc,
                      self.pendingResumePosition != nil else { return }
                self.wantsPlayback = false
                vlc.pause()
                vlc.audio?.volume = Int32((self.playbackVolume * 100).rounded())
                self.isPlaying = false
                self.isBuffering = false
                self.errorMessage = "This stream could not seek to the saved position. Reopen it and choose Start over."
            }
        }
    }

    private func stopVLCPlayback() {
        guard let previous = vlcPlayer else {
            useVLCPlayback = false
            return
        }
        VLCPlaybackRetirement.shared.retire(previous)
        vlcPlayer = nil
        useVLCPlayback = false
    }
    #endif
    
    /// Queries the Xtream server for a TV show's seasons and episodes,
    /// stops playback, and presents the rich Series Overview & Episodes grid first.
    public func fetchAndShowSeries(_ item: M3UItem) {
        movieOverviewItem = nil
        isViewingMovieDetails = false
        seriesLoadTask?.cancel()
        seriesGeneration = UUID()
        let generation = seriesGeneration
        tearDownPlayback()
        resumeRequest = nil
        seriesOverviewItem = item
        subtitles.reset(for: nil)
        self.currentChannel = item
        self.isViewingSeriesDetails = true
        self.isSeriesGridView = true
        self.errorMessage = nil
        self.isLoadingEpisodes = true
        self.seriesEpisodes = []
        seriesDetails = nil
        seriesDetailsFailed = false
        let loadDetails = libraryLoader.seriesDetails
        seriesLoadTask = Task { [weak self] in
            do {
                let result = try await loadDetails(item)
                guard let self, !Task.isCancelled, self.seriesGeneration == generation,
                      self.seriesOverviewItem?.id == item.id else { return }
                self.seriesEpisodes = result.episodes
                self.seriesDetails = result.details
                self.isLoadingEpisodes = false
            } catch {
                guard let self, !Task.isCancelled, self.seriesGeneration == generation,
                      self.seriesOverviewItem?.id == item.id else { return }
                self.isLoadingEpisodes = false
                self.seriesDetailsFailed = true
            }
            guard let self, self.seriesGeneration == generation else { return }
            self.seriesLoadTask = nil
        }
    }
    
    public func fetchAndPlaySeries(_ item: M3UItem) {
        fetchAndShowSeries(item)
    }

    /// Every route back to the episode browser uses the same engine-independent exit.
    public func returnToSeries() {
        let overview = seriesOverviewItem ?? currentChannel
        tearDownPlayback()
        resumeRequest = nil
        currentChannel = overview
        isViewingSeriesDetails = true
        showingEpisodesDrawer = false
        showVideoControls = true
    }

    private func playbackPosition() -> Double {
        #if os(macOS)
        if let vlcPlayer, useVLCPlayback { return max(0, Double(vlcPlayer.time.intValue) / 1000) }
        #endif
        let seconds = player?.currentTime().seconds ?? currentTime
        return seconds.isFinite ? max(0, seconds) : currentTime
    }

    private func saveProgress(force: Bool = false, completed: Bool = false) {
        guard let item = currentChannel, item.isVOD, !isViewingSeriesDetails,
              pendingResumePosition == nil, player?.currentItem != nil || useVLCPlayback else { return }
        guard force || Date().timeIntervalSince(lastProgressSave) >= 5 else { return }
        lastProgressSave = Date()
        let position = playbackPosition()
        let itemDuration = player?.currentItem?.duration.seconds ?? 0
        let total = itemDuration.isFinite && itemDuration > 0 ? itemDuration : duration
        progressStore.save(item: item, position: position, duration: total, completed: completed || playbackFinished)
    }

    /// Saves the actual engine clock before destroying its item and observers.
    private func tearDownPlayback(nextItem: M3UItem? = nil) {
        saveProgress(force: true)
        wantsPlayback = false
        pendingResumePosition = nil
        vlcResumeSeekIssued = false
        resumeTimeoutTask?.cancel()
        resumeTimeoutTask = nil
        controlsTimer?.cancel()
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        player?.currentItem?.asset.cancelLoading()
        removeTimeObserver()
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        playerTimeControlObserver?.invalidate()
        playerTimeControlObserver = nil
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        playbackEndObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        subtitles.reset(for: nextItem?.isVOD == true ? nextItem : nil)
        #if os(macOS)
        stopVLCPlayback()
        #endif
        isPlaying = false
        isBuffering = false
        currentTime = 0
        duration = 0
    }

    /// Explicitly hiding/backgrounding the app pauses without discarding the surface.
    func pauseForBackground() {
        saveProgress(force: true)
        wantsPlayback = false
        player?.pause()
        #if os(macOS)
        vlcPlayer?.pause()
        #endif
        isPlaying = false
        isBuffering = false
    }

    func playerViewAppeared(_ identity: UUID) { visiblePlayerViews.insert(identity) }

    func playerViewDisappeared(_ identity: UUID) {
        visiblePlayerViews.remove(identity)
        // SwiftUI can briefly replace a host during fullscreen/navigation layout.
        // Wait one run-loop turn so a replacement can claim the same player.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.visiblePlayerViews.isEmpty else { return }
            self.stop()
        }
    }
    
    /// Re-syncs and refreshes the current Xtream Codes server or M3U playlist to fetch updated channels.
    public func refreshPlaylist() async {
        if let saved = storageDefaults.dictionary(forKey: "com.iptvplayer.savedXtream") as? [String: String],
           let server = saved["server"], let user = saved["username"], let pass = saved["password"], !server.isEmpty {
            await loadXtream(serverURL: server, username: user, password: pass)
        } else if let savedURL = storageDefaults.string(forKey: lastPlaylistKey), !savedURL.isEmpty {
            await loadPlaylist(from: savedURL)
        }
    }
    
    /// Tracks the media clock at 100 ms intervals for progress and sidecar subtitles.
    private func setupTimeObserver() {
        removeTimeObserver()
        guard let pl = self.player, let observedItem = pl.currentItem else { return }
        
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = pl.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak pl] time in
            Task { @MainActor [weak self, weak pl] in
                guard let self = self, let pl, !self.isSeeking, !self.useVLCPlayback,
                      self.player === pl, pl.currentItem === observedItem else { return }
                let sec = time.seconds
                if sec.isFinite && sec >= 0 {
                    self.currentTime = sec
                }
                self.saveProgress()
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
        guard seconds.isFinite, pendingResumePosition == nil, !isViewingSeriesDetails else { return }
        playbackFinished = false
        subtitles.clearForSeek()
        #if os(macOS)
        if useVLCPlayback, let vlcPlayer {
            vlcPlayer.time = VLCTime(int: Int32(max(0, min(seconds * 1000, Double(Int32.max)))))
            currentTime = seconds
            return
        }
        #endif
        guard let player = self.player else { return }
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
        #if os(macOS)
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
            let enteringFullscreen = !window.styleMask.contains(.fullScreen)
            if enteringFullscreen {
                isFullscreen = true
                columnVisibility = .detailOnly
                window.toolbar?.isVisible = false
                window.titleVisibility = .hidden
            }
            window.toggleFullScreen(nil)
        }
        #else
        isFullscreen.toggle()
        columnVisibility = isFullscreen ? .detailOnly : .all
        #endif
    }

    #if os(macOS)
    /// Keeps SwiftUI's fullscreen state aligned with the native window transition.
    public func updateFullscreenState(_ isFullscreen: Bool) {
        self.isFullscreen = isFullscreen
        columnVisibility = isFullscreen ? .detailOnly : .all
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else { return }
        window.toolbar?.isVisible = !isFullscreen
        window.titleVisibility = isFullscreen ? .hidden : .visible
    }
    #endif

    private func applyPlaybackVolume() {
        storageDefaults.set(playbackVolume, forKey: "com.iptvplayer.playbackVolume")
        player?.volume = playbackVolume
        #if os(macOS)
        vlcPlayer?.audio?.volume = pendingResumePosition == nil ? Int32((playbackVolume * 100).rounded()) : 0
        #endif
    }
    
    /// Toggles between play and pause.
    public func togglePlayPause() {
        guard !isViewingSeriesDetails, resumeRequest == nil, pendingResumePosition == nil,
              currentChannel != nil else { return }
        wantsPlayback = !isPlaying
        if wantsPlayback { playbackFinished = false }
        if !wantsPlayback { saveProgress(force: true) }
        #if os(macOS)
        if useVLCPlayback, let vlcPlayer {
            if isPlaying {
                vlcPlayer.pause()
            } else {
                vlcPlayer.play()
            }
            return
        }
        #endif
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
        seriesLoadTask?.cancel()
        seriesLoadTask = nil
        seriesGeneration = UUID()
        isLoadingEpisodes = false
        tearDownPlayback()
        resumeRequest = nil
        seriesOverviewItem = nil
        seriesDetails = nil
        seriesDetailsFailed = false
        movieOverviewItem = nil
        isViewingMovieDetails = false
        self.currentChannel = nil
        self.seriesEpisodes = []
        self.showingEpisodesDrawer = false
        self.isViewingSeriesDetails = false
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
        guard !subtitles.showingMenu else { return }
        controlsTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled, self?.subtitles.showingMenu != true {
                withAnimation {
                    self?.showVideoControls = false
                }
            }
        }
    }

    /// Keeps the playback HUD visible while the user is dragging a control slider.
    public func cancelControlsAutoHide() {
        controlsTimer?.cancel()
        controlsTimer = nil
    }

    private func subtitleProvider(for item: M3UItem) -> () async throws -> [SubtitleSource] {
        let service = xtreamManager
        return {
            try await service.fetchSubtitleSources(for: item)
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
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                    object: playerItem, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === playerItem, !self.useVLCPlayback else { return }
                self.saveProgress(force: true, completed: true)
                self.playbackFinished = true
                self.wantsPlayback = false
                self.isPlaying = false
            }
        }
        
        // Observe status (readyToPlay, failed, unknown)
        playerItemStatusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.useVLCPlayback, self.player?.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    if let position = self.pendingResumePosition, let player = self.player {
                        let total = item.duration.seconds
                        let target = total.isFinite && total > 0 ? min(position, total) : position
                        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                            Task { @MainActor [weak self] in
                                guard let self, self.player === player, player.currentItem === item,
                                      !self.useVLCPlayback else { return }
                                if finished {
                                    self.pendingResumePosition = nil
                                    if self.wantsPlayback { player.play() }
                                } else {
                                    // Preserve the bookmark on a failed seek; don't
                                    // overwrite it with zero during subsequent teardown.
                                    self.wantsPlayback = false
                                    self.isPlaying = false
                                    player.pause()
                                    self.errorMessage = "Could not resume at the saved position. Reopen the item and choose Start over."
                                }
                            }
                        }
                    } else if self.wantsPlayback { self.player?.play() }
                    self.subtitles.loadTracksIfNeeded()
                case .failed:
#if os(macOS)
                    if !self.useVLCPlayback, self.currentChannel != nil {
                        self.playCurrentStreamWithVLC()
                        return
                    }
#endif
                    self.isBuffering = false
                    self.isPlaying = false
                    self.errorMessage = Self.playbackErrorDescription(for: item)
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
                Task { @MainActor [weak self] in
                    guard let self = self, !self.useVLCPlayback, self.player === pl,
                          pl.currentItem === playerItem else { return }
                    self.isPlaying = self.wantsPlayback && pl.timeControlStatus == .playing
                    self.isBuffering = self.wantsPlayback && pl.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
        }
    }

    private static func playbackErrorDescription(for item: AVPlayerItem) -> String {
        guard let error = item.error as NSError? else {
            return "Playback failed before AVPlayer could decode the stream."
        }

        var details = error.localizedDescription
        if let reason = error.localizedFailureReason, !reason.isEmpty {
            details += " — \(reason)"
        }
        details += " [\(error.domain) \(error.code)]"

        if let event = item.errorLog()?.events.last {
            let domain = event.errorDomain.isEmpty ? "stream" : event.errorDomain
            details += "\nStream: \(domain) \(event.errorStatusCode)"
        }
        return details
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
    
    private static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EasyIPTV/cached_channels.json")
    }

    private var cachedChannelsURL: URL { libraryPersistence.url }
    
    private func persistLoadedChannels() {
        libraryPersistence.save(channels: channels, source: playlistURLString)
    }
    
    private func loadPersistedState() {
        if let savedFavorites = storageDefaults.stringArray(forKey: favoritesKey) {
            self.favoriteStreamURLs = Set(savedFavorites)
        }
        if let lastURL = storageDefaults.string(forKey: lastPlaylistKey), !lastURL.isEmpty {
            self.playlistURLString = lastURL
        }
        if let savedXtream = storageDefaults.dictionary(forKey: "com.iptvplayer.savedXtream") as? [String: String] {
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
        _ = beginLibraryLoad()
        foregroundLibraryTask = nil
        backgroundLibraryTask = nil
        isLoading = false
        self.stop()
        self.channels = []
        self.currentChannel = nil
        self.playlistURLString = ""
        self.reindexCategoriesAndChannels()
        libraryPersistence.clear()
        storageDefaults.removeObject(forKey: "com.iptvplayer.savedXtream")
    }
    
    private func persistFavorites() {
        storageDefaults.set(Array(favoriteStreamURLs), forKey: favoritesKey)
    }
}

#if os(macOS)
extension IPTVPlayerManager: VLCMediaPlayerDelegate {
    private func applyPendingVLCResume(_ player: VLCMediaPlayer) {
        guard let position = pendingResumePosition else { return }
        if vlcResumeSeekIssued {
            // libvlc's set_time is asynchronous: don't save zero or unmute until
            // the engine reports that the requested position actually took effect.
            guard abs(Double(player.time.intValue) / 1000 - position) < 2 else { return }
            pendingResumePosition = nil
            resumeTimeoutTask?.cancel()
            resumeTimeoutTask = nil
            player.audio?.volume = Int32((playbackVolume * 100).rounded())
            if !wantsPlayback { player.pause() }
        } else if player.isSeekable, player.media?.length.intValue ?? 0 > 0 {
            vlcResumeSeekIssued = true
            player.time = VLCTime(int: Int32(max(0, min(position * 1000, Double(Int32.max)))))
            currentTime = position
        }
    }

    nonisolated public func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer else { return }
        let state = player.state
        let playing = player.isPlaying
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.vlcPlayer === player else { return }
            self.isPlaying = self.wantsPlayback && playing
            self.isBuffering = self.wantsPlayback && (state == .opening || (state == .buffering && !playing))
            if state == .error {
                self.isBuffering = false
                self.errorMessage = "VLC could not play this stream. Check the stream URL or try another channel."
            } else if state == .playing {
                self.applyPendingVLCResume(player)
                if !self.wantsPlayback { player.pause() }
                self.errorMessage = nil
                self.subtitles.nativePlayerDidStart()
            } else if state == .ended {
                self.saveProgress(force: true, completed: true)
                self.playbackFinished = true
                self.wantsPlayback = false
            }
        }
    }

    nonisolated public func mediaPlayerTimeChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer else { return }
        let current = Double(player.time.intValue) / 1000
        let total = Double(player.media?.length.intValue ?? 0) / 1000
        Task { @MainActor [weak self] in
            guard let self, self.vlcPlayer === player, !self.isSeeking else { return }
            if current.isFinite && current >= 0 { self.currentTime = current }
            if total.isFinite && total > 0 { self.duration = total }
            self.applyPendingVLCResume(player)
            self.saveProgress()
        }
    }
}
#endif
