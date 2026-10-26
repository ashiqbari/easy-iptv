<div align="center">

<img src="swift-sources/AppIcon.png" alt="EasyIPTV app icon" width="112" height="112">

# EasyIPTV

### Your channels. Your movies. Your next episode.

A native Apple IPTV player built with **SwiftUI**, **AVKit**, and **SwiftVLC**.
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
| ▣ **Picture in Picture** | Automatically float playback when another in-app screen covers the player, stay in PiP while browsing, and return manually without restarting. Works with AVKit and VLC on macOS. |
| 🖥 **Native playback** | VLC by default for Live TV, movies, and episodes on macOS, with manual AVKit selection, volume controls, and native macOS fullscreen. iOS uses AVKit. |
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

**Auto Picture-in-Picture** is on by default. Toggle it in the Appearance toolbar menu
or the macOS **Playback** menu. Opening details, Home, Downloads, or another in-app
screen that covers the player moves a playing stream into PiP. Changing sections or
categories while the player stays visible, switching apps, and minimizing do not trigger
PiP; paused playback stays put. Use
**Return to player** to return to the same stream. PiP stays active while switching
sections or categories, even after the covering screen closes. Closing PiP or pressing Stop ends
playback. The playback toolbar's PiP button works independently of the automatic setting.
On macOS, both AVKit and VLC use the same resizable floating player, with playback
controls and subtitle overlays. On iOS, native PiP availability depends on system and
stream support; custom subtitle-file overlays remain in the main player.

## Start watching

1. Download the DMG from [GitHub Releases](https://github.com/ashiqbari/easy-iptv/releases/latest) and drag EasyIPTV into Applications.
2. Open the app and add your Xtream Codes account or M3U playlist.
3. Browse Live TV, Movies, or TV Shows. Choose something to watch.

The macOS app requires **macOS 15 or later**. To build from source, use
**Xcode 26.4 or later with Swift 6.3 and Swift Package Manager**.

## The little things that matter

<details>
<summary><strong>Downloads and offline viewing</strong></summary>

Choose **Download** beside Play on a movie's details page, or on an episode card.
**Download season** asks for confirmation before queuing the selected season.
Open **Downloads** from Quick Access or the macOS menu (Command–Shift–D) to see
movies and shows grouped by series and season. Open **Preferences** in Downloads
to choose 1–4 simultaneous downloads (default: two), save provider subtitles and
artwork, or reveal the download folder in Finder. Preferences are remembered;
lowering the limit lets active transfers finish before more begin. Subtitle and
artwork choices apply when downloads finish and leave existing files intact.
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
background the iOS app to pause; resume manually when returning. An existing PiP session can continue playing, but switching away never starts PiP automatically. Movies and episodes
offer **Resume from mm:ss** or **Start over**. Episodes have progress indicators and
a **Continue watching** shortcut. Items at least 95% watched or within the last 45
seconds are treated as finished (short clips use the percentage threshold).

Headset play/pause buttons and system media controls use Apple's Now Playing
support with both AVKit and VLC. The system shows the current title and playback
state, and controls are released when playback stops. These controls also work
while browsing details over a playing stream; they don't start a new episode or
bypass a Resume/Start over prompt. Headsets must expose standard media commands
to the operating system.

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

## Sources, audio, catch-up, and channel organization

Open **Sources** in the toolbar to add a source, manage saved connections, or organize channels. Successful M3U and Xtream connections are saved automatically. Saved Sources lets you rename, reconnect, or remove them. Failed connections keep the previous library. Saved connection secrets are stored in the system Keychain; source names and selection are stored locally. The active account's legacy settings and cached stream URLs remain private app data, as before. Removing a saved connection keeps downloads and watch history.

The **Audio tracks** waveform button beside subtitles lists the stream's native audio tracks in both AVKit and VLC. Choose a language or commentary track without restarting playback. Refresh tracks if the provider exposes them after playback begins. Streams with no alternate audio do not gain synthesized tracks.

**Catch-up TV** is available from an eligible channel's context menu or its player controls. It loads actual past guide entries and offers Watch within the provider's advertised archive window. **Back to Live** returns to the original channel. Supported formats are Xtream channels advertising `tv_archive` and `tv_archive_duration`, and M3U entries with `catchup="xc"`, `catchup="default"`, or `catchup="append"`, a `catchup-days` value from 1 to 365, and a supported `catchup-source` where required. The supported template tokens are `{utc}`, `{utcend}`, `{lutc}`, `{duration}`, `{duration:60}`, `${start}`, `${end}`, `${duration}`, `${now}`, and `{Y}{m}{d}{H}{M}{S}`. Unknown templates are rejected rather than guessed. These follow the [IPTV Simple catch-up format conventions](https://github.com/kodi-pvr/pvr.iptvsimple#catchup-format-specifiers). Xtream requests use the provider's advertised server timezone, or UTC if omitted. Catch-up depends on actual archive availability and past listings; it does not record streams or create a local timeshift buffer.

Interrupted HTTP streams retry up to three times with 2, 4, and 8 second delays. Buffering for 20 seconds also starts recovery. Movies resume at their saved clock position; live channels reconnect to live playback. Retries are canceled when paused, stopped, backgrounded, or replaced. Thirty seconds of stable playback resets the retry allowance; after exhaustion, use Try Again or choose another channel. Local downloaded media is not retried over the network.

In **Sources → Organize Channels**, hide or restore channels/categories and order favorites with the up/down buttons. Use a channel's context menu to hide it. Hidden items stay out of the library and dashboard; organization does not delete source media, downloads, or history. Organization settings persist locally using hashed channel identities. The sort/filter popover beside library search offers default order, natural name A–Z/Z–A, recently added, and highest-rated sorting; filters include Favorites only, added in the last 30 days, and minimum rating within the selected category. Added dates and ratings use provider catalog metadata cached during a source refresh, without per-title requests. For TV shows, recency falls back to the provider’s last update when no added date is available; the control is labeled added / updated. Unsupported options are disabled; missing values sort last and are excluded by their active filter. Existing libraries need one source refresh to populate this metadata. These choices are remembered across launches. Large searches and sorts run in the background; typing is debounced and outdated requests are cancelled.

## Build & run

From the repository root:

```bash
cd swift-sources
./run_app.command
```

Local runs and app-only builds use Debug and reuse the SwiftPM cache. To assemble the app without a disk image:

```bash
./build_dmg.sh --build-only
```

Output: `swift-sources/build/EasyIPTV.app`.

To create the app and DMG installer:

```bash
./build_dmg.sh
```

Output: `swift-sources/EasyIPTV-macOS.dmg`.

Use `--release` for an optimized app-only build, or `--clean` to discard the cache explicitly. DMG builds default to Release. Batch small UI edits before packaging; use focused checks while iterating.

SwiftVLC 1.0.0 links libVLC 4 statically into the executable. The packaging script applies an **ad-hoc code signature**. Building requires Swift 6.3+ / Xcode 26.4+.
For the full build and release instructions, see [Getting Started](GETTINGSTARTED.md).

## For contributors

### Tests

Run the full suite with `cd swift-sources && swift test -c release`.
Check packaging flags and cache handling without compiling with
`./scripts/test-build-workflow.sh` from the repository root.
The suite includes playback/resume, subtitles, lifecycle cancellation, cache
persistence. Provider requests are mocked in lifecycle tests.
Commits and pushes do not run checks automatically; run the relevant checks manually.

### Find your way around

- `swift-sources/` — Native Swift app, VLC dependency configuration, and build scripts.
- `swift-sources/Tests/` — Playback, subtitles, guide, lifecycle, and UI regression tests.
- `.github/workflows/release.yml` — macOS DMG build and GitHub Release workflow.

### Home dashboard

The app opens on a standalone Home dashboard without category or channel sidebars and without automatically playing a channel. Appearance, source, subscription, and download controls stay available in its toolbar. Continue Watching resumes unfinished movies and the last watched episode of a series. Recent Channels and Favorites offer quick access, and the Live TV, Movies, and Series cards open the full library. Empty sections stay hidden until you start watching or add favorites. Live cards show current programme details when available in the local TV guide cache; opening Home does not fetch guide data. Dashboard rows resize with the window and provide scrollbars and previous/next buttons for browsing the full saved history and favorites. Choose Navy in Appearance to apply the navy and teal palette across the library, details, player controls, and dialogs. Obsidian adds charcoal and violet, Forest uses deep green and mint, and Warm Stone pairs cream with terracotta. System, Light, and Dark remain available. The dashboard adapts to the selected appearance, and the Home button in the library toolbar returns to it during playback.

## License

The application is licensed under the MIT License; see [LICENSE](LICENSE). SwiftVLC is MIT-licensed (see `swift-sources/LICENSE-SwiftVLC`). The bundled libVLC engine is licensed under LGPL 2.1; its license is included at [swift-sources/LICENSE-LGPL-2.1](swift-sources/LICENSE-LGPL-2.1) and copied into the app bundle.
