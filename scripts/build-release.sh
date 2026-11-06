#!/usr/bin/env bash
# Builds PulseBar.app (Release, universal), ad-hoc signs it (no paid Apple
# account), zips it with ditto (preserves the signature) and writes a SHA-256.
# Output: build/release/PulseBar-<version>.dmg and .zip, each with a .sha256
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "(.*)"/\1/p' project.yml)
OUT=build/release
rm -rf "$OUT"
xcodegen generate --quiet
xcodebuild -project PulseBar.xcodeproj -scheme PulseBar -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$OUT/dd" \
  CODE_SIGN_IDENTITY=- build -quiet

APP="$OUT/dd/Build/Products/Release/PulseBar.app"
# Sign inside-out: the bundled helper, then the app itself.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/pulsebar-mcp"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

ZIP="PulseBar-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"

# Disk image: PulseBar.app next to an Applications shortcut, for drag-to-install.
DMG="PulseBar-$VERSION.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PulseBar.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PulseBar $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/$DMG" -quiet
codesign --force --sign - --timestamp=none "$OUT/$DMG"
rm -rf "$STAGE"

(cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256" && shasum -a 256 "$DMG" > "$DMG.sha256")
echo "Built $OUT/$DMG and $OUT/$ZIP"
cat "$OUT"/*.sha256
