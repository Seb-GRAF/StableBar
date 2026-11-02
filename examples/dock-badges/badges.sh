#!/bin/bash
set -euo pipefail

while IFS= read -r app; do
  info=$(lsappinfo info -only StatusLabel -only bundleID -only bundlepath "$app")
  bundle=$(printf '%s\n' "$info" | sed -n 's/^"CFBundleIdentifier"="\([^"]*\)"$/\1/p')
  [[ -n $bundle ]] || continue
  path=$(printf '%s\n' "$info" | sed -n 's/^"LSBundlePath"="\([^"]*\)"$/\1/p')
  badge=$(printf '%s\n' "$info" | sed -n 's/.*"label"="\([^"]*\)".*/\1/p')
  jq -cn --arg app "$app" --arg bundle "$bundle" --arg path "$path" --arg badge "$badge" \
    '{app: $app, bundle: $bundle, path: $path, badge: (if $badge == "" then "0" else $badge end)}'
done < <(printf '%s' "$APPS" | jq -Rrs 'split(",")[] | gsub("^ +| +$"; "") | select(length > 0)') |
  jq -s '{text: "", lists: {apps: .}}'
