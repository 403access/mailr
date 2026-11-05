#!/usr/bin/env bash
# Regenerates the app icon for both macOS and iOS.
set -euo pipefail

cd "$(dirname "$0")/.."

MASTERS="Support/Icon"
ASSET_DIR="Sources/Mailr/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$MASTERS" "$ASSET_DIR" "$ICONSET"

swift Scripts/render-icon.swift "$MASTERS"

# iOS: a single 1024pt asset, masked by the system.
cp "$MASTERS/icon-ios-1024.png" "$ASSET_DIR/AppIcon-1024.png"

# macOS: every size the .icns format expects.
sips -z 16 16     "$MASTERS/icon-macos-1024.png" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$MASTERS/icon-macos-1024.png" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$MASTERS/icon-macos-1024.png" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$MASTERS/icon-macos-1024.png" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$MASTERS/icon-macos-1024.png" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$MASTERS/icon-macos-1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$MASTERS/icon-macos-1024.png" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$MASTERS/icon-macos-1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$MASTERS/icon-macos-1024.png" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$MASTERS/icon-macos-1024.png"                 "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$MASTERS/AppIcon.icns"

# Keep the generated masters out of the way of the proofs.
rm -f "$MASTERS"/preview-*.png

echo "Updated $MASTERS/AppIcon.icns and $ASSET_DIR/AppIcon-1024.png"
