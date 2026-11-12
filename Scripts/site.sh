#!/bin/bash
# Assembles the website into a folder: the page from site/, the icon and the
# screenshots from docs/.
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
cp -R docs/screenshots "$OUT/assets/screenshots"
# Stops GitHub Pages from running the folder through Jekyll.
touch "$OUT/.nojekyll"

echo "$OUT/index.html"
