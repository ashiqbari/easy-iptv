import SwiftUI
import AVFoundation
#if os(macOS)
import VLC
#endif

struct AudioTrack: Identifiable {
    enum Source {
        case av(AVMediaSelectionOption)
        #if os(macOS)
        case vlc(Int32)
        #endif
    }
    let id: String
    let name: String
    let source: Source
}

@MainActor
final class AudioTrackController: ObservableObject {
    @Published private(set) var tracks: [AudioTrack] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var showingMenu = false
    private weak var item: AVPlayerItem?
    private var group: AVMediaSelectionGroup?
    private var discovery: Task<Void, Never>?
    #if os(macOS)
    private weak var player: VLCMediaPlayer?
    #endif
    deinit { discovery?.cancel() }

    func reset() {
        discovery?.cancel(); discovery = nil
        item = nil; group = nil; tracks = []; selectedID = nil; loading = false; error = nil; showingMenu = false
        #if os(macOS)
        player = nil
        #endif
    }
    func configure(_ item: AVPlayerItem) { reset(); self.item = item }
    #if os(macOS)
    func configure(_ player: VLCMediaPlayer) { reset(); self.player = player }
    #endif
    func refresh() {
        #if os(macOS)
        if let player {
            let names = player.audioTrackNames as? [String] ?? []
            let ids = player.audioTrackIndexes as? [NSNumber] ?? []
            tracks = zip(names, ids).filter { $0.1.int32Value >= 0 }.map {
                AudioTrack(id: "vlc:\($0.1)", name: $0.0, source: .vlc($0.1.int32Value))
            }
            selectedID = "vlc:\(player.currentAudioTrackIndex)"
            return
        }
        #endif
        guard let item, !loading else { return }
        loading = true; error = nil
        discovery = Task { [weak self] in
            do {
                let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
                try Task.checkCancellation()
                guard let self, self.item === item else { return }
                self.group = group
                self.tracks = group?.options.enumerated().map {
                    AudioTrack(id: "av:\($0.offset)", name: $0.element.displayName, source: .av($0.element))
                } ?? []
                self.selectedID = self.tracks.first {
                    if let group, case .av(let option) = $0.source { return item.currentMediaSelection.selectedMediaOption(in: group) == option }
                    return false
                }?.id
                self.loading = false
            } catch {
                guard !Task.isCancelled, let self, self.item === item else { return }
                self.loading = false; self.error = "Audio tracks couldn't be loaded. Try again after playback starts."
            }
        }
    }
    func select(_ id: String) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        switch track.source {
        case .av(let option):
            guard let item, let group else { return }
            item.select(option, in: group)
        #if os(macOS)
        case .vlc(let index):
            guard let player else { return }
            player.currentAudioTrackIndex = index
        #endif
        }
        selectedID = id
    }
}

struct AudioTrackControl: View {
    let manager: IPTVPlayerManager
    @ObservedObject var controller: AudioTrackController
    var body: some View {
        Button { controller.showingMenu.toggle(); if controller.showingMenu { controller.refresh() } } label: {
            Label("Audio", systemImage: "waveform")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                #if os(iOS)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain).accessibilityLabel("Audio tracks").help("Choose audio language or track")
        .popover(isPresented: $controller.showingMenu) { AudioTrackMenu(controller: controller) }
        #if os(macOS)
        .onChange(of: controller.showingMenu) { _, showing in menuVisibilityChanged(showing) }
        #else
        .onChange(of: controller.showingMenu) { showing in menuVisibilityChanged(showing) }
        #endif
    }

    private func menuVisibilityChanged(_ showing: Bool) {
        if showing { manager.cancelControlsAutoHide() }
        else { manager.scheduleControlsAutoHide() }
    }
}

private struct AudioTrackMenu: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject var controller: AudioTrackController
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio Tracks").font(.headline)
            if controller.loading { ProgressView("Loading tracks…") }
            if let error = controller.error { Text(error).font(.caption) }
            if controller.tracks.isEmpty, !controller.loading { Text("No selectable audio tracks yet.").foregroundStyle(.secondary) }
            ForEach(controller.tracks) { track in
                Button { controller.select(track.id) } label: {
                    HStack { Text(track.name); Spacer(); if controller.selectedID == track.id { Image(systemName: "checkmark") } }
                }.buttonStyle(.plain).padding(6).accessibilityAddTraits(controller.selectedID == track.id ? .isSelected : [])
            }
            Button("Refresh tracks") { controller.refresh() }
        }.padding(18)
        }
        .frame(width: 320, height: min(480, CGFloat(max(1, controller.tracks.count)) * 38 + 120))
        .background(palette.surface)
    }
}
