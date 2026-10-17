#!/bin/bash
# Exercise packaging flags without compiling Swift or touching the real build cache.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
cp "$REPO/swift-sources/build_dmg.sh" "$FIXTURE/"
cd "$FIXTURE"
mkdir bin .build
touch .build/cache-marker
cat > bin/swift <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> swift.log
[ "${FAIL_BUILD:-0}" = 0 ] || exit 1
mkdir -p ".build/$3" .build/artifacts/VLCKit.xcframework/macos-test/VLCKit.framework/Versions/A
printf 'original binary' > ".build/$3/EasyIPTV"
touch .build/artifacts/VLCKit.xcframework/macos-test/VLCKit.framework/Versions/A/VLCKit
STUB
for tool in xcrun otool codesign hdiutil; do
    printf '#!/bin/sh\nprintf "stub\\n"\n' > "bin/$tool"
done
cat > bin/install_name_tool <<'STUB'
#!/bin/bash
# Patching the cached SwiftPM executable would break incremental builds.
case "${!#}" in build/*|./build/*) ;; *) exit 9 ;; esac
STUB
chmod +x bin/*
export PATH="$FIXTURE/bin:/usr/bin:/bin"
./build_dmg.sh --build-only > /dev/null
test "$(tail -n 1 swift.log)" = 'build -c debug'
test -f .build/cache-marker
test -f build/EasyIPTV.app/Contents/MacOS/EasyIPTV
./build_dmg.sh --build-only > /dev/null
test -f .build/cache-marker
./build_dmg.sh --release --build-only > /dev/null
test "$(tail -n 1 swift.log)" = 'build -c release'
./build_dmg.sh > /dev/null
test "$(tail -n 1 swift.log)" = 'build -c release'
test -f .build/cache-marker
./build_dmg.sh --clean --build-only > /dev/null
test ! -e .build/cache-marker
test -d .build/debug
./build_dmg.sh --clean > /dev/null
test ! -e .build
if ./build_dmg.sh --invalid > /dev/null; then exit 1; fi
if FAIL_BUILD=1 ./build_dmg.sh --build-only > /dev/null; then exit 1; fi
printf '%s\n' 'Build workflow checks passed.'
