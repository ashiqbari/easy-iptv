import SwiftUI
import Combine

@MainActor
final class GuideSearchModel: ObservableObject {
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var scope: GuideSearchScope = .now { didSet { scheduleSearch() } }
    @Published private(set) var hits: [GuideSearchHit] = []
    @Published private(set) var channelsByKey: [String: M3UItem] = [:]
    @Published private(set) var indexing = false
    @Published private(set) var searching = false
    @Published private(set) var summary: GuideRefreshSummary?
    @Published private(set) var importError: String?
    @Published private(set) var searchError: String?
    @Published private(set) var offset = 0
    @Published private(set) var hasMore = false
    private let index: GuideSearchIndex
    private var channels: [M3UItem] = []
    private var libraryIDs: [UUID] = []
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private var refreshedAt = Date.distantPast

    init(index: GuideSearchIndex = GuideSearchIndex()) { self.index = index }
    deinit { refreshTask?.cancel(); searchTask?.cancel() }

    func setChannels(_ items: [M3UItem]) {
        let live = items.filter { $0.contentType == .live }
        let ids = live.map(\.id)
        guard ids != libraryIDs || refreshTask == nil && summary == nil else { return }
        channels = live; libraryIDs = ids
        channelsByKey = [:]; hits = []; summary = nil
        refresh()
    }

    func refresh(force: Bool = false) {
        guard !indexing || !force else { return }
        generation += 1
        let token = generation
        refreshTask?.cancel(); searchTask?.cancel()
        indexing = true; importError = nil
        let items = channels, index = self.index
        refreshTask = Task { [weak self] in
            do {
                let mappingTask = Task.detached(priority: .utility) {
                    var result: [String: M3UItem] = [:]
                    for item in items {
                        try Task.checkCancellation()
                        result[GuideSearchIndex.channelKey(item)] = item
                    }
                    return result
                }
                let mapping = try await withTaskCancellationHandler(operation: { try await mappingTask.value },
                                                                   onCancel: { mappingTask.cancel() })
                try Task.checkCancellation()
                guard let self, token == self.generation else { return }
                self.channelsByKey = mapping
                self.scheduleSearch()
                let result = try await index.refresh(channels: items, force: force)
                try Task.checkCancellation()
                guard token == self.generation else { return }
                self.summary = result
                self.refreshedAt = Date()
                self.indexing = false
                self.scheduleSearch()
            } catch {
                guard !Task.isCancelled, let self, token == self.generation else { return }
                self.indexing = false; self.importError = error.localizedDescription
                self.refreshedAt = Date()
                self.scheduleSearch()
            }
        }
    }

    func scheduleSearch(offset: Int = 0) {
        searchTask?.cancel()
        self.offset = offset; hasMore = false; searchError = nil; hits = []
        guard GuideSearchIndex.matchExpression(query) != nil else { searching = false; return }
        searching = true
        let text = query, scope = self.scope, index = self.index, token = generation
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                let result = try await index.search(text, scope: scope, offset: offset)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.hits = result.hits.filter { self.channelsByKey[$0.channelKey] != nil }
                self.hasMore = result.hasMore; self.searching = false
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.searchError = error.localizedDescription; self.searching = false
            }
        }
    }

    func tick() {
        if !indexing, !Calendar.current.isDate(refreshedAt, inSameDayAs: Date()) || Date().timeIntervalSince(refreshedAt) >= 10_800 {
            refresh()
        } else if !searching { scheduleSearch(offset: offset) }
    }

    func cancel() {
        generation += 1
        refreshTask?.cancel(); searchTask?.cancel()
        refreshTask = nil; searchTask = nil
        indexing = false; searching = false
    }
}

struct GuideSearchView: View {
    @ObservedObject var manager: IPTVPlayerManager
    @StateObject private var model = GuideSearchModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search a team, match, or programme…", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search TV guide")
                Picker("Programme time", selection: $model.scope) {
                    ForEach(GuideSearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.indexing { ProgressView("Updating guide index in the background…").font(.caption) }
                if let error = model.importError {
                    Text(error).foregroundStyle(.secondary)
                }
                if let summary = model.summary {
                    if summary.failedFeeds > 0 {
                        Text("Couldn't refresh \(summary.failedFeeds) guide(s). \(summary.failureMessage ?? "") Any previously cached listings remain searchable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if summary.unavailableChannels > 0 {
                        Text("\(summary.unavailableChannels) channel(s) have no XMLTV guide URL or channel ID and cannot be searched.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                if model.searching { ProgressView("Searching…") }
                if let error = model.searchError { Text(error).foregroundStyle(.secondary) }
                if model.hits.isEmpty, !model.searching {
                    Text(model.query.isEmpty ? "Search today's guide to find channels showing your programme." :
                            model.indexing ? "The guide import is still running. Results will update when ready." :
                            "No matching programmes found in the available guide.")
                        .foregroundStyle(.secondary)
                    Text("Results reflect provider listings, not verification of the live broadcast.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.hits) { hit in
                            if let channel = model.channelsByKey[hit.channelKey] {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(hit.program.title).font(.headline)
                                    Text(channel.name).font(.subheadline)
                                    Text(hit.program.timeRange).font(.caption).foregroundStyle(.secondary)
                                    if !hit.program.description.isEmpty {
                                        Text(hit.program.description).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                                    }
                                    if hit.program.isCurrent(at: Date()) {
                                        Button { manager.playChannel(channel); dismiss() } label: { Label("Watch", systemImage: "play.fill") }
                                            .buttonStyle(.borderedProminent)
                                            .accessibilityLabel("Watch \(channel.name)")
                                    } else {
                                        Label("Upcoming", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                HStack {
                    Button("Previous") { model.scheduleSearch(offset: max(0, model.offset - 50)) }
                        .disabled(model.offset == 0 || model.searching)
                    Text("Page \(model.offset / 50 + 1)").font(.caption).foregroundStyle(.secondary)
                    Button("Next") { model.scheduleSearch(offset: model.offset + 50) }
                        .disabled(!model.hasMore || model.searching)
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("Search TV Guide")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .automatic) {
                    Button { model.refresh(force: true) } label: { Label("Refresh guides", systemImage: "arrow.clockwise") }
                        .disabled(model.indexing)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 620, minHeight: 500, idealHeight: 650)
        #endif
        .onReceive(manager.$channels) { model.setChannels($0) }
        .onReceive(timer) { _ in if scenePhase == .active { model.tick() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in if scenePhase == .active { model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in if scenePhase == .active { model.tick() } }
        #if os(macOS)
        .onChange(of: scenePhase) { _, phase in handlePhase(phase) }
        #else
        .onChange(of: scenePhase) { phase in handlePhase(phase) }
        #endif
        .onDisappear { model.cancel() }
    }

    private func handlePhase(_ phase: ScenePhase) {
        if phase == .active { model.refresh() } else { model.cancel() }
    }
}
