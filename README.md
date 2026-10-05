# EasyIPTV 📺

[![Platform](https://img.shields.io/badge/Platform-macOS%2015%2B%20%7C%20iOS%2016%2B-blue.svg)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.0%2B-orange.svg)](https://swift.org)
[![Build & Release](https://github.com/easyiptv/easyiptv/actions/workflows/release.yml/badge.svg)](../../actions/workflows/release.yml)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**EasyIPTV** is a modern, native macOS IPTV application and web simulator. Built with **SwiftUI**, **AVKit**, **VLCKit**, and **IOKit**, it plays **Live TV**, **VOD Movies**, and **TV Series** from **Xtream Codes** accounts or **M3U / M3U Plus** playlists. macOS playback can switch to VLC when AVKit cannot decode a stream.

---

## ✨ Features

- **🎬 Live TV, Movies & TV Shows**:
  - Full support for Live Channels with Electronic Program Guide (EPG).
  - On-demand Movies (VOD) with seek scrubbers and duration tracking.
  - Multi-season TV Series browser with interactive season selector tabs (Season 1, Season 2, Season 3, etc.).
- **📺 Carousel & Full Grid View for Episodes**:
  - Left (`‹`) and right (`›`) navigation arrows to scroll smoothly through seasons with many episodes.
  - Multi-column **Grid View** toggle to view all episodes in a season at once.
- **↩ Seamless Navigation**:
  - One-click **"Back to Series Overview"** button in both the player HUD and episode switcher drawer to jump back to the show's seasons and episodes page while watching.
- **🛡️ macOS Native Power & Window Management**:
  - **No Display Sleep / Screen Lock While Watching**: Employs native I/O Kit power management assertions (`kIOPMAssertionTypePreventUserIdleDisplaySleep`) and `ProcessInfo` activity tracking so your Mac will never dim, sleep, or lock itself during active video playback.
  - **Clean Termination on Close**: Closing the main window (`x` button) stops all background network and audio streaming, terminating the process cleanly and allowing instant re-launch from the Dock or Finder.
- **⚡ Advanced Stream Engine**:
  - AVKit playback with an in-app VLC fallback for broader codec and container support on macOS.
  - Stream extension retry controls for Xtream providers that expose alternate formats.
  - Dual Xtream Codes and M3U playlist parser with category filtering and persistent favorites.
- **💻 Web Simulator Companion**:
  - Includes a React + TypeScript companion app replicating the macOS native experience directly in web browsers.

---

## 🚀 Quick Download (.dmg)

Download the latest prebuilt macOS installer directly from [**GitHub Releases**](../../releases/latest):

1. Download `EasyIPTV-macOS.dmg`.
2. Double-click the `.dmg` file.
3. Drag **EasyIPTV.app** into your **Applications** folder.
4. Launch **EasyIPTV** and connect your Xtream Codes account or paste your M3U playlist URL!

---

## 🛠️ Building Locally on macOS

### Prerequisites
- macOS 15.0 (Sequoia) or newer
- Xcode 16+ with Swift 6.0

### 1. Build and Run Directly
Navigate to the `swift-sources` directory:
```bash
cd swift-sources
./run_app.command
```
`run_app.command` builds the app and embeds VLCKit before launching it locally.

### 2. Package a Standalone `.dmg` Installer
To produce a signed, drag-and-drop `.dmg` disk image on your local machine:
```bash
cd swift-sources
./build_dmg.sh
```
The output file `EasyIPTV-macOS.dmg` will be created in `swift-sources/`.

---

## 🤖 Automated GitHub Actions Workflow (Releases)

This repository includes an automated CI/CD pipeline (`.github/workflows/release.yml`) that compiles the native Swift application on a macOS runner, packages the `.dmg`, generates SHA256 checksums, and publishes a new GitHub Release.

### Triggering a New Release

#### Option A: Pushing a Git Tag (Recommended)
Tag your commit with a version starting with `v` (e.g. `v1.0.0`):
```bash
git tag v1.0.0
git push origin v1.0.0
```
The GitHub Action will automatically:
1. Spin up a `macos-26` (Apple Silicon) runner.
2. Compile the native SwiftUI + AVKit/VLC binary using SwiftPM.
3. Assemble the `EasyIPTV.app` bundle with high-resolution icons (`AppIcon.icns`).
4. Generate `EasyIPTV-macOS.dmg` with a drag-and-drop link to `/Applications`.
5. Compute the SHA256 checksum.
6. Publish a new GitHub Release with the `.dmg` and checksum files attached.

#### Option B: Manual Trigger (`workflow_dispatch`)
1. Go to the **Actions** tab in your GitHub repository.
2. Select **Build and Release macOS DMG** in the left sidebar.
3. Click **Run workflow**.
4. Specify the release tag (e.g. `v1.0.1`) and whether you want a draft release, then click **Run workflow**.

---

## 📁 Repository Structure

```
├── .github/
│   └── workflows/
│       └── release.yml         # Automated GitHub Actions workflow for DMG releases
├── swift-sources/              # Native macOS / iOS Swift codebase
│   ├── Package.swift           # Swift Package Manager definition
│   ├── Info.plist              # macOS App bundle manifest
│   ├── build_dmg.sh            # Automated script to build .app and .dmg package
│   ├── run_app.command         # Double-clickable macOS launcher script
│   ├── AppIcon.png             # Master 1024x1024 application icon
│   ├── IPTVPlayerApp.swift     # App entry point & NSApplicationDelegate lifecycle
│   ├── IPTVPlayerManager.swift # Playback manager, IOKit display sleep engine, Xtream client
│   ├── IPTVPlaybackView.swift  # AVPlayer video view, HUD controls, multi-season carousel/grid
│   ├── ChannelListView.swift   # Channel sidebar, category tabs, and search bar
│   ├── ContentView.swift       # 3-column macOS split navigation layout
│   ├── M3UParser.swift         # M3U/M3U8 playlist streaming parser
│   ├── M3UItem.swift           # Media data models (Live, Movie, Series)
│   └── XtreamCodesManager.swift# Xtream Codes API client (episodes, seasons, VOD)
├── src/                        # React + TypeScript web simulator
├── server.ts                   # Local proxy server for CORS & video streaming
└── README.md                   # Documentation (this file)
```

---

## 🔒 Permissions & Security

- **Network Access**: Requires outgoing network access to stream media from your IPTV provider.
- **Power Management (IOKit)**: Uses standard user-level assertions (`kIOPMAssertionTypePreventUserIdleDisplaySleep`) to prevent screen lock exclusively while media is playing; no elevated privileges or kernel extensions are required.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

The macOS VLC playback dependency is licensed under LGPL 2.1; its license is included at [swift-sources/LICENSE-LGPL-2.1](swift-sources/LICENSE-LGPL-2.1) and copied into the app bundle.
