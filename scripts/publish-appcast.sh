#!/bin/zsh
set -eu
cd "${0:A:h:h}"
usage='usage: scripts/publish-appcast.sh <version> [channel]'
(( $# >= 1 )) || { print -u2 -- $usage; exit 1 }
version=$1
feed=$(mktemp -d)
# Like the store's index, the appcast is an asset of a release with a fixed tag, so the app reads one
# URL for both channels. It is a prerelease so that GitHub never shows it as the latest release.
if gh release view appcast --repo "$GITHUB_REPOSITORY" > /dev/null 2>&1; then
    gh release download appcast --repo "$GITHUB_REPOSITORY" --pattern appcast.xml --dir "$feed"
else
    gh release create appcast --repo "$GITHUB_REPOSITORY" --prerelease --target "$GITHUB_SHA" \
        --title Appcast --notes "The update feed StableBar checks for new versions. Published by CI."
fi
cp dist/StableBar.dmg "$feed/"
gh release view "v$version" --repo "$GITHUB_REPOSITORY" --json body --jq .body > "$feed/StableBar.md"
# generate_appcast reads the versions and requirements of the app in the DMG, adds it on the given
# channel with the release's notes, and keeps the newest items of the other channel.
"${STABLEBAR_PREBUILT_DIR:-.build/artifacts/sparkle/Sparkle}/bin/generate_appcast" ${2:+--channel=$2} --embed-release-notes \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/v$version/" \
    --full-release-notes-url "https://github.com/$GITHUB_REPOSITORY/releases/tag/v$version" "$feed"
gh release upload appcast "$feed/appcast.xml" --repo "$GITHUB_REPOSITORY" --clobber
