#!/bin/bash
# Builds build/iLiveWally.app (with the screen saver inside it) using only swiftc. No Xcode project.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/iLiveWally.app
SAVER="$APP/Contents/Resources/iLiveWally.saver"
SWIFTC="swiftc -O -swift-version 5 -target $(uname -m)-apple-macos14.4"
mkdir -p build

# Self-check first: compiles every shader, renders each wallpaper to build/snapshots, loads settings, exports a Live Photo.
$SWIFTC -Onone Sources/Shared/*.swift Sources/App/Export.swift Tests/main.swift -o build/tests
build/tests

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
$SWIFTC -parse-as-library Sources/Shared/*.swift Sources/App/*.swift -o "$APP/Contents/MacOS/iLiveWally"
$SWIFTC -parse-as-library -emit-library -module-name iLiveWallySaver Sources/Shared/*.swift Sources/Saver/*.swift -o "$SAVER/Contents/MacOS/iLiveWally"
# Shaders ship as source and are compiled at launch by Metal.
cp Sources/Shared/Shaders.metal "$APP/Contents/Resources/"
cp Sources/Shared/Shaders.metal "$SAVER/Contents/Resources/"
cp Info.plist "$APP/Contents/"
cp Saver-Info.plist "$SAVER/Contents/Info.plist"
# Compile the Icon Composer icon (Liquid Glass) into Assets.car + a fallback AppIcon.icns.
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist /dev/null >/dev/null
# SIGN_ID="Apple Development: …" gives a stable identity, so macOS keeps the audio permission across rebuilds; default is ad-hoc.
codesign --force --sign "${SIGN_ID:--}" "$SAVER"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP — open it with: open $APP"
