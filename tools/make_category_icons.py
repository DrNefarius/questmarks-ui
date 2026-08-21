"""Generates assets/category/*.png, the region badges the list draws on group lines.

    python tools/make_category_icons.py

Source and provenance. The originals are BG Wiki's own category images, fetched by
`tools/category-sources/fetch_icons.py` into `tools/category-sources/icons/`
alongside a manifest naming the URL of each. Which image belongs to which category is the
wiki's own mapping, taken from the anchor each `<img>` sits inside on Category:Quests and
Category:Missions, not a guess. BG Wiki content is CC BY-NC-SA 3.0; see `NOTICE`, which
carries the attribution, the licence and the per-file source list.

Why a build step rather than the files as downloaded. Three reasons, all measured:

  * Size. The originals are 132 to 136 px and the panel draws them at 16 px (40 px at
    the 2.5 scale ceiling). 64 px is comfortably above the ceiling and a bit over a
    quarter of the bytes: 17 files at 618 KB becomes 174 KB.
  * Alpha. Most of these are wiki thumbnails: artwork on a flat white or black plate with
    the corners rounded off. Dropped in as they are, they draw that plate, a white
    rectangle around a crest on a dark panel, which is the fault `ui/launcher.lua`
    refuses behind the launcher icon; see its "No plate behind the icon" note. So each is
    offered a flood fill from the four corners, which removes only background that
    touches the border; keying by colour would punch holes through anything bright or
    dark inside the artwork.

    Offered, not applied: `cut_border` refuses its own result if the fill reached the
    artwork, and 16 of the 17 take it while Jeuno's does not. Read that function's note
    before changing any of this. The refusal is not a safety margin; it is what stops a
    badge that is no longer the artwork from being written at all.

    An existing alpha channel is not evidence that the plate is gone. These thumbnails
    have transparent corners and an opaque plate behind the middle, so a "does it have
    alpha" test skips exactly the files that need the cut. Every file is offered the cut
    and the log says which took it.
  * Reproducibility. The mapping from a region to a badge is recorded in one place that
    is executable, so a wrong pairing is a diff rather than a file someone renamed.

What it cannot fix. These are two kinds of picture. The nation crests are flat heraldry
and they are still themselves at 16 px; the expansion images are cover art, a face, a
party of six or a shadowed figure, and at 16 px they are a coloured smudge that says
"expansion" rather than which one. That is a property of the source, recorded in
`tools/category-sources/README.md` with the comparison sheet.
"""
import io, json, os, sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("needs Pillow:  python -m pip install Pillow")

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.abspath(os.path.join(HERE, ".."))
SRC = os.path.join(HERE, "category-sources", "icons")
OUT = os.path.join(ADDON, "assets", "category")
SIZE = 64

# shipped name <- source file. Several regions share a badge; the file is named for the
# artwork rather than for a region, so it is stored once. ui/theme.lua maps regions onto
# these names.
BADGES = {
    "sandoria":  "Sandorian_Iconv2.png",
    "bastok":    "Bastok_Iconv2.png",
    "windurst":  "Windurst_Iconv2.png",
    "jeuno":     "Jeuno_Icon.png",
    "promathia": "Chainsofpromathia_Icon.png",
    "ahturhgan": "AhtUrghan_Icon.png",
    "wotg":      "Wingsofthegoddess_Icon.png",
    "campaign":  "Campaign_Iconv2.png",
    "acp":       "CrystallineProphecy_Icon.png",
    "mkd":       "Mooglekupodetat_Icon.png",
    "asa":       "ShantottoAscension_Icon.png",
    "adoulin":   "Seekersofadoulin_Icon.png",
    "rov":       "Rhapsodies_Icon.png",
    "tvr":       "VoraciousResurgence_Icon.png",
    "outlands":  "Outerlandsquest_Icon.png",
    "other":     "Otherquest_Icon.png",
    "abyssea":   "Abysseaquest_Icon.png",
}


#[[ How much of the middle the fill is allowed to touch: none of it. See cut_border. ]]
KEEP_BOX = 0.55


def cut_border(im, tol=24):
    """Flood fill from each corner, and refuse the result if it reached the artwork.

    The refusal is the whole of this function's correctness. Jeuno's crest is an open
    triangular emblem on a white card, and the white inside the emblem is continuous
    with the white outside it, so a fill started at a corner runs through the gaps,
    empties the middle of the artwork and leaves the dark strokes stranded: 5287 px of
    a 132x132 original, and a badge that reads as black scratches.

    No tolerance fixes that. The card and the emblem's interior are the same colour and
    they are connected, which is the one thing a flood fill cannot tell apart.

    So the fill is a proposal, not a result. If it reaches the central 55%, which is
    where the artwork is in every one of these, the whole cut is discarded and the plate
    stays. A plate is a cosmetic problem on a dark preset; a hole through the middle of
    the crest is a wrong picture, and between the two the choice is not close.
    """
    im = im.convert("RGBA")
    w, h = im.size
    # Work on an RGB copy with a sentinel colour, then map the sentinel to alpha 0.
    flat = Image.new("RGB", (w, h))
    flat.paste(im.convert("RGB"), (0, 0))
    SENT = (1, 254, 2)
    for xy in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        ImageDraw.floodfill(flat, xy, SENT, thresh=tol)
    px = flat.load()

    x0, x1 = int(w * (1 - KEEP_BOX) / 2), int(w * (1 + KEEP_BOX) / 2)
    y0, y1 = int(h * (1 - KEEP_BOX) / 2), int(h * (1 + KEEP_BOX) / 2)
    for y in range(y0, y1):
        for x in range(x0, x1):
            if px[x, y] == SENT:
                return im, 0, True          # reached the artwork: keep the plate

    out = im.load()
    cut = 0
    for y in range(h):
        for x in range(w):
            if px[x, y] == SENT:
                r, g, b, _ = out[x, y]
                out[x, y] = (r, g, b, 0)
                cut += 1
    return im, cut, False


def main():
    if not os.path.isdir(SRC):
        sys.exit("no source icons at " + SRC
                 + ", run tools/category-sources/fetch_icons.py")
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    man_path = os.path.join(SRC, "manifest.json")
    manifest = json.load(io.open(man_path, encoding="utf-8")) if os.path.exists(man_path) else {}
    by_file, url_of = {}, {}
    for cat, rec in manifest.items():
        by_file.setdefault(rec["file"], []).append(cat)
        url_of[rec["file"]] = rec.get("url", "")

    credits = {}
    for name, src in sorted(BADGES.items()):
        p = os.path.join(SRC, src)
        if not os.path.exists(p):
            sys.exit("no source image at %s"
                     "\nThat is one of BG Wiki's originals, which are not committed."
                     " Run tools/category-sources/fetch_icons.py to fetch them." % p)
        src_im = Image.open(p)
        had_alpha = src_im.mode in ("RGBA", "LA") or "transparency" in src_im.info
        orig = src_im.convert("RGBA")
        im, cut, refused = cut_border(orig.copy())
        im = im.resize((SIZE, SIZE), Image.LANCZOS)

        # Every pixel still visible must still be the source's.
        #
        # A wrong cut passes every cheap check there is: the file has an alpha channel,
        # that channel has both extremes, the byte count is sane, the badge draws. The
        # one check it fails is the picture against the picture, which is this one,
        # against the same source downscaled with nothing done to it. It is the cheap
        # half of the guard; the refusal in cut_border is the load-bearing half.
        # Compared over the central box only, which is the region cut_border promises
        # not to touch. Along the edge a legitimate cut does move pixels, because the
        # resample kernel reaches across the boundary it just made transparent, and
        # that is the cut working rather than the cut failing.
        ref = orig.resize((SIZE, SIZE), Image.LANCZOS)
        worst, wx = 0, None
        a, b = im.load(), ref.load()
        lo, hi = int(SIZE * (1 - KEEP_BOX) / 2), int(SIZE * (1 + KEEP_BOX) / 2)
        for y in range(lo, hi):
            for x in range(lo, hi):
                if a[x, y][3] > 200 and b[x, y][3] > 200:
                    d = max(abs(a[x, y][i] - b[x, y][i]) for i in range(3))
                    if d > worst:
                        worst, wx = d, (x, y)
        if worst > 12:
            sys.exit("%s: the cut moved a visible pixel by %d at %s -- refusing to write "
                     "a badge that is not the artwork" % (name, worst, wx))

        dest = os.path.join(OUT, name + ".png")
        im.save(dest, optimize=True)
        cats = sorted(by_file.get(src, []))

        credits[name + ".png"] = {
            "source_file": src,
            # The URL is carried through from the fetcher's manifest so the
            # attribution CC BY asks for ships with the addon, rather than only
            # in the source directory the badges are built from.
            "source_url": url_of.get(src, ""),
            "wiki_categories": cats,
            "source_alpha": "yes" if had_alpha else "none",
            "plate": ("kept -- the corner fill reached the artwork" if refused
                      else ("cut, %d px flood-filled from the corners" % cut
                            if cut else "none to cut")),
        }
        print("  %-14s <- %-32s %s" % (
            name + ".png", src,
            "plate KEPT (fill reached the artwork)" if refused
            else ("cut %d px" % cut if cut else "nothing to cut")))
    io.open(os.path.join(OUT, "SOURCES.json"), "w", encoding="utf-8").write(
        json.dumps(credits, indent=2, sort_keys=True) + "\n")
    print("wrote %d badges + SOURCES.json to %s" % (len(BADGES), OUT))
    sheet(credits)


def sheet(credits):
    """Every badge beside the original it came from, on a light ground and a dark one.

    Written every build, and not as a nicety. A flood fill that runs through the middle
    of a crest and leaves the dark strokes behind is invisible to every numeric check and
    obvious in one glance at the picture. A build that produces images should leave the
    images somewhere they will be looked at.
    """
    names = sorted(credits.keys())
    cell, pad, row = 76, 10, 64
    im = Image.new("RGBA", (len(names) * cell + pad * 2, pad * 2 + row * 4 + 24),
                   (236, 236, 240, 255))
    d = ImageDraw.Draw(im)
    d.rectangle([0, pad + row * 2 + 12, im.width, im.height], fill=(20, 18, 46, 255))
    for i, n in enumerate(names):
        orig = Image.open(os.path.join(SRC, credits[n]["source_file"])).convert("RGBA")
        orig = orig.resize((SIZE, SIZE), Image.LANCZOS)
        made = Image.open(os.path.join(OUT, n)).convert("RGBA")
        x = pad + i * cell
        im.alpha_composite(orig, (x, pad))
        im.alpha_composite(made, (x, pad + row))
        im.alpha_composite(orig, (x, pad + row * 2 + 12))
        im.alpha_composite(made, (x, pad + row * 3 + 12))
    dest = os.path.join(HERE, "category-sources", "badges_vs_originals.png")
    im.convert("RGB").save(dest)
    print("wrote", dest, ": original above, generated below, on light then dark")


if __name__ == "__main__":
    main()
