#!/bin/bash
# Assembles the website into a folder: the page and its pictures of the app from
# site/, the icon and the picture link previews use from docs/.
#
#   Scripts/site.sh            → _site/
#   Scripts/site.sh <folder>   → that folder
#
# Open <folder>/index.html in a browser to preview it.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-_site}"

rm -rf "$OUT"
mkdir -p "$OUT/assets"
cp -R site/. "$OUT/"
cp docs/icon.png "$OUT/assets/icon.png"
cp docs/screenshots/hero.png "$OUT/assets/hero.png"
# Stops GitHub Pages from running the folder through Jekyll.
touch "$OUT/.nojekyll"

echo "$OUT/index.html"
