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

# Pre-generated Finder metadata: icon view with the app and Applications
# side by side. Scripting Finder for this is unreliable on headless CI.
python3 "$PROJECT_DIR/scripts/generate-dmg-dsstore.py" "$STAGING/.DS_Store"

echo "💿 Creating DMG…"
rm -f "$OUTPUT_DMG"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDZO "$OUTPUT_DMG"
rm -rf "$STAGING"

echo "✅ $OUTPUT_DMG ($(du -h "$OUTPUT_DMG" | cut -f1))"
