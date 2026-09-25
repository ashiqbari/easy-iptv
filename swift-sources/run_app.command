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

echo "[1/3] Cleaning previous build cache..."
rm -rf .build

echo "[2/3] Building native macOS app with Swift Package Manager..."
swift build -c release

echo "[3/3] Launching EasyIPTV..."
./.build/release/EasyIPTV
