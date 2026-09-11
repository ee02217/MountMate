#!/bin/bash
# Builds MountMate from source and installs it, in one command:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ee02217/MountMate/main/Scripts/bootstrap.sh)"
#
# Running it again updates. It builds the latest release; set MOUNTMATE_REF to build
# a branch or another tag instead.
#
# Built on the Mac that runs it, the app is never quarantined, so Gatekeeper has
# nothing to block, unlike the download from GitHub Releases. Everything is fetched
# into a temporary folder that is removed afterwards.
#
# "bash -c" rather than piping curl into bash: create-identity.sh and the tools'
# installer may ask questions, and a piped script would be reading its own source as
# their answers.
set -euo pipefail

REPO="${MOUNTMATE_REPO:-https://github.com/ee02217/MountMate.git}"

fail() { echo "MountMate: $*" >&2; exit 1; }

# --- 1. this Mac ---------------------------------------------------------------
OS="$(sw_vers -productVersion)"
[ "${OS%%.*}" -ge 26 ] || fail "needs macOS 26 or later. This Mac has macOS $OS."

if ! xcode-select -p >/dev/null 2>&1; then
    echo "MountMate is built from source, which needs Apple's command line tools."
    echo "Opening their installer..."
    xcode-select --install >/dev/null 2>&1 || true
    fail "once the command line tools have installed, run this command again."
fi

SWIFT="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p')"
read -r SWIFT_MAJOR SWIFT_MINOR <<<"${SWIFT:-0 0}"
if [ "$SWIFT_MAJOR" -lt 6 ] || { [ "$SWIFT_MAJOR" -eq 6 ] && [ "$SWIFT_MINOR" -lt 2 ]; }; then
    fail "needs Swift 6.2 or later, which comes with Xcode 26. Update Xcode or the command line tools in System Settings > General > Software Update."
fi

# --- 2. the code ---------------------------------------------------------------
REF="${MOUNTMATE_REF:-}"
if [ -z "$REF" ]; then
    REF="$(
        git ls-remote --tags --refs --sort=-version:refname "$REPO" 'v*' 2>/dev/null \
            | head -1 | sed 's|.*refs/tags/||'
    )"
    REF="${REF:-main}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "Fetching MountMate ($REF)..."
git clone --quiet --depth 1 --branch "$REF" "$REPO" "$WORK/MountMate" 2>/dev/null \
    || fail "could not fetch $REF from $REPO."

# --- 3. a signing identity -----------------------------------------------------
# install.sh prefers an Apple Development identity and falls back to a self-signed
# one. With neither, make the self-signed one now instead of failing halfway.
if [ -z "${MOUNTMATE_IDENTITY:-}" ] \
    && ! security find-identity -v -p codesigning 2>/dev/null \
        | grep -qE '"(Apple Development: .*|MountMate Self-Signed)"'; then
    echo
    echo "MountMate needs a code-signing identity, so macOS can recognise it across"
    echo "updates. Creating one on this Mac; it never leaves it."
    "$WORK/MountMate/Scripts/create-identity.sh"
fi

# --- 4. build, install, open ---------------------------------------------------
"$WORK/MountMate/Scripts/install.sh" --open
echo "To update later, run the same command again."
