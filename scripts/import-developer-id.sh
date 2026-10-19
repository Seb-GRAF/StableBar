#!/bin/zsh
set -eu
# For CI: imports the Developer ID certificate and the notarization key from the repository's
# secrets into a temporary keychain, and passes SIGNING_IDENTITY and NOTARY_PROFILE to package.sh.
if [[ -z "${DEVELOPER_ID_CERTIFICATE:-}" ]]; then
    print "No Developer ID certificate: the build is ad-hoc signed and gets no update feed."
    exit 0
fi
keychain=$RUNNER_TEMP/developer-id.keychain-db
password=$(uuidgen)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
print -rn -- "$DEVELOPER_ID_CERTIFICATE" | base64 --decode > "$RUNNER_TEMP/developer-id.p12"
security import "$RUNNER_TEMP/developer-id.p12" -k "$keychain" -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
security default-keychain -d user -s "$keychain"
identity=$(security find-identity -v -p codesigning "$keychain" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)
if [[ -z $identity ]]; then
    print -u2 "DEVELOPER_ID_CERTIFICATE holds no Developer ID Application identity."
    exit 1
fi
print -rn -- "$NOTARY_API_KEY" > "$RUNNER_TEMP/notary.p8"
xcrun notarytool store-credentials stablebar --key "$RUNNER_TEMP/notary.p8" --key-id "$NOTARY_API_KEY_ID" \
    --issuer "$NOTARY_API_ISSUER" --keychain "$keychain"
print "SIGNING_IDENTITY=$identity" >> "$GITHUB_ENV"
print "NOTARY_PROFILE=stablebar" >> "$GITHUB_ENV"
