# EasyIPTV - macOS Native Source

This directory contains the complete native **SwiftUI** + **AVKit** application for macOS (13.0+) and iOS (16.0+).

## 🚀 Quick Run on macOS

Double-click `run_app.command` or run:
```bash
./run_app.command
```
or compile with the Swift CLI:
```bash
swift run -c release
```

---

## 📦 Building the `.dmg` Disk Image

To generate the standalone `EasyIPTV-macOS.dmg` installer package:
```bash
chmod +x build_dmg.sh
./build_dmg.sh
```

The script will:
1. Compile the native binary using `Package.swift` / `swiftc`.
2. Generate the macOS `.icns` iconset from `AppIcon.png`.
3. Assemble the `EasyIPTV.app` bundle and apply an ad-hoc code signature.
4. Create the final compressed `.dmg` disk image using native macOS `hdiutil` with a drag-and-drop shortcut to `/Applications`.

---

## 🤖 Automated GitHub Release Workflow

See [`.github/workflows/release.yml`](../.github/workflows/release.yml) in the root repository. Pushing any tag starting with `v` (e.g. `git tag v1.0.0 && git push origin v1.0.0`) automatically builds this directory on a macOS runner and attaches the generated `EasyIPTV-macOS.dmg` to a new GitHub Release.
