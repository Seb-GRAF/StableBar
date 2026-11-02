#!/bin/zsh
set -eu
cd "${0:A:h:h}"
release=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2> /dev/null) || exit 1
paths=("${(@f)$(< .github/app-paths)}")
git diff --quiet "$release" HEAD -- $paths || exit 1
print -- $release
