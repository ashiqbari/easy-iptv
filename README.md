<div align="center">

<img src="swift-sources/AppIcon.png" alt="EasyIPTV app icon" width="112" height="112">

# EasyIPTV

### Your channels. Your movies. Your next episode.

A native Apple IPTV player built with **SwiftUI**, **AVKit**, and **VLCKit**.
Bring your Xtream Codes account or M3U playlist, and make yourself at home.

**Live TV · Movies · TV Series**

[Download for macOS](https://github.com/ashiqbari/easy-iptv/releases/latest) · [Build from source](#build--run) · [Getting started](GETTINGSTARTED.md)

<sub>macOS 15+ · iOS 16+ source target · MIT licensed</sub>

</div>

---

## A place for everything you watch

| | What you get |
| :--- | :--- |
| 📺 **Live TV** | Browse channels by category, search, save favorites, and see real provider TV guide listings. |
| 🎬 **Movies** | Open a details page with available artwork, synopsis, ratings, and credits before pressing Play. |
| 🍿 **TV series** | Explore seasons and episodes, track your progress, and jump back in with Continue watching. |
| 💬 **Subtitles** | Choose embedded or provider tracks, import SRT/WebVTT files, and adjust text size while watching. |
| ⏯ **Pick up where you left off** | Saved movie and episode progress, Resume or Start over, and watched indicators. |
| 🖥 **Native playback** | AVKit playback, an in-app VLC fallback on macOS, volume controls, and native macOS fullscreen. |

Connect **Xtream Codes** accounts or **M3U/M3U Plus** playlists. Available artwork,
metadata, guide listings, and subtitle tracks depend on your source.
EasyIPTV is a player; bring your own content source.

## Start watching

1. Download the DMG from [GitHub Releases](https://github.com/ashiqbari/easy-iptv/releases/latest) and drag EasyIPTV into Applications.
2. Open the app and add your Xtream Codes account or M3U playlist.
3. Browse Live TV, Movies, or TV Shows. Choose something to watch.

The macOS app requires **macOS 15 or later**. To build from source, use
**Xcode 16 or later with Swift 6 and Swift Package Manager**.

## The little things that matter

<details>
<summary><strong>Resume, progress, and leaving the player</strong></summary>

Leaving playback (including **Back to Series Overview**, **All Episodes**, switching
items/sections, or closing the player) saves progress and stops both playback engines.
Progress is also saved every five seconds while playing. Hide the macOS app or
background the iOS app to pause; resume manually when returning. Movies and episodes
offer **Resume from mm:ss** or **Start over**. Episodes have progress indicators and
a **Continue watching** shortcut. Items at least 95% watched or within the last 45
seconds are treated as finished (short clips use the percentage threshold).

</details>

<details>
<summary><strong>Subtitle tracks, local files, and text size</strong></summary>

During movie or episode playback, open **CC** (Command–Shift–C) to select a subtitle
track or **Off**, adjust the text size (16–48 points, default 24), or load an SRT or
WebVTT file. The player discovers tracks from AVPlayer/VLC and uses subtitle URLs
advertised by Xtream movie/episode metadata. M3U entries can supply a sidecar with
`subtitle-url="https://example.com/movie.en.vtt"` and an optional
`subtitle-language="English"`. Providers that supply neither embedded tracks nor
sidecar URLs show “No subtitles available”; a local file can still be loaded.
Bitmap subtitles embedded in VLC media retain their image styling.

Track discovery runs in the background. Results and downloaded sidecar files are
cached so reopening the subtitle menu or switching back to a loaded track does
not repeat the download. Text-size preferences are remembered across sessions.

</details>

<details>
<summary><strong>TV guide tools</strong></summary>

Load real provider listings, search the guide, export or import guide JSON, or
export listings for a category. Guide availability depends on your provider.

</details>

## Build & run

From the repository root:

```bash
cd swift-sources
./run_app.command
```

To assemble the app without a disk image:

```bash
./build_dmg.sh --build-only
```

Output: `swift-sources/build/EasyIPTV.app`.

To create the app and DMG installer:

```bash
./build_dmg.sh
```

Output: `swift-sources/EasyIPTV-macOS.dmg`.

The packaging script embeds VLCKit and applies an **ad-hoc code signature**.
For the full build and release instructions, see [Getting Started](GETTINGSTARTED.md).

## For contributors

### Tests & commit checks

Run the full suite with `cd swift-sources && swift test -c release`.
The suite includes playback/resume, subtitles, lifecycle cancellation, cache
persistence, and pre-commit integration tests. Provider requests are mocked in
lifecycle tests; hook tests use disposable repositories and do not commit here.

Install the versioned pre-commit hook once per clone from the repository root:

```sh
./.githooks/install.sh
```

Every commit then runs the full release test suite. Failed tests, compilation
errors, or a missing Swift toolchain block the commit. The hook does not stage
files or create commits. It tests the working tree, so stage all intended source
changes before committing. The installer preserves a different existing hook
configuration instead of silently replacing it.

### Find your way around

- `swift-sources/` — Native Swift app, VLC dependency configuration, and build scripts.
- `swift-sources/Tests/` — Playback, subtitles, guide, lifecycle, and UI regression tests.
- `.githooks/` — Versioned pre-commit hook and installer.
- `.github/workflows/release.yml` — macOS DMG build and GitHub Release workflow.

## License

The application is licensed under the MIT License; see [LICENSE](LICENSE). The macOS VLC playback dependency is licensed under LGPL 2.1; its license is included at [swift-sources/LICENSE-LGPL-2.1](swift-sources/LICENSE-LGPL-2.1) and copied into the app bundle.
