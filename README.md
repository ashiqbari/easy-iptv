# EasyIPTV

EasyIPTV is a native Apple IPTV player built with SwiftUI, AVKit, and VLCKit. It supports live TV, movies, and series from Xtream Codes accounts or M3U/M3U Plus playlists. On macOS, VLC is available for streams AVKit cannot play.

## Features

- Live channel browsing with categories and favorites
- Movies and TV series playback
- Xtream Codes and M3U/M3U Plus sources
- Live TV guide loading, JSON export/import, category-based guide export, and search
- AVKit playback with a VLC fallback on macOS
- macOS playback volume controls and fullscreen support
- Movie and episode subtitles: embedded tracks, provider sidecar files, and SRT/WebVTT file import
- Background subtitle discovery with cached downloads and live font-size settings remembered across sessions

During movie or episode playback, open **CC** (Command–Shift–C) to select a subtitle
track or **Off**, adjust the text size (16–48 points, default 24), or load an SRT or
WebVTT file. The player discovers tracks from AVPlayer/VLC and uses subtitle URLs
advertised by Xtream movie/episode metadata. M3U entries can supply a sidecar with
`subtitle-url="https://example.com/movie.en.vtt"` and an optional
`subtitle-language="English"`. Providers that supply neither embedded tracks nor
sidecar URLs show “No subtitles available”; a local file can still be loaded.
Bitmap subtitles embedded in VLC media retain their image styling.

## Requirements

- macOS 15 or later
- Xcode 16 or later with Swift Package Manager

For the full build and release instructions, see [GETTINGSTARTED.md](GETTINGSTARTED.md).

## Build and run

```bash
cd swift-sources
./run_app.command
```

To create a signed app bundle without a disk image:

```bash
cd swift-sources
./build_dmg.sh --build-only
```

The app bundle is created at `swift-sources/build/EasyIPTV.app`.

To create the app bundle and DMG installer:

```bash
cd swift-sources
./build_dmg.sh
```

This creates `swift-sources/EasyIPTV-macOS.dmg`.

## Repository layout

- `swift-sources/` — Native Swift app, VLC dependency configuration, and build scripts.
- `.github/workflows/release.yml` — macOS DMG build and GitHub Release workflow.

## License

The application is licensed under the MIT License; see [LICENSE](LICENSE). The macOS VLC playback dependency is licensed under LGPL 2.1; its license is included at [swift-sources/LICENSE-LGPL-2.1](swift-sources/LICENSE-LGPL-2.1) and copied into the app bundle.
