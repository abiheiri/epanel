#!/bin/bash
# Create a drag-and-drop DMG for epanel.
# Usage: ./scripts/create-dmg.sh <version> <app-path> <output-dmg>
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="epanel"
VOLUME_NAME="$APP_NAME"

VERSION="${1:-$APP_NAME}"
APP="${2:-$PROJECT_DIR/build/$APP_NAME.app}"
OUTPUT_DMG="${3:-$PROJECT_DIR/$APP_NAME.dmg}"

[ -d "$APP" ] || { echo "❌ App not found: $APP"; exit 1; }

STAGING="$PROJECT_DIR/dmg-build"
rm -rf "$STAGING"
mkdir -p "$STAGING"

echo "📦 Staging $APP …"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

TEMP_DMG="$PROJECT_DIR/${APP_NAME}-temp.dmg"
rm -f "$TEMP_DMG"

echo "💿 Creating DMG…"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDRW "$TEMP_DMG"

MOUNT="/Volumes/$VOLUME_NAME"
hdiutil attach "$TEMP_DMG" -mountpoint "$MOUNT" -quiet
sleep 2

osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 600, 400}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 72
    set position of item "$APP_NAME.app" of container window to {120, 150}
    set position of item "Applications" of container window to {380, 150}
    update without registering applications
    delay 2
  end tell
end tell
EOF

sync
hdiutil detach "$MOUNT" -quiet

rm -f "$OUTPUT_DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -o "$OUTPUT_DMG"
rm -f "$TEMP_DMG"
rm -rf "$STAGING"

echo "✅ $OUTPUT_DMG ($(du -h "$OUTPUT_DMG" | cut -f1))"
