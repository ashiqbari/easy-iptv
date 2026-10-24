//
//  IPTVPlayerManager.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 15+
//

import Foundation
import AVFoundation
import Combine
import MediaPlayer
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
    let pictureInPicture = PictureInPictureCoordinator()
    @Published var autoPictureInPicture = true {
        didSet {
            storageDefaults.set(autoPictureInPicture, forKey: "com.iptvplayer.autoPictureInPicture")
            pictureInPicture.update()
        }
    }
    var isPlayerDestinationVisible: Bool {
        (!showingDashboard || isFullscreen) && !isViewingMovieDetails && !isViewingSeriesDetails
    }
    var canPresentPictureInPicture: Bool {
        currentChannel != nil && (player?.currentItem != nil || useVLCPlayback)
            && resumeRequest == nil && pendingResumePosition == nil && !playbackFinished && errorMessage == nil
    }

    private(set) var libraryNavigationTargetID: UUID?
    @Published private(set) var libraryNavigationRequest = UUID()

    private func revealLibraryItem(_ item: M3UItem) {
        let target = libraryItemsByKey[PlaybackProgressStore.key(for: item)] ?? item
        selectedSection = target.contentType
        searchText = ""
        categorySearchText = ""
        favoritesOnly = false
        recentlyAddedOnly = false
        minimumRating = 0
        selectedCategory = categories.contains(target.displayGroup) ? target.displayGroup : "All"
        showingDashboard = false
        libraryNavigationTargetID = target.id
        libraryNavigationRequest = UUID()
    }

    func openDashboardItem(_ item: M3UItem, resume: Bool = false) {
        if isCurrentPlayback(item), player?.currentItem != nil || useVLCPlayback {
            pictureInPicture.restorePlayer()
            return
        }
        revealLibraryItem(item)
        if resume { playRecentlyWatched(item, resumeSeries: true) }
        else { playChannel(item) }
    }

    func returnToPlayerFromPictureInPicture() {
        showingDashboard = false
        showingGuideSearch = false
        showingDownloads = false
        showingSources = false
        showingOrganization = false
        showingPlaylistSheet = false
        showingAboutSheet = false
        showingSubscriptionInfo = false
        showingEPGSheet = false
        catchupChannel = nil
        let target = currentChannel?.contentType == .series ? (playingSeries?.item ?? currentChannel) : currentChannel
        dismissDetails()
        if let target { revealLibraryItem(target) }
        #if os(macOS)
        pictureInPicture.activatePlayerWindow()
        #endif
        pictureInPicture.reconcile()
    }

    let subtitles = SubtitleController()
    let audioTracks = AudioTrackController()
    let sources: SavedSourceStore
    @Published var showingSources = false { didSet { pictureInPicture.update() } }
    @Published var showingOrganization = false { didSet { pictureInPicture.update() } }
    @Published var catchupChannel: M3UItem? { didSet { pictureInPicture.update() } }
    @Published private(set) var catchupOrigin: M3UItem?
    @Published var organization = ChannelOrganization() {
        didSet {
            if let data = try? JSONEncoder().encode(organization) { storageDefaults.set(data, forKey: "com.iptvplayer.organization.v1") }
            rebuildDashboard()
            reindexCategoriesAndChannels()
        }
    }
    @Published private(set) var recoveryMessage: String?
    private var recoveryTask: Task<Void, Never>?
    var isWaitingToReconnect: Bool { recoveryTask != nil }
    private var stallTask: Task<Void, Never>?
    private var stablePlaybackTask: Task<Void, Never>?
    private var playbackGeneration = UUID()
    private(set) var recoveryAttempts = 0
    let progressStore: PlaybackProgressStore
    let recentlyWatchedStore: RecentlyWatchedStore
    let guideIndex = GuideSearchIndex()
    lazy var guideSearchModel: GuideSearchModel = {
        let model = GuideSearchModel(index: guideIndex) { [weak self] in self?.guideRevision = $0 }
        $channels.sink { [weak model] in model?.setChannels($0) }.store(in: &cancellables)
        $guideRevision.dropFirst().sink { [weak model] revision in
            guard let model, revision != model.refreshID else { return }
            model.refresh()
        }.store(in: &cancellables)
        return model
    }()
    @Published var guideRevision = UUID()
    private var libraryItemsByKey: [String: M3UItem] = [:]
    private var visibleChannelIDs: Set<UUID> = []
    private var channelKeysByID: [UUID: String] = [:]
    private var librarySearchTextByID: [UUID: String] = [:]
    private var sectionsWithCatalogDates: Set<M3UItem.ContentType> = []
    private var sectionsWithRatings: Set<M3UItem.ContentType> = []
    var hasCatalogDates: Bool { sectionsWithCatalogDates.contains(selectedSection) }
    var hasRatings: Bool { sectionsWithRatings.contains(selectedSection) }
    var libraryFiltersActive: Bool { librarySortOrder != .provider || favoritesOnly || recentlyAddedOnly || minimumRating > 0 }
    var libraryFiltersApplyToSelection: Bool {
        selectedCategory != "Recently Watched" && selectedCategory != "Favorites" && selectedCategory != "★ Favorites"
    }
    func resetLibraryFilters() {
        librarySortOrder = .provider
        favoritesOnly = false
        recentlyAddedOnly = false
        minimumRating = 0
    }
    private var libraryFilterTask: Task<Void, Never>?
    private var libraryFilterRevision = UUID()
    private var categoryKeysByID: [UUID: String] = [:]
    private var categoryKeysBySection: [M3UItem.ContentType: [String: Set<String>]] = [:]
    private var organizationCategoryItems: [M3UItem.ContentType: [M3UItem]] = [:]
    private(set) var dashboardCounts: [M3UItem.ContentType: Int] = [:]
    private(set) var dashboardFavorites: [M3UItem] = []
    private var recordedCurrentPlayback = false
    let downloads: DownloadManager
    @Published var showingGuideSearch = false { didSet { pictureInPicture.update() } }
    @Published var showingDownloads = false { didSet { pictureInPicture.update() } }
    var pendingDownload: DownloadRecord?
    var downloadSeriesItem: M3UItem? { seriesOverviewItem }
    var seriesMetadata: MediaDetails? { seriesDetails }
    @Published var showingResumeChoice = false
    @Published var resumeRequest: PlaybackResumeRequest? {
        didSet { showingResumeChoice = resumeRequest != nil }
    }
    private var seriesOverviewItem: M3UItem?
    private var playingSeries: (item: M3UItem?, episodes: [M3UItem], details: MediaDetails?)?
    var seriesDetailsItem: M3UItem? { seriesOverviewItem ?? currentChannel }
    func isCurrentPlayback(_ item: M3UItem) -> Bool {
        currentChannel?.id == item.id || (currentChannel?.contentType == .series && playingSeries?.item?.id == item.id)
    }
    private var pendingResumePosition: Double?
    private var vlcResumeSeekIssued = false
    private var resumeTimeoutTask: Task<Void, Never>?
    private var wantsPlayback = false
    private var pausedPlaybackPosition: Double?
    private var resumePlaybackTask: Task<Void, Never>?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
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
    @Published public private(set) var channels: [M3UItem] = [] {
        didSet {
            if channels.count != oldValue.count || !zip(channels, oldValue).allSatisfy({ $0.id == $1.id }) {
                filteredChannels = []
            }
            libraryItemsByKey = [:]
            librarySearchTextByID = [:]
            sectionsWithCatalogDates = []; sectionsWithRatings = []
            categoryKeysByID = [:]; categoryKeysBySection = [:]; organizationCategoryItems = [:]
            var categoryHashes: [String: String] = [:]
            var itemKeys: [UUID: String] = [:]
            for item in channels {
                let key = channelKeysByID[item.id] ?? PlaybackProgressStore.key(for: item)
                libraryItemsByKey[key] = item; itemKeys[item.id] = key
                librarySearchTextByID[item.id] = Self.normalizedLibraryText(item.name + "\n" + item.groupTitle)
                if item.catalogDate != nil { sectionsWithCatalogDates.insert(item.contentType) }
                if item.rating != nil { sectionsWithRatings.insert(item.contentType) }
                let identity = ChannelOrganization.categoryIdentity(item)
                let categoryKey = categoryHashes[identity] ?? ChannelOrganization.categoryKey(item)
                categoryHashes[identity] = categoryKey; categoryKeysByID[item.id] = categoryKey
                if categoryKeysBySection[item.contentType]?[item.groupTitle] == nil {
                    organizationCategoryItems[item.contentType, default: []].append(item)
                }
                categoryKeysBySection[item.contentType, default: [:]][item.groupTitle, default: []].insert(categoryKey)
            }
            channelKeysByID = itemKeys
            for section in M3UItem.ContentType.allCases {
                organizationCategoryItems[section]?.sort { $0.groupTitle < $1.groupTitle }
            }
            rebuildDashboard()
        }
    }
    
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
                dismissDetails()
                if selectedCategory != "Recently Watched" { selectedCategory = "All" }
                categorySearchText = ""
                reindexCategoriesAndChannels()
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
    
    @Published var librarySortOrder: LibrarySortOrder = .provider {
        didSet {
            guard oldValue != librarySortOrder else { return }
            storageDefaults.set(librarySortOrder.rawValue, forKey: "com.iptvplayer.librarySort")
            updateFilteredChannelsOnly()
        }
    }
    @Published var favoritesOnly = false {
        didSet {
            guard oldValue != favoritesOnly else { return }
            storageDefaults.set(favoritesOnly, forKey: "com.iptvplayer.favoritesOnly")
            updateFilteredChannelsOnly()
        }
    }
    @Published var recentlyAddedOnly = false {
        didSet {
            guard oldValue != recentlyAddedOnly else { return }
            storageDefaults.set(recentlyAddedOnly, forKey: "com.iptvplayer.recentlyAddedOnly")
            updateFilteredChannelsOnly()
        }
    }
    @Published var minimumRating = 0.0 {
        didSet {
            guard oldValue != minimumRating else { return }
            storageDefaults.set(minimumRating, forKey: "com.iptvplayer.minimumRating")
            updateFilteredChannelsOnly()
        }
    }
    @Published private(set) var isFilteringLibrary = false

    /// Current search query string.
    @Published public var searchText: String = "" {
        didSet {
            if oldValue != searchText {
                updateFilteredChannelsOnly(debounceSearch: true)
            }
        }
    }

    @Published var categorySearchText = ""

    var filteredCategories: [String] {
        let query = categorySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return categories.filter {
            !ChannelListView.categoryShortcuts.contains($0) && $0 != "★ Favorites"
                && (query.isEmpty || $0.localizedStandardContains(query))
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
            updateRemoteNowPlaying()
            if oldValue != isPlaying {
                pictureInPicture.update()
                notePlayerActivity()
                if isPlaying { markStablePlayback() }
                else { stablePlaybackTask?.cancel() }
            }
        }
    }
    
    /// Stream buffer state indicator.
    @Published public var isBuffering: Bool = false {
        didSet {
            if isBuffering && !oldValue { watchForStall() }
            else if !isBuffering { stallTask?.cancel() }
        }
    }
    
    /// The URL string of the loaded playlist.
    @Published public var playlistURLString: String = ""
    
    // MARK: - UI & Navigation State
    
    /// Navigation split view visibility state.
    @Published public var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var showingDashboard = true { didSet { pictureInPicture.update() } }

    func browse(_ section: M3UItem.ContentType) {
        selectedSection = section
        selectedCategory = "All"
        searchText = ""
        showingDashboard = false
    }
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
    @Published public var showingPlaylistSheet: Bool = false { didSet { pictureInPicture.update() } }
    
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
    @Published public var showingAboutSheet: Bool = false { didSet { pictureInPicture.update() } }
    @Published var showingSubscriptionInfo = false { didSet { pictureInPicture.update() } }
    
    /// Controls whether playback HUD overlays are shown over the video.
    @Published public var showVideoControls: Bool = true
    
    /// Video gravity aspect fit / fill mode.
    @Published public var videoGravity: AVLayerVideoGravity = .resizeAspect
    @Published public var screenSize: VideoScreenSize = .auto {
        didSet {
            if oldValue != screenSize { storageDefaults.set(screenSize.rawValue, forKey: VideoScreenSize.storageKey) }
        }
    }
    
    /// Indicates whether the active video playback view is expanded to fullscreen.
    @Published public var isFullscreen: Bool = false {
        didSet {
            if oldValue != isFullscreen {
                pictureInPicture.update()
                cancelControlsAutoHide()
                if isFullscreen { scheduleControlsAutoHide() }
            }
        }
    }
    
    /// Current playback progress in seconds for VOD (MP4 movies and TV shows).
    @Published public var currentTime: Double = 0.0 {
        didSet { subtitles.updateTime(currentTime) }
    }
    
    /// Total duration in seconds for VOD media.
    @Published public var duration: Double = 0.0 {
        didSet { if duration != oldValue { updateRemoteNowPlaying() } }
    }
    
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
        self.episodeScrollRequest = UUID()
    }
    
    /// View mode for series episodes (false = horizontal carousel, true = full grid).
    @Published public var isSeriesGridView: Bool = false
    
    /// Current scroll target index for either episode layout.
    @Published public var episodeScrollIndex: Int = 0
    @Published var visibleEpisodeIndex = 0
    @Published var episodeScrollRequest = UUID()
    
    /// Moves to the next batch from the visible episode, including after manual scrolling.
    public func scrollEpisodesNext(from visibleIndex: Int? = nil) {
        let maxIndex = max(0, filteredEpisodesForSelectedSeason.count - 1)
        episodeScrollIndex = min(maxIndex, max(0, visibleIndex ?? episodeScrollIndex) + 3)
        episodeScrollRequest = UUID()
    }
    
    /// Moves to the previous batch from the visible episode.
    public func scrollEpisodesPrev(from visibleIndex: Int? = nil) {
        let maxIndex = max(0, filteredEpisodesForSelectedSeason.count - 1)
        episodeScrollIndex = max(0, min(maxIndex, visibleIndex ?? episodeScrollIndex) - 3)
        episodeScrollRequest = UUID()
    }
    
    /// Flag indicating if episodes drawer is visible.
    @Published public var showingEpisodesDrawer: Bool = false
    
    /// Flag indicating if user is on the rich TV Series overview & episodes page.
    @Published public var isViewingSeriesDetails: Bool = false { didSet { pictureInPicture.update() } }
    @Published private(set) var seriesDetails: MediaDetails?
    @Published private(set) var seriesDetailsFailed = false
    @Published private(set) var isViewingMovieDetails = false { didSet { pictureInPicture.update() } }
    @Published private(set) var movieOverviewItem: M3UItem?
    
    /// Loading indicator for series episode resolution.
    @Published public var isLoadingEpisodes: Bool = false
    
    /// Live TV Electronic Program Guide (EPG) modal sheet visibility.
    @Published public var showingEPGSheet: Bool = false { didSet { pictureInPicture.update() } }
    
    private var controlsTimer: Task<Void, Never>? = nil
    private var controlsInteractionHolds = Set<String>()
    var pointerInsidePlayer = false
    private(set) var playbackCursorHidden = false
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
        didSet {
            if playbackVolume == 0, oldValue > 0 { lastAudibleVolume = oldValue }
            applyPlaybackVolume()
        }
    }
    private var lastAudibleVolume: Float = 0.8

    #if os(macOS)
    /// VLC playback instance used for streams AVPlayer cannot decode.
    @Published public private(set) var vlcPlayer: VLCMediaPlayer? {
        didSet { cleanupVLCPlayer = vlcPlayer }
    }
    private var cleanupVLCPlayer: VLCMediaPlayer?
    // App volume is persisted separately; VLC's volume saving can deadlock its global config lock during channel switches.
    private static let playbackLibrary = VLCLibrary(options: ["--no-volume-save"])
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
        sources = SavedSourceStore(defaults: .standard)
        downloads = DownloadManager.shared
        progressStore = PlaybackProgressStore()
        recentlyWatchedStore = RecentlyWatchedStore()
        storageDefaults = .standard
        libraryLoader = LibraryLoader()
        libraryPersistence = LibraryPersistence(url: Self.defaultCacheURL, defaults: .standard)
        super.init()
        screenSize = VideoScreenSize(rawValue: storageDefaults.string(forKey: VideoScreenSize.storageKey) ?? "") ?? .auto
        observeProgress()
        loadPersistedState()
        setupAudioSessionIfAvailable()
        configureRemotePlaybackControls()
        migrateActiveSource()
    }

    /// Isolated storage and no automatic playlist playback for lifecycle tests.
    init(progressDefaults: UserDefaults, libraryLoader: LibraryLoader = LibraryLoader(), cacheURL: URL? = nil, downloads: DownloadManager? = nil) {
        sources = SavedSourceStore(defaults: progressDefaults, secure: false)
        self.downloads = downloads ?? DownloadManager(root: FileManager.default.temporaryDirectory.appendingPathComponent("EasyIPTVDownloadsTests-\(UUID())"),
            configuration: .ephemeral, monitorNetwork: false, preferences: progressDefaults, subtitleFetch: { $0.subtitleSources ?? [] })
        progressStore = PlaybackProgressStore(defaults: progressDefaults)
        recentlyWatchedStore = RecentlyWatchedStore(defaults: progressDefaults)
        storageDefaults = progressDefaults
        self.libraryLoader = libraryLoader
        libraryPersistence = LibraryPersistence(url: cacheURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyIPTVTests-\(UUID())/cached_channels.json"), defaults: progressDefaults)
        super.init()
        screenSize = VideoScreenSize(rawValue: storageDefaults.string(forKey: VideoScreenSize.storageKey) ?? "") ?? .auto
        observeProgress()
    }

    private func observeProgress() {
        pictureInPicture.manager = self
        autoPictureInPicture = storageDefaults.object(forKey: "com.iptvplayer.autoPictureInPicture") as? Bool ?? true
        pictureInPicture.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)

        librarySortOrder = LibrarySortOrder(rawValue: storageDefaults.string(forKey: "com.iptvplayer.librarySort") ?? "") ?? .provider
        favoritesOnly = storageDefaults.bool(forKey: "com.iptvplayer.favoritesOnly")
        recentlyAddedOnly = storageDefaults.bool(forKey: "com.iptvplayer.recentlyAddedOnly")
        let savedRating = storageDefaults.double(forKey: "com.iptvplayer.minimumRating")
        minimumRating = [0, 6, 7, 8, 9].contains(savedRating) ? savedRating : 0
        if let data = storageDefaults.data(forKey: "com.iptvplayer.organization.v1"),
           let saved = try? JSONDecoder().decode(ChannelOrganization.self, from: data) { organization = saved }
        audioTracks.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        sources.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        progressStore.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        downloads.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        downloads.$deleting.sink { [weak self] ids in
            guard let self, let item = self.currentChannel, ids.contains(PlaybackProgressStore.key(for: item)),
                  self.downloads.localURL(for: item) != nil else { return }
            self.stop()
        }.store(in: &cancellables)
    }
    
    deinit {
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        if !remoteCommandTargets.isEmpty {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            #endif
        }
        libraryFilterTask?.cancel()
        recoveryTask?.cancel()
        stallTask?.cancel()
        stablePlaybackTask?.cancel()
        foregroundLibraryTask?.cancel()
        backgroundLibraryTask?.cancel()
        seriesLoadTask?.cancel()
        controlsTimer?.cancel()
        #if os(macOS)
        if playbackCursorHidden { NSCursor.setHiddenUntilMouseMoves(false) }
        #endif
        resumeTimeoutTask?.cancel()
        resumePlaybackTask?.cancel()
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
        
        for channel in channels where channel.contentType == selectedSection && visibleChannelIDs.contains(channel.id) {
            secTotal += 1
            let grp = channel.displayGroup
            counts[grp, default: 0] += 1
            groups.insert(grp)
            if favoriteStreamURLs.contains(channel.streamURL.absoluteString) {
                favCount += 1
            }
        }
        
        let sortedGroups = groups.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        self.categories = ChannelListView.categoryShortcuts + sortedGroups
        self.categoryCounts = counts
        self.favoritesCount = favCount
        self.sectionTotalCount = secTotal
        
        updateFilteredChannelsOnly()
    }
    
    /// Filter cached library data; expensive searches and sorts run away from playback's UI thread.
    public func updateFilteredChannelsOnly(debounceSearch: Bool = false) {
        libraryFilterTask?.cancel()
        let revision = UUID()
        libraryFilterRevision = revision
        var result = channels.filter { $0.contentType == selectedSection && visibleChannelIDs.contains($0.id) }
        
        // 1. Category Filtering
        if selectedCategory == "Recently Watched" {
            result = recentlyWatchedChannels.filter { visibleChannelIDs.contains($0.id) }
        } else if selectedCategory == "Favorites" || selectedCategory == "★ Favorites" {
            result = organization.orderedFavorites(result.filter { favoriteStreamURLs.contains($0.streamURL.absoluteString) }, key: organizationKey)
        } else if selectedCategory != "All" {
            result = result.filter { $0.displayGroup == selectedCategory }
        }
        
        // History and favorites keep their own order independently of library settings.
        let applyFilters = libraryFiltersApplyToSelection
        if favoritesOnly && applyFilters { result = result.filter { favoriteStreamURLs.contains($0.streamURL.absoluteString) } }
        let query = Self.normalizedLibraryText(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        let order = applyFilters ? librarySortOrder : .provider
        let cutoff = recentlyAddedOnly && applyFilters ? Date().addingTimeInterval(-30 * 86_400) : nil
        let rating = applyFilters ? minimumRating : 0
        let searchIndex = librarySearchTextByID
        guard result.count > 1_000 && (!query.isEmpty || order != .provider || cutoff != nil || rating > 0) else {
            isFilteringLibrary = false
            filteredChannels = (try? Self.filterLibraryItems(result, query: query, searchIndex: searchIndex, order: order, addedSince: cutoff, minimumRating: rating)) ?? []
            return
        }
        isFilteringLibrary = true
        let candidates = result
        let work = Task.detached(priority: .userInitiated) {
            if debounceSearch && !query.isEmpty { try await Task.sleep(nanoseconds: 200_000_000) }
            return try Self.filterLibraryItems(candidates, query: query, searchIndex: searchIndex, order: order, addedSince: cutoff, minimumRating: rating)
        }
        libraryFilterTask = Task { [weak self] in
            do {
                let filtered = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, !Task.isCancelled, self.libraryFilterRevision == revision else { return }
                self.filteredChannels = filtered
                self.isFilteringLibrary = false
            } catch {
                guard let self, self.libraryFilterRevision == revision else { return }
                self.isFilteringLibrary = false
            }
        }
    }

    nonisolated private static func normalizedLibraryText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    nonisolated private static func filterLibraryItems(_ items: [M3UItem], query: String,
                                                       searchIndex: [UUID: String], order: LibrarySortOrder,
                                                       addedSince: Date?, minimumRating: Double) throws -> [M3UItem] {
        var result = items
        if !query.isEmpty || addedSince != nil || minimumRating > 0 {
            let now = Date()
            result = try items.enumerated().compactMap { index, item in
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                if !query.isEmpty && searchIndex[item.id]?.contains(query) != true { return nil }
                if let addedSince, item.catalogDate.map({ $0 >= addedSince && $0 <= now }) != true { return nil }
                if minimumRating > 0 && (item.rating ?? 0) < minimumRating { return nil }
                return item
            }
        }
        guard order != .provider else { return result }
        var comparisons = 0
        // Sort lightweight offsets rather than making a second array of full channel values.
        var positions = Array(result.indices)
        try positions.sort { left, right in
            comparisons += 1
            if comparisons.isMultiple(of: 1_024) { try Task.checkCancellation() }
            if order == .recentlyAdded {
                let lhs = result[left].catalogDate ?? .distantPast, rhs = result[right].catalogDate ?? .distantPast
                return lhs == rhs ? left < right : lhs > rhs
            }
            if order == .highestRated {
                let lhs = result[left].rating ?? -1, rhs = result[right].rating ?? -1
                return lhs == rhs ? left < right : lhs > rhs
            }
            let comparison = result[left].name.localizedStandardCompare(result[right].name)
            if comparison == .orderedSame { return left < right }
            return order == .nameAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return positions.map { result[$0] }
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
    public func loadPlaylist(from urlString: String, saveSource: Bool = true) async {
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
        do {
            let parsedChannels = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard acceptLibraryResponse(generation) else { return }
            
            self.playlistURLString = urlString
            if saveSource { rememberSource(.playlist(url.absoluteString)) }
            // Map favorites onto newly parsed channels
            self.channels = parsedChannels.map { item in
                var updated = item
                updated.isFavorite = self.favoriteStreamURLs.contains(item.streamURL.absoluteString)
                return updated
            }
            
            self.reindexCategoriesAndChannels()
            
            // Persist the successfully loaded playlist URL and cached channels to disk
            storageDefaults.set(urlString, forKey: lastPlaylistKey)
            storageDefaults.removeObject(forKey: "com.iptvplayer.savedXtream")
            self.persistLoadedChannels()
            self.isLoading = false
            
            // Auto-play the first channel if none is currently selected
            if let first = self.filteredChannels.first ?? self.channels.first, self.currentChannel == nil, !self.showingDashboard {
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
    public func loadXtream(serverURL: String, username: String, password: String, saveSource: Bool = true) async {
        let generation = beginLibraryLoad()
        let loader = libraryLoader
        let task = Task { try await loader.live(serverURL, username, password) }
        foregroundLibraryTask = task
        self.isLoading = true
        self.errorMessage = nil
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
            
            self.playlistURLString = "Xtream: \(username)"
            if saveSource { rememberSource(.xtream(server: serverURL, username: username, password: password)) }
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
            
            if let first = self.filteredChannels.first ?? self.channels.first, self.currentChannel == nil, !self.showingDashboard {
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
        
        if let first = self.filteredChannels.first ?? self.channels.first, !self.showingDashboard {
            self.playChannel(first)
        }
    }
    
    // MARK: - Playback Control

    var dashboardRecentChannels: [M3UItem] {
        Array(recentlyWatchedStore.records.filter { $0.contentType == .live }
            .compactMap { libraryItemsByKey[$0.libraryKey] }.filter { visibleChannelIDs.contains($0.id) })
    }

    var dashboardContinueWatching: [DashboardResumeItem] {
        Array(recentlyWatchedStore.records.compactMap { record -> DashboardResumeItem? in
            guard record.contentType != .live, let item = libraryItemsByKey[record.libraryKey], visibleChannelIDs.contains(item.id),
                  let progress = progressStore.records[record.episodeKey], progress.resumePosition != nil else { return nil }
            return DashboardResumeItem(item: item, progress: progress, season: record.season, episode: record.episode)
        }.sorted { $0.progress.updatedAt > $1.progress.updatedAt })
    }

    var recentlyWatchedChannels: [M3UItem] {
        recentlyWatchedStore.records.filter { $0.contentType == selectedSection }
            .compactMap { libraryItemsByKey[$0.libraryKey] }
    }

    func recentlyWatchedRecord(for item: M3UItem) -> RecentlyWatched? {
        let key = PlaybackProgressStore.key(for: item)
        return recentlyWatchedStore.records.first { $0.libraryKey == key }
    }

    func removeRecentlyWatched(_ item: M3UItem) {
        recentlyWatchedStore.remove(item)
        updateFilteredChannelsOnly()
    }

    func clearRecentlyWatched() {
        recentlyWatchedStore.clear(selectedSection)
        updateFilteredChannelsOnly()
    }

    func playRecentlyWatched(_ item: M3UItem, resumeSeries: Bool = false) {
        showingDashboard = false
        guard let record = recentlyWatchedRecord(for: item) else { return }
        if item.contentType == .series {
            fetchAndShowSeries(item, recentEpisodeKey: resumeSeries ? record.episodeKey : nil)
        } else if item.contentType == .movie {
            stop()
            continueWatching(item)
        } else {
            playChannel(item)
        }
    }

    func recordPlaybackStarted() {
        guard wantsPlayback, isPlaying, !recordedCurrentPlayback, let item = currentChannel, item.isCatchup != true else { return }
        recordedCurrentPlayback = true
        recentlyWatchedStore.record(item, series: playingSeries?.item)
        updateFilteredChannelsOnly()
    }
    
    /// Opens movie/series details, or begins playback for a live channel.
    /// - Parameter item: The target channel or show.
    public func playChannel(_ item: M3UItem) {
        showingDashboard = false
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
        dismissDetails()
        movieOverviewItem = item
        isViewingMovieDetails = true
    }

    func dismissDetails() {
        seriesLoadTask?.cancel()
        seriesLoadTask = nil
        seriesGeneration = UUID()
        isLoadingEpisodes = false
        isViewingMovieDetails = false
        isViewingSeriesDetails = false
        movieOverviewItem = currentChannel?.contentType == .movie ? currentChannel : nil
        seriesOverviewItem = playingSeries?.item
        seriesEpisodes = playingSeries?.episodes ?? []
        seriesDetails = playingSeries?.details
        if let currentChannel, currentChannel.contentType == .series { selectedSeason = currentChannel.groupTitle }
        seriesDetailsFailed = false
    }

    func playMovie(startOver: Bool = false) {
        guard let item = movieOverviewItem else { return }
        if !startOver, currentChannel?.subtitleCacheKey == item.subtitleCacheKey,
           player?.currentItem != nil || useVLCPlayback, !playbackFinished {
            pictureInPicture.restorePlayer()
            setPlaybackPlaying(true)
            return
        }
        if startOver { progressStore.clear(item) }
        continueWatching(item)
        showVideoControls = true
        scheduleControlsAutoHide()
    }

    func returnToMovie() {
        saveProgress(force: true)
        guard let item = movieOverviewItem ?? currentChannel, item.contentType == .movie else { return }
        movieOverviewItem = item
        isViewingMovieDetails = true
        showVideoControls = true
    }
    
    /// Plays an individual stream, movie, or resolved TV episode directly.
    public func playDirectStream(_ item: M3UItem) {
        #if os(macOS)
        requestPlayback(item, useVLC: true)
        #else
        requestPlayback(item, useVLC: false)
        #endif
    }

    private func requestPlayback(_ item: M3UItem, useVLC: Bool) {
        showingDashboard = false
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
        showingDashboard = false
        let position = progressStore.progress(for: item)?.resumePosition
        #if os(macOS)
        playDirectStream(item, useVLC: true, position: position)
        #else
        playDirectStream(item, useVLC: false, position: position)
        #endif
    }

    #if os(macOS)
    /// Retries the selected stream explicitly with AVKit, even when it is a live channel.
    public func playDirectStreamWithAVKit(_ item: M3UItem) {
        let position = currentChannel?.subtitleCacheKey == item.subtitleCacheKey ? (pendingResumePosition ?? playbackPosition()) : nil
        playDirectStream(item, useVLC: false, position: position)
    }
    #endif

    private func playDirectStream(_ item: M3UItem, useVLC: Bool, position: Double? = nil, preservingDetails: Bool = false, recoveryAttempt: Int = 0) {
        let sameMedia = currentChannel?.subtitleCacheKey == item.subtitleCacheKey
        let audioSelection = sameMedia ? audioTracks.playbackSelection : nil
        let subtitleSelection = sameMedia ? subtitles.playbackSelection : nil
        defer {
            if let audioSelection { audioTracks.restoreSelection(audioSelection) }
            if let subtitleSelection { subtitles.restoreSelection(subtitleSelection) }
        }
        let archiveOrigin = item.isCatchup == true ? catchupOrigin : nil
        tearDownPlayback(nextItem: item)
        catchupOrigin = archiveOrigin
        recoveryAttempts = recoveryAttempt
        recordedCurrentPlayback = false
        resumeRequest = nil
        pendingResumePosition = position.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        wantsPlayback = true
        playbackFinished = false
        if position == nil, progressStore.progress(for: item)?.completed == true { progressStore.clear(item) }
        lastProgressSave = Date()
        subtitles.reset(for: item.isVOD ? item : nil)
        #if os(macOS)
        stopVLCPlayback()
        #endif
        self.currentChannel = item
        if !preservingDetails, item.contentType == .series {
            selectedSeason = item.groupTitle
            playingSeries = (seriesOverviewItem, seriesEpisodes, seriesDetails)
        } else if !preservingDetails {
            playingSeries = nil
        }
        if !preservingDetails {
            self.isViewingSeriesDetails = false
            self.isViewingMovieDetails = false
            movieOverviewItem = item.contentType == .movie ? item : nil
        }
        self.useVLCPlayback = false
        if item.contentType != .series, !preservingDetails {
            seriesOverviewItem = nil
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
        
        let localURL = downloads.localURL(for: item)
        if localURL == nil, !downloads.isOnline {
            isBuffering = false; isPlaying = false
            errorMessage = "You're offline and this item hasn't been downloaded. Open Downloads to watch saved movies and episodes."
            return
        }
        let asset = AVURLAsset(url: localURL ?? item.streamURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let playerItem = AVPlayerItem(asset: asset)
        audioTracks.configure(playerItem)
        if item.isVOD {
            subtitles.configure(item: playerItem, provider: subtitleProvider(for: item), offlineSources: localURL == nil ? nil : (downloads.record(for: item)?.subtitles ?? []))
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
        guard let currentChannel, resumeRequest == nil, player != nil || useVLCPlayback else { return }
        let position = pendingResumePosition ?? playbackPosition()
        playDirectStream(currentChannel, useVLC: true, position: position,
                         preservingDetails: isViewingMovieDetails || isViewingSeriesDetails)
    }

    nonisolated static func vlcResumeTime(position: Double, seekable: Bool, duration: Double) -> Int32? {
        guard seekable, position.isFinite, position >= 0 else { return nil }
        let target = duration.isFinite && duration > 0 ? min(position, max(0, duration - 1)) : position
        return Int32(min(target * 1000, Double(Int32.max)))
    }

    private func startVLCPlayback(for item: M3UItem) {
        subtitles.reset(for: item.isVOD ? item : nil)
        stopVLCPlayback()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removeTimeObserver()
        playerItemStatusObserver?.invalidate()
        playerTimeControlObserver?.invalidate()
        let vlc = VLCMediaPlayer(library: Self.playbackLibrary)
        vlc.delegate = self
        let localURL = downloads.localURL(for: item)
        if localURL == nil, !downloads.isOnline {
            errorMessage = "You're offline. Open Downloads to watch saved movies and episodes."
            isBuffering = false; isPlaying = false
            return
        }
        vlc.media = VLCMedia(url: localURL ?? item.streamURL)
        vlcPlayer = vlc
        audioTracks.configure(vlc)
        if item.isVOD {
            subtitles.configure(player: vlc, provider: subtitleProvider(for: item), offlineSources: localURL == nil ? nil : (downloads.record(for: item)?.subtitles ?? []))
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
                self.errorMessage = "This stream could not resume at the saved position. Try again, switch player, or choose Start over."
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
    /// presents the Series Overview without interrupting the playing stream.
    public func fetchAndShowSeries(_ item: M3UItem, recentEpisodeKey: String? = nil) {
        movieOverviewItem = nil
        isViewingMovieDetails = false
        seriesLoadTask?.cancel()
        seriesGeneration = UUID()
        let generation = seriesGeneration
        seriesOverviewItem = item
        self.isViewingSeriesDetails = true
        self.isSeriesGridView = true
        self.isLoadingEpisodes = true
        self.seriesEpisodes = []
        seriesDetails = nil
        seriesDetailsFailed = false
        if !downloads.isOnline {
            let episodes = downloads.records.filter { $0.series.map { PlaybackProgressStore.key(for: $0) == PlaybackProgressStore.key(for: item) } == true && $0.status == .downloaded }
            seriesEpisodes = episodes.map(\.item).sorted { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0) }
            seriesDetails = episodes.first?.details
            isLoadingEpisodes = false
            resumeRecentEpisode(recentEpisodeKey)
            return
        }
        let loadDetails = libraryLoader.seriesDetails
        seriesLoadTask = Task { [weak self] in
            do {
                let result = try await loadDetails(item)
                guard let self, !Task.isCancelled, self.seriesGeneration == generation,
                      self.seriesOverviewItem?.id == item.id, self.isViewingSeriesDetails else { return }
                self.seriesEpisodes = result.episodes
                self.seriesDetails = result.details
                self.isLoadingEpisodes = false
                self.resumeRecentEpisode(recentEpisodeKey)
            } catch {
                guard let self, !Task.isCancelled, self.seriesGeneration == generation,
                      self.seriesOverviewItem?.id == item.id, self.isViewingSeriesDetails else { return }
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

    private func resumeRecentEpisode(_ key: String?) {
        guard let key else { return }
        guard let episode = seriesEpisodes.first(where: { PlaybackProgressStore.key(for: $0) == key }) else {
            errorMessage = "The last watched episode is unavailable. Choose another episode from this show."
            return
        }
        continueWatching(episode)
    }

    /// Every route back to the episode browser uses the same engine-independent exit.
    public func returnToSeries() {
        saveProgress(force: true)
        let overview = seriesOverviewItem ?? currentChannel
        seriesOverviewItem = overview
        isViewingSeriesDetails = true
        showingEpisodesDrawer = false
        showVideoControls = true
    }

    private func playbackPosition() -> Double {
        pausedPlaybackPosition ?? enginePlaybackPosition()
    }

    private func enginePlaybackPosition() -> Double {
        #if os(macOS)
        if let vlcPlayer, useVLCPlayback { return max(0, Double(vlcPlayer.time.intValue) / 1000) }
        #endif
        let seconds = player?.currentTime().seconds ?? currentTime
        return seconds.isFinite ? max(0, seconds) : currentTime
    }

    private func saveProgress(force: Bool = false, completed: Bool = false) {
        guard let item = currentChannel, item.isVOD,
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
        pictureInPicture.resetPlayback()
        cancelStreamRecovery()
        audioTracks.reset()
        catchupOrigin = nil
        if nextItem == nil { controlsInteractionHolds.removeAll() }
        cancelControlsAutoHide()
        saveProgress(force: true)
        pausedPlaybackPosition = nil
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
        if wantsPlayback, pausedPlaybackPosition == nil {
            pausedPlaybackPosition = pendingResumePosition ?? playbackPosition()
        }
        cancelStreamRecovery()
        saveProgress(force: true)
        wantsPlayback = false
        player?.pause()
        #if os(macOS)
        vlcPlayer?.pause()
        #endif
        isPlaying = false
        isBuffering = false
    }

    func playerViewAppeared(_ identity: UUID) {
        visiblePlayerViews.insert(identity)
    }

    func playerViewDisappeared(_ identity: UUID) {
        visiblePlayerViews.remove(identity)
        // SwiftUI can briefly replace a host during fullscreen/navigation layout.
        // Wait one run-loop turn so a replacement can claim the same player.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.visiblePlayerViews.isEmpty else { return }
            self.pictureInPicture.reconcile()
            guard !self.pictureInPicture.isActive, !self.pictureInPicture.isStarting else { return }
            self.stop()
        }
    }
    
    /// Re-syncs and refreshes the current Xtream Codes server or M3U playlist to fetch updated channels.
    public func refreshPlaylist() async {
        // Refresh library data without reading or rewriting saved connections in Keychain.
        if !playlistURLString.hasPrefix("Xtream:"),
           let savedURL = storageDefaults.string(forKey: lastPlaylistKey), !savedURL.isEmpty,
           !savedURL.hasPrefix("Xtream:") {
            await loadPlaylist(from: savedURL, saveSource: false)
        } else if let saved = storageDefaults.dictionary(forKey: "com.iptvplayer.savedXtream") as? [String: String],
           let server = saved["server"], let user = saved["username"], let pass = saved["password"], !server.isEmpty {
            await loadXtream(serverURL: server, username: user, password: pass, saveSource: false)
        } else if let savedURL = storageDefaults.string(forKey: lastPlaylistKey), !savedURL.isEmpty {
            await loadPlaylist(from: savedURL, saveSource: false)
        }
    }
    
    var subscriptionAccount: SubscriptionAccount? {
        guard playlistURLString != "Demo Public HLS Channels" else { return nil }
        if let saved = storageDefaults.dictionary(forKey: "com.iptvplayer.savedXtream") as? [String: String],
           let server = saved["server"], !server.isEmpty,
           let username = saved["username"], !username.isEmpty,
           let password = saved["password"], !password.isEmpty {
            return SubscriptionAccount(serverURL: server, username: username, password: password)
        }
        return storageDefaults.string(forKey: lastPlaylistKey).flatMap(SubscriptionAccount.init(playlistURL:))
    }

    func subscriptionInformation(for account: SubscriptionAccount, refresh: Bool = false) async throws -> SubscriptionInfo {
        if !refresh, let data = storageDefaults.data(forKey: SubscriptionInfo.storageKey),
           let saved = try? JSONDecoder().decode(SubscriptionInfo.self, from: data), saved.accountID == account.cacheID {
            return saved
        }
        guard let userInfo = try await libraryLoader.account(account.serverURL, account.username, account.password).userInfo else {
            throw XtreamCodesError.invalidResponse
        }
        try Task.checkCancellation()
        let info = SubscriptionInfo(accountID: account.cacheID, status: userInfo.status,
                                    expiryDate: userInfo.expiryDate, updatedAt: Date())
        if subscriptionAccount == account {
            storageDefaults.set(try JSONEncoder().encode(info), forKey: SubscriptionInfo.storageKey)
        }
        return info
    }

    /// Tracks the media clock at 100 ms intervals for progress and sidecar subtitles.
    private func setupTimeObserver() {
        removeTimeObserver()
        guard currentChannel?.isVOD == true, let pl = self.player, let observedItem = pl.currentItem else { return }
        
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = pl.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak pl] time in
            Task { @MainActor [weak self, weak pl] in
                guard let self = self, let pl, !self.isSeeking, !self.useVLCPlayback,
                      self.player === pl, pl.currentItem === observedItem else { return }
                self.updatePlaybackClock(position: time.seconds, duration: observedItem.duration.seconds)
                self.saveProgress()
            }
        }
    }

    var playbackBadge: String? {
        guard let channel = currentChannel else { return nil }
        if channel.isCatchup == true { return "Catch-up TV" }
        var liveOffset: Double?
        if !useVLCPlayback, let item = player?.currentItem,
           item.status == .readyToPlay, item.duration.isIndefinite {
            let position = item.currentTime().seconds
            let end = item.seekableTimeRanges.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds }
                .filter { $0.isFinite }.max()
            if position.isFinite, let end, end > 0, position >= 0, position <= end {
                liveOffset = end - position
            }
        }
        return Self.playbackBadge(for: channel, paused: !wantsPlayback, liveOffset: liveOffset)
    }

    static func playbackBadge(for item: M3UItem, paused: Bool, liveOffset: Double?) -> String {
        if item.contentType == .series { return "Episode" }
        if item.isVOD { return "Movie" }
        if paused { return "Live TV · Paused" }
        guard let liveOffset, liveOffset.isFinite, liveOffset >= 0 else { return "Live TV" }
        // Allow normal HLS latency before calling playback delayed.
        return liveOffset > 30 ? "Behind live" : "LIVE"
    }

    func updatePlaybackClock(position: Double, duration: Double) {
        // Live clocks are read from the engine; publishing them redraws the entire library without a visible time display.
        guard currentChannel?.isVOD == true else { return }
        if position.isFinite, position >= 0, currentTime != position { currentTime = position }
        if duration.isFinite, duration > 0, self.duration != duration { self.duration = duration }
    }

    func updatePlaybackState(playing: Bool, buffering: Bool) {
        if isPlaying != playing { isPlaying = playing }
        if isBuffering != buffering { isBuffering = buffering }
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
        if pausedPlaybackPosition != nil { pausedPlaybackPosition = max(0, seconds) }
        subtitles.clearForSeek()
        defer { updateRemoteNowPlaying() }
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
        var maxDur = duration > 0 ? duration : 999999
        if currentChannel?.contentType == .live {
            var liveDuration = player?.currentItem?.duration.seconds ?? 0
            #if os(macOS)
            if useVLCPlayback { liveDuration = Double(vlcPlayer?.media?.length.intValue ?? 0) / 1000 }
            #endif
            if liveDuration.isFinite, liveDuration > 0 { maxDur = liveDuration }
        }
        let position = currentChannel?.isVOD == true ? currentTime : playbackPosition()
        let target = max(0, min(maxDur, position + seconds))
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
            toggleFullscreen(in: window)
        }
        #else
        isFullscreen.toggle()
        columnVisibility = isFullscreen ? .detailOnly : .all
        #endif
    }

    #if os(macOS)
    func toggleFullscreen(in window: NSWindow) {
        if !window.styleMask.contains(.fullScreen) {
            isFullscreen = true
            columnVisibility = .detailOnly
            window.toolbar?.isVisible = false
            window.titleVisibility = .hidden
        }
        window.toggleFullScreen(nil)
    }

    /// Keeps SwiftUI's fullscreen state aligned with the native window transition.
    public func updateFullscreenState(_ isFullscreen: Bool, window: NSWindow? = nil) {
        self.isFullscreen = isFullscreen
        columnVisibility = isFullscreen ? .detailOnly : .all
        guard let window = window ?? NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else { return }
        window.toolbar?.isVisible = !isFullscreen
        window.titleVisibility = .hidden
    }
    #endif

    public func toggleMute() {
        playbackVolume = playbackVolume == 0 ? lastAudibleVolume : 0
    }

    private func applyPlaybackVolume() {
        storageDefaults.set(playbackVolume, forKey: "com.iptvplayer.playbackVolume")
        player?.volume = playbackVolume
        #if os(macOS)
        vlcPlayer?.audio?.volume = pendingResumePosition == nil ? Int32((playbackVolume * 100).rounded()) : 0
        #endif
    }
    
    /// Toggles between play and pause.
    public func togglePlayPause() {
        guard resumeRequest == nil, pendingResumePosition == nil,
              currentChannel != nil else { return }
        setPlaybackPlaying(recoveryTask == nil && !wantsPlayback)
    }

    private func setPlaybackPlaying(_ playing: Bool) {
        if !playing {
            pauseForBackground()
            return
        }
        cancelStreamRecovery()
        wantsPlayback = true
        playbackFinished = false
        if pausedPlaybackPosition != nil { watchForResume() }
        #if os(macOS)
        if useVLCPlayback, let vlcPlayer {
            vlcPlayer.play()
            return
        }
        #endif
        guard let player else { return }
        player.play()
        isPlaying = true
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
        playingSeries = nil
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
        if isViewingMovieDetails || isViewingSeriesDetails { dismissDetails() }
        if currentChannel?.contentType == .series, !isViewingSeriesDetails, !seriesEpisodes.isEmpty {
            let index = seriesEpisodes.firstIndex { $0.subtitleCacheKey == currentChannel?.subtitleCacheKey } ?? -1
            let candidates = seriesEpisodes.dropFirst(index + 1)
            if let next = candidates.first(where: { downloads.isOnline || downloads.localURL(for: $0) != nil }) { playDirectStream(next) }
            return
        }
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
        if isViewingMovieDetails || isViewingSeriesDetails { dismissDetails() }
        if currentChannel?.contentType == .series, !isViewingSeriesDetails, !seriesEpisodes.isEmpty {
            let index = seriesEpisodes.firstIndex { $0.subtitleCacheKey == currentChannel?.subtitleCacheKey } ?? 0
            if let previous = seriesEpisodes.prefix(index).last(where: { downloads.isOnline || downloads.localURL(for: $0) != nil }) { playDirectStream(previous) }
            return
        }
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
        if isFullscreen { notePlayerActivity(); return }
        showVideoControls.toggle()
        if showVideoControls {
            scheduleControlsAutoHide()
        } else {
            controlsTimer?.cancel()
        }
    }
    
    var controlsAutoHideBlocked: Bool {
        !controlsInteractionHolds.isEmpty || audioTracks.showingMenu || showingSources || showingOrganization || catchupChannel != nil || subtitles.showingMenu || showingEpisodesDrawer || isSeeking
            || showingDownloads || showingEPGSheet || showingPlaylistSheet || showingAboutSheet
            || showingSubscriptionInfo || showingResumeChoice || isViewingMovieDetails || isViewingSeriesDetails || errorMessage != nil
    }

    func setControlsInteraction(_ region: String, active: Bool) {
        let changed = active ? controlsInteractionHolds.insert(region).inserted : controlsInteractionHolds.remove(region) != nil
        guard changed else { return }
        notePlayerActivity()
    }

    func notePlayerActivity() {
        cancelControlsAutoHide()
        scheduleControlsAutoHide()
    }

    func pointerLeftPlayer() {
        let wasInside = pointerInsidePlayer
        pointerInsidePlayer = false
        let hadHover = !controlsInteractionHolds.isDisjoint(with: ["topBar", "centerControls", "bottomBar"])
        controlsInteractionHolds.subtract(["topBar", "centerControls", "bottomBar"])
        setPlaybackCursorHidden(false)
        if wasInside || hadHover { scheduleControlsAutoHide() }
    }

    private func setPlaybackCursorHidden(_ hidden: Bool) {
        guard playbackCursorHidden != hidden else { return }
        playbackCursorHidden = hidden
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(hidden)
        #endif
    }

    func hideControlsIfIdle() {
        guard isPlaying, currentChannel != nil, !controlsAutoHideBlocked else { return }
        #if os(macOS)
        guard NSApp?.modalWindow == nil, NSApp?.windows.contains(where: { $0.attachedSheet != nil }) != true else { return }
        #endif
        withAnimation(.easeInOut(duration: 0.25)) { showVideoControls = false }
        setPlaybackCursorHidden(isFullscreen && pointerInsidePlayer)
    }

    /// Uses the same inactivity deadline for the fullscreen cursor and HUD.
    public func scheduleControlsAutoHide() {
        controlsTimer?.cancel()
        controlsTimer = nil
        guard isPlaying, currentChannel != nil, !controlsAutoHideBlocked else { return }
        let delay: UInt64 = isFullscreen ? 2_500_000_000 : 4_000_000_000
        controlsTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.hideControlsIfIdle()
        }
    }

    /// Keeps the playback HUD visible while the user is dragging a control slider.
    public func cancelControlsAutoHide() {
        controlsTimer?.cancel()
        controlsTimer = nil
        if !showVideoControls { showVideoControls = true }
        setPlaybackCursorHidden(false)
    }

    private func subtitleProvider(for item: M3UItem) -> () async throws -> [SubtitleSource] {
        if item.isCatchup == true { return { [] } }
        if downloads.localURL(for: item) != nil {
            let sources = downloads.record(for: item)?.subtitles ?? []
            return { sources }
        }
        let service = xtreamManager
        return {
            try await service.fetchSubtitleSources(for: item)
        }
    }

    func playDownload(_ record: DownloadRecord) {
        stop()
        if let series = record.series {
            seriesOverviewItem = series
            seriesDetails = record.details
            seriesEpisodes = downloads.records.filter { $0.seriesKey == record.seriesKey && $0.status == .downloaded }
                .map(\.item).sorted { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0) }
        }
        playDirectStream(record.item)
    }
    
    private func rebuildDashboard() {
        dashboardCounts = [:]; dashboardFavorites = []
        visibleChannelIDs.removeAll(keepingCapacity: true)
        for item in channels where !organization.hidden.contains(channelKeysByID[item.id] ?? "")
            && !organization.hiddenCategories.contains(categoryKeysByID[item.id] ?? "") {
            visibleChannelIDs.insert(item.id)
            dashboardCounts[item.contentType, default: 0] += 1
            if item.isFavorite { dashboardFavorites.append(item) }
        }
        dashboardFavorites = organization.orderedFavorites(dashboardFavorites, key: organizationKey)
    }

    func organizationKey(_ item: M3UItem) -> String {
        channelKeysByID[item.id] ?? ChannelOrganization.key(item)
    }
    func organizationCategoryKey(_ item: M3UItem) -> String {
        categoryKeysByID[item.id] ?? ChannelOrganization.categoryKey(item)
    }
    func organizationCategories(in section: M3UItem.ContentType) -> [M3UItem] {
        organizationCategoryItems[section] ?? []
    }
    func setChannelHidden(_ item: M3UItem, hidden: Bool) {
        setChannelsHidden([item], hidden: hidden)
    }
    func setChannelsHidden(_ items: [M3UItem], hidden: Bool) {
        let keys = items.map(organizationKey)
        var updated = organization
        if hidden { updated.hidden.formUnion(keys) }
        else { updated.hidden.subtract(keys) }
        organization = updated
    }
    func setCategoryHidden(_ item: M3UItem, hidden: Bool) {
        setCategoriesHidden([item], hidden: hidden)
    }
    func setCategoriesHidden(_ items: [M3UItem], hidden: Bool) {
        let keys = items.reduce(into: Set<String>()) { keys, item in
            keys.formUnion(categoryKeysBySection[item.contentType]?[item.groupTitle] ?? [organizationCategoryKey(item)])
        }
        var updated = organization
        if hidden { updated.hiddenCategories.formUnion(keys) }
        else { updated.hiddenCategories.subtract(keys) }
        organization = updated
    }
    func moveFavorite(_ item: M3UItem, before other: M3UItem) {
        var order = organization.orderedFavorites(channels.filter { isFavorite($0) }, key: organizationKey).map(organizationKey)
        let key = organizationKey(item)
        guard key != organizationKey(other), order.contains(key) else { return }
        order.removeAll { $0 == key }
        guard let index = order.firstIndex(of: organizationKey(other)) else { return }
        order.insert(key, at: index); organization.favoriteOrder = order
    }

    func switchSource(_ id: UUID) async {
        do {
            let connection = try sources.connection(id)
            switch connection {
            case .playlist(let url): await loadPlaylist(from: url)
            case .xtream(let server, let username, let password): await loadXtream(serverURL: server, username: username, password: password)
            }
            if sources.activeID == id, errorMessage == nil { showingSources = false }
        } catch { sources.error = "Could not read this connection from Keychain. Unlock Keychain or add the source again." }
    }
    private var legacySourceConnection: SourceConnection? {
        if let saved = storageDefaults.dictionary(forKey: "com.iptvplayer.savedXtream") as? [String: String],
           let server = saved["server"], let user = saved["username"], let password = saved["password"] {
            return .xtream(server: server, username: user, password: password)
        }
        if let url = storageDefaults.string(forKey: lastPlaylistKey),
           let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") {
            return .playlist(parsed.absoluteString)
        }
        return nil
    }
    private func rememberSource(_ connection: SourceConnection) {
        let previous = sources.activeID.flatMap { try? sources.connection($0) } ?? legacySourceConnection
        if let previous, previous != connection {
            stop(); catchupChannel = nil; showingDashboard = true
        }
        sources.save(connection)
    }
    private func migrateActiveSource() {
        guard sources.sources.isEmpty, !storageDefaults.bool(forKey: "com.iptvplayer.sources.v1.migrated"),
              let connection = legacySourceConnection else { return }
        sources.save(connection)
    }

    func playCatchup(_ channel: M3UItem, program: GuideProgram) {
        guard channel.contentType == .live, let url = channel.catchup?.url(for: channel, program: program) else {
            errorMessage = "This programme is outside the provider's catch-up window or uses an unsupported archive format."
            return
        }
        let archived = M3UItem(name: "\(channel.name) · \(program.title)", logoURL: channel.logoURL,
                              streamURL: url, contentType: .movie, isCatchup: true)
        catchupOrigin = channel
        showingDashboard = false
        continueWatching(archived)
        catchupOrigin = channel
    }
    func returnToLive() {
        guard let original = catchupOrigin else { return }
        playChannel(original)
    }

    private func cancelStreamRecovery() {
        playbackGeneration = UUID()
        resumePlaybackTask?.cancel(); resumePlaybackTask = nil
        recoveryTask?.cancel(); recoveryTask = nil
        stallTask?.cancel(); stallTask = nil
        stablePlaybackTask?.cancel(); stablePlaybackTask = nil
        recoveryMessage = nil; recoveryAttempts = 0
    }

    private func watchForResume() {
        guard let channel = currentChannel,
              ["http", "https"].contains(channel.streamURL.scheme?.lowercased() ?? ""),
              downloads.localURL(for: channel) == nil else {
            pausedPlaybackPosition = nil
            return
        }
        let generation = playbackGeneration
        let initialPosition = enginePlaybackPosition()
        let useVLC = useVLCPlayback
        resumePlaybackTask = Task { @MainActor [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self, self.playbackGeneration == generation,
                      self.wantsPlayback else { return }
                if self.enginePlaybackPosition() > initialPosition + 0.1 {
                    self.pausedPlaybackPosition = nil
                    self.resumePlaybackTask = nil
                    return
                }
            }
            guard let self, let position = self.pausedPlaybackPosition else { return }
            self.playDirectStream(channel, useVLC: useVLC, position: channel.isVOD ? position : nil,
                                  preservingDetails: self.isViewingMovieDetails || self.isViewingSeriesDetails)
        }
    }
    private func watchForStall() {
        stallTask?.cancel()
        let generation = playbackGeneration
        stallTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.playbackGeneration == generation, self.wantsPlayback, self.isBuffering else { return }
            self.recoverStream()
        }
    }
    private func markStablePlayback() {
        stablePlaybackTask?.cancel()
        recoveryMessage = nil
        let generation = playbackGeneration
        stablePlaybackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.playbackGeneration == generation, self.isPlaying else { return }
            self.recoveryAttempts = 0
        }
    }
    nonisolated static func recoveryDelay(after attempts: Int) -> UInt64? {
        guard (0..<3).contains(attempts) else { return nil }
        return UInt64(2 << attempts) * 1_000_000_000
    }
    func recoverStream() {
        guard recoveryTask == nil, wantsPlayback, let channel = currentChannel,
              ["http", "https"].contains(channel.streamURL.scheme?.lowercased() ?? ""), downloads.localURL(for: channel) == nil else { return }
        if channel.contentType == .live {
            // Give the failed connection the retry delay to close before opening another provider session.
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            #if os(macOS)
            vlcPlayer?.stop()
            #endif
            isPlaying = false
        }
        guard let delay = Self.recoveryDelay(after: recoveryAttempts) else {
            recoveryMessage = nil; isBuffering = false; isPlaying = false
            errorMessage = "Could not reconnect after three attempts. Try again or choose another channel."
            return
        }
        let generation = playbackGeneration
        let attempt = recoveryAttempts + 1
        let useVLC = useVLCPlayback
        let position = channel.contentType == .live ? nil : (pendingResumePosition ?? playbackPosition())
        let details = isViewingMovieDetails || isViewingSeriesDetails
        recoveryMessage = "Reconnecting… attempt \(attempt) of 3"
        errorMessage = nil
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.playbackGeneration == generation,
                  self.wantsPlayback, self.currentChannel?.id == channel.id else { return }
            self.recoveryTask = nil
            self.playDirectStream(channel, useVLC: useVLC, position: position, preservingDetails: details, recoveryAttempt: attempt)
            self.recoveryMessage = "Reconnecting… attempt \(attempt) of 3"
        }
    }
    var canStartOverAfterResumeFailure: Bool {
        pendingResumePosition != nil && errorMessage != nil && currentChannel?.isVOD == true
    }

    func startCurrentStreamOver() {
        guard canStartOverAfterResumeFailure, let channel = currentChannel else { return }
        progressStore.clear(channel)
        playDirectStream(channel, useVLC: useVLCPlayback,
                         preservingDetails: isViewingMovieDetails || isViewingSeriesDetails)
    }

    func retryCurrentStream() {
        guard let channel = currentChannel else { return }
        playDirectStream(channel, useVLC: useVLCPlayback, position: channel.isVOD ? (pendingResumePosition ?? playbackPosition()) : nil)
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
                guard let self, self.player?.currentItem === playerItem, !self.useVLCPlayback,
                      self.wantsPlayback else { return }
                if self.currentChannel?.contentType == .live { self.recoverStream(); return }
                if self.resumePlaybackTask != nil,
                   self.enginePlaybackPosition() <= (self.pausedPlaybackPosition ?? 0) + 0.1 {
                    self.recoverStream()
                    return
                }
                self.pausedPlaybackPosition = nil
                self.cancelStreamRecovery()
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
                                    self.errorMessage = "Could not resume at the saved position. Try again, switch player, or choose Start over."
                                }
                            }
                        }
                    } else if self.wantsPlayback { self.player?.play() }
                    self.subtitles.loadTracksIfNeeded()
                case .failed:
                    guard self.wantsPlayback else { return }
#if os(macOS)
                    if !self.useVLCPlayback, self.currentChannel != nil {
                        if let channel = self.currentChannel {
                            self.playDirectStream(channel, useVLC: true, position: self.pendingResumePosition ?? self.playbackPosition(),
                                preservingDetails: self.isViewingMovieDetails || self.isViewingSeriesDetails, recoveryAttempt: self.recoveryAttempts)
                        }
                        return
                    }
#endif
                    self.isBuffering = false
                    self.isPlaying = false
                    self.errorMessage = Self.playbackErrorDescription(for: item)
                    self.recoverStream()
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
                    self.updatePlaybackState(playing: self.wantsPlayback && pl.timeControlStatus == .playing,
                                             buffering: self.wantsPlayback && pl.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                    if self.isPlaying { self.recordPlaybackStarted() }
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
                    if let first = self.filteredChannels.first ?? self.channels.first, !self.showingDashboard {
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
        self.showingDashboard = true
        self.playlistURLString = ""
        self.reindexCategoriesAndChannels()
        libraryPersistence.clear()
        storageDefaults.removeObject(forKey: "com.iptvplayer.savedXtream")
        storageDefaults.removeObject(forKey: SubscriptionInfo.storageKey)
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
        } else if let target = Self.vlcResumeTime(position: position, seekable: player.isSeekable,
                                                duration: Double(player.media?.length.intValue ?? 0) / 1000) {
            vlcResumeSeekIssued = true
            pendingResumePosition = Double(target) / 1000
            player.time = VLCTime(int: target)
        }
    }

    nonisolated public func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer else { return }
        let state = player.state
        let playing = player.isPlaying
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.vlcPlayer === player, self.recoveryTask == nil else { return }
            self.updatePlaybackState(playing: self.wantsPlayback && playing,
                                     buffering: self.wantsPlayback && (state == .opening || (state == .buffering && !playing)))
            if state == .error {
                self.isBuffering = false
                self.errorMessage = "VLC could not play this stream. Check the stream URL or try another channel."
                self.recoverStream()
            } else if state == .playing {
                self.applyPendingVLCResume(player)
                self.recordPlaybackStarted()
                if !self.wantsPlayback { player.pause() }
                if self.errorMessage != nil { self.errorMessage = nil }
                self.subtitles.nativePlayerDidStart()
                self.audioTracks.refresh()
            } else if state == .ended {
                guard self.wantsPlayback else { return }
                if self.currentChannel?.contentType == .live, self.wantsPlayback { self.recoverStream(); return }
                if self.resumePlaybackTask != nil,
                   self.enginePlaybackPosition() <= (self.pausedPlaybackPosition ?? 0) + 0.1 {
                    self.recoverStream()
                    return
                }
                self.pausedPlaybackPosition = nil
                self.cancelStreamRecovery()
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
        let playing = player.isPlaying
        Task { @MainActor [weak self] in
            guard let self, self.vlcPlayer === player, self.recoveryTask == nil, !self.isSeeking else { return }
            self.updatePlaybackClock(position: current, duration: total)
            // VLC can resume its clock while its last state notification still says buffering.
            self.updatePlaybackState(playing: self.wantsPlayback && playing,
                                     buffering: self.wantsPlayback && !playing && self.isBuffering)
            self.applyPendingVLCResume(player)
            self.saveProgress()
        }
    }
}
#endif

// MARK: - Headset and system media controls

extension IPTVPlayerManager {
    enum RemotePlaybackAction { case play, pause, toggle }

    func configureRemotePlaybackControls() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.playCommand, RemotePlaybackAction.play),
                                  (center.pauseCommand, .pause), (center.togglePlayPauseCommand, .toggle)] {
            let target = command.addTarget { [weak self] _ in
                // Accessories may deliver events off the UI thread.
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { self?.handleRemotePlayback(action) ?? .noSuchContent }
                }
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.handleRemotePlayback(action) ?? .noSuchContent }
                }
            }
            remoteCommandTargets.append((command, target))
        }
        updateRemoteNowPlaying()
    }

    @discardableResult
    func handleRemotePlayback(_ action: RemotePlaybackAction) -> MPRemoteCommandHandlerStatus {
        guard currentChannel != nil, player != nil || useVLCPlayback, resumeRequest == nil else { return .noSuchContent }
        if pendingResumePosition != nil { return .commandFailed }
        let shouldPlay: Bool
        switch action {
        case .play: shouldPlay = true
        case .pause: shouldPlay = false
        case .toggle: shouldPlay = !wantsPlayback
        }
        if shouldPlay != wantsPlayback { setPlaybackPlaying(shouldPlay) }
        return .success
    }

    private func updateRemoteNowPlaying() {
        guard !remoteCommandTargets.isEmpty else { return }
        let active = currentChannel != nil && (player != nil || useVLCPlayback)
        for (command, _) in remoteCommandTargets { command.isEnabled = active }
        let center = MPNowPlayingInfoCenter.default()
        guard active, let item = currentChannel else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.playbackTitle,
            MPMediaItemPropertyArtist: item.contentType == .series ? (playingSeries?.item?.name ?? item.displayGroup) : item.displayGroup,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: item.contentType == .live && item.isCatchup != true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if item.isVOD {
            if currentTime.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime) }
            if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
    }
}
