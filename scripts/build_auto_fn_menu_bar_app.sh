#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AutoFn"
SRC_FILE="$ROOT_DIR/macos/AutoFnMenuBar/main.swift"
ICON_SVG="$ROOT_DIR/macos/AutoFnMenuBar/Resources/AppIcon.svg"
MENUBAR_ICON_PDF="$ROOT_DIR/macos/AutoFnMenuBar/Resources/MenuBarIconTemplate.pdf"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_FILE="$MACOS_DIR/$APP_NAME"
PLIST_FILE="$CONTENTS_DIR/Info.plist"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "[build] compiling $SRC_FILE"
swiftc "$SRC_FILE" \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -o "$BIN_FILE"

if [[ -f "$ICON_SVG" ]]; then
  if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "[build] warning: rsvg-convert not found; skipping app icon generation"
  elif ! command -v iconutil >/dev/null 2>&1; then
    echo "[build] warning: iconutil not found; skipping app icon generation"
  else
    ICONSET_DIR="$(mktemp -d)/icon.iconset"
    mkdir -p "$ICONSET_DIR"

    declare -a SIZES=(16 32 128 256 512)
    for size in "${SIZES[@]}"; do
      rsvg-convert -w "$size" -h "$size" "$ICON_SVG" -o "$ICONSET_DIR/icon_${size}x${size}.png"
      size2x=$((size * 2))
      rsvg-convert -w "$size2x" -h "$size2x" "$ICON_SVG" -o "$ICONSET_DIR/icon_${size}x${size}@2x.png"
    done

    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/${APP_NAME}.icns"
    rm -rf "$ICONSET_DIR"
    echo "[build] icon generated: $RESOURCES_DIR/${APP_NAME}.icns"
  fi
else
  echo "[build] warning: icon source not found at $ICON_SVG; skipping app icon generation"
fi

if [[ -f "$MENUBAR_ICON_PDF" ]]; then
  cp "$MENUBAR_ICON_PDF" "$RESOURCES_DIR/MenuBarIconTemplate.pdf"
else
  echo "[build] warning: menu bar icon source not found at $MENUBAR_ICON_PDF"
fi

cat >"$PLIST_FILE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>AutoFn</string>
  <key>CFBundleExecutable</key>
  <string>AutoFn</string>
  <key>CFBundleIdentifier</key>
  <string>com.lessismore.autofnmenubar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AutoFn</string>
  <key>CFBundleName</key>
  <string>AutoFn</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Used to monitor focused input controls and toggle Fn key state.</string>
</dict>
</plist>
PLIST

chmod +x "$BIN_FILE"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --timestamp=none "$APP_DIR"
  echo "[build] app signed (ad-hoc): $APP_DIR"
else
  echo "[build] warning: codesign not found; app is unsigned"
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
fi

echo "[build] app created: $APP_DIR"
echo "[build] run: open \"$APP_DIR\""
