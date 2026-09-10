#!/bin/bash
# Assembles a minimal unsigned MountMate.app so the menu bar item can be seen
# during development.
#
# This is NOT spec section 7's bundle: no signing, no self-signed identity, no
# Homebrew, no install. Milestone 7 replaces it. It exists because SwiftPM emits a
# bare executable with no Info.plist, and LSUIElement lives in one.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/MountMate.app"

swift build -c "$CONFIG" --product MountMate
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/MountMate"

# The .icns is a build product and is gitignored, so a fresh clone has none.
# Regenerate when it is missing or older than the code that draws it.
ICON="$ROOT/Resources/MountMate.icns"
if [ ! -f "$ICON" ] || [ "$ROOT/Scripts/make-icon.swift" -nt "$ICON" ]; then
    swift "$ROOT/Scripts/make-icon.swift"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MountMate</string>
    <key>CFBundleIdentifier</key><string>com.sergio.mountmate</string>
    <key>CFBundleName</key><string>MountMate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1-dev</string>
    <key>CFBundleIconFile</key><string>MountMate</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cp "$BINARY" "$APP/Contents/MacOS/MountMate"
cp "$ICON" "$APP/Contents/Resources/MountMate.icns"

echo "Built $APP"
echo "Run it with:  open \"$APP\""
echo "Stop it from the menu bar item, or:  pkill -x MountMate"
