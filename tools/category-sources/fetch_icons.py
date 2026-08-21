"""Fetch the category icons BG Wiki uses on Category:Quests and Category:Missions.

    python tools/category-sources/fetch_icons.py [--cache <directory>]

Writes the originals into `icons/` beside this file, and `icons/manifest.json` naming
the source URL of each. `tools/make_category_icons.py` reads both: the images are what
the 17 shipped badges are built from, and the manifest is the attribution that
`assets/category/SOURCES.json` carries into the addon. The images themselves are not
committed, because they are BG Wiki's to distribute rather than this addon's, and the
manifest is, because it is the attribution record. README.md in this directory has the
licence reasoning, which is what decides that rather than tidiness.

The URLs are not guessed: they come from questmarks' own cached copies of the two
category pages, which store the rendered Parsoid HTML but no images. Each icon is the
<img> inside the anchor that links to the sub-category, so the mapping is the wiki's
own rather than a guess.

Conventions copied from questmarks' tools/pipeline/fetch_wiki.py, from its
`USER_AGENT` and the fetch loop under it, because they are the polite ones and this
hits the same host: a descriptive User-Agent, one request at a time, a fixed delay
between them, and nothing refetched that is already on disk.
"""
import argparse, glob, hashlib, io, json, os, re, sys, time
import urllib.request

HOST = "https://www.bg-wiki.com"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "icons")

#[ questmarks' page cache, derived rather than named. This file sits in
#  questmarks-ui/tools/category-sources/, so three levels up is Windower's addons
#  directory and questmarks is a sibling of this addon, which is where an install of
#  both puts it. --cache is for a checkout that keeps them somewhere else. ]
CACHE = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "questmarks", "bgwiki-rest-cache", "directories"))

#[ The two pages by title, not by filename. cached_page derives the filename. ]
PAGES = ("Category:Quests", "Category:Missions")

# The shape questmarks' fetch_wiki.py gives its own `USER_AGENT`. Same host, same
# manners.
USER_AGENT = ("questmarks-ui/1.0 (FFXI questmarks-ui addon build tool; "
              "category icon fetch; polite, cached)")
DELAY = 1.0

PAIR = re.compile(r'<a\b[^>]*?href="([^"]+)"[^>]*>\s*(?:<[^>]+>\s*)*?<img[^>]+src="([^"]+)"',
                  re.S)


def cached_page(cache, title):
    """The cached record for one page, found by title rather than by filename.

    questmarks names these <page id>_<slug>_<first ten of sha1 of the title>.json,
    and its fetch_wiki.cache_filename is the rule. Only the page id is unknown here,
    so the id is globbed and the rest computed, which pins the match to this exact
    title. The digest is a filename, not a security claim.
    """
    slug = re.sub(r"[^a-z0-9]+", "_", title.lower()).strip("_")
    stamp = hashlib.sha1(title.encode("utf-8")).hexdigest()[:10]
    hits = sorted(glob.glob(os.path.join(cache, "*_%s_%s.json" % (slug, stamp))))
    if not hits:
        sys.exit("no cached page for %s in %s"
                 "\nThat directory is questmarks' page cache. Build it by running"
                 " questmarks' tools/pipeline/fetch_wiki.py, or point --cache at a"
                 " directory that already holds one." % (title, cache))
    return hits[-1]


def targets(cache):
    """-> {category title: image path} taken from the cached pages, in page order."""
    out = {}
    for title in PAGES:
        path = cached_page(cache, title)
        rec = json.load(io.open(path, encoding="utf-8"))
        html = (rec.get("normalized") or {}).get("html") or ""
        if not html:
            sys.exit("%s holds no rendered html for %s"
                     "\nRefetch that page with questmarks'"
                     " tools/pipeline/fetch_wiki.py." % (path, title))
        for href, src in PAIR.findall(html):
            out.setdefault(href.replace("./", ""), src)
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Fetch the BG Wiki category icons the region badges are built "
                    "from.")
    ap.add_argument("--cache", default=CACHE, metavar="DIR",
                    help="questmarks' bgwiki-rest-cache/directories "
                         "(default: %(default)s)")
    args = ap.parse_args()
    if not os.path.isdir(args.cache):
        sys.exit("no page cache at %s"
                 "\nThis reads questmarks' cached copies of the two category pages."
                 " Install questmarks beside this addon, or point --cache at its"
                 " bgwiki-rest-cache/directories." % args.cache)
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    found = targets(args.cache)
    print("%d icons named by the two cached category pages" % len(found))
    manifest, last = {}, 0.0
    for cat, src in sorted(found.items()):
        name = src.rsplit("/", 1)[-1]
        dest = os.path.join(OUT, name)
        manifest[cat] = {"file": name, "url": HOST + src}
        if os.path.exists(dest):
            print("  have  %-46s %s" % (cat[:46], name))
            continue
        gap = DELAY - (time.time() - last)
        if gap > 0:
            time.sleep(gap)
        req = urllib.request.Request(HOST + src, headers={"User-Agent": USER_AGENT})
        try:
            body = urllib.request.urlopen(req, timeout=45).read()
        except Exception as e:
            print("  FAIL  %-46s %s" % (cat[:46], e))
            last = time.time()
            continue
        last = time.time()
        io.open(dest, "wb").write(body)
        print("  got   %-46s %s (%d bytes)" % (cat[:46], name, len(body)))
    io.open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8").write(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print("wrote", os.path.join(OUT, "manifest.json"))


if __name__ == "__main__":
    main()
