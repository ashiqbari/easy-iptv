import SwiftUI
import CryptoKit

struct SubscriptionAccount: Hashable, Sendable {
    let serverURL: String
    let username: String
    let password: String

    var cacheID: String {
        var hash = SHA256()
        for value in [serverURL, username, password] {
            hash.update(data: Data("\(value.utf8.count):\(value)".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct SubscriptionInfo: Codable, Sendable {
    static let storageKey = "com.iptvplayer.subscriptionInfo.v1"
    let accountID: String
    let status: String?
    let expiryDate: Date?
    let updatedAt: Date
}

extension SubscriptionAccount {
    init?(playlistURL: String) {
        guard let url = URL(string: playlistURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.lastPathComponent.lowercased() == "get.php",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let users = (parts.queryItems ?? []).filter { $0.name == "username" }
        let passwords = (parts.queryItems ?? []).filter { $0.name == "password" }
        guard users.count == 1, passwords.count == 1,
              let username = users.first?.value, !username.isEmpty,
              let password = passwords.first?.value, !password.isEmpty else { return nil }
        parts.path = url.deletingLastPathComponent().path
        parts.queryItems = nil
        parts.fragment = nil
        guard let base = parts.url else { return nil }
        self.init(serverURL: base.absoluteString, username: username, password: password)
    }
}

struct SubscriptionInfoView: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject var manager: IPTVPlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var info: SubscriptionInfo?
    @State private var loading = true
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Subscription Info", systemImage: "calendar.badge.clock")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Group {
                if manager.subscriptionAccount == nil {
                    Text("Expiry information is unavailable for this playlist. Xtream Codes accounts and compatible M3U links can provide subscription details.")
                        .foregroundStyle(.secondary)
                } else if loading && info == nil {
                    ProgressView("Checking subscription…").frame(maxWidth: .infinity)
                } else if let info {
                    VStack(alignment: .leading, spacing: 16) {
                        LabeledContent("Status", value: info.status ?? "Not provided")
                        LabeledContent("Expires") {
                            if let date = info.expiryDate {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .textSelection(.enabled)
                            } else {
                                Text("Not provided by provider")
                            }
                        }
                        Text("Dates are shown in your local time zone (\(TimeZone.current.identifier)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Updated \(info.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if loading { ProgressView().controlSize(.small) }
                            Button("Refresh") { retry += 1 }.disabled(loading)
                        }
                        if failed {
                            Text("Couldn’t refresh. Showing saved details.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if failed {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Couldn’t load subscription details. Check your connection or refresh your source and try again.")
                        Button("Try Again") { retry += 1 }
                    }
                } else {
                    Text("The provider did not return subscription information.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 420)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .background(palette.background)
        .task(id: retry) {
            guard let account = manager.subscriptionAccount else { loading = false; return }
            loading = true
            failed = false
            do {
                let result = try await manager.subscriptionInformation(for: account, refresh: retry > 0)
                try Task.checkCancellation()
                info = result
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
            loading = false
        }
    }
}
