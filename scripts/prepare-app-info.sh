#!/bin/zsh
set -eu
cd "${0:A:h:h}"
(( $# == 1 )) || { print -u2 'usage: scripts/prepare-app-info.sh <destination Info.plist>'; exit 1 }
plist=$1
cp Resources/Info.plist "$plist"
# Release jobs stamp the source plist before packaging. Local builds need their own identity:
# even a beta tag's source plist still contains the last stable version.
if [[ "${STABLEBAR_RELEASE_BUILD:-0}" == 1 ]]; then
    exit 0
fi
version=0.0.0-dev
if revision=$(git describe --tags --match 'v[0-9]*' --long --always 2>/dev/null); then
    if [[ $revision == v* ]]; then
        version=${revision#v}
    else
        version="0.0.0-dev.$revision"
    fi
    if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
        version+="-dirty"
    fi
fi
# Keep the release version for package minimumVersion comparisons; About uses the source identity.
/usr/libexec/PlistBuddy -c 'Add :StableBarDevelopmentBuild bool true' \
    -c "Add :StableBarSourceRevision string $version" "$plist"
