#!/bin/zsh
# Builds a signed (and, if credentials are available, notarized) DMG and publishes it as a GitHub Release.
#
#   ./release.sh 0.1.0                       # sign + DMG + GitHub release (marked pre-release if not notarized)
#   NOTARY_PROFILE=macduo ./release.sh 0.1.0 # also notarize with `xcrun notarytool` and staple
#
# One-time setup for notarization (Apple ID with an app-specific password, Team ID from the certificate):
#   xcrun notarytool store-credentials macduo --apple-id you@example.com --team-id 4NZF9USX28
set -e
cd "$(dirname "$0")"
VERSION=${1:?usage: release.sh <version>}
APP=build/MacDuo.app
DMG=build/MacDuo-$VERSION.dmg
IDENTITY=$(security find-identity -v -p codesigning | grep -oE '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in the keychain"; exit 1; }

./build.sh >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Hardened runtime is required for notarization. The app needs no special entitlements: Screen Recording is
# a TCC permission, and the lid angle sensor is a plain HID feature report.
codesign -s "$IDENTITY" -f --options runtime --timestamp "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed: $IDENTITY"

rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "MacDuo $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign -s "$IDENTITY" --timestamp "$DMG"
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"

NOTARIZED=0
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  NOTARIZED=1
  echo "Notarized and stapled."
else
  echo "NOTARY_PROFILE not set — skipping notarization (Gatekeeper will warn on first open)."
fi

NOTES="Signed build of MacDuo $VERSION for Apple Silicon MacBooks (macOS 14+)."
if [ $NOTARIZED = 1 ]; then
  NOTES="$NOTES Notarized by Apple: open the DMG and drag MacDuo to Applications."
  PRE=""
else
  NOTES="$NOTES

**Not notarized yet.** macOS will refuse to open it on the first try: go to System Settings → Privacy & Security, scroll down and click **Open Anyway**, or run \`xattr -d com.apple.quarantine /Applications/MacDuo.app\`."
  PRE="--prerelease"
fi
if gh release view "v$VERSION" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DMG" --clobber
else
  gh release create "v$VERSION" "$DMG" --title "MacDuo $VERSION" --notes "$NOTES" $PRE
fi
echo "Released: $(gh release view "v$VERSION" --json url --jq .url)"
