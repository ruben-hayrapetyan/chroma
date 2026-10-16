#!/bin/bash
# Builds Chroma.app from source with the Swift compiler from the Command Line
# Tools. No Xcode project, no dependencies.
#
# Universal by default, so one download runs on Apple silicon and Intel Macs
# alike. ARCHS="arm64" ./build.sh builds just one, which halves the compile.
#
# GOOGLE_CLIENT_JSON=path/to/client.json builds a Google OAuth client into
# the app, so Google Calendar works without choosing a client file. Without it
# the app reads one from Application Support. Either way it never goes in git.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Chroma"
EXECUTABLE="Chroma"
BUNDLE_ID="com.chroma.app"
VERSION="1.0.1"

BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "==> Cleaning"
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

ARCHS="${ARCHS:-arm64 x86_64}"
SLICES=()
for ARCH in $ARCHS; do
  echo "==> Compiling Swift sources ($ARCH)"
  # macOS 14 is the floor: requestFullAccessToEvents does not exist before it.
  xcrun swiftc \
    -O \
    -swift-version 5 \
    -target "$ARCH-apple-macos14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -framework EventKit \
    -framework Carbon \
    Sources/*.swift \
    -o "$BUILD_DIR/$EXECUTABLE-$ARCH"
  SLICES+=("$BUILD_DIR/$EXECUTABLE-$ARCH")
done
lipo -create "${SLICES[@]}" -output "$MACOS_DIR/$EXECUTABLE"
rm -f "${SLICES[@]}"

if [ -f tools/MakeIcon.swift ]; then
  echo "==> Rendering app icon"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  xcrun swift tools/MakeIcon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
  rm -rf "$ICONSET"
fi

GOOGLE_KEYS=""
if [ -n "${GOOGLE_CLIENT_JSON:-}" ]; then
  echo "==> Building in the Google client from $GOOGLE_CLIENT_JSON"
  CLIENT_ID=$(plutil -extract installed.client_id raw -o - "$GOOGLE_CLIENT_JSON")
  CLIENT_SECRET=$(plutil -extract installed.client_secret raw -o - "$GOOGLE_CLIENT_JSON" 2>/dev/null || true)
  GOOGLE_KEYS="    <key>ChromaGoogleClientID</key>      <string>$CLIENT_ID</string>
    <key>ChromaGoogleClientSecret</key>  <string>$CLIENT_SECRET</string>"
fi

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>        <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Chroma shows the calendars you choose and adds and edits events on the one you pick as your main calendar.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Chroma shows the calendars you choose and adds and edits events on the one you pick as your main calendar.</string>
$GOOGLE_KEYS
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

touch "$APP"
echo "==> Built $APP"
