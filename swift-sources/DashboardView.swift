import SwiftUI

struct DashboardResumeItem: Identifiable {
    let item: M3UItem
    let progress: PlaybackProgress
    let season: Int?
    let episode: Int?
    var id: UUID { item.id }
    var subtitle: String {
        let episodeLabel = season.flatMap { season in episode.map { "S\(season) · E\($0) · " } } ?? ""
        return "\(episodeLabel)Resume at \(PlaybackProgress.timestamp(progress.position))"
    }
}

struct DashboardView: View {
    @ObservedObject var manager: IPTVPlayerManager
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appPalette) private var palette
    private var accent: Color { palette.accent }
    private var background: Color {
        palette.background
    }

    var body: some View {
        GeometryReader { geometry in
            let padding: CGFloat = geometry.size.width < 600 ? 16 : 28
            let width = max(0, min(1400, geometry.size.width) - padding * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    welcome(compact: width < 560)
                    browseShortcuts
                    if manager.isLoading {
                        ProgressView("Loading your library…")
                    }
                    if let error = manager.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    let resumeItems = manager.dashboardContinueWatching
                    if !resumeItems.isEmpty {
                        sectionHeader("Continue watching", subtitle: "Pick up where you left off", icon: "play.circle.fill")
                        DashboardShelf(items: resumeItems, width: width, cardWidth: min(280, max(140, width - 6))) { entry in
                            Button { manager.openDashboardItem(entry.item, resume: true) } label: {
                                mediaCard(entry.item, subtitle: entry.subtitle, progress: entry.progress.fraction,
                                          width: min(280, max(140, width - 6)), large: true)
                            }
                            .buttonStyle(DashboardCardStyle())
                            .accessibilityLabel("\(entry.item.name), \(entry.subtitle)")
                        }.padding(.top, -16)
                    }
                    channelSection("Recent channels", subtitle: "Your last stops on live TV", icon: "clock.arrow.circlepath",
                                   items: manager.dashboardRecentChannels, width: width)
                    channelSection("Favorites", subtitle: "Always within reach", icon: "star.fill", items: manager.dashboardFavorites, width: width)
                    if manager.channels.isEmpty, !manager.isLoading {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Your next watch starts here", systemImage: "sparkles").font(.title3.bold())
                            Text("Add your IPTV source to browse channels, movies, and series. Your favorites and watch history will appear here.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button { manager.showingPlaylistSheet = true } label: { Label("Add Source", systemImage: "plus.circle.fill") }
                                .buttonStyle(.borderedProminent).tint(palette.controlAccent)
                        }
                        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(padding)
                .frame(width: geometry.size.width)
            }
        }
        .background(background)
        .tint(palette.controlAccent)
        .navigationTitle("Home")
    }

    private func welcome(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Label("YOUR WATCHING SPACE", systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(accent)
                Text("Something good\nto come home to.")
                    .font(.system(size: compact ? 26 : 34, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Live moments. Movie nights. One place.")
                    .font(.subheadline).foregroundStyle(Color.primary.opacity(0.78))
                if let current = manager.currentChannel {
                    Button { manager.pictureInPicture.restorePlayer() } label: {
                        Label("Back to \(current.name)", systemImage: "play.fill").lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent).tint(palette.controlAccent)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            if !compact {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(accent.opacity(0.7))
                .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Color.primary)
        .padding(compact ? 20 : 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [palette.surface, accent.opacity(0.14)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var browseShortcuts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { shortcutCards }
            VStack(spacing: 14) { shortcutCards }
        }
    }

    private var shortcutCards: some View {
        ForEach(M3UItem.ContentType.allCases, id: \.self) { section in
            let color = sectionColor(section)
            Button { manager.browse(section) } label: {
                HStack(spacing: 12) {
                    Image(systemName: section.iconName).font(.title2).foregroundStyle(color)
                        .frame(width: 42, height: 46)
                        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section == .series ? "Series" : section.rawValue).font(.headline)
                        Text("\(manager.dashboardCounts[section, default: 0]) \(section == .live ? "channels" : "titles")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(minWidth: 175, maxWidth: .infinity)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(DashboardCardStyle())
        }
    }

    private func sectionHeader(_ title: String, subtitle: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.title3.bold())
                .foregroundStyle(title == "Favorites" ? (scheme == .dark ? Color.yellow : .brown) : accent)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func channelSection(_ title: String, subtitle: String, icon: String, items: [M3UItem], width: CGFloat) -> some View {
        if !items.isEmpty {
            sectionHeader(title, subtitle: subtitle, icon: icon)
            DashboardShelf(items: items, width: width, cardWidth: min(200, max(140, width - 6))) { item in
                Button { manager.openDashboardItem(item) } label: {
                    mediaCard(item, subtitle: item.contentType == .live ? "Watch live" : item.contentType.rawValue,
                              width: min(200, max(140, width - 6)))
                }
                .buttonStyle(DashboardCardStyle())
                .accessibilityLabel("\(item.name), \(item.contentType == .live ? "Watch live" : "Open details")")
            }.padding(.top, -16)
        }
    }

    private var cardBackground: Color {
        palette.surface
    }

    private func sectionColor(_ section: M3UItem.ContentType) -> Color {
        switch section {
        case .live: return accent
        case .movie: return scheme == .dark ? .purple.opacity(0.9) : .purple
        case .series: return scheme == .dark ? .orange : .brown
        }
    }

    private func mediaCard(_ item: M3UItem, subtitle: String, progress: Double? = nil, width: CGFloat, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(LinearGradient(colors: [sectionColor(item.contentType).opacity(0.25), cardBackground],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                AsyncImage(url: item.logoURL) { image in
                    image.resizable().scaledToFit().padding(12)
                } placeholder: {
                    Image(systemName: item.contentType.iconName)
                        .font(.system(size: large ? 48 : 36)).foregroundStyle(sectionColor(item.contentType).opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                Label(item.contentType == .live ? "LIVE" : (large ? "RESUME" : item.contentType.rawValue.uppercased()),
                      systemImage: item.contentType == .live ? "dot.radiowaves.left.and.right" : "play.fill")
                    .font(.caption2.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule()).padding(12)
            }
            .frame(height: large ? 154 : 100).clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(item.name).font(.headline).lineLimit(2).frame(height: 38, alignment: .topLeading)
                if item.contentType == .live {
                    DashboardNowPlaying(item: item, index: manager.guideIndex, revision: manager.guideRevision)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let progress { ProgressView(value: progress).tint(palette.controlAccent).accessibilityLabel("Watch progress") }
            }
            .padding(14)
        }
        .frame(width: width, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.12)))
    }
}

private struct DashboardCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @Environment(\.appPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.accent.opacity(hovering ? 0.65 : 0), lineWidth: 2))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Only reads the existing guide cache; opening Home never downloads provider schedules.
private struct DashboardNowPlaying: View {
    let item: M3UItem
    let index: GuideSearchIndex
    let revision: UUID
    @State private var programs: [GuideProgram] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let program = programs.first { $0.isCurrent(at: context.date) }
            VStack(alignment: .leading, spacing: 8) {
                Text(program.map { "On now · \($0.title)" } ?? "Watch live")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let program {
                    ProgressView(value: program.progress(at: context.date))
                        .accessibilityLabel("Programme progress")
                }
            }
            .task(id: "\(revision)|\(context.date.timeIntervalSince1970 / 60)") {
                programs = (try? await index.programs(for: item, now: context.date)) ?? []
            }
        }
    }
}

private struct DashboardShelfPositions: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct DashboardShelf<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let width: CGFloat
    let cardWidth: CGFloat
    @ViewBuilder let card: (Item) -> Card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var firstVisible = 0
    @State private var coordinateSpace = UUID()

    private var pageSize: Int { max(1, Int(width / (cardWidth + 16))) }
    private var lastPage: Int { max(0, items.count - pageSize) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .trailing, spacing: 8) {
                if items.count > pageSize {
                    HStack(spacing: 12) {
                        Button {
                            scroll(to: max(0, firstVisible - pageSize), proxy: proxy)
                        } label: { Image(systemName: "chevron.left").frame(width: 28, height: 24) }
                        .disabled(firstVisible == 0).accessibilityLabel("Previous items")
                        Button {
                            scroll(to: min(lastPage, firstVisible + pageSize), proxy: proxy)
                        } label: { Image(systemName: "chevron.right").frame(width: 28, height: 24) }
                        .disabled(firstVisible >= lastPage).accessibilityLabel("Next items")
                    }
                    .buttonStyle(.bordered)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            card(item).id(item.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: DashboardShelfPositions.self,
                                        value: [index: geometry.frame(in: .named(coordinateSpace))])
                                })
                        }
                    }.padding(3)
                }
                .coordinateSpace(name: coordinateSpace)
                .onPreferenceChange(DashboardShelfPositions.self) { frames in
                    firstVisible = frames.filter { $0.value.minX >= -1 && $0.value.minX < width }.map(\.key).min() ?? 0
                }
            }
            .frame(width: width)
        }
    }

    private func scroll(to index: Int, proxy: ScrollViewProxy) {
        guard items.indices.contains(index) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            proxy.scrollTo(items[index].id, anchor: .leading)
        }
    }
}
