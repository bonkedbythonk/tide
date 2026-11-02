#!/bin/zsh
# Packages Tide.app as dist/Tide-<version>.zip (ad-hoc signed, not notarized)
# and publishes it as a GitHub release tagged v<version>, with notes from
# dist/notes.md. Bump version.txt first.
set -e
cd "${0:A:h}/.."
version=$(cat version.txt)
./run.sh --package
rm -rf dist && mkdir dist
cp -R Tide.app dist/
codesign --force --deep -s - dist/Tide.app
ditto -c -k --keepParent dist/Tide.app dist/Tide-$version.zip
[[ $1 == --dry-run ]] && { echo "dist/Tide-$version.zip"; exit 0; }
gh release create v$version dist/Tide-$version.zip --title "Tide $version" --notes-file dist/notes.md
