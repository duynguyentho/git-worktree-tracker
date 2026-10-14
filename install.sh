#!/bin/sh
# Install Worktrees.app from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/duynguyentho/git-worktree-tracker/main/install.sh | sh
# Options (environment): WORKTREES_VERSION=0.1.0  WORKTREES_INSTALL_DIR=/Applications  WORKTREES_NO_OPEN=1
set -eu

REPO="duynguyentho/git-worktree-tracker"
DEST="${WORKTREES_INSTALL_DIR:-$HOME/Applications}"
VERSION="${WORKTREES_VERSION:-}"

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "macOS only"
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 14 ] || fail "macOS 14 (Sonoma) or later is required"
xcode-select -p > /dev/null 2>&1 || fail "git and Python 3 come with the Xcode Command Line Tools: run 'xcode-select --install' first"

if [ -z "$VERSION" ]; then
  VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$VERSION" ] || fail "could not find the latest release"
fi

URL="https://github.com/$REPO/releases/download/v$VERSION/Worktrees-$VERSION.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf 'Downloading Worktrees %s…\n' "$VERSION"
curl -fsSL "$URL" -o "$TMP/Worktrees.zip" || fail "download failed: $URL"
curl -fsSL "$URL.sha256" -o "$TMP/Worktrees.zip.sha256" || fail "checksum download failed"
[ "$(shasum -a 256 "$TMP/Worktrees.zip" | awk '{print $1}')" = "$(tr -d '[:space:]' < "$TMP/Worktrees.zip.sha256")" ] \
  || fail "checksum mismatch"

ditto -x -k "$TMP/Worktrees.zip" "$TMP"
pkill -x Worktrees 2> /dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/Worktrees.app"
ditto "$TMP/Worktrees.app" "$DEST/Worktrees.app"
# The app is ad-hoc signed, not notarized: without this macOS refuses to open a downloaded copy.
xattr -dr com.apple.quarantine "$DEST/Worktrees.app" 2> /dev/null || true

printf 'Installed %s/Worktrees.app\n' "$DEST"
[ -n "${WORKTREES_NO_OPEN:-}" ] || open "$DEST/Worktrees.app"
