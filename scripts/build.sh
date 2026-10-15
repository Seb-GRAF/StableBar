#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build -c release
app="${1:-dist/StableBar.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/StableBar "$app/Contents/MacOS/StableBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/config.json "$app/Contents/Resources/config.json"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app"
else
    codesign --force --sign - "$app"
fi
