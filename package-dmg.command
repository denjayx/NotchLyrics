#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
NOTCHLYRICS_NO_OPEN=1 ./build.command
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)
RELEASE_TAG="${NOTCHLYRICS_RELEASE_TAG:-${VERSION}-beta.${BUILD}}"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/notchlyrics-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p dist
ditto --norsrc --noextattr NotchLyrics.app "$STAGE/NotchLyrics.app"
codesign --verify --deep --strict "$STAGE/NotchLyrics.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.txt "$STAGE/READ-ME.txt"
DMG="dist/NotchLyrics-${RELEASE_TAG}-universal.dmg"
hdiutil create -volname "NotchLyrics ${RELEASE_TAG}" -srcfolder "$STAGE" \
  -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd dist && shasum -a 256 "${DMG:t}" > SHA256SUMS.txt)
echo "DMG siap: $DMG"
