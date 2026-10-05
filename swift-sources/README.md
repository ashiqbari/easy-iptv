# EasyIPTV - macOS Native Source

This directory contains the native **SwiftUI** IPTV application for macOS (15.0+) and iOS (16.0+). macOS uses AVKit with an in-app VLC playback fallback; VLC playback is macOS-only.

The VLC Swift package and VLCKit are distributed under LGPL 2.1. The corresponding license is included in the app bundle resources as `LICENSE-LGPL-2.1.txt`.

## 🚀 Quick Run on macOS

Building the native macOS target requires Xcode 16 or newer with Swift 6.0. SwiftPM downloads VLCKit and embeds it in the app.

Double-click `run_app.command` or run:
```bash
./run_app.command
```
The run script embeds VLCKit beside the executable before launching, so the VLC fallback works outside the app bundle too.

---

## 📦 Building the `.dmg` Disk Image

To generate the standalone `EasyIPTV-macOS.dmg` installer package:
```bash
chmod +x build_dmg.sh
./build_dmg.sh
```

The script will:
1. Resolve the SwiftPM VLC dependency and compile the native binary.
2. Generate the macOS `.icns` iconset from `AppIcon.png`.
3. Embed `VLCKit.framework`, assemble the `EasyIPTV.app` bundle, and apply an ad-hoc code signature.
4. Create the final compressed `.dmg` disk image using native macOS `hdiutil` with a drag-and-drop shortcut to `/Applications`.

---

## 🤖 Automated GitHub Release Workflow

See [`.github/workflows/release.yml`](../.github/workflows/release.yml) in the root repository. Pushing any tag starting with `v` (e.g. `git tag v1.0.0 && git push origin v1.0.0`) automatically builds this directory on a macOS runner and attaches the generated `EasyIPTV-macOS.dmg` to a new GitHub Release.
