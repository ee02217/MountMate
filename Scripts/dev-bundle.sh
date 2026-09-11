#!/bin/bash
# Assembles a minimal unsigned MountMate.app so the menu bar item can be seen
# during development.
#
# Not the installed bundle: no hardened runtime, no /Applications, no launch-at-login.
# It exists because SwiftPM emits a bare executable with no Info.plist, and
# LSUIElement lives in one. It is signed with an Apple Development identity when there
# is one — an unsigned build is a different app to the Keychain every time, so each
# rebuild would ask for the login password (spec §6).
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

DEV_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -F '"Apple Development:' | head -1 | awk '{print $2}'
)"
if [ -n "$DEV_IDENTITY" ]; then
    codesign --force --sign "$DEV_IDENTITY" "$APP" 2>/dev/null
    echo "Signed with an Apple Development identity."
else
    echo "Unsigned: macOS will ask for your login password each rebuild." >&2
fi

echo "Built $APP"
echo "Run it with:  open \"$APP\""
echo "Stop it from the menu bar item, or:  pkill -x MountMate"
