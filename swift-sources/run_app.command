#!/bin/bash
# ==============================================================================
# EasyIPTV - Quick Clean Build & Launch Script
# Double-click this script on macOS to build and run EasyIPTV
# ==============================================================================

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "======================================================"
echo "  EasyIPTV - Clean Build & Launch"
echo "======================================================"

echo "[1/4] Cleaning previous build cache..."
rm -rf .build

echo "[2/4] Building native macOS app with Swift Package Manager..."
swift build -c release

echo "[3/4] Embedding VLCKit for local launch..."
VLC_FRAMEWORK=$(find .build/artifacts -path '*/VLCKit.xcframework/macos-*/VLCKit.framework' -type d ! -path '*/__MACOSX/*' -print -quit)
if [ -z "$VLC_FRAMEWORK" ]; then
    echo "Error: VLCKit.framework was not found in the SwiftPM artifacts."
    exit 1
fi
mkdir -p .build/Frameworks
cp -R "$VLC_FRAMEWORK" .build/Frameworks/VLCKit.framework
VLC_BINARY=".build/Frameworks/VLCKit.framework/Versions/A/VLCKit"
VLC_INSTALL_ID=$(otool -D "$VLC_BINARY" | tail -n 1)
install_name_tool -id "@rpath/VLCKit.framework/Versions/A/VLCKit" "$VLC_BINARY"
install_name_tool -change "$VLC_INSTALL_ID" "@rpath/VLCKit.framework/Versions/A/VLCKit" .build/release/EasyIPTV
install_name_tool -add_rpath "@executable_path/../Frameworks" .build/release/EasyIPTV
codesign --force --deep --sign - .build/Frameworks/VLCKit.framework
codesign --force --sign - .build/release/EasyIPTV

echo "[4/4] Launching EasyIPTV..."
./.build/release/EasyIPTV
