# Getting Started with EasyIPTV

EasyIPTV is a native **SwiftUI** IPTV application for macOS (15.0+) and iOS (16.0+). macOS defaults to VLC for Live TV, movies, and episodes, with AVKit available from the Player menu. iOS uses AVKit; VLC playback is macOS-only.

The VLC Swift package and VLCKit are distributed under LGPL 2.1. The corresponding license is included in the app bundle resources as `LICENSE-LGPL-2.1.txt`.

## 🚀 Quick Run on macOS

Building the native macOS target requires Xcode 16 or newer with Swift 6.0. SwiftPM downloads VLCKit and embeds it in the app.

From the repository root, run:

```bash
cd swift-sources
./run_app.command
```
The run script incrementally builds and launches a signed Debug app bundle with VLCKit embedded.

---

## 📦 Building the `.dmg` Disk Image

To generate the standalone `EasyIPTV-macOS.dmg` installer package:
```bash
cd swift-sources
chmod +x build_dmg.sh
./build_dmg.sh
```

To build just the signed `.app` bundle without creating a disk image:

```bash
cd swift-sources
./build_dmg.sh --build-only
```

The app bundle will be at `swift-sources/build/EasyIPTV.app`. App-only builds default to Debug; add `--release` for an optimized build. DMG builds default to Release. Both reuse the SwiftPM cache; add `--clean` only when a fresh build is needed.

Batch small UI edits before assembling the app. Use focused checks during development; installed Git hooks check staged whitespace on commit and run the full test suite once before push (see README).

The script will:
1. Resolve the SwiftPM VLC dependency and compile the native binary.
2. Generate the macOS `.icns` iconset from `AppIcon.png`.
3. Embed `VLCKit.framework`, assemble the `EasyIPTV.app` bundle, and apply an ad-hoc code signature.
4. When run without `--build-only`, create the compressed `.dmg` disk image using native macOS `hdiutil` with a drag-and-drop shortcut to `/Applications`.

---

## 🤖 Automated GitHub Release Workflow

See [`.github/workflows/release.yml`](.github/workflows/release.yml). Pushing any tag starting with `v` (e.g. `git tag v1.0.0 && git push origin v1.0.0`) automatically performs a clean Release build on a macOS runner and attaches the generated `EasyIPTV-macOS.dmg` to a new GitHub Release.
