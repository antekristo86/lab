#!/bin/zsh
# Public release: universal take.app, ad-hoc signed with hardened runtime, packed into dist/take.dmg.
# Ad-hoc on purpose. The Apple Development certificate would embed a personal identity in the signature.
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
trap 'hdiutil detach -force "$TMP/mnt" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

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

codesign --force --options runtime --entitlements take.entitlements --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

mkdir "$TMP/take"
ditto "$APP" "$TMP/take/take.app"
ln -s /Applications "$TMP/take/Applications"

# Volume icon: the app icon up to 128 pt only (about 20 KB), so the download size stays where it is.
iconutil -c iconset -o "$TMP/volume.iconset" Resources/take.icns
find "$TMP/volume.iconset" -name 'icon_*' ! -name 'icon_16x16*' ! -name 'icon_32x32*' ! -name 'icon_128x128.png' -delete
iconutil -c icns -o "$TMP/take/.VolumeIcon.icns" "$TMP/volume.iconset"

# hdiutil drops the custom-icon flag of a source folder, so the flag is set on a writable copy, then compressed.
hdiutil create -volname take -srcfolder "$TMP/take" -fs HFS+ -format UDRW -ov "$TMP/rw.dmg" >/dev/null
mkdir "$TMP/mnt"
hdiutil attach -nobrowse -noautoopen -readwrite -mountpoint "$TMP/mnt" "$TMP/rw.dmg" >/dev/null
if command -v SetFile >/dev/null; then SetFile -a C "$TMP/mnt"; else echo "SetFile missing, no volume icon"; fi
rm -rf "$TMP/mnt/.fseventsd"
hdiutil detach "$TMP/mnt" >/dev/null || hdiutil detach -force "$TMP/mnt" >/dev/null
hdiutil convert "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

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
  "signature": "ad-hoc, hardened runtime",
  "notarized": false
}
EOF

echo "$DMG  $DMG_MB MB  $ARCHS  sha256 $SHA"
echo "Every run changes these bytes. Publish size and hash from $DIST/release.json, and ship this exact $DMG."
