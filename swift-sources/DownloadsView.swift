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

struct DownloadsView: View {
    @ObservedObject var manager: IPTVPlayerManager
    @ObservedObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingAll = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                if downloads.ready && downloads.records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle").font(.largeTitle)
                        Text("No downloads yet").font(.headline)
                        Text("Download movies from their details page, or episodes from a series.").foregroundStyle(.secondary)
                    }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        let movies = downloads.records.filter { $0.item.contentType == .movie }
                        if !movies.isEmpty { Section("Movies") { ForEach(movies) { row($0) } } }
                        let shows = Dictionary(grouping: downloads.records.filter { $0.item.contentType == .series }, by: \.seriesKey)
                        ForEach(shows.keys.sorted(), id: \.self) { key in
                            let episodes = shows[key] ?? []
                            Section(episodes.first?.series?.name ?? episodes.first?.item.groupTitle ?? "TV Shows") {
                                let seasons = Dictionary(grouping: episodes, by: { $0.item.seasonNumber ?? 0 })
                                ForEach(seasons.keys.sorted(), id: \.self) { season in
                                    Text(season > 0 ? "Season \(season)" : (seasons[season]?.first?.item.groupTitle ?? "Episodes"))
                                        .font(.headline).foregroundStyle(.secondary)
                                    ForEach((seasons[season] ?? []).sorted { ($0.item.episodeNumber ?? 0) < ($1.item.episodeNumber ?? 0) }) { row($0) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Delete all downloads…", role: .destructive) { confirmingAll = true }
                        .disabled(downloads.records.isEmpty || !downloads.deleting.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 740, minHeight: 500, idealHeight: 650)
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
                    : "\(record.title) • Size not available yet").font(.caption).foregroundStyle(.secondary)
                if record.status != .downloaded {
                    ProgressView(value: record.progress).accessibilityLabel("Download progress for \(record.item.name)")
                }
                if let message = record.message { Text(message).font(.caption).foregroundStyle(record.status == .failed ? .red : .secondary) }
                HStack {
                    if downloads.localURL(for: record.item) != nil {
                        Button { manager.pendingDownload = record; dismiss() } label: { Label("Play", systemImage: "play.fill") }
                    }
                    DownloadControl(item: record.item, series: record.series, downloads: downloads)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }
}
