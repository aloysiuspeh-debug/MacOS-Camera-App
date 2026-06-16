#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Camera"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
STAGE_DIR="$ROOT_DIR/.build/installer-root"
COMPONENT_PKG="$ROOT_DIR/.build/$APP_NAME-component.pkg"
EXPANDED_DIR="$ROOT_DIR/.build/installer-expanded"

cd "$ROOT_DIR"

export COPYFILE_DISABLE=1

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - resources/Info.plist)"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - resources/Info.plist)"
PKG_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION-Installer.pkg"

"$ROOT_DIR/scripts/build-app.sh"

rm -rf "$STAGE_DIR" "$COMPONENT_PKG" "$EXPANDED_DIR" "$PKG_PATH"
mkdir -p "$STAGE_DIR/Applications"

ditto --norsrc --noextattr "$APP_DIR" "$STAGE_DIR/Applications/$APP_NAME.app"
xattr -cr "$STAGE_DIR"

pkgbuild \
    --root "$STAGE_DIR" \
    --identifier "$BUNDLE_ID.installer" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT_PKG"

productbuild \
    --package "$COMPONENT_PKG" \
    "$PKG_PATH"

pkgutil --expand-full "$PKG_PATH" "$EXPANDED_DIR"
test -x "$EXPANDED_DIR/$APP_NAME-component.pkg/Payload/Applications/$APP_NAME.app/Contents/MacOS/CameraApp"

echo "Built $PKG_PATH"
echo "Install it with: open \"$PKG_PATH\""
