#!/bin/bash
# Build Worktrees.app and install it into ~/Applications.
#   app/build.sh            build + install
#   app/build.sh --login    also add it to Login Items
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
BUILD="$HERE/build"
APP="$BUILD/Worktrees.app"
DEST="$HOME/Applications/Worktrees.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Worktrees" "$HERE/WorktreeBar.swift"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Worktrees</string>
  <key>CFBundleIdentifier</key><string>io.github.duynguyentho.git-worktree-tracker</string>
  <key>CFBundleExecutable</key><string>Worktrees</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Reads your repos and their git worktrees.</string>
  <key>WTScriptPath</key><string>$PROJECT/scripts/wt.py</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null

pkill -x Worktrees 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "installed $DEST"

if [[ "${1:-}" == "--login" ]]; then
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$DEST\", hidden:true}" >/dev/null
  echo "added to Login Items"
fi
