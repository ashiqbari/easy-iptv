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

struct SubtitleButtonAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The button opens a panel contained by the player.
struct SubtitleControls: View {
    @ObservedObject var manager: IPTVPlayerManager
    @ObservedObject var controller: SubtitleController

    var body: some View {
        Button {
            controller.showingMenu.toggle()
            if controller.showingMenu {
                manager.cancelControlsAutoHide()
                controller.loadTracksIfNeeded()
            }
        } label: {
            Label("Subtitles", systemImage: controller.selectedID == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                #if os(iOS)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Subtitles (CC)")
        .accessibilityValue(controller.selectedID == nil ? "Off" : "On")
        .help("Choose subtitles, timing, and text size (Command–Shift–C)")
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .anchorPreference(key: SubtitleButtonAnchor.self, value: .bounds) { $0 }
    }
}

struct SubtitleDialog: View {
    var buttonAnchor: Anchor<CGRect>? = nil
    @ObservedObject var manager: IPTVPlayerManager
    @ObservedObject var controller: SubtitleController
    @State private var importingFile = false
    @State private var importMediaKey: String?

    var body: some View {
        GeometryReader { geometry in
            if controller.showingMenu {
                let button = buttonAnchor.map { geometry[$0] }
                    ?? CGRect(x: geometry.size.width - 172, y: geometry.size.height - 44, width: 0, height: 0)
                let width = min(320, max(1, geometry.size.width - 24))
                let height = max(1, min(geometry.size.height - 24, button.minY - 20))
                let left = max(12, min(button.midX - width / 2, geometry.size.width - width - 12))
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { controller.showingMenu = false }
                        .accessibilityHidden(true)
                    SubtitleMenuView(controller: controller,
                                     availableWidth: width,
                                     availableHeight: height) {
                        importMediaKey = manager.currentChannel?.subtitleCacheKey
                        importingFile = true
                        manager.cancelControlsAutoHide()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                    .frame(width: width, height: height, alignment: .bottom)
                    .offset(x: left, y: 12)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
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

/// Track discovery updates the panel independently of the playback controls.
struct SubtitleMenuView: View {
    @State private var showingPreferences = false
    @State private var showingLanguages = false
    @State private var contentHeight: CGFloat = 220
    @Environment(\.appPalette) private var palette
    @AppStorage(LanguagePreference.subtitleKey) private var preferredLanguage = ""
    @ObservedObject var controller: SubtitleController
    var availableWidth: CGFloat = 320
    var availableHeight: CGFloat = 440
    let onImport: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        // Keep concrete scroll bounds while fitting the visible controls.
        .frame(width: min(320, availableWidth), height: min(440, availableHeight, contentHeight))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.primary)
        .background(.regularMaterial)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Subtitles", systemImage: "captions.bubble")
                    .font(.headline)
                Spacer()
                Button { showingPreferences.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showingPreferences ? palette.accent : .primary)
                .accessibilityLabel("Subtitle preferences")
                .help("Subtitle preferences")
                .accessibilityValue(showingPreferences ? "Expanded" : "Collapsed")
                Button("Done") { controller.showingMenu = false }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showingLanguages.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "captions.bubble")
                            .foregroundStyle(palette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Subtitle language").font(.subheadline.weight(.semibold))
                            Text(controller.tracks.first { $0.id == controller.selectedID }?.label ?? "Off")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if controller.isLoadingTracks {
                                Text("Loading subtitle languages…")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if controller.tracks.isEmpty {
                                Text(controller.errorMessage == nil ? "No subtitle languages available" : "Subtitle languages unavailable")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        if !controller.tracks.isEmpty {
                            Text("\(controller.tracks.count) available")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(palette.accent.opacity(0.12), in: Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showingLanguages ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(controller.tracks.isEmpty)
                .accessibilityLabel("Subtitle language")
                .accessibilityValue("\(controller.tracks.first { $0.id == controller.selectedID }?.label ?? "Off"), \(controller.tracks.count) available, \(showingLanguages ? "Expanded" : "Collapsed")")
                .accessibilityHint("Show or hide subtitle tracks")
                .help("Show or hide subtitle tracks")

                if showingLanguages && !controller.tracks.isEmpty {
                    Divider().padding(.horizontal, 12)
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 4) {
                                trackButton("Off", id: nil).id("off")
                                ForEach(controller.tracks) { track in
                                    trackButton(track.label, id: track.id).id(track.id)
                                }
                            }
                            .padding(10)
                        }
                        .frame(height: min(180, CGFloat(controller.tracks.count + 1) * 48 + 20))
                        .onAppear { proxy.scrollTo(controller.selectedID ?? "off", anchor: .center) }
                    }
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
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
            Button("Load subtitle file…", action: onImport)
                .help("Open an SRT or WebVTT subtitle file for this movie or episode")

            subtitleTiming

            if showingPreferences {
                Divider()
                LanguagePreferencePicker(title: "Preferred language", defaultLabel: "Off", selection: $preferredLanguage)
                Text("Applies to new movie and episode playback; unavailable languages leave subtitles off.").font(.caption).foregroundStyle(.secondary)
                fontPreferences
            }
        }
    }

    private var subtitleTiming: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Subtitle timing").font(.headline)
                Text(controller.timingDelay == 0 ? "No adjustment" :
                     "\(abs(controller.timingDelay), specifier: "%.1f") seconds \(controller.timingDelay > 0 ? "later" : "earlier")")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                HStack {
                    Button { controller.setTimingDelay(controller.timingDelay - 0.5) } label: {
                        VStack(spacing: 2) { Text("−0.5s"); Text("Earlier").font(.caption) }
                    }
                        .disabled(controller.timingDelay <= -60)
                        .accessibilityLabel("Show subtitles half a second earlier")
                    Button { controller.setTimingDelay(controller.timingDelay + 0.5) } label: {
                        VStack(spacing: 2) { Text("+0.5s"); Text("Later").font(.caption) }
                    }
                        .disabled(controller.timingDelay >= 60)
                        .accessibilityLabel("Show subtitles half a second later")
                    Spacer()
                    Button("Reset") { controller.setTimingDelay(0) }
                        .disabled(controller.timingDelay == 0)
                }
                .disabled(!controller.supportsTimingAdjustment)
                if !controller.supportsTimingAdjustment {
                    Text(controller.selectedID == nil ? "Select a subtitle track to adjust its timing." :
                         "Timing adjustment for embedded subtitles requires VLC or an external subtitle file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        }
    }

    private var fontPreferences: some View {
        VStack(alignment: .leading, spacing: 12) {
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

        }
    }

    private func trackButton(_ label: String, id: String?) -> some View {
        Button { controller.select(id) } label: {
            HStack {
                Text(label).multilineTextAlignment(.leading)
                Spacer()
                if controller.selectedID == id { Image(systemName: "checkmark") }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(controller.selectedID == id ? palette.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
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
