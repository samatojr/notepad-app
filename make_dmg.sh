#!/bin/bash
# Usage: ./make_dmg.sh <path/to/Notepad.app> <version> <output_dir>
set -e

APP="$1"
VERSION="$2"
OUT_DIR="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VOL_NAME="Notepad $VERSION"
DMG_FINAL="$OUT_DIR/Notepad_$VERSION.dmg"
RW_DMG="/tmp/NotepadRW_$VERSION.dmg"
BG_PNG="/tmp/dmg_background_$VERSION.png"

rm -f "$RW_DMG"

# ── 1. Background image ───────────────────────────────────────────────────────
# Use a pre-made background if it exists alongside this script, otherwise generate one
if [ -f "$SCRIPT_DIR/dmg_background.png" ]; then
    echo "→ Using pre-made background image…"
    cp "$SCRIPT_DIR/dmg_background.png" "$BG_PNG"
else
    echo "→ Generating background image…"
    swift "$SCRIPT_DIR/make_dmg_background.swift" "$BG_PNG"
fi

# ── 2. Create empty r/w DMG ───────────────────────────────────────────────────
echo "→ Creating r/w DMG…"
SIZE_MB=$(( $(du -sm "$APP" | cut -f1) + 30 ))
hdiutil create -volname "$VOL_NAME" -fs HFS+ -size ${SIZE_MB}m -ov "$RW_DMG"

# ── 3. Mount ──────────────────────────────────────────────────────────────────
echo "→ Mounting…"
MOUNT_OUT=$(hdiutil attach "$RW_DMG" -readwrite -nobrowse -plist)
MOUNT_POINT=$(python3 -c "
import sys, plistlib
pl = plistlib.loads(sys.stdin.buffer.read())
for e in pl.get('system-entities', []):
    if 'mount-point' in e:
        print(e['mount-point'])
        break
" <<< "$MOUNT_OUT")
echo "  Mounted at: $MOUNT_POINT"
# Use the actual volume name from the mount point (may differ from VOL_NAME if suffixed)
VOL_ACTUAL=$(basename "$MOUNT_POINT")

# ── 4. Populate (background image goes in a VISIBLE folder first) ─────────────
echo "→ Copying files…"
cp -r "$APP"   "$MOUNT_POINT/Notepad.app"
ln -s /Applications "$MOUNT_POINT/Applications"
mkdir -p "$MOUNT_POINT/dmgbg"
cp "$BG_PNG"   "$MOUNT_POINT/dmgbg/background.png"

# ── 5. Finder layout ──────────────────────────────────────────────────────────
echo "→ Setting Finder layout (waiting for Finder to discover volume)…"
sleep 4

osascript - "$MOUNT_POINT" "$VOL_ACTUAL" << 'APPLESCRIPT'
on run argv
    set mountPoint to item 1 of argv
    set volName    to item 2 of argv
    set bgPath     to mountPoint & "/dmgbg/background.png"

    tell application "Finder"
        -- Retry opening the disk
        repeat with i from 1 to 8
            try
                open disk volName
                exit repeat
            on error
                delay 2
            end try
        end repeat
        delay 3

        tell disk volName
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            -- Window bounds: width=540 matches image; height=380+22 for title bar overhead
            -- bounds = {left, top, right, bottom}
            -- width = 540 (matches image width exactly)
            -- height = image (380) + chrome overhead (title bar ~28 + tab bar ~28 + status bar ~22 = ~78) + 10 padding = ~468
            -- bottom = top (150) + 468 = 618
            set the bounds of container window to {200, 150, 740, 627}

            set opts to the icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 100
            set background picture of opts to POSIX file bgPath

            -- Notepad on LEFT, Applications on RIGHT
            set position of item "Notepad.app"  of container window to {140, 210}
            set position of item "Applications" of container window to {390, 210}
            set position of item "dmgbg"        of container window to {650, 210}

            update without registering applications
            delay 4
            close
            delay 2
            -- Reopen once to ensure DS_Store is fully written
            open
            delay 3
            close
            delay 2
        end tell
    end tell
end run
APPLESCRIPT

# ── 6. Rename bg folder to hidden .background, flush ─────────────────────────
echo "→ Hiding background folder…"
mv "$MOUNT_POINT/dmgbg" "$MOUNT_POINT/.background"
# Mark it invisible using xattr (works without SetFile/Xcode tools)
/usr/bin/SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || true
sync
sleep 3

# ── 7. Unmount ────────────────────────────────────────────────────────────────
echo "→ Unmounting…"
hdiutil detach "$MOUNT_POINT" -quiet

# ── 8. Convert to compressed read-only DMG ───────────────────────────────────
echo "→ Converting to final DMG…"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" -ov

rm -f "$RW_DMG" "$BG_PNG"
echo "✓ DMG ready: $DMG_FINAL"
