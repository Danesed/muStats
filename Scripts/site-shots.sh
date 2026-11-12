#!/bin/bash
# Renders the website's pictures of the app, in light and in dark, into site/shots/.
#
#   Scripts/site-shots.sh
#
# Every picture comes from `muStats --render`, which draws the real views on fixture
# data without a screen, so the site shows the app as it is and both themes match.
# Run it after a change to the look of the panel or the menu bar.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build >/dev/null
BIN="$(swift build --show-bin-path)/muStats"
OUT="site/shots"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# render <name> <surface> [render flags…], with any MUSTATS_* set by the caller.
render() {
  local name="$1" surface="$2"; shift 2
  for theme in light dark; do
    rm -rf "$TMP/one"
    "$BIN" --render "$surface" --scale 2 "--$theme" --out "$TMP/one" "$@" >/dev/null
    mkdir -p "$OUT/$theme"
    mv "$TMP/one"/*.png "$OUT/$theme/$name.png"
  done
}

rm -rf "$OUT"

export MUSTATS_RENDER_CHIP=1
render panel-now    panel --scenario nominal
render panel-cpu    panel --scenario nominal --open cpu
render panel-alert  panel --scenario underLoad --open memory
render panel-apps   panel --scenario underLoad --open processes
MUSTATS_RENDER_RECAP=360 render panel-recap panel --scenario nominal
MUSTATS_RENDER_TAB=today render panel-today panel --scenario nominal
MUSTATS_RENDER_TAB=chip  render panel-chip  panel --scenario nominal
MUSTATS_RENDER_TAB=chip  render panel-chip-load panel --scenario underLoad
unset MUSTATS_RENDER_CHIP

render menubar-base   menuBar --scenario nominal
MUSTATS_RINGS=1 render menubar-rings menuBar --scenario nominal \
  --menubar cpuTemperature,networkThroughput
render menubar-graphs menuBar --scenario nominal \
  --menubar cpuUsage:graph,memoryPressure:miniGraph,gpuUsage:textAndGraph,diskActivity:stackedPair,networkThroughput:statusDot
render menubar-icons  menuBar --scenario nominal \
  --menubar cpuTemperature:iconAndText,fanSpeed:iconAndText,diskFree:iconAndText,uptime:iconAndText,batteryTime,battery:battery

du -sh "$OUT" | cut -f1
