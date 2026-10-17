#!/bin/bash
# Double-click to incrementally build and launch the Debug app; --release and --clean are optional.
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"
./build_dmg.sh --build-only "$@"
exec ./build/EasyIPTV.app/Contents/MacOS/EasyIPTV
