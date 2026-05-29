#!/bin/bash
# Usage: ./make_dmg.sh <path/to/Notepad.app> <version> <output_dir>
set -e

APP="$1"
VERSION="$2"
OUT_DIR="$3"
VOL_NAME="Notepad $VERSION"
DMG_OUT="$OUT_DIR/Notepad_$VERSION.dmg"
STAGING=$(mktemp -d)

echo "→ Staging files…"
cp -r "$APP" "$STAGING/Notepad.app"
ln -s /Applications "$STAGING/Applications"

echo "→ Creating DMG…"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_OUT"

rm -rf "$STAGING"
echo "✓ DMG ready: $DMG_OUT"
