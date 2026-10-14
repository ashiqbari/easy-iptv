#if os(macOS)
import Foundation
import VLC

/// VLCKit stops asynchronously. Retirement must outlive the manager that owns
/// playback, otherwise releasing a manager can release a still-stopping player.
@MainActor
final class VLCPlaybackRetirement: NSObject, VLCMediaPlayerDelegate {
    static let shared = VLCPlaybackRetirement()
    private var players: [ObjectIdentifier: RetiredVLCPlayer] = [:]

    func retire(_ player: VLCMediaPlayer) {
        let identity = ObjectIdentifier(player)
        guard players[identity] == nil else { return }
        players[identity] = RetiredVLCPlayer(player)
        player.delegate = self
        player.audio?.volume = 0
        player.pause()
        player.stop()
    }

    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer, player.state == .stopped else { return }
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let retired = self?.players.removeValue(forKey: identity) else { return }
            retired.player?.delegate = nil
            retired.player?.drawable = nil
            // Finish native event delivery before releasing; VLC destruction can wait for main-thread video setup.
            DispatchQueue.main.async {
                DispatchQueue.global(qos: .userInitiated).async { retired.player = nil }
            }
        }
    }
}

// Ownership transfers to the release queue after main-thread drawable cleanup.
private final class RetiredVLCPlayer: @unchecked Sendable {
    var player: VLCMediaPlayer?
    init(_ player: VLCMediaPlayer) { self.player = player }
}
#endif
