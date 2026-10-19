#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build -c release --disable-keychain
app="${1:-dist/StableBar.app}"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp .build/release/StableBar "$app/Contents/MacOS/StableBar"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/StableBar"
rm -rf "$sparkle"
cp -R .build/release/Sparkle.framework "$sparkle"
./scripts/prepare-app-info.sh "$app/Contents/Info.plist"
cp Resources/config.json "$app/Contents/Resources/config.json"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
rm -rf "$app/Contents/Resources/themes"
cp -R Resources/themes "$app/Contents/Resources/themes"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    # Sparkle ships ad-hoc signed. Sign its helpers, then the framework, as its documentation shows.
    sign=(codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
    $sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
    $sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    $sign "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"
    $sign "$app"
else
    codesign --force --sign - "$app"
fi
