#!/bin/sh
# Builds dist/GLBOptimizer.app and dist/GLBOptimizer.dmg.
# SIGN_IDENTITY defaults to ad-hoc ("-"). Set it to a "Developer ID Application: ..." identity
# to produce a build that other Macs accept after notarization.
# APP_VERSION (e.g. 1.2.0) overrides the version shown in Finder and the About window.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
BUILD="$ROOT/macos/build-release"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [ ! -d "$ROOT/Toolchain/node_modules/@gltf-transform/core" ]; then
  (cd "$ROOT/Toolchain" && npm ci)
fi

xcodebuild \
  -project "$ROOT/macos/GLBOptimizer.xcodeproj" \
  -scheme GLBOptimizer \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD" \
  CODE_SIGNING_ALLOWED=NO \
  ${APP_VERSION:+MARKETING_VERSION="$APP_VERSION"} \
  build

rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$BUILD/Build/Products/Release/GLBOptimizer.app" "$DIST/GLBOptimizer.app"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$DIST/GLBOptimizer.app"
else
  find "$DIST/GLBOptimizer.app/Contents/Resources" \( -name '*.node' -o -name '*.dylib' \) -print0 \
    | xargs -0 -I{} codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" {}
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$DIST/GLBOptimizer.app"
fi
codesign --verify --deep --strict "$DIST/GLBOptimizer.app"

STAGE="$(mktemp -d)"
ditto "$DIST/GLBOptimizer.app" "$STAGE/GLBOptimizer.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "GLB 优化器" -srcfolder "$STAGE" -ov -format UDZO "$DIST/GLBOptimizer.dmg" >/dev/null
rm -rf "$STAGE"

echo "App: $DIST/GLBOptimizer.app"
echo "DMG: $DIST/GLBOptimizer.dmg"
