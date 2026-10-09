#if os(macOS)
import Foundation
import VLC

/// VLCKit stops asynchronously. Retirement must outlive the manager that owns
/// playback, otherwise releasing a manager can release a still-stopping player.
@MainActor
final class VLCPlaybackRetirement: NSObject, VLCMediaPlayerDelegate {
    static let shared = VLCPlaybackRetirement()
    private var players: [ObjectIdentifier: VLCMediaPlayer] = [:]

    func retire(_ player: VLCMediaPlayer) {
        let identity = ObjectIdentifier(player)
        guard players[identity] == nil else { return }
        players[identity] = player
        player.delegate = self
        player.audio?.volume = 0
        player.pause()
        player.stop()
    }

    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer, player.state == .stopped else { return }
        Task { @MainActor [weak self] in
            guard let self, self.players[ObjectIdentifier(player)] != nil else { return }
            player.delegate = nil
            player.drawable = nil
            self.players.removeValue(forKey: ObjectIdentifier(player))
        }
    }
}
#endif
