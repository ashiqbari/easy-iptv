---
name: easy-iptv
description: Develop and maintain this repository's native SwiftUI IPTV app, including playback, guide data, and macOS builds.
---

# EasyIPTV project guidance

This repository contains the native SwiftUI app in `swift-sources/`. Keep application changes in the Swift sources unless the user requests a separate tool or service.

## App and playback

- The app supports Xtream Codes and M3U/M3U Plus sources, live TV, movies, and series.
- AVKit is the primary playback engine. macOS has a VLCKit fallback for streams AVKit cannot decode; preserve this path when changing playback.
- The macOS deployment target is 15.0. Check `swift-sources/Package.swift` and `Info.plist` for current platform settings before changing them.
- Keep TV guide displays grounded in real provider XMLTV data or a user-imported guide file. Match listings to the selected channel; do not synthesize schedules from channel names or categories.

## Build workflow

Run commands from `swift-sources/`:

- Compile incrementally for development: `swift build`
- Assemble and sign the `.app` without a DMG (Debug): `./build_dmg.sh --build-only` (output: `build/EasyIPTV.app`)
- Assemble the Release app and DMG: `./build_dmg.sh` (output: `EasyIPTV-macOS.dmg`)
- Build and launch locally: `./run_app.command`

The packaging script embeds VLCKit into the app bundle. SwiftPM must successfully build the VLC dependency; a direct `swiftc` fallback does not produce the required app. Use the build-only option when a DMG is not needed. Builds preserve the SwiftPM cache; use `--release` for an optimized app-only build or `--clean` for an explicit fresh build. Batch small UI edits before packaging and run focused checks during iteration. Installed Git hooks check staged whitespace on commit and run the full Release test suite once before push.

See the root `README.md` for the project overview and `GETTINGSTARTED.md` for setup and release instructions.
