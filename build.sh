#!/bin/bash
# Builds BigNums.app and launches it. Usage: ./build.sh [--install]  (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/BigNums.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/BigNums" "$APP/Contents/MacOS/BigNums"
cp .env "$APP/Contents/Resources/.env"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BigNums</string>
  <key>CFBundleIdentifier</key><string>com.jaiamin.bignums</string>
  <key>CFBundleExecutable</key><string>BigNums</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

pkill -x BigNums || true
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/BigNums.app && cp -R "$APP" /Applications/ && APP=/Applications/BigNums.app
fi
open "$APP"
echo "Running $APP"
