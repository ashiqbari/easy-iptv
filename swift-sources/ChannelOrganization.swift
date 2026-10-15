import SwiftUI
import CryptoKit

struct ChannelOrganization: Codable {
    var hidden: Set<String> = []
    var hiddenCategories: Set<String> = []
    var favoriteOrder: [String] = []

    static func key(_ item: M3UItem) -> String { PlaybackProgressStore.key(for: item) }
    static func categoryIdentity(_ item: M3UItem) -> String {
        "\(item.streamURL.deletingLastPathComponent().absoluteString)|\(item.contentType.rawValue)|\(item.groupTitle)"
    }
    static func categoryKey(_ item: M3UItem) -> String {
        // Scope provider categories to the source URL without persisting its credentials.
        SHA256.hash(data: Data(categoryIdentity(item).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    func orderedFavorites(_ items: [M3UItem], key: (M3UItem) -> String = Self.key) -> [M3UItem] {
        guard !favoriteOrder.isEmpty else { return items }
        let positions = Dictionary(favoriteOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked: [(item: M3UItem, offset: Int, rank: Int)] = items.enumerated().map { index, item in
            (item, index, positions[key(item)] ?? Int.max)
        }
        return ranked.sorted { left, right in
            left.rank == right.rank ? left.offset < right.offset : left.rank < right.rank
        }.map(\.item)
    }
}

struct ChannelOrganizationView: View {
    @ObservedObject var manager: IPTVPlayerManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appPalette) private var palette
    @State private var search = ""
    @State private var section: M3UItem.ContentType = .live
    @State private var scope = "Channels"
    private var items: [M3UItem] {
        manager.channels.filter { $0.contentType == section && (search.isEmpty || $0.name.localizedStandardContains(search) || $0.groupTitle.localizedStandardContains(search)) }
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Section", selection: $section) {
                    ForEach(M3UItem.ContentType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Organize", selection: $scope) {
                    ForEach(["Channels", "Categories", "Favorites"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                TextField("Search channels or categories…", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if scope == "Categories" {
                            let matchingGroups = search.isEmpty ? nil : Set(items.map(\.groupTitle))
                            let representatives = manager.organizationCategories(in: section).filter { matchingGroups?.contains($0.groupTitle) ?? true }
                            ForEach(representatives) { item in
                                Toggle(item.groupTitle, isOn: Binding(get: {
                                    !manager.organization.hiddenCategories.contains(manager.organizationCategoryKey(item))
                                }, set: { manager.setCategoryHidden(item, hidden: !$0) }))
                            }
                        } else {
                            let visible = scope == "Favorites" ? manager.organization.orderedFavorites(items.filter { manager.isFavorite($0) }, key: manager.organizationKey) : items
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                                HStack {
                                    Toggle(item.name, isOn: Binding(get: { !manager.organization.hidden.contains(manager.organizationKey(item)) },
                                                                  set: { manager.setChannelHidden(item, hidden: !$0) }))
                                    if scope == "Favorites" {
                                        Button { manager.moveFavorite(item, before: visible[index - 1]) } label: { Image(systemName: "arrow.up") }
                                            .disabled(index == 0).accessibilityLabel("Move \(item.name) up")
                                        Button { manager.moveFavorite(visible[index + 1], before: item) } label: { Image(systemName: "arrow.down") }
                                            .disabled(index == visible.count - 1).accessibilityLabel("Move \(item.name) down")
                                    }
                                }
                            }
                        }
                    }.padding(4)
                }
                Text("Turn items off to hide them. Your source, favorites, and watch history are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).background(palette.background)
            .navigationTitle("Organize Channels")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(minWidth: 450, idealWidth: 600, minHeight: 440)
    }
}
