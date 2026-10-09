import Foundation
import Combine
import CryptoKit

struct PlaybackProgress: Codable, Equatable {
    let position: Double
    let duration: Double
    let updatedAt: Date
    let completed: Bool

    var resumePosition: Double? {
        guard !completed, position >= 5 else { return nil }
        return position
    }

    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    static func isFinished(position: Double, duration: Double) -> Bool {
        duration > 0 && (position >= duration * 0.95 || (duration >= 90 && duration - position <= 45))
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Stable media identity includes provider, media ID, series, season and episode.
/// Hashing keeps provider credentials out of persisted dictionary keys.
@MainActor
final class PlaybackProgressStore: ObservableObject {
    @Published private(set) var records: [String: PlaybackProgress]
    private let defaults: UserDefaults
    private let storageKey = "com.iptvplayer.playbackProgress.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: PlaybackProgress].self, from: $0) } ?? [:]
    }

    static func key(for item: M3UItem) -> String {
        SHA256.hash(data: Data(item.subtitleCacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func progress(for item: M3UItem) -> PlaybackProgress? { records[Self.key(for: item)] }

    func save(item: M3UItem, position: Double, duration: Double, completed: Bool = false) {
        guard item.contentType != .live, position.isFinite, duration.isFinite, position >= 0 else { return }
        let key = Self.key(for: item)
        let total = duration > 0 ? duration : (records[key]?.duration ?? 0)
        records[key] = PlaybackProgress(position: total > 0 ? min(position, total) : position,
                                        duration: total, updatedAt: Date(),
                                        completed: completed || PlaybackProgress.isFinished(position: position, duration: total))
        persist()
    }

    func clear(_ item: M3UItem) {
        records.removeValue(forKey: Self.key(for: item))
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: storageKey) }
    }
}

struct PlaybackResumeRequest: Identifiable {
    let id = UUID()
    let item: M3UItem
    let position: Double
    let useVLC: Bool
}
