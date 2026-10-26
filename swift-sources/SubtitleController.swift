import AVFoundation
import Combine
import Foundation
#if os(macOS)
import SwiftVLC
#endif

struct SubtitleTrack: Identifiable {
    enum Source {
        case av(AVMediaSelectionOption)
        case file(SubtitleSource)
        #if os(macOS)
        case vlc(SwiftVLC.Track)
        #endif
    }
    let id: String
    let label: String
    let source: Source
}

@MainActor
final class SubtitleController: NSObject, ObservableObject {
    struct PlaybackSelection {
        let track: (id: String, label: String)?
        let files: [SubtitleSource]
    }
    @Published private(set) var tracks: [SubtitleTrack] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var text = ""
    @Published private(set) var isLoadingTracks = false
    @Published private(set) var isLoadingFile = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var timingDelay = 0.0
    @Published var showingMenu = false
    @Published var fontSize: Double = SubtitleController.savedFontSize() {
        didSet {
            let bounded = fontSize.isFinite ? min(48, max(16, fontSize)) : 24
            if fontSize != bounded { fontSize = bounded }
            UserDefaults.standard.set(fontSize, forKey: "com.iptvplayer.subtitleFontSize")
            applyNativeFontSize()
        }
    }

    private var mediaKey: String?
    private var generation = UUID()
    private var selection = UUID()
    private var requestedID: String?
    private var selectionToRestore: (id: String, label: String)?
    private var nativeTracksLoaded = false
    private var providerSources: [SubtitleSource]?
    private var usingOfflineSources = false
    private var failedTrackID: String?
    private var nativeDiscovery: Task<Void, Never>?
    private var providerDiscovery: Task<Void, Never>?
    private var nativeTimeout: Task<Void, Never>?
    private var nativeAttempt = UUID()
    private var nativeError: String?
    private var providerError: String?
    private var fileSelection: Task<Void, Never>?
    private var fileCache = SubtitleFileCache()
    private var document: SubtitleDocument?
    private var time = 0.0
    private var provider: (() async throws -> [SubtitleSource])?
    private weak var avItem: AVPlayerItem?
    private var avGroup: AVMediaSelectionGroup?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    #if os(macOS)
    private weak var vlcPlayer: SwiftVLC.Player?
    #endif

    private static func savedFontSize() -> Double {
        let value = UserDefaults.standard.object(forKey: "com.iptvplayer.subtitleFontSize") as? Double ?? 24
        return value.isFinite ? min(48, max(16, value)) : 24
    }

    deinit {
        nativeDiscovery?.cancel()
        providerDiscovery?.cancel()
        nativeTimeout?.cancel()
        fileSelection?.cancel()
        let cache = fileCache
        Task { await cache.cancel() }
    }

    var playbackSelection: PlaybackSelection {
        let selected = tracks.first { $0.id == (requestedID ?? selectedID) }
        return PlaybackSelection(track: selectionToRestore ?? selected.map { ($0.id, $0.label) },
            files: tracks.compactMap { if case .file(let source) = $0.source { return source }; return nil })
    }

    func restoreSelection(_ selection: PlaybackSelection) {
        selectionToRestore = selection.track
        appendTracks(selection.files.map { SubtitleTrack(id: $0.id, label: $0.label, source: .file($0)) })
    }

    private func applyRestoredSelection() {
        guard let selection = selectionToRestore else { return }
        let native = selection.id.hasPrefix("av:") || selection.id.hasPrefix("vlc:")
        guard let track = tracks.first(where: { $0.id == selection.id && $0.label == selection.label })
            ?? tracks.first(where: {
                if case .file = $0.source { return false }
                return native && $0.label == selection.label
            }) else { return }
        select(track.id)
    }

    func reset(for item: M3UItem?) {
        requestedID = nil
        selectionToRestore = nil
        generation = UUID()
        selection = UUID()
        nativeAttempt = UUID()
        nativeDiscovery?.cancel()
        providerDiscovery?.cancel()
        nativeTimeout?.cancel()
        fileSelection?.cancel()
        nativeDiscovery = nil
        providerDiscovery = nil
        nativeTimeout = nil
        fileSelection = nil
        if let output = legibleOutput {
            output.setDelegate(nil, queue: nil)
            avItem?.remove(output)
        }
        legibleOutput = nil
        avItem = nil
        avGroup = nil
        #if os(macOS)
        try? vlcPlayer?.setSubtitleDelay(.zero)
        vlcPlayer = nil
        #endif
        if mediaKey != item?.subtitleCacheKey {
            let oldCache = fileCache
            Task { await oldCache.cancel() }
            fileCache = SubtitleFileCache()
            providerSources = nil
            timingDelay = 0
        }
        mediaKey = item?.subtitleCacheKey
        tracks = []
        selectedID = nil
        text = ""
        document = nil
        time = 0
        nativeTracksLoaded = false
        nativeError = nil
        providerError = nil
        isLoadingTracks = false
        isLoadingFile = false
        errorMessage = nil
        failedTrackID = nil
        showingMenu = false
        provider = nil
    }

    private func prepareProvider(_ provider: @escaping () async throws -> [SubtitleSource], offlineSources: [SubtitleSource]?) {
        if usingOfflineSources != (offlineSources != nil) { providerSources = nil }
        usingOfflineSources = offlineSources != nil
        if let offlineSources { providerSources = offlineSources }
        self.provider = provider
    }

    func configure(item: AVPlayerItem, provider: @escaping () async throws -> [SubtitleSource], offlineSources: [SubtitleSource]? = nil) {
        avItem = item
        prepareProvider(provider, offlineSources: offlineSources)
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
        item.add(output)
        legibleOutput = output
        loadTracksIfNeeded()
    }

    #if os(macOS)
    func configure(player: SwiftVLC.Player, provider: @escaping () async throws -> [SubtitleSource], offlineSources: [SubtitleSource]? = nil) {
        vlcPlayer = player
        prepareProvider(provider, offlineSources: offlineSources)
        loadTracksIfNeeded()
    }

    func nativePlayerDidStart() {
        if document != nil || selectedID == nil { vlcPlayer?.selectedSubtitleTrack = nil }
        applyNativeFontSize()
        applyNativeTiming()
        loadTracksIfNeeded()
    }
    #endif

    func loadTracksIfNeeded() {
        guard mediaKey != nil else { return }
        let token = generation
        if !nativeTracksLoaded, nativeDiscovery == nil {
            startNativeDiscovery(generation: token)
        }
        if let sources = providerSources {
            appendTracks(sources.map { SubtitleTrack(id: $0.id, label: $0.label, source: .file($0)) })
        } else if providerDiscovery == nil {
            providerError = nil
            let provider = self.provider
            providerDiscovery = Task { [weak self] in
                do {
                    let files = try await provider?() ?? []
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.providerSources = files
                    self.appendTracks(files.map { SubtitleTrack(id: $0.id, label: $0.label, source: .file($0)) })
                } catch {
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.providerError = "Could not load provider subtitles. \(error.localizedDescription)"
                }
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.providerDiscovery = nil
                self.refreshDiscoveryState()
            }
        }
        refreshDiscoveryState()
    }

    private func startNativeDiscovery(generation token: UUID) {
        nativeError = nil
        nativeAttempt = UUID()
        let attempt = nativeAttempt
        let item = avItem
        #if os(macOS)
        let player = vlcPlayer
        #endif
        nativeDiscovery = Task { [weak self] in
            var available: [SubtitleTrack] = []
            do {
                if let item {
                    let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
                    try Task.checkCancellation()
                    guard let self, self.generation == token, self.nativeAttempt == attempt else { return }
                    self.avGroup = group
                    available += (group?.options ?? []).enumerated().map { index, option in
                        SubtitleTrack(id: "av:\(index)", label: option.displayName, source: .av(option))
                    }
                    if self.selectedID == nil, let group { item.select(nil, in: group) }
                }
                #if os(macOS)
                if let player {
                    // Opening/buffering can precede discovery of the embedded tracks.
                    for _ in 0..<100 {
                        if player.state == .playing || player.state == .paused || player.didReachEnd { break }
                        if player.state == .error { throw SubtitleError.discovery }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try Task.checkCancellation()
                    guard let self, self.generation == token, self.nativeAttempt == attempt else { return }
                    guard player.state == .playing || player.state == .paused || player.didReachEnd else { throw SubtitleError.discovery }
                    available += player.subtitleTracks.map {
                        SubtitleTrack(id: "vlc:\($0.id)", label: $0.name, source: .vlc($0))
                    }
                }
                #endif
                try Task.checkCancellation()
                guard let self, self.generation == token, self.nativeAttempt == attempt else { return }
                self.appendTracks(available)
                self.nativeTracksLoaded = true
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.nativeAttempt == attempt else { return }
                self.nativeError = "Could not read embedded subtitles. \(error.localizedDescription)"
            }
            guard let self, !Task.isCancelled, self.generation == token, self.nativeAttempt == attempt else { return }
            self.nativeTimeout?.cancel()
            self.nativeTimeout = nil
            self.nativeDiscovery = nil
            self.refreshDiscoveryState()
        }
        nativeTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled, self.generation == token, self.nativeAttempt == attempt else { return }
            self.nativeAttempt = UUID()
            self.nativeDiscovery?.cancel()
            self.nativeDiscovery = nil
            self.nativeTimeout = nil
            self.nativeError = "Reading embedded subtitles timed out. Retry after playback starts."
            self.refreshDiscoveryState()
        }
    }

    private func appendTracks(_ available: [SubtitleTrack]) {
        var ids = Set(tracks.map(\.id))
        tracks += available.filter { ids.insert($0.id).inserted }
        applyRestoredSelection()
    }

    private func refreshDiscoveryState() {
        isLoadingTracks = nativeDiscovery != nil || providerDiscovery != nil
        if failedTrackID == nil { errorMessage = nativeError ?? providerError }
    }

    func select(_ id: String?) {
        selectionToRestore = nil
        requestedID = id
        selection = UUID()
        let selectionToken = selection
        fileSelection?.cancel()
        fileSelection = nil
        isLoadingFile = false
        errorMessage = nil
        failedTrackID = nil
        selectedID = nil
        document = nil
        text = ""
        if let group = avGroup { avItem?.select(nil, in: group) }
        #if os(macOS)
        vlcPlayer?.selectedSubtitleTrack = nil
        try? vlcPlayer?.setSubtitleDelay(.zero)
        #endif
        guard let id, let track = tracks.first(where: { $0.id == id }) else { return }
        switch track.source {
        case .av(let option):
            guard let group = avGroup else { return }
            selectedID = id
            avItem?.select(option, in: group)
        #if os(macOS)
        case .vlc(let index):
            selectedID = id
            vlcPlayer?.selectedSubtitleTrack = index
            applyNativeFontSize()
            applyNativeTiming()
        #endif
        case .file(let source):
            isLoadingFile = true
            let token = generation
            let cache = fileCache
            fileSelection = Task { [weak self] in
                do {
                    let document = try await cache.document(for: source.url)
                    guard let self, !Task.isCancelled, self.generation == token, self.selection == selectionToken else { return }
                    self.document = document
                    self.selectedID = id
                    self.text = document.text(at: self.time - self.timingDelay)
                    self.isLoadingFile = false
                    self.fileSelection = nil
                } catch {
                    guard let self, !Task.isCancelled, self.generation == token, self.selection == selectionToken else { return }
                    self.errorMessage = "Could not load subtitles. \(error.localizedDescription)"
                    self.failedTrackID = id
                    self.isLoadingFile = false
                    self.fileSelection = nil
                }
            }
        }
    }

    func importFile(_ url: URL) {
        guard mediaKey != nil else { return }
        let source = SubtitleSource(url: url, label: url.deletingPathExtension().lastPathComponent)
        if !tracks.contains(where: { $0.id == source.id }) {
            tracks.append(SubtitleTrack(id: source.id, label: source.label, source: .file(source)))
        }
        select(source.id)
    }

    func reportImportError(_ error: Error) { errorMessage = "Could not open subtitles. \(error.localizedDescription)" }

    func retry() {
        if let failedTrackID { select(failedTrackID) }
        else { loadTracksIfNeeded() }
    }

    func updateTime(_ seconds: Double) {
        time = seconds
        if let document {
            let updated = document.text(at: seconds - timingDelay)
            if text != updated { text = updated }
        }
    }

    var supportsTimingAdjustment: Bool {
        guard let track = tracks.first(where: { $0.id == selectedID }) else { return false }
        switch track.source {
        case .av: return false
        default: return true
        }
    }

    func setTimingDelay(_ seconds: Double) {
        guard seconds.isFinite else { return }
        timingDelay = min(60, max(-60, seconds))
        updateTime(time)
        applyNativeTiming()
    }

    private func applyNativeTiming() {
        #if os(macOS)
        let isNative = tracks.contains { track in
            guard track.id == selectedID else { return false }
            if case .vlc = track.source { return true }
            return false
        }
        do { try vlcPlayer?.setSubtitleDelay(.seconds(isNative ? timingDelay : 0)) }
        catch { errorMessage = "Could not adjust subtitle timing. \(error.localizedDescription)" }
        #endif
    }

    func setNativePictureInPictureRendering(_ enabled: Bool) {
        legibleOutput?.suppressesPlayerRendering = !enabled
    }

    func clearForSeek() { text = "" }

    private func applyNativeFontSize() {
        #if os(macOS)
        guard let player = vlcPlayer else { return }
        player.setSubtitleScale(SubtitleScale(Float(fontSize / 24)))
        #endif
    }
}

extension SubtitleController: AVPlayerItemLegibleOutputPushDelegate {
    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        let value = strings.map(\.string).joined(separator: "\n")
        Task { @MainActor [weak self] in
            guard let self, self.legibleOutput === output,
                  let id = self.selectedID,
                  let track = self.tracks.first(where: { $0.id == id }),
                  case .av = track.source else { return }
            self.text = value
        }
    }
}
