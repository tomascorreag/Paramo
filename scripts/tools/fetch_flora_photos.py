#!/usr/bin/env python3
"""Fetch CC0-only photographs of the eight in-game flora species for review.

Output is REVIEW MATERIAL, not shipping assets: it lands in res://flora_photos/,
which is gitignored and excluded from both web export presets. Anything chosen
from it gets copied into assets/ deliberately, palette-reduced, by hand.

Every image is verified CC0 at the MEDIA level, not the record level -- a GBIF
occurrence and its attached photo carry separate licences and they do disagree.

Sources, in the order they are preferred:
  1. iNaturalist -- live plants, photographer-released CC0
  2. GBIF HUMAN_OBSERVATION / MACHINE_OBSERVATION -- live plants
  3. GBIF PRESERVED_SPECIMEN -- pressed herbarium sheets (the bulk of CC0)

Usage:
  python scripts/tools/fetch_flora_photos.py [--per-species 10] [--out flora_photos]
  python scripts/tools/fetch_flora_photos.py --dry-run
  python scripts/tools/fetch_flora_photos.py --basis specimen --kinds chusquea,hypericum --append
"""

import argparse
import csv
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

UA = "Paramo-game/1.0 flora reference fetcher (contact via github.com/tomascorreag/Paramo)"

# kind id -> (scientific name, verified GBIF usageKey)
# Keys resolved and checked 2026-08-28. species/match falls back UP the tree
# silently, so the key is pinned here and re-asserted at runtime.
SPECIES = [
    ("frailejon", "Espeletia grandiflora", 3105059),
    ("espeletia_hartwegiana", "Espeletia hartwegiana", 8286763),
    ("espeletia_barclayana", "Espeletia barclayana", 3105057),
    ("calamagrostis", "Calamagrostis effusa", 4108700),
    ("chusquea", "Chusquea tessellata", 4128117),
    ("cortaderia", "Cortaderia nitida", 4148794),
    ("hypericum", "Hypericum juniperinum", 3711397),
    ("arcytophyllum", "Arcytophyllum nitidum", 2892716),
]

# Licence pools. CC0 is the default and the only one with no downstream
# obligation. CC BY exists because for some species it is the ONLY licence a
# photograph of the living plant is available under -- E. barclayana has zero
# CC0 photos in either aggregator, only a line drawing. A CC BY image carries a
# mandatory credit line; the manifest records who, and the filename says ccby so
# the obligation is visible on disk rather than buried in a CSV column.
LICENSES = {
    "cc0": {
        "inat": "cc0",
        "gbif": "CC0_1_0",
        "markers": ("publicdomain/zero", "cc0"),
        "label": "CC0 1.0",
        "suffix": "",
    },
    "cc-by": {
        "inat": "cc-by",
        "gbif": "CC_BY_4_0",
        "markers": ("licenses/by/4.0", "licenses/by/3.0"),
        "label": "CC BY 4.0",
        "suffix": "_ccby",
    },
}

# Specimen sheets are NOT interchangeable. These herbaria image the whole plant
# on a clean card with a legible determination label and a colour bar; others
# return a cropped fragment on grey, or a scan too dark to read. Ordering the
# specimen pool by holder is the only quality lever the API exposes -- there is
# no "good photo" flag. Anything unlisted sorts last, it is not excluded.
INSTITUTION_RANK = ["us", "l", "f", "ny", "nhmuk", "rbge", "b", "cas", "mo"]


def get_json(url, tries=3):
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.load(r)
        except Exception as exc:
            if attempt == tries - 1:
                print("    ! %s" % exc, file=sys.stderr)
                return None
            time.sleep(2 * (attempt + 1))
    return None


def licensed(text, spec):
    """True only if the text names THIS licence. 'Usage Conditions Apply' and a
    bare occurrence-level grant both fail here, which is the point."""
    if not text:
        return False
    t = str(text).lower()
    return any(m in t for m in spec["markers"])


def photo_key(url):
    """Stable identity so an iNat photo reached via GBIF is not fetched twice."""
    m = re.search(r"/photos/(\d+)", url or "")
    return "inat:%s" % m.group(1) if m else (url or "")


def verify_gbif_key(name, pinned):
    """species/match returns a FAMILY key on a miss. Catch that, don't fetch 6M rows."""
    j = get_json("https://api.gbif.org/v1/species/match?name=" + urllib.parse.quote(name))
    if not j:
        return pinned
    if j.get("rank") == "SPECIES" and j.get("matchType") != "HIGHERRANK":
        live = j.get("usageKey")
        if live and live != pinned:
            print("    note: GBIF key drifted %s -> %s" % (pinned, live))
        return live or pinned
    print("    note: species/match gave rank=%s matchType=%s; using pinned key %s"
          % (j.get("rank"), j.get("matchType"), pinned))
    return pinned


def from_inaturalist(sci_name, want, spec):
    url = ("https://api.inaturalist.org/v1/observations?taxon_name=%s"
           "&photo_license=%s&per_page=%d&order_by=votes&order=desc"
           % (urllib.parse.quote(sci_name), spec["inat"], min(want * 4, 200)))
    j = get_json(url)
    out = []
    for obs in (j or {}).get("results", []):
        for ph in obs.get("photos", []):
            if (ph.get("license_code") or "").lower() != spec["inat"]:
                continue  # per-PHOTO licence, not the observation's
            sq = ph.get("url") or ""
            big = re.sub(r"/(square|small|medium)\.", "/large.", sq)
            if not big:
                continue
            out.append({
                "kind": "live",
                "source": "iNaturalist",
                "institution": "inaturalist",
                "url": big,
                "license": spec["label"],
                "credit": (ph.get("attribution") or "").replace("\n", " "),
                "record": "https://www.inaturalist.org/observations/%s" % obs.get("id"),
                "locality": obs.get("place_guess") or "",
                "observed": obs.get("observed_on") or "",
            })
    return out


def from_gbif(taxon_key, basis, kind, want, spec):
    url = ("https://api.gbif.org/v1/occurrence/search?taxonKey=%d&mediaType=StillImage"
           "&license=%s&basisOfRecord=%s&limit=%d"
           % (taxon_key, spec["gbif"], basis, min(want * 6, 300)))
    j = get_json(url)
    out = []
    for occ in (j or {}).get("results", []):
        for med in occ.get("media", []) or []:
            if med.get("type") not in (None, "StillImage"):
                continue
            # The MEDIA licence, not occ["license"] -- these genuinely differ.
            if not licensed(med.get("license") or occ.get("license"), spec):
                continue
            ident = med.get("identifier")
            if not ident:
                continue
            inst = (occ.get("institutionCode") or occ.get("publisher") or "?")
            out.append({
                "kind": kind,
                "source": "GBIF/%s" % inst,
                "institution": inst.lower(),
                "url": ident,
                "license": spec["label"],
                "credit": (med.get("rightsHolder") or occ.get("recordedBy") or "").replace("\n", " "),
                "record": "https://www.gbif.org/occurrence/%s" % occ.get("key"),
                "locality": occ.get("locality") or occ.get("country") or "",
                "observed": occ.get("eventDate") or "",
            })
    return out


def by_institution(cands):
    """Best-imaging herbaria first. Stable, so GBIF's own order breaks ties."""
    rank = {code: i for i, code in enumerate(INSTITUTION_RANK)}
    return sorted(cands, key=lambda c: rank.get(c.get("institution", ""), len(rank)))


def next_index(sp_dir):
    """Highest NN already on disk, so --append does not overwrite a review pick."""
    top = 0
    if os.path.isdir(sp_dir):
        for f in os.listdir(sp_dir):
            m = re.match(r"(\d+)_", f)
            if m:
                top = max(top, int(m.group(1)))
    return top + 1


def download(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=90) as r:
        ctype = (r.headers.get("Content-Type") or "").lower()
        if not ctype.startswith("image/"):
            raise ValueError("not an image (%s)" % ctype)
        data = r.read()
    ext = ".png" if "png" in ctype else ".jpg"
    path = dest + ext
    with open(path, "wb") as f:
        f.write(data)
    return path, len(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-species", type=int, default=10)
    ap.add_argument("--out", default="flora_photos")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--basis", choices=["any", "live", "specimen"], default="any",
                    help="restrict to living-plant photos or to herbarium sheets")
    ap.add_argument("--kinds", default="",
                    help="comma-separated kind ids; default is all eight")
    ap.add_argument("--license", choices=sorted(LICENSES), default="cc0",
                    help="cc0 (default, no attribution owed) or cc-by (credit required)")
    ap.add_argument("--append", action="store_true",
                    help="number after the files already on disk instead of from 01, "
                         "and add to manifest.csv rather than replacing it")
    args = ap.parse_args()

    spec = LICENSES[args.license]
    if args.license != "cc0":
        # Project policy is CC0-only in the review folder: an image with a credit
        # obligation must not sit in a pool someone picks from without noticing.
        # The mode stays for SURVEYING what exists; writing it here is opt-in.
        print("WARNING: --license %s is not CC0. These images carry a mandatory\n"
              "         credit line and must not be shipped as if public domain.\n"
              "         Files are suffixed %r so they are identifiable on disk."
              % (args.license, spec["suffix"]), file=sys.stderr)
    root = os.path.abspath(args.out)
    os.makedirs(root, exist_ok=True)
    man = os.path.join(root, "manifest.csv")

    wanted = [k.strip() for k in args.kinds.split(",") if k.strip()]
    todo = [s for s in SPECIES if not wanted or s[0] in wanted]
    unknown = set(wanted) - {s[0] for s in SPECIES}
    if unknown:
        sys.exit("unknown kind id(s): %s" % ", ".join(sorted(unknown)))

    rows = []
    if args.append and os.path.exists(man):
        with open(man, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        print("carrying %d existing manifest rows" % len(rows))

    for kind_id, sci, pinned in todo:
        print("\n== %s (%s)" % (sci, kind_id))
        key = verify_gbif_key(sci, pinned)
        time.sleep(0.5)

        live_sources = (
            lambda: from_inaturalist(sci, args.per_species, spec),
            lambda: from_gbif(key, "HUMAN_OBSERVATION", "live", args.per_species, spec),
            lambda: from_gbif(key, "MACHINE_OBSERVATION", "live", args.per_species, spec),
        )
        specimen_sources = (
            lambda: by_institution(
                from_gbif(key, "PRESERVED_SPECIMEN", "specimen", args.per_species, spec)),
        )
        sources = {
            "any": live_sources + specimen_sources,
            "live": live_sources,
            "specimen": specimen_sources,
        }[args.basis]

        pool, seen = [], set()
        for fetch in sources:
            if len(pool) >= args.per_species:
                break
            for cand in fetch():
                k = photo_key(cand["url"])
                if k in seen:
                    continue
                seen.add(k)
                pool.append(cand)
                if len(pool) >= args.per_species:
                    break
            time.sleep(1.0)

        live = sum(1 for p in pool if p["kind"] == "live")
        print("   %d candidates (%d live, %d specimen)" % (len(pool), live, len(pool) - live))

        sp_dir = os.path.join(root, kind_id)
        os.makedirs(sp_dir, exist_ok=True)
        first = next_index(sp_dir) if args.append else 1
        for i, cand in enumerate(pool, first):
            stem = os.path.join(sp_dir, "%02d_%s%s" % (i, cand["kind"], spec["suffix"]))
            fname = "(dry run)"
            if not args.dry_run:
                try:
                    path, nbytes = download(cand["url"], stem)
                    fname = os.path.basename(path)
                    print("   %2d %-8s %-24s %6.0f KB" % (i, cand["kind"], fname, nbytes / 1024.0))
                except Exception as exc:
                    print("   %2d FAILED %s" % (i, exc), file=sys.stderr)
                    continue
                time.sleep(0.3)
            rows.append({
                "kind_id": kind_id, "species": sci, "file": "%s/%s" % (kind_id, fname),
                "type": cand["kind"], "source": cand["source"], "license": cand["license"],
                "credit": cand["credit"], "record_url": cand["record"],
                "image_url": cand["url"], "locality": cand["locality"], "date": cand["observed"],
            })

    rows.sort(key=lambda r: (r["kind_id"], r["file"]))
    with open(man, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["kind_id"])
        w.writeheader()
        w.writerows(rows)

    live_total = sum(1 for r in rows if r["type"] == "live")
    print("\n%d images, %d live / %d specimen -> %s"
          % (len(rows), live_total, len(rows) - live_total, root))
    print("manifest: %s" % man)


if __name__ == "__main__":
    main()
