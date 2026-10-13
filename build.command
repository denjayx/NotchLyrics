#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/NotchLyrics.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/.build-cache"
./build-icon.command
# Remove the obsolete raster icon from earlier prototype builds.
rm -f "$APP/Contents/Resources/AppIcon.icns"
cp .build-cache/icon-resources/Assets.car "$APP/Contents/Resources/Assets.car"
cp .build-cache/icon-resources/NotchLyrics.icns "$APP/Contents/Resources/NotchLyrics.icns"
for arch in arm64 x86_64; do
  xcrun swiftc -O -module-cache-path "$PWD/.build-cache" \
    -target "${arch}-apple-macosx13.0" main.swift \
    -o ".build-cache/NotchLyrics-${arch}" -framework AppKit -framework SwiftUI
done
xcrun lipo -create .build-cache/NotchLyrics-arm64 .build-cache/NotchLyrics-x86_64 \
  -output "$APP/Contents/MacOS/NotchLyrics"
cp Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
if [[ -n "${NOTCHLYRICS_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$NOTCHLYRICS_SIGN_IDENTITY" --timestamp --options runtime \
    --entitlements Entitlements.plist "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Build selesai (Universal): $APP"
if [[ "${NOTCHLYRICS_NO_OPEN:-0}" != "1" ]]; then
  open "$APP"
fi
