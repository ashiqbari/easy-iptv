import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct DownloadArtwork: View {
    let url: URL?
    let symbol: String
    @State private var localImage: Image?

    var body: some View {
        Group {
            if let url, url.isFileURL {
                if let localImage { localImage.resizable().scaledToFill() }
                else { placeholder }
            } else {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            }
        }
        .task(id: url) {
            localImage = nil
            guard let url, url.isFileURL else { return }
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5 * 1024 * 1024 else { return nil }
                return try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            guard !Task.isCancelled, let data else { return }
            #if os(macOS)
            if let image = NSImage(data: data) { localImage = Image(nsImage: image) }
            #else
            if let image = UIImage(data: data) { localImage = Image(uiImage: image) }
            #endif
        }
    }
    private var placeholder: some View {
        Image(systemName: symbol).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
    }
}

struct DownloadControl: View {
    let item: M3UItem
    let series: M3UItem?
    var details: MediaDetails? = nil
    @ObservedObject var downloads: DownloadManager
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let record = downloads.record(for: item) {
                Menu {
                    if let message = record.message { Text(message) }
                    switch record.status {
                    case .downloading, .queued:
                        Button("Pause") { downloads.pause(record.id) }.disabled(!downloads.canPause(record))
                        Button("Cancel download", role: .destructive) { downloads.remove(record.id) }
                    case .paused:
                        Button("Resume") { downloads.resume(record.id) }
                        Button("Cancel download", role: .destructive) { downloads.remove(record.id) }
                    case .failed:
                        Button("Retry") { downloads.retry(record.id) }
                        Button("Delete", role: .destructive) { confirmingDelete = true }
                    case .downloaded:
                        if downloads.localURL(for: item) == nil { Button("Download missing file again") { downloads.retry(record.id) } }
                        Button("Delete download…", role: .destructive) { confirmingDelete = true }
                    }
                } label: {
                    Label(record.status == .downloaded && downloads.localURL(for: item) == nil ? "Missing — Retry" : record.title,
                          systemImage: record.status == .downloaded && downloads.localURL(for: item) != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                }
            } else {
                Button {
                    downloads.enqueue(item, series: series, details: details)
                } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
        .disabled(!downloads.ready || downloads.deleting.contains(PlaybackProgressStore.key(for: item)))
        .accessibilityLabel("Download \(item.name)")
        .accessibilityValue(downloads.record(for: item)?.title ?? "Not downloaded")
        #if os(iOS)
        .frame(minHeight: 44)
        #endif
        .confirmationDialog("Delete the download for \(item.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete download", role: .destructive) {
                if let record = downloads.record(for: item) { downloads.remove(record.id) }
            }
        } message: { Text("The offline files will be removed. Your viewing progress will be kept.") }
    }
}

struct DownloadSeasonControl: View {
    @ObservedObject var manager: IPTVPlayerManager
    @State private var batch: [M3UItem] = []
    @State private var series: M3UItem?
    @State private var details: MediaDetails?
    @State private var confirming = false
    var body: some View {
        Button {
            batch = manager.filteredEpisodesForSelectedSeason.filter { manager.downloads.record(for: $0) == nil }
            series = manager.downloadSeriesItem
            details = manager.seriesMetadata
            confirming = true
        } label: { Label("Download season", systemImage: "arrow.down.to.line") }
        .disabled(!manager.downloads.ready || manager.filteredEpisodesForSelectedSeason.isEmpty)
        .confirmationDialog("Download \(batch.count) episodes?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Download \(batch.count) episodes") {
                for item in batch { manager.downloads.enqueue(item, series: series, details: details) }
                batch = []
            }
            Button("Cancel", role: .cancel) { batch = [] }
        } message: { Text("Size depends on your provider and may be several GB. Two episodes download at a time; existing downloads are skipped.") }
    }
}

struct DownloadHeaderControls: View {
    @ObservedObject var manager: IPTVPlayerManager
    @ObservedObject var downloads: DownloadManager
    @FocusState private var downloadsFocused: Bool

    static func activeCount(_ records: [DownloadRecord]) -> Int {
        records.filter { $0.status == .queued || $0.status == .downloading }.count
    }

    var body: some View {
        Group {
            Button { Task { await manager.refreshPlaylist() } } label: {
                Label("Refresh Library", systemImage: "arrow.clockwise")
            }
            .help("Refresh and sync latest channels, movies, and TV shows")
            .disabled(manager.isLoading)

            Button { manager.showingDownloads = true } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            .focused($downloadsFocused)
            .help("Downloads")
            .accessibilityLabel("Downloads")
            .accessibilityValue("\(Self.activeCount(downloads.records)) active downloads")
            .overlay(alignment: .topTrailing) {
                let count = Self.activeCount(downloads.records)
                if count > 0 {
                    Text("\(count)").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .foregroundStyle(.white).background(.blue, in: Capsule())
                        .offset(x: 8, y: -7).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .onChange(of: manager.showingDownloads) { _, showing in
            if !showing {
                Task { @MainActor in
                    await Task.yield()
                    if !manager.showingDownloads { downloadsFocused = true }
                }
            }
        }
    }
}

struct DownloadsDialog: View {
    @ObservedObject var manager: IPTVPlayerManager
    @ObservedObject var downloads: DownloadManager

    static func size(in container: CGSize) -> CGSize {
        CGSize(width: min(760, max(0, container.width - 24)),
               height: min(container.width < 600 ? container.height : 720, max(0, container.height - 24)))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { manager.showingDownloads = false }
                    .accessibilityHidden(true)
                DownloadsView(manager: manager, downloads: downloads)
                    .frame(width: Self.size(in: geometry.size).width, height: Self.size(in: geometry.size).height)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { } // Only taps outside the card dismiss it.
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DownloadsView: View {
    @ObservedObject var manager: IPTVPlayerManager
    @ObservedObject var downloads: DownloadManager
    @State private var confirmingAll = false
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.title2.bold())
                Spacer()
                Button { manager.showingDownloads = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .padding(8)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Close Downloads")
                .help("Close Downloads")
                .keyboardShortcut(.cancelAction)
                .focused($closeFocused)
            }.padding()
            Divider()
            if !downloads.isOnline {
                Text("You're offline. Downloaded movies and episodes are ready to play.")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
            if let error = downloads.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).padding()
            }
            if downloads.loading { ProgressView("Loading downloads…").padding() }
            if !downloads.loading && !downloads.ready {
                Text("Downloads couldn't be opened. Check storage access and reopen the app.").foregroundStyle(.secondary).padding()
            }
            if downloads.ready {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let movies = downloads.records.filter { $0.item.contentType == .movie }
                        Text("Movies (\(movies.count))").font(.headline)
                        if movies.isEmpty { Text("No downloaded movies").foregroundStyle(.secondary) }
                        ForEach(movies) { row($0) }
                        Divider()
                        let shows = Dictionary(grouping: downloads.records.filter { $0.item.contentType == .series }, by: \.seriesKey)
                        Text("Series (\(shows.count))").font(.headline)
                        if shows.isEmpty { Text("No downloaded series").foregroundStyle(.secondary) }
                        ForEach(shows.keys.sorted(), id: \.self) { key in
                            let episodes = shows[key] ?? []
                            DisclosureGroup("\(episodes.first?.series?.name ?? episodes.first?.item.groupTitle ?? "TV Shows") (\(episodes.count))") {
                                let seasons = Dictionary(grouping: episodes, by: { $0.item.seasonNumber ?? 0 })
                                ForEach(seasons.keys.sorted(), id: \.self) { season in
                                    DisclosureGroup("\(season > 0 ? "Season \(season)" : "Episodes") (\(seasons[season]?.count ?? 0))") {
                                        ForEach((seasons[season] ?? []).sorted { ($0.item.episodeNumber ?? 0) < ($1.item.episodeNumber ?? 0) }) { row($0) }
                                    }.padding(.leading, 12)
                                }
                            }
                        }
                    }.padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Spacer()
                Button("Delete all downloads…", role: .destructive) { confirmingAll = true }
                    .disabled(downloads.records.isEmpty || !downloads.deleting.isEmpty)
            }.padding()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloads")
        .onAppear { closeFocused = true }
        #if os(macOS)
        .focusSection()
        .onExitCommand { manager.showingDownloads = false }
        #else
        .accessibilityAddTraits(.isModal)
        #endif
        .confirmationDialog("Delete all downloads?", isPresented: $confirmingAll, titleVisibility: .visible) {
            Button("Delete all downloads", role: .destructive) {
                if manager.currentChannel.map({ downloads.localURL(for: $0) != nil }) == true { manager.stop() }
                for record in downloads.records { downloads.remove(record.id) }
            }
        } message: { Text("All offline media and subtitle files will be removed. Viewing progress will be kept.") }
    }

    private func row(_ record: DownloadRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            DownloadArtwork(url: downloads.poster(for: record), symbol: record.item.contentType.iconName)
                .frame(width: 52, height: 76).clipped().cornerRadius(6).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.item.name).font(.headline)
                if let season = record.item.seasonNumber, let episode = record.item.episodeNumber {
                    Text("Season \(season) • Episode \(episode)").font(.caption).foregroundStyle(.secondary)
                }
                Text(record.totalBytes > 0
                    ? "\(record.title) • \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file))"
                    : record.bytes > 0 ? "\(record.title) • \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))"
                    : "\(record.title) • Size not available yet").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: record.status == .downloaded ? 1 : record.progress)
                    .accessibilityLabel("Download progress for \(record.item.name)")
                if let message = record.message { Text(message).font(.caption).foregroundStyle(record.status == .failed ? .red : .secondary) }
                ViewThatFits(in: .horizontal) {
                    HStack { actions(record) }
                    VStack(alignment: .leading) { actions(record) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func actions(_ record: DownloadRecord) -> some View {
        if downloads.localURL(for: record.item) != nil {
            Button {
                manager.pendingDownload = record
                manager.showingDownloads = false
            } label: { Label("Play", systemImage: "play.fill") }
        }
        DownloadControl(item: record.item, series: record.series, downloads: downloads)
    }
}
