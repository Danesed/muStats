#!/usr/bin/env python3
"""Draws the app icon: a serif μ and the status dot, on a chip drawn as a load map.

    python3 Scripts/icon.py

Writes the layers of Resources/AppIcon.icon (the Icon Composer file macOS 26 builds
its icon from), Resources/AppIcon.icns for macOS 14 and 15, and docs/icon.png.

The μ is the micro sign of TeX Gyre Pagella Bold, an open Palatino (GUST Font
License), bold so its thin strokes survive at sixteen pixels,
taken as an outline so nothing depends on a font being installed where the icon is
shown. The dot is the one the panel's status line starts with: green, all is well.

Behind them is the floorplan of an Apple silicon package, pressed into the paper and
turned a few degrees, so the icon crops it the way a photograph crops a die: the
performance cores with their cache bands, the efficiency cores, the GPU's grid, the
memory banks. It is not decoration only. Every cell is shaded by a load, darker is
busier, and the memory banks are filled from the bottom, so the background is what
the app shows: the chip, read as statistics.

Needs fontTools and cairosvg (pip install fonttools cairosvg), the font from a TeX
installation or FONT=/path/to/texgyrepagella-bold.otf, and macOS's iconutil.
"""
import glob
import json
import os
import subprocess
import tempfile
from pathlib import Path

import cairosvg
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "Resources" / "AppIcon.icon"
SIZE = 1024

PAPER_TOP, PAPER_BOTTOM = "#FCF9F1", "#F1DFC2"
INK, CALM = "#191919", "#2F9E44"

font_path = os.environ.get("FONT") or next(iter(
    glob.glob("/usr/local/texlive/*/texmf-dist/fonts/opentype/public/tex-gyre/texgyrepagella-bold.otf")), None)
if not font_path:
    raise SystemExit("texgyrepagella-bold.otf not found: set FONT=/path/to/it")
font = TTFont(font_path)
glyphs = font.getGlyphSet()
name = font.getBestCmap()[0x00B5]

bounds = BoundsPen(glyphs)
glyphs[name].draw(bounds)
x0, y0, x1, y1 = bounds.bounds

# The μ and its dot are set as one mark and centred as one. The glyph stands 520
# units tall of the 1024, which leaves the corner radius of the icon clear of it.
scale = 520 / (y1 - y0)
width, height = (x1 - x0) * scale, (y1 - y0) * scale
dot_r, gap = 47, 30
left = (SIZE - (width + gap + 2 * dot_r)) / 2
# Optically centred: the descender is one stroke, the bowl is the mass.
top = (SIZE - height) / 2 + 26
baseline = top + y1 * scale

pen = SVGPathPen(glyphs)
glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, left - x0 * scale, baseline)))
mu = f'<path fill="{INK}" d="{pen.getCommands()}"/>'

# "Stats", small, set beside the stem of the μ: the mark reads "μ" first and the
# name second. Same family, as outlines, with the font's own spacing and kerning.
WORD, WORD_SIZE = "Stats", 132


def word_path(text: str, size: float, x: float, baseline_y: float):
    cmap, k = font.getBestCmap(), size / font["head"].unitsPerEm
    names = [cmap[ord(ch)] for ch in text]
    kerning = {}
    if "GPOS" in font:
        for lookup in font["GPOS"].table.LookupList.Lookup:
            for sub in lookup.SubTable:
                if getattr(sub, "LookupType", None) == 9:
                    sub = sub.ExtSubTable
                if sub.__class__.__name__ != "PairPos":
                    continue
                if sub.Format == 1:
                    for first, pairs in zip(sub.Coverage.glyphs, sub.PairSet):
                        for pair in pairs.PairValueRecord:
                            if pair.Value1 and pair.Value1.XAdvance:
                                kerning.setdefault((first, pair.SecondGlyph), pair.Value1.XAdvance)
                elif sub.Format == 2:
                    covered = set(sub.Coverage.glyphs)
                    for first in set(names) & covered:
                        c1 = sub.ClassDef1.classDefs.get(first, 0)
                        for second in set(names):
                            c2 = sub.ClassDef2.classDefs.get(second, 0)
                            value = sub.Class1Record[c1].Class2Record[c2].Value1
                            if value and value.XAdvance:
                                kerning.setdefault((first, second), value.XAdvance)
    out = SVGPathPen(glyphs)
    cursor = 0.0
    for index, glyph in enumerate(names):
        if index:
            cursor += kerning.get((names[index - 1], glyph), 0)
        glyphs[glyph].draw(TransformPen(out, (k, 0, 0, -k, x + cursor * k, baseline_y)))
        cursor += glyphs[glyph].width
    return out.getCommands(), cursor * k


# The word sits in the corner the μ leaves open: right of the stem, under the bowl,
# on the line where the stem ends.
stem_right = left + 0.30 * width
word_d, word_width = word_path(WORD, WORD_SIZE, stem_right + 16, top + height - 6)
word = f'<path fill="{INK}" d="{word_d}"/>'
dot = f'<circle cx="{left + width + gap + dot_r:.1f}" cy="{baseline - dot_r:.1f}" r="{dot_r}" fill="{CALM}"/>'


def svg(body: str, defs: str = "") -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" '
            f'width="{SIZE}" height="{SIZE}">{defs}{body}</svg>')


def srgb(color: str) -> str:
    r, g, b = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"extended-srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


# --- the floorplan -----------------------------------------------------------
#
# Drawn on a die larger than the icon and turned, so the icon is a crop of it.
# Two inks from the website's palette: a warm brown for the processor, a slate for
# the GPU and the memory. A cell's fill is its load; nothing here is random at run
# time, the loads are written out so the icon is the same every time it is built.
BROWN, SLATE, LIGHT = "#5D524B", "#738B9C", "#FFFFFF"
DIE, TURN = 1320, -9

P_LOADS = [0.82, 0.34, 0.12, 0.56, 0.95, 0.22]
E_LOADS = [0.18, 0.44, 0.08, 0.30, 0.12, 0.62]
GPU_LOADS = [0.20, 0.55, 0.35, 0.10, 0.70, 0.25,
             0.45, 0.15, 0.80, 0.30, 0.20, 0.50,
             0.10, 0.65, 0.25, 0.40, 0.90, 0.15,
             0.35, 0.20, 0.50, 0.10, 0.30, 0.60]
MEMORY_USED = [0.74, 0.38]          # two banks, filled from the bottom


def tone(load: float, low: float = 0.05, high: float = 0.34) -> float:
    return round(low + (high - low) * load, 3)


def pressed(x: float, y: float, w: float, h: float, ink: str, load: float, r: float = 9) -> str:
    """A cell pressed into the paper: its tint, a dark edge, and the light the top edge catches."""
    return (f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{r}" fill="{ink}" fill-opacity="{tone(load)}"/>'
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{r}" fill="none" stroke="{ink}" stroke-opacity="0.34" stroke-width="2.2"/>'
            f'<path d="M{x + r:.1f},{y + 3.2:.1f} H{x + w - r:.1f}" stroke="{LIGHT}" stroke-opacity="0.75" stroke-width="2.2" stroke-linecap="round"/>')


def core(x: float, y: float, w: float, h: float, load: float) -> str:
    """A CPU core as a die shot shows it: the cache band on top, two halves of logic under it."""
    band = h * 0.26
    out = [pressed(x, y, w, h, BROWN, load, 11)]
    stripes = "".join(f"M{sx:.1f},{y + 7:.1f} V{y + band - 4:.1f}" for sx in frange(x + 9, x + w - 6, 7))
    out.append(f'<path d="{stripes}" stroke="{BROWN}" stroke-opacity="0.30" stroke-width="1.6"/>')
    out.append(f'<path d="M{x + 4:.1f},{y + band:.1f} H{x + w - 4:.1f}" stroke="{BROWN}" stroke-opacity="0.30" stroke-width="1.6"/>')
    half = (w - 30) / 2
    for column in range(2):
        px, py, ph = x + 10 + column * (half + 10), y + band + 10, h - band - 20
        out.append(f'<rect x="{px:.1f}" y="{py:.1f}" width="{half:.1f}" height="{ph:.1f}" rx="5" fill="none" '
                   f'stroke="{BROWN}" stroke-opacity="0.24" stroke-width="1.6"/>')
        rules = "".join(f"M{px + 6:.1f},{ry:.1f} H{px + half - 6:.1f}" for ry in frange(py + 9, py + ph - 5, 9))
        out.append(f'<path d="{rules}" stroke="{BROWN}" stroke-opacity="0.15" stroke-width="1.4"/>')
    return "".join(out)


def frange(start: float, stop: float, step: float):
    value = start
    while value < stop:
        yield value
        value += step


def block(x: float, y: float, w: float, h: float, ink: str) -> str:
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="{LIGHT}" fill-opacity="0.30"/>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="none" stroke="{ink}" stroke-opacity="0.26" stroke-width="2"/>')


def grid(x, y, w, h, columns, rows, gap):
    cw, ch = (w - gap * (columns - 1)) / columns, (h - gap * (rows - 1)) / rows
    return [(x + c * (cw + gap), y + r * (ch + gap), cw, ch) for r in range(rows) for c in range(columns)]


def ruled(x, y, w, h, ink, step=8, vertical=False) -> str:
    """Unnamed logic: a block of fine rules, the sea of cells between the named parts."""
    if vertical:
        lines = "".join(f"M{v:.1f},{y + 8} V{y + h - 8}" for v in frange(x + 10, x + w - 6, step))
    else:
        lines = "".join(f"M{x + 8},{v:.1f} H{x + w - 8}" for v in frange(y + 10, y + h - 6, step))
    return block(x, y, w, h, ink) + f'<path d="{lines}" stroke="{ink}" stroke-opacity="0.20" stroke-width="1.5"/>'


def floorplan() -> str:
    out = []
    # The die's edge and its ring of bond pads.
    out.append(f'<rect x="0" y="0" width="{DIE}" height="{DIE}" rx="30" fill="none" stroke="{BROWN}" stroke-opacity="0.30" stroke-width="2.5"/>')
    pads = "".join(f'<rect x="{v:.0f}" y="12" width="12" height="5" rx="1.5"/><rect x="{v:.0f}" y="{DIE - 17}" width="12" height="5" rx="1.5"/>'
                   f'<rect x="12" y="{v:.0f}" width="5" height="12" rx="1.5"/><rect x="{DIE - 17}" y="{v:.0f}" width="5" height="12" rx="1.5"/>'
                   for v in frange(44, DIE - 50, 22))
    out.append(f'<g fill="{BROWN}" fill-opacity="0.26">{pads}</g>')

    # Performance cores: three across, two down, the large cells of the die.
    out.append(block(40, 40, 600, 500, BROWN))
    for (x, y, w, h), load in zip(grid(58, 58, 564, 464, 3, 2, 14), P_LOADS):
        out.append(core(x, y, w, h, load))

    # The GPU: many small cores, one grid.
    out.append(block(664, 40, 616, 500, SLATE))
    for (x, y, w, h), load in zip(grid(682, 58, 580, 464, 6, 4, 10), GPU_LOADS):
        out.append(pressed(x, y, w, h, SLATE, load, 7))
        out.append(f'<path d="M{x + w / 2:.1f},{y + 8:.1f} V{y + h - 8:.1f} M{x + 8:.1f},{y + h / 2:.1f} H{x + w - 8:.1f}" '
                   f'stroke="{SLATE}" stroke-opacity="0.26" stroke-width="1.4"/>')

    # The band between: caches and the neural engine, as ruled logic.
    out.append(ruled(40, 564, 380, 150, BROWN, 8, vertical=True))
    out.append(ruled(444, 564, 432, 150, SLATE, 9))
    out.append(ruled(900, 564, 380, 150, BROWN, 8, vertical=True))

    # Efficiency cores: the same core, smaller.
    out.append(block(40, 738, 452, 290, BROWN))
    for (x, y, w, h), load in zip(grid(56, 754, 420, 258, 3, 2, 12), E_LOADS):
        out.append(core(x, y, w, h, load))
    out.append(ruled(40, 1052, 452, 228, BROWN, 9))

    # Memory: two banks of cells that fill from the bottom, as the Chip view fills them.
    for bank, used in enumerate(MEMORY_USED):
        bx = 516 + bank * 390
        out.append(block(bx, 738, 374, 542, SLATE))
        cells = grid(bx + 16, 754, 342, 510, 4, 7, 9)
        lit = round(used * len(cells))
        for index, (x, y, w, h) in enumerate(cells):
            row_from_bottom = 6 - index // 4
            filled = row_from_bottom * 4 + index % 4 < lit
            out.append(pressed(x, y, w, h, SLATE, 0.85 if filled else 0.0, 6))
            rows = "".join(f"M{x + 7:.1f},{v:.1f} H{x + w - 7:.1f}" for v in frange(y + 12, y + h - 6, 11))
            out.append(f'<path d="{rows}" stroke="{SLATE}" stroke-opacity="0.22" stroke-width="1.3"/>')

    shift = (SIZE - DIE) / 2
    return (f'<g transform="rotate({TURN} {SIZE / 2} {SIZE / 2}) translate({shift - 30:.1f} {shift + 40:.1f})" fill="none">'
            + "".join(out) + '</g>')


plan = floorplan()
# The paper again, soft, under the μ: the drawing gives way where the mark stands.
clearing = (f'<circle cx="{left + (width + gap + 2 * dot_r) / 2:.0f}" cy="{top + height / 2 - 18:.0f}" r="330" fill="url(#clear)"/>')
clearing_defs = (f'<defs><radialGradient id="clear"><stop offset="0" stop-color="{PAPER_TOP}" stop-opacity="0.78"/>'
                 f'<stop offset="0.55" stop-color="{PAPER_TOP}" stop-opacity="0.42"/>'
                 f'<stop offset="1" stop-color="{PAPER_TOP}" stop-opacity="0"/></radialGradient></defs>')


# --- the Icon Composer file: the paper as the fill, the μ and the dot as layers.
assets = ICON / "Assets"
for old in assets.glob("*.svg"):
    old.unlink()
(assets / "plan.svg").write_text(svg(plan))
(assets / "clearing.svg").write_text(svg(clearing, clearing_defs))
(assets / "mu.svg").write_text(svg(mu + word))
(assets / "dot.svg").write_text(svg(dot))


def group(layer: str) -> dict:
    return {"layers": [{"image-name": f"{layer}.svg", "name": layer, "glass": False}],
            "specular": False, "shadow": {"kind": "neutral", "opacity": 0.0},
            "translucency": {"enabled": False, "value": 0}}


(ICON / "icon.json").write_text(json.dumps({
    "fill": {"linear-gradient": [srgb(PAPER_TOP), srgb(PAPER_BOTTOM)]},
    # Front to back, the order Icon Composer lists its groups in.
    "groups": [group("dot"), group("mu"), group("clearing"), group("plan")],
    "supported-platforms": {"squares": ["macOS"]},
}, indent=2) + "\n")

# --- the flat icon: the same drawing on a tile of the shape macOS 14 and 15 expect,
# 824 of the 1024 with the system's corner radius and a soft shadow under it.
tile, inset, radius = 824, 100, 185.4
k = tile / SIZE
defs = (f'<defs><linearGradient id="paper" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{PAPER_TOP}"/><stop offset="1" stop-color="{PAPER_BOTTOM}"/></linearGradient>'
        f'<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">'
        f'<feGaussianBlur in="SourceAlpha" stdDeviation="12"/><feOffset dy="10"/>'
        f'<feComponentTransfer><feFuncA type="linear" slope="0.22"/></feComponentTransfer>'
        f'<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>')
defs = defs.replace("</defs>", f'<clipPath id="tile"><rect x="{inset}" y="{inset}" width="{tile}" height="{tile}" rx="{radius}"/></clipPath>'
                    + clearing_defs.replace("<defs>", "").replace("</defs>", "") + "</defs>")


def flat(detailed: bool) -> str:
    """The whole icon. Below 64 pixels the floorplan and the word are noise, so the small sizes carry the μ and the dot alone."""
    background = f'<g clip-path="url(#tile)"><g transform="translate({inset} {inset}) scale({k})">{plan}{clearing}</g></g>' if detailed else ""
    return svg(
        f'<rect x="{inset}" y="{inset}" width="{tile}" height="{tile}" rx="{radius}" fill="url(#paper)" filter="url(#shadow)"/>'
        f'{background}'
        f'<g transform="translate({inset} {inset}) scale({k})">{dot}{mu}{word if detailed else ""}</g>', defs)


with tempfile.TemporaryDirectory() as tmp:
    iconset = Path(tmp) / "AppIcon.iconset"
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            pixels = points * factor
            suffix = "@2x" if factor == 2 else ""
            cairosvg.svg2png(bytestring=flat(pixels >= 64).encode(), write_to=str(iconset / f"icon_{points}x{points}{suffix}.png"),
                             output_width=pixels, output_height=pixels)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "Resources" / "AppIcon.icns")], check=True)

cairosvg.svg2png(bytestring=flat(True).encode(), write_to=str(ROOT / "docs" / "icon.png"), output_width=512, output_height=512)
print("icon written: Resources/AppIcon.icon, Resources/AppIcon.icns, docs/icon.png")
