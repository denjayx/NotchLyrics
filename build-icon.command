#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
ICON_OUTPUT="$PWD/.build-cache/icon-resources"
mkdir -p "$ICON_OUTPUT"
xcrun actool Assets/NotchLyrics.icon \
  --compile "$ICON_OUTPUT" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon NotchLyrics \
  --output-partial-info-plist "$PWD/.build-cache/icon-info.plist" \
  --output-format human-readable-text
