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
| ◐ **Appearance** | Choose System, Light, or Dark from the sidebar's Appearance menu (or the macOS menu bar). Your choice is remembered and changes without restarting playback. |
| ⬇ **Offline viewing** | Download movies, individual episodes, or a season. Manage the queue from Downloads and play saved media with the same subtitles and resume progress. |

Connect **Xtream Codes** accounts or **M3U/M3U Plus** playlists. Available artwork,
metadata, guide listings, and subtitle tracks depend on your source.
EasyIPTV is a player; bring your own content source.

Use **Search categories** in the library sidebar to narrow category names in
Live TV, Movies, or TV Shows. It is independent of channel search; All and
Favorites stay available, and filtering categories does not change playback.

Click the small **calendar button** beside EasyIPTV at the top of the category
sidebar to check your provider's expiry date and account status. Successful results
are saved locally and reused next time, including after restarting the app. Use
**Refresh** inside the info sheet to check again; dates use your local time zone. Xtream Codes accounts and compatible M3U
`get.php` links are supported; other playlists may not provide expiry information.

## Start watching

1. Download the DMG from [GitHub Releases](https://github.com/ashiqbari/easy-iptv/releases/latest) and drag EasyIPTV into Applications.
2. Open the app and add your Xtream Codes account or M3U playlist.
3. Browse Live TV, Movies, or TV Shows. Choose something to watch.

The macOS app requires **macOS 15 or later**. To build from source, use
**Xcode 16 or later with Swift 6 and Swift Package Manager**.

## The little things that matter

<details>
<summary><strong>Downloads and offline viewing</strong></summary>

Choose **Download** beside Play on a movie's details page, or on an episode card.
**Download season** asks for confirmation before queuing the selected season.
Open **Downloads** from Quick Access or the macOS menu (Command–Shift–D) to see
movies and shows grouped by series and season. Two transfers run at a time.
Pause, resume, cancel, retry, or delete individual items; deleting files or the
whole library asks for confirmation and keeps viewing progress.

Direct-file transfers use URLSession and save bytes to disk, not an in-memory
video buffer. Partial transfers resume when the provider and URLSession support
it; otherwise Resume restarts the transfer. HLS uses Apple's native offline asset
downloader, not a saved `.m3u8` playlist. Background sessions reconnect when the
app opens again. DASH and DRM-protected sources aren't supported for downloads.

Completed downloads are used automatically by the existing player. Downloaded
episodes support next/previous episode, subtitles, saved progress, resume, and
pause-on-exit. Available provider sidecar subtitles and poster artwork are saved
alongside the media; a subtitle failure shows a warning without discarding the
video. Embedded HLS tracks depend on the media selections downloaded by Apple.
When offline, use Downloads for saved content; unavailable items show an offline
message instead of starting another stream.

On macOS, direct media, sidecars, artwork, and the download manifest live in
`~/Library/Application Support/EasyIPTV/Downloads/`. HLS packages stay at Apple's
system-managed location and may be purged by the OS; missing files can be downloaded
again. Downloads consume disk space and may be several GB per item. The manifest
contains provider URLs, so it is private app data; don't share it. Wi-Fi-only and
whole-library download settings aren't included.

</details>

<details>
<summary><strong>Resume, progress, and leaving the player</strong></summary>

Switching sections or categories keeps the current stream playing. Movie and series
details open over the mounted player while playback continues; **Back to Player**
returns to it. Pressing **Play** on a new item replaces the current stream.
Leaving playback through **Back to Series Overview**, **All Episodes**, or closing
the player saves progress and stops both playback engines.
Progress is also saved every five seconds while playing. Hide the macOS app or
background the iOS app to pause; resume manually when returning. Movies and episodes
offer **Resume from mm:ss** or **Start over**. Episodes have progress indicators and
a **Continue watching** shortcut. Items at least 95% watched or within the last 45
seconds are treated as finished (short clips use the percentage threshold).

Fullscreen controls hide after 2.5 seconds of inactivity even when another window
or app has focus. Moving the pointer over the player reveals them; hovering controls,
open menus/dialogs, and paused playback keep them visible. The cursor is hidden only
over the fullscreen player, so using another display keeps its cursor visible.
On macOS, **Command–Shift–I** toggles playback diagnostics (off by default): resolution,
VLC displayed FPS/lost frames/input throughput, or AVKit bitrate/buffer/dropped frames.
These measurements do not change playback quality.

The player badge describes the playing item, even while browsing another section:
**Movie**, **Episode**, or **Live TV**. **LIVE** indicates playback within 30 seconds
of an AVKit stream's reported live edge; **Behind live** indicates a larger delay.
Streams without live-edge timing (including VLC) show **Live TV** instead of claiming
they are at the live edge. Paused channels show **Live TV · Paused**.

Use the **aspect ratio button beside subtitles and volume** in the bottom player
controls to choose **Auto / Original**, **16:9**, **4:3**,
**21:9**, **1:1**, **Fill / Stretch**, or **Zoom / Crop**. Fixed ratios fit inside
the player with black bars; Stretch fills the area, and Zoom fills it by cropping
the edges. Changes apply during playback without restarting the stream. The choice
is remembered globally for all content and both playback engines; **Reset to Auto**
restores the video's original proportions.

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

View real provider listings for the current channel or search across live TV.
Guide availability depends on your provider.

In Live TV, choose **Search TV Guide** in the toolbar (Command–Shift–G on macOS).
Search a team, match, or programme across **On now** or **Later today** listings,
then use **Watch** to open a matching live channel. Results include up to 50
channels per page and reflect the provider's schedule, not verified broadcast content.

The first search window starts a background XMLTV import. Current and upcoming
programmes for the rest of the local day are indexed on disk in a SQLite cache;
the whole guide is not retained in app memory. Reopening the window uses cached
listings, with refreshes three hours after the actual download or at the next
local day. Failed or unusable imports preserve the previous guide and retry
after one minute while the guide is open. Channels need a guide URL and a matching
XMLTV channel ID (`tvg-id` / provider EPG ID); channels without these are reported
as unavailable rather than guessed by name.

The player's **TV Guide** reads the same XMLTV cache as search. If XMLTV has no
usable listings, Xtream channels can use the provider's single-channel schedule.
Both guide windows offer **Refresh guides** to download new XMLTV listings, and
show download times and refresh failures. **Refresh Library** reloads the active
source's channels, movies, and shows; it is separate from a guide refresh.

Imports stream directly into database transactions, and searches are debounced
and paginated. The cache has a 256 MiB database budget (temporary journal files
also use disk space), downloads have a 1 GiB safety budget, and expensive queries
are interrupted. A provider may still require downloading its full XMLTV feed,
even though only today's relevant listings are retained. No separate SQLite
installation is required.

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

### Home dashboard

The app opens on Home without automatically playing a channel. Continue Watching resumes unfinished movies and the last watched episode of a series. Recent Channels and Favorites offer quick access, and the Live TV, Movies, and Series cards open the full library. Empty sections stay hidden until you start watching or add favorites. Live cards show current programme details when available in the local TV guide cache; opening Home does not fetch guide data. Dashboard rows resize with the window and provide scrollbars and previous/next buttons for browsing the full saved history and favorites. Choose Navy in Appearance to apply the navy and teal palette across the library, details, player controls, and dialogs. System, Light, and Dark remain available. The dashboard adapts to the selected appearance, and the Home button in the sidebar returns to it during playback.

## License

The application is licensed under the MIT License; see [LICENSE](LICENSE). The macOS VLC playback dependency is licensed under LGPL 2.1; its license is included at [swift-sources/LICENSE-LGPL-2.1](swift-sources/LICENSE-LGPL-2.1) and copied into the app bundle.
