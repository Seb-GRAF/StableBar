#!/bin/zsh
set -eu
cd "${0:A:h:h}"
# generate_appcast refuses a missing or malformed key, but signs nothing when the key doesn't match
# SUPublicEDKey in the app, and the app refuses an unsigned update. Ad-hoc releases get no feed.
[[ -n "${SIGNING_IDENTITY:-}" ]] || exit 0
feed=$(mktemp -d)
cp dist/StableBar.dmg "$feed/"
print -r -- $SPARKLE_ED_PRIVATE_KEY | "${STABLEBAR_PREBUILT_DIR:-.build/artifacts/sparkle/Sparkle}/bin/generate_appcast" \
    --ed-key-file - "$feed"
if ! grep -q 'sparkle:edSignature=' "$feed/appcast.xml"; then
    print -u2 "SPARKLE_ED_PRIVATE_KEY doesn't match SUPublicEDKey in the app."
    exit 1
fi
