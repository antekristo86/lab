#!/bin/zsh
# Dev build for this Mac, in its own architecture. Signed with the Apple Development certificate if there is one, so permissions stick between builds, ad hoc otherwise.
# Optional argument: output path for the app (default build/take.app). Public builds: ./release.sh
set -e
cd "${0:A:h}"
APP=${1:-build/take.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" Sources/*.swift -o "$APP/Contents/MacOS/take"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/* "$APP/Contents/Resources/"
ID=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
echo "$APP"
