import SwiftUI
import Security

struct SavedSource: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
}

enum SourceConnection: Codable, Equatable {
    case playlist(String)
    case xtream(server: String, username: String, password: String)

    var suggestedName: String {
        let address: String
        switch self {
        case .playlist(let url): address = url
        case .xtream(let server, _, _): address = server
        }
        return URLComponents(string: address)?.host ?? "IPTV Source"
    }
}

@MainActor
final class SavedSourceStore: ObservableObject {
    @Published private(set) var sources: [SavedSource]
    @Published private(set) var activeID: UUID?
    @Published var error: String?
    private let defaults: UserDefaults
    private let secure: Bool
    private var memory: [UUID: Data] = [:]
    private let key = "com.iptvplayer.sources.v1"
    private let service = "com.iptvplayer.savedSources"

    // Tests use isolated in-memory secrets so fixtures never access the user's Keychain.
    init(defaults: UserDefaults, secure: Bool = true) {
        self.defaults = defaults; self.secure = secure
        sources = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedSource].self, from: $0) } ?? []
        activeID = defaults.string(forKey: key + ".active").flatMap(UUID.init(uuidString:))
    }

    func connection(_ id: UUID) throws -> SourceConnection {
        let data: Data
        if secure {
            var query = query(id)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let found = result as? Data else {
                throw CocoaError(.fileReadNoPermission)
            }
            data = found
        } else {
            guard let found = memory[id] else { throw CocoaError(.fileNoSuchFile) }
            data = found
        }
        return try JSONDecoder().decode(SourceConnection.self, from: data)
    }

    func save(_ connection: SourceConnection) {
        do {
            let existing = sources.first { (try? self.connection($0.id)) == connection }
            let record = existing ?? SavedSource(id: UUID(), name: connection.suggestedName)
            let data = try JSONEncoder().encode(connection)
            if secure {
                let attributes: [CFString: Any] = [kSecValueData: data]
                var status = SecItemUpdate(query(record.id) as CFDictionary, attributes as CFDictionary)
                if status == errSecItemNotFound {
                    var item = query(record.id)
                    item[kSecValueData] = data
                    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    status = SecItemAdd(item as CFDictionary, nil)
                }
                guard status == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
            } else { memory[record.id] = data }
            if existing == nil { sources.append(record) }
            activeID = record.id
            defaults.set(record.id.uuidString, forKey: key + ".active")
            persist()
            defaults.set(true, forKey: key + ".migrated")
            error = nil
        } catch {
            activeID = nil; defaults.removeObject(forKey: key + ".active")
            self.error = "The source loaded, but its connection could not be saved securely. Check Keychain access and try again." }
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].name = String(clean.prefix(80)); persist()
    }

    func remove(_ id: UUID) {
        if secure {
            let status = SecItemDelete(query(id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                error = "Could not remove this source from Keychain. Try again after unlocking Keychain."
                return
            }
        } else { memory[id] = nil }
        sources.removeAll { $0.id == id }
        if activeID == id { activeID = nil; defaults.removeObject(forKey: key + ".active") }
        persist()
    }

    private func query(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(sources) { defaults.set(data, forKey: key) }
    }
}

struct SavedSourcesView: View {
    @ObservedObject var manager: IPTVPlayerManager
    @ObservedObject var store: SavedSourceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appPalette) private var palette
    @State private var removing: SavedSource?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if store.sources.isEmpty { Text("Sources you successfully connect to are saved here.").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.sources) { source in
                            HStack {
                                TextField("Source name", text: Binding(get: {
                                    store.sources.first { $0.id == source.id }?.name ?? source.name
                                }, set: { store.rename(source.id, to: $0) }))
                                if store.activeID == source.id { Text("Active").font(.caption).foregroundStyle(.secondary) }
                                Button("Connect") { Task { await manager.switchSource(source.id) } }.disabled(manager.isLoading)
                                Button(role: .destructive) { removing = source } label: { Image(systemName: "trash") }
                                    .accessibilityLabel("Remove \(source.name)")
                            }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                if manager.isLoading { ProgressView("Connecting…") }
                if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
                if let error = manager.errorMessage { Text(error).font(.callout).foregroundStyle(.secondary) }
                Button { dismiss(); manager.showingPlaylistSheet = true } label: { Label("Add Source", systemImage: "plus") }
            }
            .padding(20).background(palette.background)
            .navigationTitle("Sources")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 420, idealWidth: 540, minHeight: 300)
        .confirmationDialog("Remove saved source?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let source = removing {
                Button("Remove \(source.name)", role: .destructive) { store.remove(source.id); removing = nil }
            }
        } message: { Text("This removes the saved connection. It does not delete downloads or viewing history.") }
    }
}
