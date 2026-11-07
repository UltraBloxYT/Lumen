#!/bin/bash
# Builds Lumen.app (universal: Apple Silicon + Intel).
# Usage: ./build.sh        -> ./build/Lumen.app      (or set OUT=/some/dir)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/build}"
NAME="Lumen"; BID="com.lumen.overlay"; APP="$OUT/$NAME.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Install the Xcode Command Line Tools first:  xcode-select --install"; exit 1
fi

rm -rf "$OUT/obj"; mkdir -p "$OUT/obj"

echo "[1/4] Icon"
swiftc -O "$HERE/Tools/make-icon.swift" -o "$OUT/obj/make-icon"
"$OUT/obj/make-icon" "$OUT/obj/$NAME.iconset"
iconutil -c icns "$OUT/obj/$NAME.iconset" -o "$OUT/obj/$NAME.icns"

echo "[2/4] Compiling arm64 and x86_64"
for A in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$A-apple-macos13.0" "$HERE/Sources/main.swift" -o "$OUT/obj/$NAME-$A"
done
lipo -create "$OUT/obj/$NAME-arm64" "$OUT/obj/$NAME-x86_64" -output "$OUT/obj/$NAME"

echo "[3/4] Bundling"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/obj/$NAME" "$APP/Contents/MacOS/$NAME"
cp "$OUT/obj/$NAME.icns" "$APP/Contents/Resources/$NAME.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Lumen records your microphone only when you turn it on.</string>
</dict>
</plist>
PLIST

echo "[4/4] Signing"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
