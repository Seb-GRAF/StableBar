#!/bin/zsh
# Draws the images in docs/images from the app's own views and writes them as WebP. Needs cwebp: brew install webp.
set -eu
cd "${0:A:h:h}"
staging=$(mktemp -d "${TMPDIR:-/tmp}/stablebar-docs.XXXXXX")
trap 'rm -rf "$staging"' EXIT
./scripts/build.sh "$staging/StableBar.app"
"$staging/StableBar.app/Contents/MacOS/StableBar" --render-docs-images "$staging/images"
mkdir -p docs/images
for image in "$staging"/images/*.png; do
    cwebp -quiet -q 90 -alpha_q 100 "$image" -o "docs/images/${image:t:r}.webp"
done
