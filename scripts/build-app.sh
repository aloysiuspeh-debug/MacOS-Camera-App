#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Camera"
BINARY_NAME="CameraApp"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_NAME="AppIcon.icns"
ICON_SOURCE="$ROOT_DIR/resources/$ICON_NAME"
ICON_GENERATOR="$ROOT_DIR/scripts/generate-app-icon.py"

cd "$ROOT_DIR"

swift build -c release

if [[ ! -f "$ICON_SOURCE" || "$ICON_GENERATOR" -nt "$ICON_SOURCE" ]]; then
    python3 "$ICON_GENERATOR" "$ICON_SOURCE"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/$BINARY_NAME" "$MACOS_DIR/$BINARY_NAME"
cp "resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ICON_SOURCE" "$RESOURCES_DIR/$ICON_NAME"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
plutil -lint "resources/Camera.entitlements" >/dev/null

codesign --force --sign - --entitlements "resources/Camera.entitlements" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built $APP_DIR"
echo "Run it with: open \"$APP_DIR\""
