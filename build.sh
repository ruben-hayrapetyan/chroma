#!/bin/bash
# Builds "Calendar.app" from source with the Swift compiler from the Command
# Line Tools. No Xcode project, no dependencies.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Chroma"
EXECUTABLE="Chroma"
BUNDLE_ID="com.chroma.app"
VERSION="1.0"

BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "==> Cleaning"
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> Compiling Swift sources"
# macOS 14 is the floor: requestFullAccessToEvents does not exist before it.
xcrun swiftc \
  -O \
  -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework EventKit \
  -framework Carbon \
  Sources/*.swift \
  -o "$MACOS_DIR/$EXECUTABLE"

if [ -f tools/MakeIcon.swift ]; then
  echo "==> Rendering app icon"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  xcrun swift tools/MakeIcon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
  rm -rf "$ICONSET"
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
    <string>Chroma reads and edits the events on your "Calendar" calendar.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Chroma reads and edits the events on your "Calendar" calendar.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

touch "$APP"
echo "==> Built $APP"
