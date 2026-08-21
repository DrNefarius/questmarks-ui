"""Derive the two page sheets from the papyrus, so the panes read as one open book.

    python tools/make_pages.py

Reads assets/papyrus.png, the original, which is never modified, and writes
assets/page_left.png and assets/page_right.png. The derivation is a tool rather than
hand-edited art, so it can be re-run when the source changes and so the reasoning
lives next to the numbers, which is the pattern make_category_icons.py follows too.

Why two sheets and not one stretched across both panes. The obvious way to draw a
spread is one image over the whole window. The window is 812x502, aspect 1.617; the
papyrus is 1091x1442, aspect 0.757. Stretching one into the other is 2.14x horizontally
and the grain turns into visible streaking. So each pane gets its own sheet at its own
aspect, and what makes the pair read as a book is done here instead:

  Mirrored. The left page is the source flipped horizontally. One sheet used twice
  side by side repeats its stains in the same places and reads as two copies of a
  texture; mirrored, the wear runs outward from the centre the way a folded sheet
  does.

  Cropped, not stretched, to each pane's own aspect. The list pane is 430x502 (0.857)
  and the detail pane 380x502 (0.757). The source is 0.757, so the detail pane keeps all
  but one row of it, 1442 down to 1441, and the list pane is cropped to 1274. Cropping
  loses sheet; stretching loses the grain, and the grain is the whole reason for using a
  photograph.

  A gutter shadow on the inner edge of each page, the left page's right side and
  the right page's left side, so the two lean into a fold rather than butting together.
  It is a cosine ramp because a linear one has a visible edge where it ends.

  And a page edge on the outer side, much fainter, which is what stops each page
  looking like it was cut with scissors.

The shadows are baked into the sheet and not drawn as prims. Prims cannot draw a
gradient, because there is no gradient primitive on this platform, and faking one with
twenty stacked rects per pane would cost forty objects to do badly what one multiply
does exactly. They are also multiplied through by the tint afterwards, which is why
they are authored as luminance and carry no colour of their own.
"""

import math
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow:  python -m pip install Pillow")

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, "..", "assets"))
SRC = os.path.join(ASSETS, "papyrus.png")

#[ The panes, from ui/theme.lua: list_width 430, detail_width 380, both 502 tall at
#  scale 1.0. Only the aspect is used: the sheet is authored at source resolution and
#  the client scales it to whatever the quad is. ]
PANES = {
    "page_left.png": (430.0, 502.0, True),    # list pane, mirrored, gutter on the right
    "page_right.png": (380.0, 502.0, False),  # detail pane, gutter on the left
}

#[ How deep the fold goes, and how far across the page it reaches. 0.75 means the gutter
#  edge keeps 75% of its brightness; 0.13 means the shadow is spent by 13% of the way
#  across.
#
#  0.62 / 0.17 is measurably too deep, and arithmetic says so rather than taste. The
#  right-hand page carries the step glyph and step number at x 26 and 48 of 380, inside
#  the gutter, and at 0.62 / 0.17 the darkest 5% of that column measures luminance
#  0.1510. ui/theme.lua holds the glyph column to 3.0:1, WCAG's large-text bar, and the
#  faintest ink that reaches it needs the column at 0.2060 to clear that, so three of
#  parchment's four glyph inks sat under the bar in the fold. At 0.75 / 0.13 the same
#  column measures 0.2147 and all four clear it: text 4.6:1, text_dim 3.6:1, amber
#  3.2:1, text_faint 3.1:1. The prose column is unaffected either way: it sits past
#  x 56, where the shadow is already spent (0.4156 at 0.62 / 0.17, 0.4160 at
#  0.75 / 0.13). ]
GUTTER_MIN, GUTTER_SPAN = 0.75, 0.13

#[ The outer page edge. Far weaker, and narrower: it is a hint of thickness, not a
#  second fold. ]
EDGE_MIN, EDGE_SPAN = 0.86, 0.06


def crop_to_aspect(im, aspect):
    """Crop centred to `aspect` (w/h). Never stretches."""
    w, h = im.size
    if w / h > aspect:
        nw = int(round(h * aspect))
        x = (w - nw) // 2
        return im.crop((x, 0, x + nw, h))
    nh = int(round(w / aspect))
    y = (h - nh) // 2
    return im.crop((0, y, w, y + nh))


def ramp(t, lo, span):
    """1.0 in the open field, falling to `lo` at t = 0. Cosine, so it has no edge."""
    if t >= span:
        return 1.0
    # 0 at the gutter, 1 at `span`, eased
    u = t / span
    return lo + (1.0 - lo) * (0.5 - 0.5 * math.cos(math.pi * u))


def shade(im, gutter_on_right):
    """Multiply in the gutter shadow and the outer page edge."""
    w, h = im.size
    px = im.load()
    #[ One column of multipliers, then applied down the whole height. The shading is
    #  purely horizontal, because a vertical component would fight the source's own top and
    #  bottom staining, which is already doing that job. ]
    mult = []
    for x in range(w):
        t = x / (w - 1.0)
        gut = t if gutter_on_right else 1.0 - t          # distance from the gutter
        out = 1.0 - gut                                   # distance from the outer edge
        mult.append(ramp(1.0 - gut, GUTTER_MIN, GUTTER_SPAN)
                    * ramp(1.0 - out, EDGE_MIN, EDGE_SPAN))
    for y in range(h):
        for x in range(w):
            m = mult[x]
            r, g, b = px[x, y][:3]
            px[x, y] = (int(r * m), int(g * m), int(b * m))
    return im


#[ Where the panel puts things, from ui/theme.lua at scale 1.0, and measured as two
#  columns rather than one box.
#
#  The gutter shadow this tool bakes in spans the first 13% of a page's width, and on
#  the right-hand page that is x 0..49 of 380, which covers the step glyph (26) and the
#  step number (48) and stops short of the text column, which starts at 56. So the
#  darkest part of the page is under the glyph column and not under the prose, and one
#  figure for the whole box would hold the prose to a floor set by a shadow it never
#  touches. Two columns, each checked against what actually lands on it.
#
#  y 11..481 for both: the title's baseline down to the last ladder line of a 502px
#  pane. The corners are the most stained part of the sheet and carry nothing. ]
BOXES = {
    "glyph": (14, 11, 56, 481, 502),    # step glyph, step number, the state bar
    "main":  (56, 11, 352, 481, 502),   # every string the panel draws
}


def lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lum(t):
    return 0.2126 * lin(t[0]) + 0.7152 * lin(t[1]) + 0.0722 * lin(t[2])


def measure(im, pane_w, box):
    """One column's colour, as RGB triples Lua can multiply.

    RGB and not luminance, because the panel multiplies a tint through the sheet and
    the luminance of the product is not any function of the luminances. Emitting the
    actual pixel at each luminance percentile lets ui/theme.lua's presets be checked
    exactly: tint that triple, take its luminance, and that is a real pixel of the
    real sheet under that preset.
    """
    x0, y0, x1, y1, ph = box
    sx, sy = im.width / float(pane_w), im.height / float(ph)
    crop = (int(x0 * sx), int(y0 * sy), int(x1 * sx), int(y1 * sy))
    px = list(im.crop(crop).convert("RGB").get_flattened_data())
    px.sort(key=lum)
    n = len(px)
    mean = tuple(int(round(sum(p[i] for p in px) / float(n))) for i in range(3))
    return {"mean": mean, "p05": px[n // 20], "p50": px[n // 2],
            "p95": px[n * 19 // 20], "darkest": px[0], "lightest": px[-1]}


def emit_stats(stats):
    """Write ui/pagestats.lua, generated like ui/metrics.lua.

    Carries the sheets' own dimensions and byte counts as well as the colour, so
    tools/smoke.lua can refuse to trust a stats file that no longer describes the
    files on disk. A measurement that has quietly gone stale is worse than none.
    """
    path = os.path.normpath(os.path.join(HERE, "..", "ui", "pagestats.lua"))
    lines = [
        "--[[",
        "ui/pagestats.lua -- GENERATED FILE, DO NOT EDIT BY HAND.",
        "    python tools/make_pages.py",
        "",
        "What the page sheets look like where the panel puts text, as RGB triples. It",
        "exists because the presets in ui/theme.lua multiply a tint through these sheets",
        "and the result has to clear a contrast floor, and Lua cannot decode a PNG, so the",
        "measurement has to be taken here and carried across.",
        "",
        "RGB and not luminance: the panel multiplies per channel, and the luminance of",
        "the product is not any function of the luminances. Each triple is a real pixel",
        "of the sheet at that luminance percentile, so tinting it gives an exact answer",
        "rather than an estimate.",
        "",
        "Measured as two columns of a 380x502 pane at scale 1.0, y 11..481:",
        "",
        "  glyph   x 14..56   the step glyph, the step number, the row state bar",
        "  main    x 56..352  every string the panel draws",
        "",
        "Two and not one because the gutter shadow spans the first 13% of a page: on the",
        "right-hand page that is x 0..49 of 380, the glyph column and no further. One",
        "figure for the whole box would hold the prose to a floor set by a shadow it",
        "never touches.",
        "",
        "`w`, `h` and `bytes` are the sheet's own, so a consumer can tell whether these",
        "numbers still describe the file on disk.",
        "]]",
        "",
        "return {",
    ]
    for name in sorted(stats):
        st = stats[name]
        lines.append("    ['%s'] = {" % name)
        lines.append("        w = %d, h = %d, bytes = %d,"
                     % (st["w"], st["h"], st["bytes"]))
        for col in sorted(BOXES):
            lines.append("        %s = {" % col)
            for k in ("darkest", "p05", "mean", "p50", "p95", "lightest"):
                r, g, b = st[col][k]
                lines.append("            %-9s = {%3d, %3d, %3d},   -- luminance %.4f"
                             % (k, r, g, b, lum((r, g, b))))
            lines.append("        },")
        lines.append("    },")
    lines.append("}")
    io_write(path, "\n".join(lines) + "\n")
    print("%-16s measured colour for both pages" % "ui/pagestats.lua")


def io_write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def main():
    if not os.path.exists(SRC):
        sys.exit("no papyrus at %s"
                 "\nEvery page sheet is derived from that file and it ships with the"
                 " addon, so restore it from the repository rather than replacing it"
                 " with another photograph without re-reading this file." % SRC)
    src = Image.open(SRC).convert("RGB")
    print("source %s  %dx%d  aspect %.4f"
          % (os.path.basename(SRC), src.width, src.height, src.width / src.height))
    stats = {}
    for name, (pw, ph, mirror) in sorted(PANES.items()):
        im = crop_to_aspect(src, pw / ph)
        if mirror:
            im = im.transpose(Image.FLIP_LEFT_RIGHT)
        #[ The gutter is on the side that faces the other pane. The left page is
        #  mirrored, so after the flip its inner edge is on the right either way.
        #  Stated explicitly rather than relying on the flip to line up. ]
        im = shade(im, gutter_on_right=mirror)
        out = os.path.join(ASSETS, name)
        im.save(out)
        st = {"w": im.width, "h": im.height, "bytes": os.path.getsize(out)}
        for col, box in BOXES.items():
            st[col] = measure(im, pw, box)
        stats[name] = st
        print("%-16s %dx%d  aspect %.4f (pane %.4f)%s  glyph p05 L=%.3f  main p05 L=%.3f"
              % (name, im.width, im.height, im.width / im.height, pw / ph,
                 " mirrored" if mirror else "",
                 lum(st["glyph"]["p05"]), lum(st["main"]["p05"])))
    emit_stats(stats)

    #[ A preview of the pair as they sit, so the fold can be judged as a fold. ]
    left = Image.open(os.path.join(ASSETS, "page_left.png")).resize((430, 502),
                                                                   Image.LANCZOS)
    right = Image.open(os.path.join(ASSETS, "page_right.png")).resize((380, 502),
                                                                     Image.LANCZOS)
    prev = Image.new("RGB", (430 + 2 + 380, 502), (0, 0, 0))
    prev.paste(left, (0, 0))
    prev.paste(right, (432, 0))
    prev.save(os.path.join(HERE, "pages_preview.png"))
    print("preview          tools/pages_preview.png  (812x502, the real 2px pane gap)")


if __name__ == "__main__":
    main()
