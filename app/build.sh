#!/bin/bash
# Build Worktrees.app.
#   app/build.sh                    dev build: points at this checkout's scripts/wt.py, installs into
#                                   ~/Applications and launches it
#   app/build.sh --login            dev build + add to Login Items
#   app/build.sh --release          release build: universal (arm64 + x86_64), self-contained
#                                   (bundled wt.py), zipped to app/build/Worktrees-$VERSION.zip
#   VERSION=0.2.0 app/build.sh --release
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
BUILD="$HERE/build"
APP="$BUILD/Worktrees.app"
DEST="$HOME/Applications/Worktrees.app"
VERSION="${VERSION:-0.0.0-dev}"
RELEASE=false
LOGIN=false
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=true ;;
    --login) LOGIN=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$HERE/Sources" -name '*.swift' | sort)

if $RELEASE; then
  for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos14.0" \
      -o "$BUILD/Worktrees-$arch" "${SOURCES[@]}"
  done
  lipo -create -output "$APP/Contents/MacOS/Worktrees" "$BUILD/Worktrees-arm64" "$BUILD/Worktrees-x86_64"
  rm -f "$BUILD/Worktrees-arm64" "$BUILD/Worktrees-x86_64"
  DEV_SCRIPT=""
else
  swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    -o "$APP/Contents/MacOS/Worktrees" "${SOURCES[@]}"
  DEV_SCRIPT="<key>WTScriptPath</key><string>$PROJECT/scripts/wt.py</string>"
fi

cp "$PROJECT/scripts/wt.py" "$APP/Contents/Resources/wt.py"
rsync -a --exclude '__pycache__' "$PROJECT/scripts/wtlib/" "$APP/Contents/Resources/wtlib/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Worktrees</string>
  <key>CFBundleDisplayName</key><string>Worktrees</string>
  <key>CFBundleIdentifier</key><string>io.github.duynguyentho.git-worktree-tracker</string>
  <key>CFBundleExecutable</key><string>Worktrees</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Reads your repos and their git worktrees.</string>
  $DEV_SCRIPT
</dict>
</plist>
PLIST

# Ad-hoc signature: required to run on Apple Silicon. Not notarized (no Developer ID).
codesign --force --sign - "$APP" >/dev/null

if $RELEASE; then
  ZIP="$BUILD/Worktrees-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
  echo "built $ZIP"
  echo "sha256 $(cat "$ZIP.sha256")"
  lipo -archs "$APP/Contents/MacOS/Worktrees"
  exit 0
fi

pkill -x Worktrees 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "installed $DEST"

if $LOGIN; then
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$DEST\", hidden:true}" >/dev/null
  echo "added to Login Items"
fi
