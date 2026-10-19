import AVKit
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
final class PictureInPictureCoordinator: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate {
    weak var manager: IPTVPlayerManager?
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var failureMessage: String?
    private(set) var isStarting = false
    private(set) var controller: AVPictureInPictureController?
    private var possibilityObserver: NSKeyValueObservation?
    private var automaticSession = false
    private var returning = false
    private var isStopping = false
    private var updateScheduled = false
    #if os(macOS)
    private weak var home: NSView?
    private var floatingSurface: NSView?
    private(set) var floatingWindow: NSPanel?
    private weak var mainWindow: NSWindow?
    private weak var controlsHost: NSHostingView<PictureInPictureControls>?
    #endif

    deinit {
        let controller = controller
        #if os(macOS)
        let window = floatingWindow
        #endif
        Task { @MainActor in
            controller?.delegate = nil
            controller?.stopPictureInPicture()
            #if os(macOS)
            window?.delegate = nil
            window?.close()
            #endif
        }
    }

    func attach(_ layer: AVPlayerLayer) {
        guard controller?.playerLayer !== layer else { return }
        resetPlayback()
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        self.controller = controller
        controller.delegate = self
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        #endif
        possibilityObserver = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPossible = self.controller?.isPictureInPicturePossible == true
                self.update()
            }
        }
    }

    #if os(macOS)
    func attachSurface(_ surface: NSView, home: NSView) {
        guard floatingSurface !== surface else { return }
        resetPlayback()
        self.home = home
        floatingSurface = surface
        isPossible = true
        update()
    }

    func activatePlayerWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func trackWindow(_ window: NSWindow?) {
        if let window { mainWindow = window }
    }
    #endif

    // Coalesce navigation mutations so opening details or switching a stream cannot briefly start PiP.
    func update() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.updateScheduled = false
            self.reconcile()
        }
    }

    func reconcile() {
        guard let manager else { return }
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        #endif
        #if os(macOS)
        controlsHost?.rootView = makeControls(for: manager)
        #endif
        let away = !manager.isPlayerDestinationVisible
        if isActive || isStarting {
            guard !returning, !isStopping else { return }
            if !manager.autoPictureInPicture && automaticSession {
                returnInline()
            }
        } else if away, manager.autoPictureInPicture, manager.isPlaying, manager.canPresentPictureInPicture {
            start(automatically: true)
        }
    }

    func toggle() {
        if isActive || isStarting {
            restorePlayer()
        } else {
            start(automatically: false)
        }
    }

    @objc func restorePlayer() {
        returning = true
        manager?.returnToPlayerFromPictureInPicture()
        returnInline()
    }

    private func start(automatically: Bool) {
        guard !isActive, !isStarting, isPossible, let manager, manager.canPresentPictureInPicture else { return }
        automaticSession = automatically
        returning = false
        failureMessage = nil
        #if os(macOS)
        if let surface = floatingSurface {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 432, height: 303),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "PiP"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(button)?.isHidden = true
            }
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 320, height: 240)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 432, height: 303))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            content.layer?.cornerRadius = 14
            content.layer?.masksToBounds = true
            let video = NSView(frame: NSRect(x: 0, y: 60, width: 432, height: 243))
            video.autoresizingMask = [.width, .height]
            content.addSubview(video)
            Self.move(surface, to: video)
            let subtitles = NSHostingView(rootView: SubtitleOverlay(controller: manager.subtitles, controlsVisible: false))
            subtitles.frame = video.bounds
            subtitles.autoresizingMask = [.width, .height]
            video.addSubview(subtitles)
            let dragHandle = PictureInPictureDragHandle(frame: NSRect(x: 0, y: video.bounds.height - 36, width: video.bounds.width - 46, height: 36))
            dragHandle.autoresizingMask = [.width, .minYMargin]
            video.addSubview(dragHandle)
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close PiP and stop playback")!, target: self, action: #selector(stopPlayback))
            close.isBordered = false
            close.contentTintColor = .white
            close.wantsLayer = true
            close.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            close.layer?.cornerRadius = 13
            close.frame = NSRect(x: video.bounds.width - 36, y: video.bounds.height - 36, width: 26, height: 26)
            close.autoresizingMask = [.minXMargin, .minYMargin]
            close.toolTip = "Close PiP and stop playback"
            video.addSubview(close)
            let controls = NSHostingView(rootView: makeControls(for: manager))
            controls.frame = NSRect(x: 0, y: 0, width: 432, height: 60)
            controls.autoresizingMask = [.width]
            controlsHost = controls
            content.addSubview(controls)
            panel.contentView = content
            panel.delegate = self
            floatingWindow = panel
            if let screen = mainWindow?.screen ?? NSScreen.main {
                let area = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 20, y: area.minY + 20))
            }
            isActive = true
            panel.orderFrontRegardless()
            return
        }
        #endif
        isStarting = true
        controller?.startPictureInPicture()
    }

    private func returnInline() {
        returning = true
        #if os(macOS)
        if floatingWindow != nil {
            closeFloatingWindow()
            isActive = false
            return
        }
        #endif
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }

    func resetPlayback() {
        // A stream replacement must not let a delayed close callback stop the new stream.
        manager?.subtitles.setNativePictureInPictureRendering(false)
        possibilityObserver = nil
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
        #if os(macOS)
        closeFloatingWindow()
        home = nil
        floatingSurface = nil
        #endif
        isActive = false
        isStarting = false
        isPossible = false
        returning = false
        isStopping = false
        automaticSession = false
        failureMessage = nil
    }

    #if os(macOS)
    private func makeControls(for manager: IPTVPlayerManager) -> PictureInPictureControls {
        PictureInPictureControls(
            title: manager.currentChannel?.playbackTitle ?? "Now playing",
            kind: manager.currentChannel?.isCatchup == true ? "Catch-up TV" : manager.currentChannel?.contentType.rawValue ?? "",
            isLive: manager.currentChannel?.contentType == .live && manager.currentChannel?.isCatchup != true,
            isPlaying: manager.isPlaying,
            onToggle: { [weak self] in self?.manager?.togglePlayPause() },
            onRestore: { [weak self] in self?.restorePlayer() }
        )
    }
    @objc private func stopPlayback() { manager?.stop() }

    private static func move(_ surface: NSView, to parent: NSView) {
        surface.removeFromSuperview()
        surface.frame = parent.bounds
        surface.autoresizingMask = [.width, .height]
        parent.addSubview(surface)
    }

    private func closeFloatingWindow() {
        if let surface = floatingSurface, let home { Self.move(surface, to: home) }
        floatingWindow?.delegate = nil
        floatingWindow?.close()
        floatingWindow = nil
        controlsHost = nil
    }
    #endif

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        manager?.subtitles.setNativePictureInPictureRendering(true)
        isStarting = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        isStarting = false
        isActive = true
        if returning { pictureInPictureController.stopPictureInPicture() }
        else { update() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        manager?.subtitles.setNativePictureInPictureRendering(false)
        isStarting = false
        isActive = false
        failureMessage = "Picture in Picture is unavailable for this stream."
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        isStopping = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        manager?.subtitles.setNativePictureInPictureRendering(false)
        let userClosed = !returning
        isStopping = false
        isActive = false
        isStarting = false
        returning = false
        if userClosed { manager?.stop() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard controller === pictureInPictureController, let manager else { completionHandler(false); return }
        returning = true
        manager.returnToPlayerFromPictureInPicture()
        completionHandler(true)
    }
}

#if os(macOS)
extension PictureInPictureCoordinator: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        manager?.stop()
        return false
    }
}

#endif

#if os(macOS)
struct PictureInPictureWindowTracking: NSViewRepresentable {
    let coordinator: PictureInPictureCoordinator
    func makeNSView(context: Context) -> PictureInPictureWindowView { PictureInPictureWindowView(coordinator) }
    func updateNSView(_ view: PictureInPictureWindowView, context: Context) { }
}

final class PictureInPictureWindowView: NSView {
    private let coordinator: PictureInPictureCoordinator
    init(_ coordinator: PictureInPictureCoordinator) { self.coordinator = coordinator; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator.trackWindow(window)
    }
}
#endif

#if os(macOS)
struct PictureInPictureControls: View {
    let title: String
    let kind: String
    let isLive: Bool
    let isPlaying: Bool
    let onToggle: () -> Void
    let onRestore: () -> Void
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    @Environment(\.colorScheme) private var colorScheme
    private var palette: AppPalette { AppPalette(appearance: appearance, colorScheme: colorScheme) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                HStack(spacing: 5) {
                    if isLive { Circle().fill(.red).frame(width: 5, height: 5) }
                    Text(isLive ? "LIVE" : kind)
                        .font(.system(size: 9, weight: .medium))
                        .tracking(isLive ? 1 : 0)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(action: onRestore) {
                Image(systemName: "pip.exit")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .help("Return to player")
            .accessibilityLabel("Return to player")

            Button(action: onToggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 34, height: 34)
                    .background(palette.accent, in: Circle())
            }
            .help(isPlaying ? "Pause" : "Play")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
        .overlay(alignment: .top) { palette.accent.opacity(0.2).frame(height: 1) }
        .preferredColorScheme(appearance.colorScheme)
    }
}

private final class PictureInPictureDragHandle: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
#endif
