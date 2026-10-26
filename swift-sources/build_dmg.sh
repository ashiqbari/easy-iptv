#!/bin/bash
# ==============================================================================
# EasyIPTV - Native macOS .app & optional .dmg Automated Build Script
# Compatible with macOS Sequoia (15.0+) and newer
# Requires: Xcode 26.4+ with Swift 6.3 (SwiftPM links SwiftVLC and libVLC)
# ==============================================================================

set -e

BUILD_ONLY=false
CLEAN=false
CONFIGURATION=""
for argument in "$@"; do
    case "$argument" in
        --build-only) BUILD_ONLY=true ;;
        --release) CONFIGURATION=release ;;
        --clean) CLEAN=true ;;
        *) echo "Usage: $0 [--build-only] [--release] [--clean]"; exit 2 ;;
    esac
done
if [ -z "$CONFIGURATION" ]; then
    if [ "$BUILD_ONLY" = true ]; then CONFIGURATION=debug; else CONFIGURATION=release; fi
fi

APP_NAME="EasyIPTV"
DMG_NAME="EasyIPTV-macOS.dmg"
BUILD_DIR="./build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
STAGING_DIR="${BUILD_DIR}/dmg_staging"

# Terminal Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================${NC}"
if [ "${BUILD_ONLY}" = true ]; then
    echo -e "${BLUE}          EasyIPTV macOS App Builder                  ${NC}"
else
    echo -e "${BLUE}       EasyIPTV macOS App & DMG Builder               ${NC}"
fi
echo -e "${BLUE}======================================================${NC}"

# Check for Xcode tools
if ! command -v xcrun &> /dev/null; then
    echo -e "${RED}Error: Xcode Command Line Tools not detected.${NC}"
    echo "Please install them by opening Terminal and running:"
    echo "  xcode-select --install"
    exit 1
fi

SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
ARCH=$(uname -m)

echo -e "${YELLOW}Architecture:${NC} ${ARCH}"
echo -e "${YELLOW}macOS SDK:${NC}    ${SDK_PATH}"

# Recreate the app bundle without discarding SwiftPM's incremental compilation cache.
echo -e "\n${BLUE}[1/4] Preparing app bundle...${NC}"
rm -rf "${BUILD_DIR}"
if [ "${CLEAN}" = true ]; then rm -rf ".build"; fi
if [ "${BUILD_ONLY}" = false ]; then
    rm -f "${DMG_NAME}"
fi
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${FRAMEWORKS_DIR}"

# Compile through SwiftPM so the SwiftVLC binary dependency is linked correctly.
echo -e "${BLUE}[2/4] Building ${CONFIGURATION} Swift, AVKit, and VLC sources for macOS 15+...${NC}"
if ! command -v swift &> /dev/null; then
    echo -e "${RED}Error: Swift Package Manager is required to build the VLC playback engine.${NC}"
    exit 1
fi
if ! swift build -c "${CONFIGURATION}"; then
    echo -e "${RED}Error: SwiftPM build failed. The VLC playback framework is required; direct swiftc fallback is unavailable.${NC}"
    exit 1
fi
if [ ! -f ".build/${CONFIGURATION}/${APP_NAME}" ]; then
    echo -e "${RED}Error: SwiftPM build did not produce ${APP_NAME}.${NC}"
    exit 1
fi
cp ".build/${CONFIGURATION}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
for RESOURCE_BUNDLE in .build/${CONFIGURATION}/*.resources; do
    if [ -d "${RESOURCE_BUNDLE}" ]; then
        cp -R "${RESOURCE_BUNDLE}" "${MACOS_DIR}/"
    fi
done

# SwiftVLC's libVLC XCFramework is statically linked into the executable.
# No VLCKit framework or build-cache runtime paths are needed.
echo -e "${GREEN}✓ Binary compiled via SwiftPM successfully.${NC}"

# Package Info.plist and Resources (AppIcon)
echo -e "${BLUE}[3/4] Assembling .app bundle & icon resources...${NC}"

# Generate macOS .icns icon from AppIcon.png if available
if [ -f "AppIcon.png" ]; then
    echo "Generating macOS AppIcon.icns..."
    ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"
    
    # Create all standard macOS iconset resolutions using native sips
    if command -v sips &> /dev/null; then
        sips -z 16 16     AppIcon.png --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null 2>&1 || true
        sips -z 32 32     AppIcon.png --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null 2>&1 || true
        sips -z 32 32     AppIcon.png --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null 2>&1 || true
        sips -z 64 64     AppIcon.png --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null 2>&1 || true
        sips -z 128 128   AppIcon.png --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null 2>&1 || true
        sips -z 256 256   AppIcon.png --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null 2>&1 || true
        sips -z 256 256   AppIcon.png --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null 2>&1 || true
        sips -z 512 512   AppIcon.png --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null 2>&1 || true
        sips -z 512 512   AppIcon.png --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null 2>&1 || true
        sips -z 1024 1024 AppIcon.png --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null 2>&1 || true
        
        if command -v iconutil &> /dev/null; then
            iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns" || cp AppIcon.png "${RESOURCES_DIR}/AppIcon.png"
        else
            cp AppIcon.png "${RESOURCES_DIR}/AppIcon.png"
        fi
        rm -rf "${ICONSET_DIR}"
    else
        cp AppIcon.png "${RESOURCES_DIR}/AppIcon.png"
    fi
fi

if [ -f "Info.plist" ]; then
    cp Info.plist "${CONTENTS_DIR}/Info.plist"
else
    echo "Warning: Info.plist not found, generating minimal manifest..."
    cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>EasyIPTV</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF
fi

if [ -f "LICENSE-LGPL-2.1" ]; then
    cp LICENSE-LGPL-2.1 "${RESOURCES_DIR}/LICENSE-LGPL-2.1.txt"
fi

cp LICENSE-SwiftVLC "${RESOURCES_DIR}/LICENSE-SwiftVLC.txt"

# Code sign locally for ad-hoc execution on Mac
echo "Applying ad-hoc code signature..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo -e "${GREEN}✓ ${APP_NAME}.app created.${NC}"

if [ "${BUILD_ONLY}" = true ]; then
    echo -e "\n${GREEN}======================================================${NC}"
    echo -e "${GREEN}  BUILD COMPLETE! ${APP_BUNDLE} is ready.${NC}"
    echo -e "${GREEN}======================================================${NC}"
    exit 0
fi

# Clean release jobs can free large VLC artifacts before hdiutil duplicates the app.
if [ "${CLEAN}" = true ]; then rm -rf ".build"; fi

# Generate the DMG disk image using built-in hdiutil
echo -e "${BLUE}[4/4] Creating ${DMG_NAME} using native hdiutil...${NC}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"

# Add drag-and-drop shortcut to /Applications
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "EasyIPTV" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_NAME}"

# Clean temporary staging
rm -rf "${STAGING_DIR}"

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}  BUILD COMPLETE! ${DMG_NAME} is ready!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "You can now open or distribute ${YELLOW}${DMG_NAME}${NC}."
echo -e "Simply double-click the .dmg and drag ${YELLOW}${APP_NAME}.app${NC} into Applications."
