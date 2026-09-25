#!/bin/bash
# ==============================================================================
# EasyIPTV - Native macOS .app & .dmg Automated Build Script
# Compatible with macOS Ventura (13.0+), Sonoma (14.0+), and Sequoia (15.0+)
# Requires: Xcode Command Line Tools (`xcode-select --install`)
# ==============================================================================

set -e

APP_NAME="EasyIPTV"
DMG_NAME="EasyIPTV-macOS.dmg"
BUILD_DIR="./build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
STAGING_DIR="${BUILD_DIR}/dmg_staging"

# Terminal Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}       EasyIPTV macOS App & DMG Builder               ${NC}"
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

# Clean previous build artifacts
echo -e "\n${BLUE}[1/4] Cleaning previous build artifacts...${NC}"
rm -rf "${BUILD_DIR}" "${DMG_NAME}" ".build"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Locate macro plugin paths for Swift 5.9+ / Xcode 15/16 (e.g. SwiftUIMacros)
PLATFORM_DIR=$(xcrun --show-sdk-platform-path 2>/dev/null || true)
DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
PLUGIN_ARGS=()

if [ -d "${PLATFORM_DIR}/Developer/usr/lib/swift/host/plugins" ]; then
    PLUGIN_ARGS+=("-plugin-path" "${PLATFORM_DIR}/Developer/usr/lib/swift/host/plugins")
fi
if [ -d "${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins" ]; then
    PLUGIN_ARGS+=("-plugin-path" "${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins")
fi
if [ ${#PLUGIN_ARGS[@]} -eq 0 ] && [ -n "${DEVELOPER_DIR}" ]; then
    FOUND_DIR=$(find "${DEVELOPER_DIR}" -name "libSwiftUIMacros.dylib" -exec dirname {} \; 2>/dev/null | head -n 1)
    if [ -n "${FOUND_DIR}" ]; then
        PLUGIN_ARGS+=("-plugin-path" "${FOUND_DIR}")
    fi
fi

# Compile all Swift files into a native macOS binary
echo -e "${BLUE}[2/4] Compiling native Swift & AVKit sources for macOS 13+...${NC}"

BUILD_SUCCESS=false

# Clean previous build artifacts if needed
rm -rf .build/release/${APP_NAME}

# Method A: Swift Package Manager (handles macros and modern toolchains automatically)
if [ -f "Package.swift" ] && command -v swift &> /dev/null; then
    echo -e "${YELLOW}Compiling with Swift Package Manager (swift build -c release)...${NC}"
    if swift build -c release; then
        if [ -f ".build/release/${APP_NAME}" ]; then
            cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
            BUILD_SUCCESS=true
            echo -e "${GREEN}✓ Binary compiled via SwiftPM successfully.${NC}"
        fi
    fi
fi

# Method B: Direct swiftc invocation with discovered plugin search path
if [ "$BUILD_SUCCESS" = false ]; then
    echo -e "${YELLOW}Compiling with swiftc direct invocation...${NC}"
    swiftc -O \
      -target "${ARCH}-apple-macos13.0" \
      -sdk "${SDK_PATH}" \
      "${PLUGIN_ARGS[@]}" \
      -framework SwiftUI \
      -framework AVFoundation \
      -framework QuartzCore \
      -framework AppKit \
      -framework IOKit \
      -framework Combine \
      M3UItem.swift \
      M3UParser.swift \
      XtreamCodesManager.swift \
      IPTVPlayerManager.swift \
      IPTVPlaybackView.swift \
      ChannelListView.swift \
      ContentView.swift \
      IPTVPlayerApp.swift \
      -o "${MACOS_DIR}/${APP_NAME}"
    echo -e "${GREEN}✓ Binary compiled with swiftc successfully.${NC}"
fi

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
    <string>13.0</string>
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

# Code sign locally for ad-hoc execution on Mac
echo "Applying ad-hoc code signature..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo -e "${GREEN}✓ ${APP_NAME}.app created.${NC}"

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
