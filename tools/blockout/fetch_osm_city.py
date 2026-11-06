"""Download a city's buildings and ground features from the Overpass API.

    python -I tools/blockout/fetch_osm_city.py <raw dir> --bbox S,W,N,E
    python -I tools/blockout/fetch_osm_city.py <raw dir> --boundary "Orleans Parish"

--boundary names an administrative boundary relation instead of a box: its
outline is saved as boundary.json, for osm_city.py to clip the city to,
and its bounding box is downloaded.

Writes bld_I_J.json (buildings, one file per tile of a 4x4 split, because
one query for a whole city times out; a tile that still times out is
split again, into bld_I_J_K.json), features.json (water, roads, green
space, rail) and coast.json (coastline), the input of osm_city.py. Files
already present are skipped, so a failed run can be resumed. The script
waits for a free query slot before each query and backs off after a
failure, so it never hammers the server.

Map data (c) OpenStreetMap contributors, ODbL 1.0.
"""
import argparse
import json
import os
import re
import time
import urllib.parse
import urllib.request

## One server, asked politely. It allows each address a few query slots,
## and a heavy query keeps its slot blocked for a while after it ends, so
## the fetcher asks /api/status when a slot is free and waits for it
## rather than retrying into a 429. Override with --server.
SERVER = "https://overpass-api.de/api/interpreter"
AGENT = {"User-Agent": "combat_test-blockout/1.0"}
SPLIT = 4
TRIES = 12
## A tile of buildings that keeps failing, a dense downtown that times the
## servers out, is split into quarters, up to this many times.
SPLIT_DEPTH = 2
SPLIT_TRIES = 4


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--bbox")
    ap.add_argument("--boundary", help="name of an administrative boundary relation")
    ap.add_argument("--server", default=SERVER, help="an Overpass interpreter URL")
    args = ap.parse_args()
    globals()["SERVER"] = args.server
    os.makedirs(args.out, exist_ok=True)
    if args.boundary:
        path = os.path.join(args.out, "boundary.json")
        _fetch(path, '[out:json][timeout:300];relation["boundary"="administrative"]["name"="%s"];out geom;'
               % args.boundary.replace('"', '\\"'))
        s, w, n, e = boundary_bbox(path)
        print("bbox %f,%f,%f,%f" % (s, w, n, e))
    elif args.bbox:
        s, w, n, e = (float(v) for v in args.bbox.split(","))
    else:
        raise SystemExit("give --bbox or --boundary")
    for i in range(SPLIT):
        for j in range(SPLIT):
            ts, tn = s + (n - s) * i / SPLIT, s + (n - s) * (i + 1) / SPLIT
            tw, te = w + (e - w) * j / SPLIT, w + (e - w) * (j + 1) / SPLIT
            _buildings(os.path.join(args.out, "bld_%d_%d" % (i, j)), ts, tw, tn, te, SPLIT_DEPTH)
    bb = "(%f,%f,%f,%f)" % (s, w, n, e)
    # `out geom`, not `out tags geom`: relations need their members, and
    # the bbox clips them, which osm_city.py repairs.
    _fetch(os.path.join(args.out, "features.json"), f"""[out:json][timeout:300];
(
 way["natural"="water"]{bb}; relation["natural"="water"]{bb};
 way["waterway"~"^(river|canal|riverbank)$"]{bb}; relation["waterway"="riverbank"]{bb};
 way["highway"~"^(motorway|trunk|primary|secondary|tertiary|motorway_link|trunk_link|primary_link)$"]{bb};
 way["highway"~"^(residential|unclassified|living_street|service|pedestrian)$"]{bb};
 way["leisure"~"^(park|golf_course|stadium|pitch)$"]{bb}; relation["leisure"="park"]{bb};
 way["landuse"~"^(cemetery|grass|forest|meadow|recreation_ground|industrial|railway)$"]{bb};
 relation["landuse"~"^(cemetery|forest|industrial)$"]{bb};
 way["natural"~"^(wood|wetland|scrub)$"]{bb}; relation["natural"~"^(wood|wetland)$"]{bb};
 way["man_made"="dyke"]{bb}; way["railway"="rail"]{bb};
);
out geom{bb};""")
    # The sea and the bays open to it (Lake Borgne) have no water polygon,
    # only the coastline, land to its left.
    _fetch(os.path.join(args.out, "coast.json"), f'[out:json][timeout:300];way["natural"="coastline"]{bb};out geom{bb};')


def boundary_bbox(path):
    """S, W, N, E of the boundary relation in a boundary.json."""
    with open(path, encoding="utf-8") as f:
        rel = json.load(f)["elements"][0]
    pts = [p for m in rel["members"] if m["type"] == "way" for p in m.get("geometry") or [] if p]
    return (min(p["lat"] for p in pts), min(p["lon"] for p in pts),
            max(p["lat"] for p in pts), max(p["lon"] for p in pts))


def _buildings(stem, s, w, n, e, depth):
    """The buildings in a box into stem.json, or, if it fails too often,
    its quarters into stem_K.json."""
    query = '[out:json][timeout:300];way["building"](%f,%f,%f,%f);out tags geom;' % (s, w, n, e)
    split = os.path.exists(stem + "_0.json")
    if not split and _fetch(stem + ".json", query, SPLIT_TRIES if depth else TRIES):
        return
    print("splitting", os.path.basename(stem), flush=True)
    for k in range(4):
        qs, qn = (s, (s + n) / 2) if k < 2 else ((s + n) / 2, n)
        qw, qe = (w, (w + e) / 2) if k % 2 == 0 else ((w + e) / 2, e)
        _buildings("%s_%d" % (stem, k), qs, qw, qn, qe, depth - 1)


def _fetch(path, query, tries=TRIES):
    """Fetches query into path, unless it is there already. False if every
    try failed and tries was not the last resort, TRIES."""
    if os.path.exists(path) and os.path.getsize(path) > 100:
        print("have", os.path.basename(path))
        return True
    data = urllib.parse.urlencode({"data": query}).encode()
    for attempt in range(tries):
        _wait_for_slot()
        try:
            req = urllib.request.Request(SERVER, data=data, headers=AGENT)
            with urllib.request.urlopen(req, timeout=400) as r:
                body = r.read()
            json.loads(body)
            with open(path, "wb") as f:
                f.write(body)
            print("got", os.path.basename(path), len(body) // 1024, "KB", flush=True)
            return True
        except Exception as ex:
            # A failure that is not about slots (a timeout, a server under
            # load) backs off: 30 s, then a minute, up to five.
            pause = min(300, 30 * 2 ** attempt)
            print("retry", os.path.basename(path), ex, "in %d s" % pause, flush=True)
            time.sleep(pause)
    if tries < TRIES:
        return False
    raise SystemExit("failed " + path)


def _wait_for_slot():
    """Sleeps until /api/status says one of this address's slots is free."""
    url = SERVER.rsplit("/", 1)[0] + "/status"
    for _ in range(60):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=30) as r:
                status = r.read().decode("utf-8", "replace")
        except Exception:
            return  # No status page; the query itself will say.
        if re.search(r"^[1-9]\d* slots? available now", status, re.M):
            return
        waits = [int(v) for v in re.findall(r"in (\d+) seconds", status)]
        pause = min(waits) + 1 if waits else 15
        print("waiting %d s for a slot" % pause, flush=True)
        time.sleep(pause)


if __name__ == "__main__":
    main()
