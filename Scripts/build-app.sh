#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Mailr
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Mailr.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/Mailr" "$APP/Contents/MacOS/Mailr"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing lets macOS treat the app as a stable application for
# Keychain access and WebKit. It is not distribution signing.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
