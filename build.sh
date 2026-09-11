#!/bin/zsh
# Builds build/MacDuo.app with plain swiftc (no Xcode project needed).
set -e
cd "$(dirname "$0")"
APP=build/MacDuo.app
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>pl.jesion.macduo</string>
  <key>CFBundleName</key><string>MacDuo</string>
  <key>CFBundleExecutable</key><string>MacDuo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/MacDuo" \
  -framework AppKit -framework IOKit -framework ScreenCaptureKit -framework QuartzCore -framework CoreImage
# Sign with a stable identity: TCC (Screen Recording) remembers the grant per code-signing requirement.
# An ad-hoc signature's requirement is the cdhash, which changes with every build — the grant would be lost.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
  codesign -s "$IDENTITY" -f --timestamp=none "$APP" && echo "Signed: $IDENTITY"
else
  codesign -s - -f "$APP" && echo "Signed ad hoc (the Screen Recording grant will not survive a rebuild)"
fi
echo "OK: $APP"
