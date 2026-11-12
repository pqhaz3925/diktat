#!/bin/bash
# Builds Diktat.app into ./build (universal binary, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Diktat"
APP=build/Diktat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Diktat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime \
  --entitlements Resources/Diktat.entitlements "$APP"
echo "built $APP"
