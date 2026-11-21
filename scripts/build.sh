#!/bin/zsh
set -eu
cd "${0:A:h:h}"
if [[ -z "${STABLEBAR_PREBUILT_DIR:-}" ]]; then
    swift build -c release --disable-keychain
fi
build="${STABLEBAR_PREBUILT_DIR:-.build/release}"
app="${1:-dist/StableBar.app}"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$build/StableBar" "$app/Contents/MacOS/StableBar"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/StableBar"
rm -rf "$sparkle"
cp -R "$build/Sparkle.framework" "$sparkle"
# The now-playing library, which perl loads; a build of an earlier commit has none.
adapter="$app/Contents/Frameworks/libStableBarNowPlaying.dylib"
if [[ -f "$build/libStableBarNowPlaying.dylib" ]]; then cp "$build/libStableBarNowPlaying.dylib" "$adapter"; fi
cp Resources/now-playing.pl "$app/Contents/Resources/now-playing.pl"
./scripts/prepare-app-info.sh "$app/Contents/Info.plist"
cp Resources/config.json "$app/Contents/Resources/config.json"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/StatusBarIconTemplate*.png "$app/Contents/Resources/"
cp Resources/SetupDay.heic Resources/SetupDusk.heic "$app/Contents/Resources/"
cp Resources/shantell-sans-display.woff2 Resources/shantell-sans-hand.woff2 Resources/shantell-sans-OFL.txt "$app/Contents/Resources/"
rm -rf "$app/Contents/Resources/themes" "$app/Contents/Resources/store-themes"
cp -R Resources/themes "$app/Contents/Resources/themes"
cp -R Resources/store-themes "$app/Contents/Resources/store-themes"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    # Sparkle ships ad-hoc signed. Sign its helpers, then the framework, as its documentation shows.
    sign=(codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
    $sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
    $sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    $sign "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"
    if [[ -f "$adapter" ]]; then $sign "$adapter"; fi
    $sign --entitlements Resources/StableBar.entitlements "$app"
else
    if [[ -f "$adapter" ]]; then codesign --force --sign - "$adapter"; fi
    codesign --force --sign - "$app"
fi
