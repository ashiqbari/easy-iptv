import SwiftUI
import UniformTypeIdentifiers

struct SubtitleOverlay: View {
    @ObservedObject var controller: SubtitleController
    let controlsVisible: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer(minLength: 0)
                if !controller.text.isEmpty {
                    Text(controller.text)
                        .font(.system(size: controller.fontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black, radius: 2)
                        .frame(maxWidth: geometry.size.width * 0.9)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, controlsVisible ? min(130, geometry.size.height * 0.3) : 24)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Subtitles")
    }
}

/// A popover allows loading/error state and live font controls to update while open.
struct SubtitleControls: View {
    @ObservedObject var manager: IPTVPlayerManager
    @ObservedObject var controller: SubtitleController
    @State private var importingFile = false
    @State private var importMediaKey: String?

    var body: some View {
        Button {
            controller.showingMenu.toggle()
            if controller.showingMenu {
                manager.cancelControlsAutoHide()
                controller.loadTracksIfNeeded()
            }
        } label: {
            Image(systemName: controller.selectedID == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Subtitles (CC)")
        .accessibilityValue(controller.selectedID == nil ? "Off" : "On")
        .help("Choose subtitles and text size (Command–Shift–C)")
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .popover(isPresented: $controller.showingMenu, arrowEdge: .bottom) {
            SubtitleMenuView(controller: controller) {
                importMediaKey = manager.currentChannel?.subtitleCacheKey
                importingFile = true
                manager.cancelControlsAutoHide()
            }
        }
        #if os(macOS)
        .onChange(of: controller.showingMenu) { _, isOpen in menuVisibilityChanged(isOpen) }
        #else
        .onChange(of: controller.showingMenu) { isOpen in menuVisibilityChanged(isOpen) }
        #endif
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [
            UTType(filenameExtension: "srt") ?? .plainText,
            UTType(filenameExtension: "vtt") ?? .plainText
        ]) { result in
            // A file picker can stay open while keyboard commands switch episodes.
            guard importMediaKey == manager.currentChannel?.subtitleCacheKey else { return }
            switch result {
            case .success(let url): controller.importFile(url)
            case .failure(let error): controller.reportImportError(error)
            }
            controller.showingMenu = true
            manager.showVideoControls = true
            manager.cancelControlsAutoHide()
        }
    }

    private func menuVisibilityChanged(_ isOpen: Bool) {
        if isOpen { manager.cancelControlsAutoHide() }
        else if !importingFile { manager.scheduleControlsAutoHide() }
    }
}

/// The presentation owns its observation. Updates must not depend on rebuilding
/// the CC button's parent when asynchronous track discovery completes.
struct SubtitleMenuView: View {
    @ObservedObject var controller: SubtitleController
    let onImport: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        // A popover needs concrete bounds. A flexible empty ScrollView combined
        // with idealWidth/fixedSize can collapse its hosted content after loading.
        .frame(width: 320, height: 440)
        .foregroundStyle(.primary)
        .background(.regularMaterial)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Subtitles", systemImage: "captions.bubble")
                    .font(.headline)
                Spacer()
                Button("Done") { controller.showingMenu = false }
                    .keyboardShortcut(.cancelAction)
            }

            trackButton("Off", id: nil)

            if controller.isLoadingTracks {
                HStack { ProgressView().controlSize(.small); Text("Loading subtitles…") }
            } else if controller.tracks.isEmpty && controller.errorMessage == nil {
                Text("No subtitles available").foregroundStyle(.secondary)
            }

            if !controller.tracks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(controller.tracks) { track in
                        trackButton(track.label, id: track.id)
                    }
                }
            }

            if controller.isLoadingFile {
                HStack { ProgressView().controlSize(.small); Text("Loading subtitle file…") }
            }
            if let error = controller.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { controller.retry() }
                    .disabled(controller.isLoadingTracks || controller.isLoadingFile)
            }

            Divider()
            HStack {
                Text("Font size")
                Spacer()
                Text("\(Int(controller.fontSize)) pt").monospacedDigit()
            }
            Slider(value: $controller.fontSize, in: 16...48, step: 2)
                .accessibilityLabel("Subtitle font size")
                .accessibilityValue("\(Int(controller.fontSize)) points")
            HStack {
                ForEach([18.0, 24.0, 32.0, 40.0], id: \.self) { size in
                    Button(sizeLabel(size)) { controller.fontSize = size }
                        .accessibilityLabel("\(sizeLabel(size)) subtitles, \(Int(size)) points")
                }
            }

            Divider()
            Button("Load subtitle file…", action: onImport)
            .help("Open an SRT or WebVTT subtitle file for this movie or episode")
        }
    }

    private func trackButton(_ label: String, id: String?) -> some View {
        Button { controller.select(id) } label: {
            HStack {
                Text(label).multilineTextAlignment(.leading)
                Spacer()
                if controller.selectedID == id { Image(systemName: "checkmark") }
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(controller.selectedID == id ? "Selected" : "")
    }

    private func sizeLabel(_ size: Double) -> String {
        switch size {
        case 18: return "Small"
        case 24: return "Medium"
        case 32: return "Large"
        default: return "Extra large"
        }
    }

}
