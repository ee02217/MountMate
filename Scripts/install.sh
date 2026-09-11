#!/bin/bash
# Builds, signs and installs MountMate.app into /Applications.
#
# Which identity signs it decides whether the Keychain prompts after every update.
# macOS partitions each Keychain item by the code that created it: by team for code
# signed with a developer team, by the exact binary's cdhash otherwise. So:
#
#   1. MOUNTMATE_IDENTITY, if set — the caller knows best.
#   2. An "Apple Development" identity, if there is one. It carries a team ID, so
#      every build reads the stored password without a prompt. Any Apple ID signed
#      into Xcode gets one; it is renewed yearly, and a renewed certificate keeps the
#      same team and designated requirement.
#   3. "MountMate Self-Signed" as a last resort. Stable enough for launch-at-login,
#      but it has no team, so macOS asks for the login password after every update
#     . Create it once with ./Scripts/create-identity.sh.
set -euo pipefail

if [ -n "${MOUNTMATE_IDENTITY:-}" ]; then
    IDENTITY="$MOUNTMATE_IDENTITY"
else
    IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"'
    )"
    [ -n "$IDENTITY" ] || IDENTITY="MountMate Self-Signed"
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING="$ROOT/.build/install/MountMate.app"
DESTINATION="/Applications/MountMate.app"

# --- 1. the identity must exist before anything else happens -------------------
# Resolved to its SHA-1 hash rather than used by name. Two certificates can share a
# common name — `security add-trusted-cert` can itself add a keyless copy — and
# codesign then refuses with "ambiguous (matches ... and ...)". Only a certificate
# with a private key appears in `find-identity -v`, so taking the first match here
# picks the usable one.
IDENTITY_HASH="$(
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -F "\"$IDENTITY\"" | head -1 | awk '{print $2}'
)"

if [ -z "$IDENTITY_HASH" ]; then
    cat >&2 <<MESSAGE
No code-signing identity named "$IDENTITY" was found.

Create one, once, either way:

  Scripted:
    ./Scripts/create-identity.sh

  By hand:
    1. Open Keychain Access
    2. Menu: Keychain Access > Certificate Assistant > Create a Certificate...
    3. Name:             $IDENTITY
       Identity Type:    Self Signed Root
       Certificate Type: Code Signing

Then run this script again.

Or point at an identity you already have:
  MOUNTMATE_IDENTITY="Your Identity" $0

Better still, sign into Xcode with any Apple ID (Xcode > Settings > Accounts): it
creates an "Apple Development" identity, which this script prefers, and which stops
macOS asking for your login password after every update.
MESSAGE
    exit 1
fi

# --- 2. build ------------------------------------------------------------------
swift build -c release --product MountMate
BINARY="$(swift build -c release --show-bin-path)/MountMate"

# The .icns is a build product and is gitignored, so a fresh clone has none.
# Regenerate when it is missing or older than the code that draws it.
ICON="$ROOT/Resources/MountMate.icns"
if [ ! -f "$ICON" ] || [ "$ROOT/Scripts/make-icon.swift" -nt "$ICON" ]; then
    swift "$ROOT/Scripts/make-icon.swift"
fi

VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo 0.1)"

# --- 3. assemble ---------------------------------------------------------------
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"

cat >"$STAGING/Contents/Info.plist" <<PLIST
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

cp "$BINARY" "$STAGING/Contents/MacOS/MountMate"
# Before codesign: adding a file to a signed bundle invalidates the signature.
cp "$ICON" "$STAGING/Contents/Resources/MountMate.icns"

# --- 4. sign -------------------------------------------------------------------
codesign --force --options runtime --timestamp=none \
    --sign "$IDENTITY_HASH" "$STAGING"

# Verify before installing. An unsigned or badly signed bundle would fail later
# inside SMAppService with an error that says nothing useful, and this script exists
# precisely to make launch-at-login work.
codesign --verify --strict --verbose=2 "$STAGING"

TEAM="$(codesign -dvvv "$STAGING" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
if [ -z "$TEAM" ] || [ "$TEAM" = "not set" ]; then
    cat >&2 <<WARNING

Signed without a developer team. macOS will ask for your login password the first
time each new build reads a stored share password — after every update. Sign into
Xcode with an Apple ID and re-run this script to stop the prompts.
WARNING
fi

# --- 5. install ----------------------------------------------------------------
if pgrep -x MountMate >/dev/null; then
    echo "Quitting the running MountMate..."
    pkill -x MountMate || true
    sleep 1
fi

rm -rf "$DESTINATION"
cp -R "$STAGING" "$DESTINATION"

cat <<DONE

Installed $DESTINATION  (version $VERSION, signed as "$IDENTITY" / $IDENTITY_HASH)

Next:
  open "$DESTINATION"
  then Settings > General > "Launch MountMate at login"

The login item points at /Applications, so re-running this script upgrades in
place without re-enabling it.
DONE
