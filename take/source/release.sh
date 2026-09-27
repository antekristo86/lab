#!/bin/zsh
# Public release: universal take.app, ad-hoc signed with hardened runtime, packed into dist/take.dmg.
# Signed with a "Developer ID Application" certificate and notarized when both exist on this Mac:
#   the certificate in the keychain, and notary credentials stored as the keychain profile "take-notary"
#   (xcrun notarytool store-credentials take-notary --apple-id ... --team-id ...). Otherwise ad-hoc, like before:
#   then macOS blocks the first launch until Open Anyway in System Settings > Privacy & Security.
set -euo pipefail
cd "${0:A:h}"

plist() { /usr/libexec/PlistBuddy -c "Print $1" Info.plist }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
MINOS=$(plist LSMinimumSystemVersion)

DIST=dist
APP=$DIST/take.app
DMG=$DIST/take.dmg
TMP=$(mktemp -d)
trap '[[ -n "${MNT:-}" && -e "$MNT" ]] && hdiutil detach -force "$MNT" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

rm -rf "$APP" "$DMG" "$DIST/release.json"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  echo "compile $ARCH"
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos$MINOS" Sources/*.swift -o "$TMP/take-$ARCH"
done
lipo -create "$TMP/take-arm64" "$TMP/take-x86_64" -output "$APP/Contents/MacOS/take"
strip -x "$APP/Contents/MacOS/take"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/* "$APP/Contents/Resources/"
chmod -R u+rwX,go+rX,go-w "$APP"
xattr -cr "$APP"

DEVID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [[ -n "$DEVID" ]]; then
  echo "sign with $DEVID"
  codesign --force --options runtime --timestamp --entitlements take.entitlements --sign "$DEVID" "$APP"
  SIGNATURE="Developer ID, hardened runtime"
else
  echo "no Developer ID Application certificate: ad-hoc"
  codesign --force --options runtime --entitlements take.entitlements --sign - "$APP"
  SIGNATURE="ad-hoc, hardened runtime"
fi
codesign --verify --strict --verbose=2 "$APP"

mkdir "$TMP/take"
ditto "$APP" "$TMP/take/take.app"
ln -s /Applications "$TMP/take/Applications"

# Volume icon: the app icon up to 128 pt only (about 20 KB), so the download size stays where it is.
iconutil -c iconset -o "$TMP/volume.iconset" Resources/take.icns
find "$TMP/volume.iconset" -name 'icon_*' ! -name 'icon_16x16*' ! -name 'icon_32x32*' ! -name 'icon_128x128.png' -delete
iconutil -c icns -o "$TMP/take/.VolumeIcon.icns" "$TMP/volume.iconset"

# hdiutil drops the custom-icon flag of a source folder, so the flag is set on a writable copy, then compressed.
# The window: Icon/dmg/background.tiff (600 x 400, 1x and 2x, rendered from Icon/dmg/background.html),
# the app on the left, Applications on the right, a dotted arrow between them.
mkdir "$TMP/take/.background"
cp Icon/dmg/background.tiff "$TMP/take/.background/background.tiff"

hdiutil create -volname take -srcfolder "$TMP/take" -fs HFS+ -format UDRW -ov "$TMP/rw.dmg" >/dev/null
# Mounted under /Volumes where Finder sees it, so Finder can write the window layout into the volume's .DS_Store
[[ -e /Volumes/take ]] && { echo "/Volumes/take is already mounted, eject it first"; exit 1; }
hdiutil attach -noautoopen -readwrite "$TMP/rw.dmg" >/dev/null
MNT=/Volumes/take
osascript <<OSA
tell application "Finder"
  tell disk "take"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "take.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
if command -v SetFile >/dev/null; then SetFile -a C "$MNT"; else echo "SetFile missing, no volume icon"; fi
rm -rf "$MNT/.fseventsd"
hdiutil detach "$MNT" >/dev/null || hdiutil detach -force "$MNT" >/dev/null
hdiutil convert "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

NOTARIZED=false
if [[ -n "$DEVID" ]]; then
  codesign --force --timestamp --sign "$DEVID" "$DMG"
  if xcrun notarytool history --keychain-profile take-notary >/dev/null 2>&1; then
    echo "notarize (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile take-notary --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG"
    NOTARIZED=true
  else
    echo "no notary profile take-notary: signed, not notarized"
  fi
fi

ARCHS=$(lipo -archs "$APP/Contents/MacOS/take")
DMG_BYTES=$(stat -f%z "$DMG")
DMG_MB=$(awk -v b="$DMG_BYTES" 'BEGIN { printf "%.1f", b / 1000000 }')
SHA=$(shasum -a 256 "$DMG" | awk '{ print $1 }')
APP_BYTES=$(find "$APP" -type f -exec stat -f%z {} + | awk '{ s += $1 } END { print s }')
JSON_ARCHS=$(print -r -- "$ARCHS" | awk '{ for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i > 1 ? ", " : ""), $i }')

cat > "$DIST/release.json" <<EOF
{
  "name": "take",
  "bundleIdentifier": "$(plist CFBundleIdentifier)",
  "version": "$VERSION",
  "build": "$BUILD",
  "minimumSystemVersion": "$MINOS",
  "architectures": [$JSON_ARCHS],
  "file": "take.dmg",
  "dmgBytes": $DMG_BYTES,
  "dmgMegabytes": $DMG_MB,
  "sha256": "$SHA",
  "appBytes": $APP_BYTES,
  "signature": "$SIGNATURE",
  "notarized": $NOTARIZED
}
EOF

echo "$DMG  $DMG_MB MB  $ARCHS  sha256 $SHA"
echo "Every run changes these bytes. Publish size and hash from $DIST/release.json, and ship this exact $DMG."
