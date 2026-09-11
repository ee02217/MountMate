#!/bin/bash
# Builds, assembles and signs MountMate.app. Shared by install.sh and release.sh, so
# the app a friend downloads is put together exactly like the one install.sh builds.
#
#   Scripts/build-app.sh [--universal] <signing identity SHA-1> <output .app path>
#
# --universal builds for Apple silicon and Intel in one binary. It needs Xcode itself,
# not just the command line tools, so only release.sh asks for it.
# The version comes from MOUNTMATE_VERSION, or else from the nearest git tag.
set -euo pipefail

ARCHS=()
if [ "${1:-}" = "--universal" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
    shift
fi
IDENTITY_HASH="${1:?usage: $0 [--universal] <identity SHA-1> <output .app>}"
APP="${2:?usage: $0 [--universal] <identity SHA-1> <output .app>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- 1. build ------------------------------------------------------------------
swift build -c release --product MountMate ${ARCHS[@]+"${ARCHS[@]}"}
BINARY="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/MountMate"

# The .icns is a build product and is gitignored, so a fresh clone has none.
# Regenerate when it is missing or older than the code that draws it.
ICON="$ROOT/Resources/MountMate.icns"
if [ ! -f "$ICON" ] || [ "$ROOT/Scripts/make-icon.swift" -nt "$ICON" ]; then
    swift "$ROOT/Scripts/make-icon.swift"
fi

# Tags are "v1.2.0"; the bundle version is "1.2.0".
VERSION="${MOUNTMATE_VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo 0.1)}"
VERSION="${VERSION#v}"

# --- 2. assemble ---------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MountMate</string>
    <key>CFBundleIdentifier</key><string>com.sergio.mountmate</string>
    <key>CFBundleName</key><string>MountMate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleIconFile</key><string>MountMate</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cp "$BINARY" "$APP/Contents/MacOS/MountMate"
# Before codesign: adding a file to a signed bundle invalidates the signature.
cp "$ICON" "$APP/Contents/Resources/MountMate.icns"

# --- 3. sign -------------------------------------------------------------------
codesign --force --options runtime --timestamp=none \
    --sign "$IDENTITY_HASH" "$APP"

# Verify before handing it on. An unsigned or badly signed bundle would fail later
# inside SMAppService with an error that says nothing useful.
codesign --verify --strict --verbose=2 "$APP"
