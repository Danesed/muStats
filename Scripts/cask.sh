#!/bin/bash
# Writes the Homebrew cask for a release into a checkout of the tap.
#
#   Scripts/cask.sh ../homebrew-tap            → Casks/mustats.rb for the version in
#                                               Info.plist and the sha256 of dist/muStats.dmg
#
# The checksum is of the exact file uploaded to the GitHub release, so run this after
# Scripts/release.sh and before anything rebuilds dist/muStats.dmg.
set -euo pipefail

cd "$(dirname "$0")/.."

TAP="${1:?usage: Scripts/cask.sh <path to the homebrew-tap checkout>}"
DMG="${DMG:-dist/muStats.dmg}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

if [ ! -f "$DMG" ]; then
  echo "error: no $DMG. Run Scripts/release.sh first." >&2
  exit 1
fi

SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
mkdir -p "$TAP/Casks"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/homebrew/mustats.rb \
  > "$TAP/Casks/mustats.rb"

echo "$TAP/Casks/mustats.rb: mustats $VERSION, sha256 $SHA"
echo "Check it with: brew audit --cask --strict --online danesed/tap/mustats"
