#!/bin/bash
# Publishes a MountMate release: a signed, universal MountMate.app, zipped and
# attached to a GitHub release, for people who would rather not build it.
#
#   ./Scripts/release.sh 1.2.0             tag v1.2.0, build, publish
#   ./Scripts/release.sh --dry-run 1.2.0   build the zip and notes; publish nothing
#
# The asset is always named MountMate.zip, so the README can link to
# .../releases/latest/download/MountMate.zip and never go stale.
#
# The download is not notarized: that needs a paid Apple Developer Program
# membership. macOS therefore blocks its first launch until the person allows it in
# System Settings > Privacy & Security > Open Anyway, once per version.
#
# Signing identity. "MountMate Self-Signed" by default, set MOUNTMATE_RELEASE_IDENTITY
# to override:
#   - Not the Apple Development identity. Its certificate is named after the Apple
#     ID's email address, and signing a public download with it publishes that
#     address. Without notarization it gets past Gatekeeper no better than
#     self-signed does.
#   - Not ad hoc. An ad hoc signature changes with every build, and the login item
#     would need turning on again after each update. A certificate gives every
#     release the same designated requirement.
#   - The private key exists only in this Mac's keychain. Releases signed with a
#     different key still work, but people's login item then needs turning on again
#     once.
set -euo pipefail

fail() { echo "release: $*" >&2; exit 1; }

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
    shift
fi
VERSION="${1:?usage: $0 [--dry-run] <version, e.g. 1.2.0>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.0, not \"$VERSION\"."
TAG="v$VERSION"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="ee02217/MountMate"
cd "$ROOT"

# --- 1. preconditions ----------------------------------------------------------
# A release is the code people will run, so it must be exactly what is on GitHub.
[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes."
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "$TAG already exists."
fi
if ! $DRY_RUN; then
    [ "$(git branch --show-current)" = "main" ] || fail "release from main."
    git fetch --quiet origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
        || fail "main and origin/main differ. Push or pull first."
    gh auth status >/dev/null 2>&1 || fail "gh is not signed in. Run: gh auth login"
fi

IDENTITY="${MOUNTMATE_RELEASE_IDENTITY:-MountMate Self-Signed}"
IDENTITY_HASH="$(
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -F "\"$IDENTITY\"" | head -1 | awk '{print $2}'
)"
[ -n "$IDENTITY_HASH" ] || fail "no code-signing identity named \"$IDENTITY\". Create it with ./Scripts/create-identity.sh"

# --- 2. build ------------------------------------------------------------------
OUT="$ROOT/.build/release-$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
MOUNTMATE_VERSION="$VERSION" "$ROOT/Scripts/build-app.sh" --universal "$IDENTITY_HASH" "$OUT/MountMate.app"

# ditto rather than zip: it keeps the bundle's signature and extended attributes
# intact, and it is what Finder's Compress uses.
ZIP="$OUT/MountMate.zip"
ditto -c -k --keepParent "$OUT/MountMate.app" "$ZIP"

# --- 3. notes ------------------------------------------------------------------
PREVIOUS="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
{
    if [ -n "$PREVIOUS" ]; then
        echo "## Changes since $PREVIOUS"
        echo
        git log --no-merges --format='- %s' "$PREVIOUS..HEAD"
    else
        echo "The first release of MountMate."
    fi
    cat <<NOTES

## Install

1. Download **MountMate.zip** below and open it.
2. Drag **MountMate** into your **Applications** folder, then open it from there.
3. macOS says it can't verify MountMate, because it isn't notarized by Apple.
   Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down to **Security**, click
   **Open Anyway** next to the message about MountMate, and confirm.

Steps 3 and 4 are needed once for each new version. Updating is the same: replace
the app in Applications.

When a new version first reads a saved share password, macOS asks for your login
password. Click **Always Allow**. To avoid both, build MountMate yourself instead;
see the [README](https://github.com/$REPO#install).

Requires macOS 26 or later. Runs on Apple silicon and Intel.

SHA-256 of MountMate.zip: \`$(shasum -a 256 "$ZIP" | awk '{print $1}')\`
NOTES
} >"$OUT/notes.md"

if $DRY_RUN; then
    cat <<DONE

Dry run: nothing tagged or published.
  $ZIP
  $OUT/notes.md
DONE
    exit 0
fi

# --- 4. publish ----------------------------------------------------------------
git tag -a "$TAG" -m "MountMate $VERSION"
git push --quiet origin "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --verify-tag \
    --title "MountMate $VERSION" --notes-file "$OUT/notes.md"

echo
echo "Published https://github.com/$REPO/releases/tag/$TAG"
