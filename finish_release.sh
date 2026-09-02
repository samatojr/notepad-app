#!/bin/bash
# Finish a Notepad release: notarize -> staple -> re-zip -> EdDSA sign -> build and
# notarize the DMG -> appcast entry -> (optionally) publish to GitHub.
#
# The Release build is already made and Developer ID signed at /tmp/np-release.
# The one thing Claude could not do is notarization: it needs your Apple ID and an
# app-specific password, which it must never handle. Do this once, yourself:
#
#   xcrun notarytool store-credentials "notarytool" \
#       --apple-id "you@example.com" \
#       --team-id HHW8S56U26 \
#       --password "xxxx-xxxx-xxxx-xxxx"     # app-specific password from appleid.apple.com
#
# Then:  ./finish_release.sh            (prepares everything, publishes nothing)
#        ./finish_release.sh --publish  (also creates the GitHub release and pushes)

set -euo pipefail

VERSION="3.4"
BUILD="29"
REPO="samatojr/notepad-app"
DIR="/tmp/np-release"
APP="$DIR/Notepad.app"
ZIP="$DIR/Notepad_${VERSION}.zip"
DMG="$DIR/Notepad_${VERSION}.dmg"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPCAST="$PROJECT_DIR/appcast.xml"
# DerivedData directory names change whenever the project is relocated, so find the
# tool rather than hard-coding last release's path.
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)"
CERT="Developer ID Application: St. Joseph By-The-Sea High School (HHW8S56U26)"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_V="$SPARKLE_FW/Versions/B"

[ -d "$APP" ] || { echo "✗ $APP missing — re-run the Release build first."; exit 1; }

echo "==> 1/6 Checking notarization credentials"
if ! xcrun notarytool history --keychain-profile "notarytool" >/dev/null 2>&1; then
    echo "✗ No 'notarytool' keychain profile. Run the store-credentials command in the"
    echo "  header of this script first — it needs an app-specific password, which is"
    echo "  yours to enter, not Claude's."
    exit 1
fi

echo "==> 2a/6 Re-signing Sparkle's nested binaries"
# Sparkle ships prebuilt Updater.app/Autoupdate/XPC services that are NOT Developer ID
# signed and carry no secure timestamp — notarization rejects them. Sign inside-out:
# nested code first, then the framework, then the app, or the outer signature breaks.
for t in "$SPARKLE_V/XPCServices/Downloader.xpc" "$SPARKLE_V/XPCServices/Installer.xpc" \
         "$SPARKLE_V/Updater.app" "$SPARKLE_V/Autoupdate"; do
    [ -e "$t" ] && codesign -f -s "$CERT" --timestamp --options runtime "$t"
done
codesign -f -s "$CERT" --timestamp --options runtime "$SPARKLE_FW"
codesign -f -s "$CERT" --timestamp --options runtime \
    --entitlements "$PROJECT_DIR/Notepad/Notepad.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "   ✓ re-signed and verified"

echo "==> 2b/6 Submitting for notarization (this can take several minutes)"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIR/notarize-submit.zip"
SUBMIT_OUT=$(xcrun notarytool submit "$DIR/notarize-submit.zip" \
    --keychain-profile "notarytool" --wait 2>&1)
echo "$SUBMIT_OUT"
# --wait exits 0 even when the result is Invalid, so check the status explicitly.
NOTARY_STATUS=$(echo "$SUBMIT_OUT" | sed -n 's/^ *status: *//p' | tail -1)
SUBMIT_ID=$(echo "$SUBMIT_OUT" | sed -n 's/^ *id: *//p' | head -1)
if [ "$NOTARY_STATUS" != "Accepted" ]; then
    echo "✗ Notarization failed (status: ${NOTARY_STATUS:-unknown}). Full log:"
    xcrun notarytool log "$SUBMIT_ID" --keychain-profile "notarytool" 2>&1 | head -40
    echo "Nothing published. Fix the issues above and re-run."
    exit 1
fi
echo "✓ Notarization accepted"

echo "==> 3/6 Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> 4/6 Verifying Gatekeeper now accepts it"
spctl -a -vvv -t exec "$APP" 2>&1 | head -3
if ! spctl -a -t exec "$APP" >/dev/null 2>&1; then
    echo "✗ Gatekeeper still rejects the app. Do NOT publish. Stopping."
    exit 1
fi
echo "✓ Notarized and accepted"

echo "==> 5/6 Re-zipping and signing the STAPLED build"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIGLINE=$("$SIGN_UPDATE" "$ZIP")
ED_SIG=$(echo "$SIGLINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(stat -f%z "$ZIP")
echo "   edSignature: $ED_SIG"
echo "   length:      $LENGTH"

echo "==> 6/7 Building, notarizing and stapling the DMG"
# 3.3 shipped without one; fresh installs want the branded installer back.
rm -f "$DMG"
bash "$PROJECT_DIR/make_dmg.sh" "$APP" "$VERSION" "$DIR" >/dev/null
[ -f "$DMG" ] || { echo "✗ DMG was not produced"; exit 1; }
DMG_OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "notarytool" --wait 2>&1)
DMG_STATUS=$(echo "$DMG_OUT" | sed -n 's/^ *status: *//p' | tail -1)
if [ "$DMG_STATUS" != "Accepted" ]; then
    echo "✗ DMG notarization failed (status: ${DMG_STATUS:-unknown})"
    echo "$DMG_OUT" | head -20
    exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "   ✓ DMG notarized and stapled ($(stat -f%z "$DMG") bytes)"

echo "==> 7/7 Writing appcast entry"
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
ITEM="        <item>
            <title>${VERSION}</title>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <ul>
                    <li>Files that aren't UTF-8 — a spreadsheet exported from Excel on Windows, say — now open properly instead of coming up blank. Saving keeps the file's original encoding and line endings.</li>
                    <li>Saving an empty document over a file that still has content now asks first.</li>
                    <li>Opening a file that isn't text is refused, rather than filling the window with garbage you could save over the original.</li>
                    <li>Printing works. ⌘P prints the document, and a CSV prints as a real table with the column headings repeated on every page.</li>
                    <li>Go to Line (⌘L) jumps to a line number, or to a row when a CSV is showing as a grid.</li>
                    <li>The grid now uses the same monospaced font as the editor, so figures line up. Columns align themselves: numbers to the right, short entries like Yes/No centred, text to the left.</li>
                    <li>Zoom (⌘+ and ⌘−) now works in grid view as well as the editor.</li>
                    <li>Undo works in the grid — cell edits, row deletions and pastes can all be taken back.</li>
                    <li>Insert Row and Duplicate Row added to the grid's right-click menu.</li>
                    <li>Replace All now works in grid view instead of quietly throwing the replacements away.</li>
                </ul>
            ]]></description>
            <pubDate>${PUBDATE}</pubDate>
            <enclosure url=\"https://github.com/${REPO}/releases/download/v${VERSION}/Notepad_${VERSION}.zip\"
                       sparkle:version=\"${BUILD}\"
                       sparkle:shortVersionString=\"${VERSION}\"
                       sparkle:edSignature=\"${ED_SIG}\"
                       length=\"${LENGTH}\"
                       type=\"application/octet-stream\" />
        </item>"

cp "$APPCAST" "$APPCAST.bak"
python3 - "$APPCAST" "$ITEM" "$BUILD" <<'PY'
import sys
path, item = sys.argv[1], sys.argv[2]
import re
xml = open(path).read()
# Always REPLACE any existing entry for this build rather than skipping. ditto is not
# byte-reproducible, so every re-run yields a new zip with a new length and signature —
# skipping left the appcast advertising a signature for a zip that no longer existed,
# which makes Sparkle reject the update on every client.
build = sys.argv[3]
pattern = re.compile(
    r"[ \t]*<item>(?:(?!</item>).)*?<sparkle:version>" + build + r"</sparkle:version>.*?</item>\n?",
    re.S)
xml, n = pattern.subn("", xml)
if n:
    print(f"   replaced {n} stale entry/entries for this build")
marker = "        <item>"
if marker in xml:
    xml = xml.replace(marker, item + "\n" + marker, 1)
else:
    xml = xml.replace("</channel>", item + "\n    </channel>", 1)
open(path, "w").write(xml)
print("   ✓ appcast entry written to match the current zip")
PY

echo
echo "Prepared:"
echo "  $ZIP  ($LENGTH bytes, notarized + stapled)"
echo "  $DMG  ($(stat -f%z "$DMG") bytes, notarized + stapled)"
echo "  $APPCAST  (backup at $APPCAST.bak)"

if [ "${1:-}" != "--publish" ]; then
    echo
    echo "Nothing published. Re-run with --publish to create the GitHub release and push."
    exit 0
fi

echo
echo "==> Publishing to GitHub"
# Read the token from the macOS Keychain via git's credential helper, so it is
# never stored in .git/config or in this script.
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential-osxkeychain get | sed -n 's/^password=//p')
[ -n "$TOKEN" ] || { echo "✗ No GitHub credential in Keychain; upload manually."; exit 1; }

BODY_JSON=$(python3 -c "
import json, sys
print(json.dumps({
    'tag_name': 'v${VERSION}',
    'name': 'Notepad ${VERSION}',
    'body': open('${DIR}/release-notes.md').read()
}))")
REL=$(curl -sS -X POST "https://api.github.com/repos/${REPO}/releases" \
    -H "Authorization: token ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$BODY_JSON")
UPLOAD_URL=$(echo "$REL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('upload_url','').split('{')[0])")
[ -n "$UPLOAD_URL" ] || { echo "✗ Release creation failed:"; echo "$REL" | head -20; exit 1; }

curl -sS -X POST "${UPLOAD_URL}?name=Notepad_${VERSION}.zip" \
    -H "Authorization: token ${TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$ZIP" >/dev/null && echo "✓ zip uploaded (Sparkle auto-update)"

curl -sS -X POST "${UPLOAD_URL}?name=Notepad_${VERSION}.dmg" \
    -H "Authorization: token ${TOKEN}" \
    -H "Content-Type: application/x-apple-diskimage" \
    --data-binary @"$DMG" >/dev/null && echo "✓ dmg uploaded (manual install)"

git -C "$PROJECT_DIR" add appcast.xml Info.plist Notepad.xcodeproj/project.pbxproj Notepad/*.swift finish_release.sh
git -C "$PROJECT_DIR" commit -F "$DIR/commit-message.txt"
git -C "$PROJECT_DIR" push origin main
echo "✓ published — clients will pick up ${VERSION} on their next update check"
