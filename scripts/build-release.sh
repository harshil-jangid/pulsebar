#!/usr/bin/env bash
# Builds PulseBar.app (Release, universal), ad-hoc signs it (no paid Apple
# account), zips it with ditto (preserves the signature) and writes a SHA-256.
# Output: build/release/PulseBar-<version>.zip and .zip.sha256
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
(cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
echo "Built $OUT/$ZIP"
cat "$OUT/$ZIP.sha256"
