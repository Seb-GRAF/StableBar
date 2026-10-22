#!/bin/zsh
set -eu
cd "${0:A:h:h}"
staging=$(mktemp -d "${TMPDIR:-/tmp}/stablebar-installer.XXXXXX")
trap 'rm -rf "$staging"' EXIT
./scripts/build.sh "$staging/StableBar.app"
mkdir -p dist
rm -f dist/StableBar.dmg
create-dmg \
    --volname StableBar \
    --volicon Resources/AppIcon.icns \
    --background Resources/InstallerBackground.png \
    --window-size 680 468 \
    --icon-size 128 \
    --text-size 14 \
    --icon StableBar.app 185 240 \
    --hide-extension StableBar.app \
    --app-drop-link 495 240 \
    dist/StableBar.dmg "$staging"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" dist/StableBar.dmg
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit dist/StableBar.dmg --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple dist/StableBar.dmg
    xcrun stapler validate dist/StableBar.dmg
fi
