#!/bin/bash
# Builds BigNums.app.
#   ./build.sh              build for this Mac and launch it (development)
#   ./build.sh --install    the same, copied to /Applications first
#   ./build.sh --package    universal (Apple silicon + Intel) release build, packaged into dist/ as a .dmg and a .zip
#                           for sharing. Launches nothing and imports no keys.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

if [[ "$MODE" == "--package" ]]; then
  ARCHS=(--arch arm64 --arch x86_64)
else
  ARCHS=()
fi

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
if [[ "$MODE" == "--package" ]]; then APP=build/package/BigNums.app; else APP=build/BigNums.app; fi  # a package never replaces the copy you run
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/BigNums" "$APP/Contents/MacOS/BigNums"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BigNums</string>
  <key>CFBundleDisplayName</key><string>BigNums</string>
  <key>CFBundleIdentifier</key><string>com.jaiamin.bignums</string>
  <key>CFBundleExecutable</key><string>BigNums</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"

if [[ "$MODE" == "--package" ]]; then
  # Nothing personal may end up in a package someone else will run.
  if [[ -f .env ]] && grep -rqF "$(grep '^PLAID_SECRET' .env | cut -d= -f2- | tr -d "\"' ")" "$APP" 2>/dev/null; then
    echo "ERROR: a Plaid secret was found inside the app. Not packaging." >&2
    exit 1
  fi
  NAME="BigNums-$VERSION"
  rm -rf dist
  mkdir -p "dist/stage"
  cp -R "$APP" dist/stage/
  ln -s /Applications dist/stage/Applications
  cp Resources/HOW-TO-OPEN.txt "dist/stage/How to open BigNums.txt"
  hdiutil create -quiet -volname "BigNums" -srcfolder dist/stage -ov -format UDZO "dist/$NAME.dmg"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME.zip"
  rm -rf dist/stage
  (cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
  echo
  echo "Packaged BigNums $VERSION:"
  ls -lh dist | tail -n +2
  lipo -info "$APP/Contents/MacOS/BigNums"
  exit 0
fi

# Keys live in the Keychain, never inside the app. For development, move the keys from .env there. This runs the app just
# built, so the Keychain item is created by, and trusted for, this exact build (no permission prompt on launch).
if [[ -f .env ]]; then
  "$APP/Contents/MacOS/BigNums" --import-env .env || echo "Note: no Plaid keys found in .env"
fi

pkill -x BigNums || true
# Wait for the old copy to actually exit, or `open` can race it and fail with error -600.
for _ in {1..40}; do pgrep -x BigNums >/dev/null || break; sleep 0.1; done
if [[ "$MODE" == "--install" ]]; then
  rm -rf /Applications/BigNums.app && cp -R "$APP" /Applications/ && APP=/Applications/BigNums.app
fi
open "$APP"
echo "Running $APP"
